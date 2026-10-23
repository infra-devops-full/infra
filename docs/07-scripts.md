# Scripts e Makefile: o que cada um faz

Você **não precisa decorar** os scripts. Você opera pelo `make`, e os scripts
são a implementação. Vale entender **qual problema cada um resolve**, para
saber onde olhar quando algo der errado.

## Como eles se encadeiam

```
make setup
  └─ setup.sh
       ├─ doctor.sh                       confere antes de começar
       ├─ (k3d, ingress, argocd, prometheus/grafana — dentro do setup.sh)
       ├─ setup-observability.sh          métricas do ingress, Loki, Alloy
       ├─ apply-project.sh  (por projeto)
       │    ├─ setup-postgres.sh / setup-redis.sh / setup-rabbitmq.sh
       │    ├─ ../create-ghcr-secrets.sh  (se houver GITHUB_TOKEN)
       │    └─ apply-secrets.sh
       ├─ apply-platform.sh               ArgoCD genérico + dashboards
       └─ hosts.sh apply                  /etc/hosts

lib-project.sh  ← usado por quase todos: "quais projetos/apps/ambientes/hosts existem?"
```

## Mapa dos scripts

| Script | Problema que resolve | Comando que o chama |
| ------ | -------------------- | ------------------- |
| `lib-project.sh` | descobrir projetos, apps, ambientes, hosts e dependências a partir de `projects/` (biblioteca) | — |
| `apply-platform.sh` | aplicar `argocd/` e `k8s/`, preenchendo a URL do repo (`envsubst`) | `make apply-argocd`, `make render-platform` |
| `setup-observability.sh` | métricas do Ingress + Loki + Alloy | `make observability` |
| `apply-project.sh` | preparar o que o ArgoCD **não** cria: namespaces, bancos, filas, secrets | `make project-apply` |
| `setup-postgres.sh` | Postgres num namespace + Secret `postgres` (URL, JDBC, `DB_*`) | `make postgres` |
| `setup-redis.sh` / `setup-rabbitmq.sh` | Redis e RabbitMQ + Secrets de conexão | via `apply-project.sh` |
| `apply-secrets.sh` | `secrets/<env>.env` → Secret `app-secrets` | `make secrets` |
| `hosts.sh` | bloco isolado no `/etc/hosts` (só mexe entre os marcadores) | `make hosts` |
| `github-bootstrap.sh` | branch develop, deploy key, proteção da main, CodeQL, Dependabot | `make github` |
| `doctor.sh` | checar ferramentas, tokens, secrets, GitHub, git e Docker antes de quebrar | `make doctor` |
| `99-show-urls.sh` | listar URLs e pods | manual |
| `../create-ghcr-secrets.sh` | `ghcr-secret` (valida o token no GHCR antes) | `make ghcr` |

Todos são **idempotentes**: rodar de novo não quebra nada, só reconcilia.

## Os comandos do Makefile, por frequência de uso

| Frequência | Comandos |
| ---------- | -------- |
| **todo dia** | `status`, `pods`, `apps`, `logs`, `describe`, `events` |
| **quando algo muda** | `project-apply`, `secrets`, `rollout`, `refresh`, `hosts`, `doctor` |
| **raramente** | `setup`, `destroy`, `start`, `stop`, `github`, `observability`, `apply-argocd`, `postgres`, `ghcr` |
| **validar antes do commit** | `helm-lint`, `helm-template`, `render-platform`, `projects` |
| **acesso** | `shell`, `pf`, `grafana`, `argocd`, `prometheus`, `k9s` |
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
| `setup-postgres.sh` | banco gerenciado (RDS/Cloud SQL) ou operador (CloudNativePG) |
| `apply-secrets.sh` | External Secrets / Sealed Secrets / Vault |
| criação do cluster no `setup.sh` | Terraform/OpenTofu |
| `hosts.sh` | DNS real (Route53, Cloudflare) + external-dns |
| `github-bootstrap.sh` | Terraform provider do GitHub |

O **conceito** é o mesmo: os scripts são a ponte do lab até essas ferramentas.
