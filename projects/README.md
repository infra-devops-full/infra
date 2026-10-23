# Projetos

Cada pasta aqui é uma aplicação implantada pela plataforma. **Só** isto é
específico de um projeto. ArgoCD, chart e manifests de Kubernetes são
genéricos e ficam na raiz (`argocd/`, `charts/app/`, `k8s/`). O passo a passo
completo está no [README principal](../README.md#4-adicionar-um-projeto-novo-passo-a-passo).

```
projects/<projeto>/                  # nome da pasta = nome do projeto
├── project.yaml                     # dependências: database / redis / rabbitmq
├── logo.png                         # logo no dashboard do Grafana (PNG)
├── secrets/
│   ├── example.env                  # valores fictícios de lab (versionado)
│   └── <env>.env                    # valores reais (gitignored, opcional)
└── apps/<app>/                      # nome da pasta = nome do app/Service
    ├── values.yaml                  # comum a todos os ambientes
    └── values-<env>.yaml            # um por ambiente; o CI atualiza image.tag
```

- **Apps** são as pastas em `apps/`.
- **Ambientes** são os `values-<env>.yaml`.
- **Namespace** é `<projeto>-<env>`.
- **Host** é `<env>.<app>.<projeto>.local` (em `prod`, sem prefixo:
  `<app>.<projeto>.local`), a menos que você defina `ingress.host`.
- O ArgoCD injeta `app.name`, `app.environment` e `app.project`, então os
  values não repetem esses dados.

## Exemplos

| Projeto | Mostra |
| ------- | ------ |
| [`crivo/`](crivo) | dois apps (API + front), Postgres, Redis, `app-secrets`, front chamando a API pelo Service interno |
| [`nest-rabbitmq/`](nest-rabbitmq) | um app e RabbitMQ |
| [`wlstore/`](wlstore) | microsserviços Spring (um banco por serviço via `extraDbs`, eventos pelo RabbitMQ, variáveis do Spring montadas com `$(VAR)`) e microfrontends Next em Nx (`catalog-mfe` em `/catalog` e `pricing-mfe` em `/pricing`, no mesmo host do `shell`) |

## Checklist de um projeto novo

- [ ] `project.yaml` (mesmo vazio)
- [ ] `logo.png` (PNG, ~256px), exibido no dashboard do Grafana
- [ ] `apps/<app>/values.yaml` com `image.repository` igual à imagem que o CI publica
- [ ] `service.port` igual à porta que o container escuta
- [ ] `apps/<app>/values-<env>.yaml` para cada ambiente, com `image.tag`
- [ ] `envFrom` com os Secrets das dependências (`postgres`, `redis`, `rabbitmq`, `app-secrets`)
- [ ] `make helm-lint` sem erro
- [ ] commit e push deste repo, depois `make project-apply PROJECT=<projeto>`
- [ ] no repo do app: Dockerfile (`templates/`), `.github/workflows/deploy.yml` (com `setup`/`test` de cada app) e `.github/dependabot.yml`
- [ ] `make github PROJECT=<projeto>` (deploy key, `develop`, `main` protegida com check `ci`, CodeQL, Dependabot) e `make doctor` sem erros
