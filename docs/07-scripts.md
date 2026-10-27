# Scripts e Makefile: o que cada um faz

Você **não precisa decorar** os scripts. Você opera pelo `make`, e os scripts
são a implementação. Vale entender **qual problema cada um resolve**, para
saber onde olhar quando algo der errado.

## Como eles se encadeiam

```
make setup
  └─ setup.sh
       ├─ doctor.sh                       confere antes de começar
       ├─ (k3d, ingress — dentro do setup.sh)
       ├─ setup-security.sh               cert-manager + CA local, Kyverno
       ├─ (argocd — dentro do setup.sh)
       ├─ setup-observability.sh          Prometheus/Alertmanager/Grafana, métricas, Loki, Alloy
       ├─ setup-delivery.sh               Argo Rollouts (canary)
       ├─ setup-data.sh                   CloudNativePG + backup (S3 fora do cluster)
       ├─ setup-tracing.sh                Tempo + OpenTelemetry Operator
       ├─ setup-sealed-secrets.sh         controller + restaura/backup da chave
       ├─ apply-project.sh  (por projeto)
       │    ├─ kubectl apply sealed/<env>/  (SealedSecrets → Secrets)
       │    ├─ setup-postgres.sh / setup-redis.sh / setup-rabbitmq.sh  (leem os Secrets)
       │    └─ ../create-ghcr-secrets.sh  (se houver GITHUB_TOKEN)
       ├─ apply-platform.sh               ArgoCD genérico + dashboards + regras de alerta
       └─ hosts.sh apply                  /etc/hosts

lib-project.sh  ← usado por quase todos: "quais projetos/apps/ambientes/hosts existem?"
```

## Mapa dos scripts

| Script | Problema que resolve | Comando que o chama |
| ------ | -------------------- | ------------------- |
| `lib-project.sh` | descobrir projetos, apps, ambientes, hosts e dependências a partir de `projects/` (biblioteca) | — |
| `apply-platform.sh` | aplicar `argocd/` e `k8s/`, preenchendo a URL do repo (`envsubst`) | `make apply-argocd`, `make render-platform` |
| `setup-observability.sh` | kube-prometheus-stack (values em `config/observability/`), métricas do Ingress e do ArgoCD, Loki, Alloy | `make observability` |
| `dev/gen-prometheus-rules.py`, `dev/gen-dashboard-slo.py` | gerar `k8s/prometheus-rules-apps.yaml` e o dashboard de SLO (edite os geradores, não o YAML) | `make gen-observability` |
| `apply-project.sh` | preparar o que o ArgoCD **não** cria: namespaces, SealedSecrets (antes das dependências), bancos, filas | `make project-apply` |
| `setup-security.sh` | cert-manager + CA local (backup/restauração da CA) e Kyverno | `make security` |
| `setup-delivery.sh` | Argo Rollouts (controller + dashboard) | `make delivery` |
| `rollback.sh` | voltar a versão de um projeto/ambiente pelo Git (commit + push + refresh do ArgoCD) | `make rollback` |
| `policy-check.sh` | testar as políticas do Kyverno contra todos os apps renderizados, sem cluster | `make policy-check` |
| `setup-sealed-secrets.sh` | instalar o controller do Sealed Secrets e fazer backup/restauração da chave | `make sealed-secrets` |
| `seal-secrets.sh` | `secrets/<env>.env` → `sealed/<env>/*.yaml` (gera senhas de infra que faltarem) | `make seal` |
| `setup-data.sh` | storage de backup (S3 num container fora do cluster), operador CloudNativePG e plugin de backup | `make data` |
| `setup-tracing.sh` | Tempo (traces + métricas geradas) e OpenTelemetry Operator (agentes injetados) | `make tracing` |
| `terraform.sh` | Terraform da nuvem (local ou em Docker): `check` = fmt + validate + tflint + trivy | `make cloud-check`, `make cloud TF=...` |
| `cloud-backup-env.sh` | outputs do Terraform → config de backup do cluster da nuvem | `make cloud-backup-env` |
| `setup-postgres.sh` | Postgres de um namespace (Cluster do CloudNativePG, backups, bancos extras); restaura do backup se houver | `make postgres`, via `apply-project.sh` |
| `db.sh` | status, backup, restauração (PITR), teste de restauração e psql | `make db-*` |
| `setup-redis.sh` / `setup-rabbitmq.sh` | Redis e RabbitMQ, com credenciais dos Secrets `redis`/`rabbitmq` | via `apply-project.sh` |
| `hosts.sh` | bloco isolado no `/etc/hosts` (só mexe entre os marcadores) | `make hosts` |
| `github-bootstrap.sh` | branch develop, deploy key, proteção da main, CodeQL, Dependabot | `make github` |
| `doctor.sh` | checar ferramentas, tokens, secrets, GitHub, git e Docker antes de quebrar | `make doctor` |
| `99-show-urls.sh` | listar URLs e pods | manual |
| `../create-ghcr-secrets.sh` | `ghcr-secret` (valida o token no GHCR antes) | `make ghcr` |

Todos são **idempotentes**: rodar de novo não quebra nada, só reconcilia.

## Os comandos do Makefile, por frequência de uso

| Frequência | Comandos |
| ---------- | -------- |
| **todo dia** | `status`, `alerts`, `policies`, `rollouts`, `pods`, `apps`, `logs`, `describe`, `events` |
| **num deploy em prod** | `release`, `rollouts`, `promote`, `abort`, `retry`, `rollback` |
| **quando algo muda** | `project-apply`, `seal`, `rollout`, `refresh`, `hosts`, `doctor` |
| **raramente** | `setup`, `destroy`, `start`, `stop`, `github`, `observability`, `security`, `trust-ca`, `sealed-secrets`, `apply-argocd`, `postgres`, `ghcr` |
| **validar antes do commit** | `helm-lint`, `helm-template`, `render-platform`, `gen-observability`, `policy-check`, `projects` |
| **acesso** | `shell`, `pf`, `grafana`, `argocd`, `prometheus`, `alertmanager`, `k9s` |
| **treino** | `lab-up`, `lab-status`, `lab-down` |

`make help` lista todos, com o uso de cada um.

## Como ler um script quando precisar

1. O **cabeçalho** de cada script explica o que ele faz e como usar.
2. Procure os `kubectl apply` e `helm upgrade`: eles mostram o que é criado.
3. Rode só a parte que interessa. Vários aceitam modo de visualização:
   `./scripts/hosts.sh show`, `./scripts/apply-platform.sh --render`,
   `./scripts/github-bootstrap.sh --dry-run`.

## Por que scripts (e o que os substitui em produção)

| Aqui (script) | Em produção, costuma virar |
| ------------- | -------------------------- |
| `setup-postgres.sh` (CloudNativePG) | o mesmo operador num cluster gerenciado, ou banco gerenciado (RDS/Cloud SQL) |
| `seal-secrets.sh` (Sealed Secrets) | External Secrets + Vault/AWS Secrets Manager |
| criação do cluster no `setup.sh` | Terraform/OpenTofu (`terraform/digitalocean/`, [23-nuvem.md](23-nuvem.md)) |
| `hosts.sh` | DNS real (Route53, Cloudflare) + external-dns |
| `github-bootstrap.sh` | Terraform provider do GitHub |

O **conceito** é o mesmo: os scripts são a ponte do lab até essas ferramentas.
