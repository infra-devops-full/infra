# Banco de dados: Postgres gerenciado, backup e restauração

## O que mudou

Antes, cada projeto tinha um Postgres num Deployment com `emptyDir`: o pod
reiniciou, os dados sumiram. Para lab servia (migrations e seed recriam), mas
não ensina o que importa em produção: **dado não se perde, e backup que nunca
foi restaurado não é backup**.

Agora:

| | Antes | Agora |
| - | ----- | ----- |
| quem cuida | um Deployment escrito à mão | o operador **CloudNativePG** |
| disco | `emptyDir` (some com o pod) | PVC por instância |
| prod | 1 pod | **primário + réplica**, failover automático (`database.instances`; no lab desta máquina, 1) |
| backup | nenhum | WAL contínuo + backup base diário, num S3 **fora do cluster** |
| restaurar | — | `make db-restore` (inclusive para um horário exato) |
| provar que restaura | — | `make db-restore-test` |
| `make destroy && make setup` | bancos vazios | bancos voltam com os dados |
| alertas | só "pod fora" | banco fora, WAL sem backup, backup velho, réplica fora/atrasada |

Os apps não mudam nada: o Secret `postgres` (`DATABASE_URL`, `JDBC_URL`,
`DB_HOST`...) é o mesmo, e o host continua `postgres.<projeto>-<env>.svc`.

## Como funciona

```
 namespace crivo-prod                                      fora do cluster
 ─────────────────────────────────────────                 ──────────────────────
 app ──► Service postgres ──► postgres-1 (primário) ──WAL──► S3 (SeaweedFS)
                               │  streaming                  container devops-lab-backup
                               ▼                             volume Docker devops-lab-backup
                              postgres-2 (réplica)            s3://postgres/crivo-prod/
                                                                 postgres-<data>/wals/  (contínuo)
 operador CloudNativePG (cnpg-system)                            postgres-<data>/base/  (diário)
   cria pods e PVCs, promove a réplica se o primário cair,
   troca o Service, roda os backups (plugin Barman Cloud)
```

- **WAL** (*write-ahead log*): todo commit do Postgres vira WAL antes de
  ir para as tabelas. O sidecar de backup manda cada arquivo de WAL para o
  S3 assim que ele fecha (no máximo a cada 5 min, `archive_timeout`).
- **Backup base**: uma cópia inteira do banco, todo dia às 03:00 (Brasília)
  e uma logo que o banco nasce.
- **Restaurar** = pegar o backup base mais recente antes do horário pedido e
  reaplicar o WAL até aquele instante (**PITR**, *point-in-time recovery*).
  Por isso dá para voltar para "14:29, um minuto antes do `DELETE` errado".
- **Retenção**: 7 dias (`database.backupRetention`). Backup base e WAL mais
  velhos que isso são apagados; a janela de restauração é a última semana.
- **Por que fora do cluster**: backup no mesmo lugar dos dados morre junto.
  Aqui o S3 é um container Docker que o `make destroy` não apaga (como a
  chave do Sealed Secrets e a CA). Na nuvem, é um bucket S3/Spaces/R2 em
  outra conta ou região.

## O que cada projeto recebe

Declarado no `project.yaml` (só `database:` é obrigatório):

```yaml
database:
  user: wlstore
  defaultDb: catalogdb
  extraDbs: [pricingdb]        # um banco por serviço, no mesmo Postgres
  instances:                   # opcional; padrão: prod 2, outros 1
    prod: 2
  storage: 1Gi                 # opcional; disco de cada instância
  backupRetention: 7d          # opcional
```

Por ambiente, o `make project-apply` (`setup-postgres.sh`) cria:

| Recurso | Nome | Para quê |
| ------- | ---- | -------- |
| Cluster | `postgres` | as instâncias (pods `postgres-1`, `postgres-2`...) e seus PVCs |
| Service | `postgres` | sempre o primário, leitura e escrita (é o `DB_HOST`) |
| Services | `postgres-rw`, `postgres-ro`, `postgres-r` | primário, só réplicas, qualquer instância |
| Database | `postgres-<db>` | cada banco de `extraDbs` (criar um novo não recria nada) |
| ObjectStore | `backup` | onde e como guardar (S3, gzip, retenção) |
| ScheduledBackup | `postgres-diario` | backup base diário |
| PodMonitor | `postgres` | métricas no Prometheus |
| Secrets | `postgres-credentials`, `backup-s3` | senha do app no formato do operador; chave do S3 |

