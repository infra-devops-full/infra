# Projetos: anatomia e como adicionar

## Anatomia

```
projects/<projeto>/                 # nome da pasta = nome do projeto
├── project.yaml                    # dependências que a plataforma provisiona
├── logo.png                        # logo no Grafana (PNG ~256px)
├── secrets/
│   ├── example.env                 # modelo dos segredos (versionado, valores fictícios)
│   └── <env>.env                   # valores reais (gitignored)
├── sealed/<env>/*.yaml             # segredos SELADOS (make seal, versionados)
└── apps/<app>/                     # nome da pasta = nome do app/Service/imagem
    ├── values.yaml                 # comum a todos os ambientes
    ├── values-develop.yaml         # um arquivo POR AMBIENTE
    └── values-prod.yaml            # o CI atualiza só o image.tag
```

**Tudo é derivado das pastas:**

| Deriva de | Vira |
| --------- | ---- |
| pasta do projeto | prefixo do namespace e label `project` nos logs |
| `apps/<app>/` | nome do Deployment, do Service e da imagem |
| `values-<env>.yaml` | um ambiente: namespace `<projeto>-<env>` e uma Application no ArgoCD |
| `ingress.host` ou a regra padrão | host: `<env>.<app>.<projeto>.local`, sem prefixo em `prod` |

## `project.yaml`: referência

```yaml
appRepo: https://github.com/<owner>/<repo>   # usado pelo `make github` e pelo doctor

database:                 # Postgres por ambiente → Secret `postgres`
  user: app               # SENHAS NÃO VÃO AQUI: `make seal` gera e sela
  defaultDb: app
  extraDbs: [outro_db]    # um banco por serviço, no mesmo Postgres

redis:                    # → Secret `redis` (com senha gerada)
  enabled: true

rabbitmq:                 # → Secret `rabbitmq`
  enabled: true
  user: app

extraHosts: [ferramenta.devops.local]   # hosts extras no /etc/hosts
```

## Secrets que a plataforma cria

Todos (menos o `ghcr-secret`) vêm de **SealedSecrets** em `sealed/<env>/`,
gerados por `make seal`. Veja [12-segredos.md](12-segredos.md).

| Origem | Secret | Chaves |
| ------ | ------ | ------ |
| `database` | `postgres` | `DATABASE_URL`, `DIRECT_URL` (`postgresql://`), `JDBC_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` |
| `redis` | `redis` | `REDIS_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` |
| `rabbitmq` | `rabbitmq` | `RABBITMQ_URL`, `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD` |
| demais chaves do `secrets/<env>.env` | `app-secrets` | as chaves do arquivo |
| `GITHUB_TOKEN` válido no `.env` | `ghcr-secret` | credencial de pull do GHCR |

## `values.yaml`: o que cada app costuma definir

```yaml
image:
  repository: ghcr.io/<owner>/<repo>/<app>    # o que o CI publica
service:
  port: 8080                                  # a porta em que o app ESCUTA
livenessProbe:  { path: /health, initialDelaySeconds: 45 }
readinessProbe: { path: /health, initialDelaySeconds: 20 }
resources:
  limits:   { cpu: 500m, memory: 512Mi }
  requests: { cpu: 50m,  memory: 192Mi }
env:
  NODE_ENV: production
envFrom:
  - secretRef: postgres
  - secretRef: app-secrets
    optional: true            # sobe mesmo sem o Secret
```

Apps que esperam nomes próprios de variável (Spring) montam o valor a partir
dos Secrets com `$(VAR)`. O Kubernetes expande usando o que veio do `envFrom`:

```yaml
env:
  SPRING_DATASOURCE_URL: "jdbc:postgresql://$(DB_HOST):$(DB_PORT)/pricingdb"
  SPRING_DATASOURCE_USERNAME: "$(DB_USER)"
```

Outros campos do chart: `ingress.enabled/host/path`, `autoscaling` (HPA),
`podDisruptionBudget`, `metrics.serviceMonitor`, `initContainers`,
`extraVolumes`. Os defaults estão em
[`charts/app/values.yaml`](../charts/app/values.yaml).

## Adicionar…

| Quero adicionar | Passos |
| --------------- | ------ |
| **um projeto** | `projects/<p>/` com `project.yaml`, `logo.png` e `apps/` → `make seal PROJECT=<p>` → `make helm-lint` → commit/push → `make project-apply PROJECT=<p>` → `make github PROJECT=<p>` → Dockerfile e workflow no repo do app |
| **um app** | `apps/<app>/values.yaml` + um `values-<env>.yaml` por ambiente → item no `APPS_JSON` do workflow do app → commit/push dos dois repos |
| **um ambiente** (ex.: `staging`) | `values-staging.yaml` em cada app → `make seal PROJECT=<p> ENV=staging` → commit → `make project-apply` (cria o namespace e as dependências) → no workflow, mapear a branch para `DEPLOY_ENV=staging` |
| **um microfrontend** | mesmo host do shell + `ingress.path` == `basePath` (veja abaixo) |
| **um banco para um serviço novo** | `extraDbs` no `project.yaml` → `make postgres PROJECT=<p> ENV=<e>` (recria o Postgres; dados de lab se perdem) |

## Microfrontends (Next.js Multi-Zones)

```
develop.wlstore.local/           → shell        (ingress.path: /)
develop.wlstore.local/catalog/*  → catalog-mfe  (ingress.path: /catalog)
develop.wlstore.local/pricing/*  → pricing-mfe  (ingress.path: /pricing)
```

- Todos os fronts usam o **mesmo** `ingress.host` (nos `values-<env>.yaml`).
- Cada mfe tem `ingress.path` igual ao `basePath` do `next.config.js`, único
  no projeto.
- Quem roteia é o **Ingress**. O shell não faz proxy em produção e não precisa
  ser rebuildado quando um time publica um mfe.
- A navegação entre mfes é por `<a>` (recarrega a página). Dentro do mfe, é
  client-side.

O passo a passo do lado do código está no `wlstore-fe/README.md` do repo do
wlstore.
