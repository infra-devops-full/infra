# Segredos com Sealed Secrets

## O problema e a solução

Segredo em texto puro no Git é vazamento permanente: o histórico guarda para
sempre. Mas sem os segredos no Git, o GitOps fica incompleto, porque o cluster
não pode ser recriado só a partir do repositório.

O **Sealed Secrets** resolve as duas coisas:

```
 sua máquina                         Git                         cluster
 ───────────                         ───                         ───────
 secrets/<env>.env  ──make seal──►  sealed/<env>/*.yaml  ──ArgoCD──►  SealedSecret
 (texto puro,          (criptografa     (criptografado:                    │ controller
  gitignored)           com cert.pem)    seguro commitar)                  ▼ (chave privada)
                                                                         Secret
                                                                           │ envFrom
                                                                           ▼
                                                                          app
```

- A **chave pública** (`config/sealed-secrets/cert.pem`, versionada) só
  **fecha**. Qualquer um pode selar.
- A **chave privada** fica no controller do cluster e no seu backup. Só ela
  **abre**.
- Um arquivo selado só abre **no namespace e com o nome** para os quais foi
  selado. Copiar o `postgres.yaml` de develop para prod não funciona.

## Onde fica cada coisa

| O quê | Onde | Vai pro Git? |
| ----- | ---- | ------------ |
| valores reais (senhas, API keys) | `projects/<p>/secrets/<env>.env` | **não** (gitignored, `chmod 600`) |
| valores fictícios de lab (modelo) | `projects/<p>/secrets/example.env` | sim |
| segredos selados | `projects/<p>/sealed/<env>/*.yaml` | **sim** |
| chave pública | `config/sealed-secrets/cert.pem` | sim |
| chave privada (backup) | `~/.config/devops-platform/sealed-secrets/keys.yaml` | **nunca** |
| usuário e banco (não são segredo) | `project.yaml` (`database.user`, `defaultDb`) | sim |

O `project.yaml` **não tem mais senha nenhuma**. O `make doctor` acusa erro se
alguma aparecer.

## O que o `make seal` gera

| Arquivo | Quando | Chaves |
| ------- | ------ | ------ |
| `postgres.yaml` | `database` no project.yaml | `DATABASE_URL`, `DIRECT_URL`, `JDBC_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` |
| `rabbitmq.yaml` | `rabbitmq.enabled` | `RABBITMQ_URL`, `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD` |
| `redis.yaml` | `redis.enabled` | `REDIS_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` |
| `app-secrets.yaml` | há chaves no `<env>.env` além das reservadas | todas as outras chaves do `<env>.env` |

As senhas de infra (`DB_PASSWORD`, `RABBITMQ_PASSWORD`, `REDIS_PASSWORD`) são
**geradas aleatoriamente** (32 caracteres hex) na primeira vez e gravadas no
`<env>.env`. Assim, um novo `make seal` mantém as mesmas senhas. Cada ambiente
tem as suas.

Postgres, Redis e RabbitMQ leem usuário e senha **desses mesmos Secrets**, então
não há credencial em script nem em argumento de linha de comando.

## Dia a dia

### Mudar ou adicionar um segredo do app

```bash
$EDITOR projects/crivo/secrets/develop.env     # ex.: STRIPE_SECRET_KEY=sk_live_...
make seal PROJECT=crivo ENV=develop
git add projects/crivo/sealed && git commit -m "secrets(crivo/develop): stripe" && git push
# o ArgoCD aplica; o app só lê env na subida:
make rollout SERVICE=crivo-be NAMESPACE=crivo-develop
```

### Rotacionar uma senha de infra

```bash
sed -i '' '/^DB_PASSWORD=/d' projects/wlstore/secrets/prod.env   # apaga a atual
make seal PROJECT=wlstore ENV=prod                               # gera outra
git add projects/wlstore/sealed && git commit -m "secrets(wlstore/prod): rotaciona db" && git push
make project-apply PROJECT=wlstore     # aplica e recria o Postgres (checksum do Secret mudou)
make rollout SERVICE=catalog-service NAMESPACE=wlstore-prod
make rollout SERVICE=pricing-service NAMESPACE=wlstore-prod
```