Senha nova no `make seal` → `make project-apply`: o operador troca a senha
do usuário no banco sozinho.

## Comandos

```bash
make db-status       PROJECT=crivo ENV=prod   # instâncias, primário, backups, janela de PITR
make db-backup       PROJECT=crivo ENV=prod   # backup base agora (antes de uma migration arriscada)
make db-restore-test PROJECT=crivo ENV=prod   # restaura numa CÓPIA, compara e apaga
make db-restore      PROJECT=crivo ENV=prod TIME="2026-10-26 14:29:00-03"   # volta o banco para esse instante
make db-restore      PROJECT=crivo ENV=prod   # recria do backup até o último WAL
make db-psql         PROJECT=crivo ENV=prod [DB=crivo]
make postgres        PROJECT=crivo ENV=develop # recria VAZIO (os backups antigos ficam)
make data                                      # (re)instala operador, plugin e storage
```

O `db-restore` e o `postgres` pedem para digitar o namespace antes de apagar
(`YES=1` pula, para scripts).

## Cenários

### "Apaguei dados às 14:30" (o mais comum)

1. Descubra o horário **antes** do erro (log do app, `make logs`).
2. Confira se ele está na janela: `make db-status ...` → "de ... até agora".
3. `make db-restore PROJECT=<p> ENV=<e> TIME="2026-10-26 14:29:00-03"`.

O banco inteiro volta para aquele instante, e se perde o que foi escrito
certo depois dele. Quando isso não serve, restaure numa **cópia** ao lado e
traga só as linhas perdidas, sem tirar o banco do ar:

```bash
make db-restore-test PROJECT=<p> ENV=<e> TIME="2026-10-26 14:29:00-03" KEEP=1
kubectl exec -it -n <ns> postgres-restore-test-1 -c postgres -- psql -d <banco>   # consulte/exporte
kubectl delete cluster postgres-restore-test -n <ns>                            # quando terminar
```

### "O cluster inteiro sumiu"

```bash
make setup     # o setup-postgres.sh acha backup do namespace no S3 e RESTAURA
```

É automático: banco novo + backup existente = restauração do mais recente.
Para começar vazio de propósito: `make postgres PROJECT=<p> ENV=<e>`.

### "O primário caiu"

Nada a fazer em prod: o operador promove a réplica em segundos e aponta o
Service `postgres` para ela; depois recria a instância perdida como réplica.
Para ver acontecer:

```bash
kubectl get pods -n crivo-prod -l cnpg.io/cluster=postgres -L cnpg.io/instanceRole -w &
kubectl delete pod -n crivo-prod "$(kubectl get cluster postgres -n crivo-prod -o jsonpath='{.status.currentPrimary}')"
```

Em develop (1 instância) o pod volta no mesmo disco: fica fora uns segundos
e não perde nada.

### Rotina: provar que o backup volta

```bash
make db-restore-test PROJECT=crivo ENV=prod
#   banco              em uso (tab/linhas)  restaurado (tab/linhas)
#   crivo                        19 / 312               19 / 312
#   tempo de restauração: 74s
#   ✅ backup restaurável: mesmos bancos e tabelas
```

O tempo medido é o seu **RTO** real (quanto tempo fica sem banco num
desastre). O **RPO** (quanto dado se perde) é de até 5 min: o WAL que ainda
não fechou.

## Alertas

Gerados em `k8s/prometheus-rules-apps.yaml` (grupo `platform-apps.postgres`),
com `project`/`env`: prod vai para `#alertas`, develop para `#alertas-develop`.

### PostgresDown

Há disco de banco mas nenhuma instância responde há 5 min. Os apps estão sem
banco. `make db-status`; `kubectl describe pod postgres-1 -n <ns>` (sem
memória? PVC?); log: `kubectl logs postgres-1 -c postgres -n <ns>`. Se o disco
se perdeu: `make db-restore`.

### PostgresWALArchiveFailing

WAL acumulando sem ir para o S3: o que é escrito agora não tem backup, e o
PITR para no último arquivo enviado. Quase sempre é o storage:
`docker ps | grep backup` (container parado? `make data` religa) e
`kubectl logs postgres-1 -c plugin-barman-cloud -n <ns> | grep ERROR`.

### PostgresBackupTooOld

O último backup base tem mais de 30h. Restaurar ainda funciona, mas reaplica
WAL demais. `kubectl get backups -n <ns>`; um `failed` tem o motivo em
`kubectl describe backup <nome> -n <ns>`. Força um: `make db-backup`.

### PostgresReplicaMissing

Prod com menos réplicas recebendo WAL do que instâncias - 1: um failover
agora não teria para onde ir. `kubectl get pods -n <ns> -l cnpg.io/cluster=postgres`
(réplica em `Pending` = falta CPU/memória no node; em `CrashLoop` = veja o log).

### PostgresReplicationLag

A réplica está mais de 5 min atrás do primário (carga alta ou node lento).
Se persistir, apague o pod da réplica: o operador a recria a partir do
primário.

## Rede e políticas

- O operador precisa falar com a porta 8000 (status) dos pods de banco. O
  Kyverno gera em todo namespace de projeto a NetworkPolicy
  `allow-from-cnpg-operator`, que libera só isso (docs/14-seguranca.md).
- As imagens `ghcr.io/cloudnative-pg/*` ficam fora da política de assinatura
  (não saem do CI dos projetos; versão fixada em `setup-postgres.sh`).
- Os pods de banco passam pelo `platform-require-resources` como qualquer
  outro (requests/limits no Cluster).

## Na nuvem

| Lab | Nuvem |
| --- | ----- |
| SeaweedFS num container | bucket S3 / DigitalOcean Spaces / Cloudflare R2, de preferência em outra conta, com versionamento e *object lock* |
| `backup-s3` com chave estática | IRSA (AWS) ou Workload Identity: o pod assume um papel, sem chave |
| PVC `local-path` (disco do node) | volume de bloco (EBS, DO Volumes), `storageClass` no Cluster |
| 2 instâncias em 2 nodes | 3 instâncias em 3 zonas |

Alternativa: banco gerenciado (RDS, Cloud SQL, DO Managed Postgres). Some o
operador e o backup fica com o provedor; o Secret `postgres` passa a apontar
para o endpoint dele. O CloudNativePG é a escolha quando se quer o mesmo
comportamento em qualquer lugar (inclusive on-premises) e sem custo por
instância.

## Arquivos

| Arquivo | O quê |
| ------- | ----- |
| `scripts/setup-data.sh` | storage de backup + operador + plugin (`make data`, roda no setup) |
| `scripts/lib-backup.sh` | o container S3: subir, credencial, listar backups |
| `scripts/setup-postgres.sh` | o Postgres de um namespace (restaura se houver backup) |
| `scripts/db.sh` | `make db-*` |
| `config/data/*-values.yaml` | values do operador e do plugin |
| `~/.config/devops-platform/backup/s3.json` | chave do S3 (gerada uma vez, fora do Git) |

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `make project-apply`: `CloudNativePG não instalado` | cluster antigo | `make data` |
| Cluster parado em `Instance Status Extraction Error: HTTP communication issue` | NetworkPolicy sem a liberação do operador | `make apply-argocd` (gera `allow-from-cnpg-operator`) |
| réplica presa em `Creating a new replica` / `pg_basebackup: waiting for checkpoint` | WAL não arquiva (storage fora) | `docker ps -a \| grep backup`; `make data` |
| log do sidecar: `No writable volumes and no free volumes left` | SeaweedFS com blocos grandes demais para o disco | recriar o container com o `lib-backup.sh` atual (`docker rm -f <cluster>-backup && make data`; o volume fica) |
| `make db-restore` com `TIME` fora da janela | pediu antes do primeiro backup base guardado | `make db-status` mostra a janela |
| tudo lento ao criar os bancos | o Docker Desktop no limite de memória (cada instância usa até 512 MB) | `database.instances.prod: 1` no project.yaml, ou mais memória para o Docker (README, seção 9) |
| apps com erro de conexão depois de um restore | pool de conexões preso no banco antigo | `make rollout SERVICE=<app> NAMESPACE=<ns>` |