> Durante a rotação, aparecem alguns `password authentication failed` no log
> do Postgres por ~1 a 2 min. São os pods **antigos** do app (ainda no ar
> durante o rolling update) tentando reconectar com a senha velha. Param quando
> eles terminam. É esperado.

> Neste lab, recriar o Postgres recria os dados (`emptyDir`). Em produção, a
> rotação é feita no banco (`ALTER USER … PASSWORD`) sem recriá-lo.

### Projeto novo

```bash
make seal PROJECT=<p>          # cria secrets/<env>.env a partir do example.env e gera tudo
git add projects/<p>/sealed && git commit && git push
make project-apply PROJECT=<p>
```

## A chave privada: backup e recuperação de desastre

O `make sealed-secrets` (e o `make setup`):

1. **restaura** a chave de `~/.config/devops-platform/sealed-secrets/keys.yaml`,
   se existir, **antes** de instalar o controller, que adota a chave
   existente;
2. instala o controller (chart 2.20.0, sem renovação automática de chave);
3. **faz backup** da chave nesse mesmo arquivo (`chmod 600`);
4. grava a chave pública em `config/sealed-secrets/cert.pem`.

O `make destroy` **nunca** apaga esse diretório. Mesmo assim, guarde uma cópia
fora da máquina (gerenciador de senhas, cofre). Se perder a chave e o cluster
junto, os arquivos selados do Git ficam ilegíveis. Aí só resta gerar segredos
novos (`make seal`) a partir dos `.env` locais.

### Conferir que o backup abre os arquivos (sem cluster)

```bash
kubeseal --recovery-unseal \
  --recovery-private-key ~/.config/devops-platform/sealed-secrets/keys.yaml \
  < projects/wlstore/sealed/prod/postgres.yaml -o yaml
```

### Usar o backup numa máquina ou num cluster novo

```bash
mkdir -p ~/.config/devops-platform/sealed-secrets
cp /caminho/do/backup/keys.yaml ~/.config/devops-platform/sealed-secrets/
make setup        # restaura a chave antes de subir o controller
make doctor       # "a chave do cluster é a mesma do cert.pem commitado"
```

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `make doctor`: "a chave do cluster é DIFERENTE do cert.pem" | cluster recriado sem o backup da chave | restaurar o `keys.yaml` e `make sealed-secrets`; ou `make seal` em todos os projetos e commitar |
| `kubectl describe sealedsecret <s>`: `no key could decrypt secret` | selado com outra chave | mesma solução acima |
| SealedSecret não cria o Secret: `already exists and is not managed by SealedSecret` | Secret antigo criado à mão | o `make project-apply` anota `sealedsecrets.bitnami.com/managed=true` e adota |
| app sobe com a senha antiga | o app lê env só na subida | `make rollout SERVICE=<app> NAMESPACE=<ns>` |
| `make seal`: `cert.pem não existe` | controller nunca instalado | `make sealed-secrets` com o cluster no ar |
| `git status` mostra `sealed/` alterado sem você mudar nada | selar de novo gera criptografia diferente (chave de sessão aleatória) | commite só quando quiser mudar; `git checkout projects/<p>/sealed` desfaz |

## Referência

- `scripts/setup-sealed-secrets.sh`: controller e chave (`make sealed-secrets`).
- `scripts/seal-secrets.sh`: gera os SealedSecrets (`make seal`).
- `argocd/applicationset-secrets.yaml`: cada `projects/<p>/sealed/<env>/` vira
  a Application `<p>-secrets-<env>`.
- Próximos passos possíveis: **External Secrets** com Vault ou AWS Secrets
  Manager (o segredo nem passa pelo Git), e **Reloader** (reinicia o app
  sozinho quando o Secret muda).
