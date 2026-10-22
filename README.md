# DevOps Platform

Plataforma **genérica** de Kubernetes local com GitOps. Um cluster k3d com
NGINX Ingress, ArgoCD, Prometheus e Grafana. Cada aplicação entra como um
**projeto** em `projects/<nome>/` com o mínimo de arquivos.

Tudo fora de `projects/` é genérico e não cita nenhuma aplicação:

| Pasta | O que é |
| ----- | ------- |
| `argocd/` | **um** AppProject e **um** ApplicationSet que descobrem os apps de todos os projetos no Git |
| `charts/app/` | **um** chart Helm usado por todos os apps (Deployment, Service, Ingress, HPA, PDB, ServiceMonitor) |
| `k8s/` | manifests da plataforma, como o dashboard genérico do Grafana |
| `scripts/` | setup de projeto, dependências (Postgres, Redis, RabbitMQ), secrets e `/etc/hosts` |
| `templates/` | Dockerfiles (NestJS, Next.js) e o workflow de CI para os repos dos apps |

```
Repo do app (crivo, microservice-with-nestjs-rabbitmq, ...)
   │  push na main
   ▼
GitHub Actions ── build ──► ghcr.io/<owner>/<repo>/<app>:sha-xxxxxxx
   │
   └─ commit ──► ESTE repo: projects/<projeto>/apps/<app>/values-develop.yaml
                    │  (image.tag = sha-xxxxxxx)
                    ▼
     ArgoCD ApplicationSet (argocd/) ──sync──► namespace <projeto>-develop
                                                   │
                                   Prometheus/Grafana coletam métricas
```

## Como um projeto é descoberto

```
projects/<projeto>/
├── project.yaml                  # dependências: database, redis, rabbitmq
├── secrets/example.env           # segredos de lab (opcional)
└── apps/<app>/
    ├── values.yaml               # imagem, porta, probes, env, envFrom
    ├── values-develop.yaml       # um arquivo por ambiente
    └── values-prod.yaml
```

Cada arquivo `apps/<app>/values-<env>.yaml` no Git **é** um deploy:

| Derivado do caminho | Exemplo (`projects/crivo/apps/crivo-be/values-develop.yaml`) |
| ------------------- | ------------------------------------------------------------ |
| Application no ArgoCD | `crivo-be-develop` (vira `<projeto>-<app>-<env>` se o app não começar com o nome do projeto) |
| Namespace | `crivo-develop` |
| Host | `develop.crivo-be.crivo.local` (ou `ingress.host` dos values) |
| Release / Service | `crivo-be` |

Novo app, novo ambiente ou novo projeto = novos arquivos em `projects/`, um
commit e um push. O ArgoCD encontra sozinho. Nada em `argocd/`, `charts/` ou
`k8s/` muda.

Projetos incluídos:

| Projeto | Apps | Dependências |
| ------- | ---- | ------------ |
| [`crivo`](projects/crivo) | `crivo-be` (NestJS, :8080), `crivo-fe` (Next.js, :3000) | Postgres, Redis |
| [`nest-rabbitmq`](projects/nest-rabbitmq) | `products` (NestJS, :3000) | RabbitMQ |

---

## 1. Pré-requisitos

```bash
brew install k3d kubectl helm yq gettext   # gettext traz o envsubst
brew install --cask docker                 # ou OrbStack / Colima
brew install k9s                           # opcional
```

O Docker precisa estar rodando, com pelo menos 8 GB de RAM.

## 2. Configurar o `.env`

```bash
cp .env.template .env
```

| Variável | Para quê |
| -------- | -------- |
| `CLUSTER_NAME` | nome do cluster k3d (default `devops-lab`) |
| `DATA_DIR` | volumes do cluster **no disco do Mac** (default `~/.devops-lab`) |
| `GITHUB_TOKEN` | PAT com `read:packages`, para o cluster baixar imagens privadas do GHCR |
| `GITHUB_USERNAME` | seu usuário do GitHub |
| `INFRA_REPO_URL` | opcional; repo que o ArgoCD observa (default: `git remote origin`) |
| `INFRA_BRANCH` | opcional; branch observada (default `main`) |

> `DATA_DIR` não depende de SSD externo. Para usar um, aponte para ele, por
> exemplo `DATA_DIR=/Volumes/Backup/devops-lab`.

## 3. Subir a plataforma

**Antes**, faça commit e push deste repo. O ArgoCD lê `projects/` do GitHub,
não da sua máquina.

```bash
make setup
```

O setup pede confirmação e a senha do `sudo` (por causa do `/etc/hosts`). Leva
de 10 a 15 minutos na primeira vez. Ele:

1. cria o cluster k3d, com volumes em `DATA_DIR`;
2. instala o NGINX Ingress, o ArgoCD e o kube-prometheus-stack;
3. para cada projeto, cria os namespaces, as dependências (Postgres, Redis,
   RabbitMQ), o `ghcr-secret` e o `app-secrets`;
4. aplica `argocd/` e `k8s/`. A partir daí, o ApplicationSet cria os apps;
5. grava os hosts no `/etc/hosts`, num **bloco isolado** entre
   `# >>> devops-platform >>>` e `# <<< devops-platform <<<`. Entradas suas
   fora desse bloco não são tocadas.

```bash
make status          # cluster, namespaces, apps do ArgoCD, pods e URLs
make projects        # projetos, apps e ambientes descobertos
```

| Ferramenta | URL | Login |
| ---------- | --- | ----- |
| ArgoCD | http://argocd.devops.local | `admin` / senha exibida no `make status` |
| Grafana | http://grafana.devops.local | `admin` / `devops.local2026` |
| Prometheus | http://prometheus.devops.local | — |
| AlertManager | http://alertmanager.devops.local | — |

## 4. Adicionar um projeto novo (passo a passo)

### 4.1 Neste repo (infra)

1. Crie a pasta. O nome da pasta é o nome do projeto:
   ```bash
   mkdir -p projects/meu-app/apps/api
   ```
2. Em `projects/meu-app/project.yaml`, declare só as dependências (pode ficar
   vazio). Veja os exemplos em [`projects/crivo`](projects/crivo/project.yaml)
   e [`projects/nest-rabbitmq`](projects/nest-rabbitmq/project.yaml).
3. Em `apps/api/values.yaml`, defina `image.repository`, `service.port`, o
   path das probes, `env` e `envFrom` (os Secrets que a plataforma cria estão
   na tabela abaixo).
4. Crie um `apps/api/values-<env>.yaml` para cada ambiente, com pelo menos
   `image.tag: latest`.
5. Se houver segredos, crie `secrets/example.env` com valores fictícios. Os
   reais vão em `secrets/<env>.env`, que é gitignored.
6. Valide sem cluster:
   ```bash
   make projects
   make helm-lint
   make helm-template PROJECT=meu-app APP=api ENV=develop
   ```
7. Faça commit e push, e prepare o projeto no cluster que já está rodando:
   ```bash
   make project-apply PROJECT=meu-app   # namespaces, dependências, secrets, /etc/hosts
   ```
   O ArgoCD cria os apps sozinho (consulta o Git a cada ~3 min; para não
   esperar, use *Refresh*).

Secrets que a plataforma cria em cada namespace `<projeto>-<env>`:

| `project.yaml` | Secret | Chaves |
| -------------- | ------ | ------ |
| `database: {user, password, defaultDb, extraDbs}` | `postgres` | `DATABASE_URL`, `DIRECT_URL` |
| `redis: {enabled: true, password?}` | `redis` | `REDIS_URL`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` |
| `rabbitmq: {enabled: true, user, password}` | `rabbitmq` | `RABBITMQ_URL`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD` |
| `secrets/<env>.env` (ou `example.env`) | `app-secrets` | as chaves do arquivo |
| `GITHUB_TOKEN` no `.env` | `ghcr-secret` | pull de imagens do GHCR |

Também vale `extraHosts: [...]` no `project.yaml`, para hosts extras no
`/etc/hosts`.

### 4.2 No repo do app

| Template | Para |
| -------- | ---- |
| [`templates/nestjs/`](templates/nestjs) | Dockerfile e `.dockerignore` de um app NestJS |
| [`templates/nextjs/`](templates/nextjs) | Dockerfile e `.dockerignore` de um app Next.js |
| [`templates/github/deploy.yml`](templates/github/deploy.yml) | CI: build, push no GHCR e commit da tag aqui |

1. Copie o Dockerfile para a pasta do app e o `deploy.yml` para
   `.github/workflows/`.
2. No `deploy.yml`, ajuste `INFRA_PROJECT`, `matrix.include` (uma entrada por
   app: `app`, `context`, `dockerfile`, `build-args`) e `APPS`.
3. Crie um PAT fine-grained com *Contents: Read and write* **no repo de
   infra** e salve-o no repo do app:
   ```bash
   gh secret set INFRA_REPO_TOKEN --repo <owner>/<repo-do-app>
   ```
4. Faça commit e push na `main` do app.

> **Next.js:** `NEXT_PUBLIC_*` é embutido no **build**. Para uma imagem servir
> todos os ambientes, passe em `build-args` uma URL igual em qualquer
> namespace, como o Service interno da API (`http://crivo-be:8080`). Isso
> funciona quando só o servidor Next chama a API. É o caso do crivo.

### 4.3 Testar o deploy

1. **GitHub Actions** (repo do app): o `build` publica as imagens, e o
   `deploy` faz commit da tag em `values-develop.yaml` aqui.
2. **Imagem privada?** `make ghcr NAMESPACES="<p>-develop <p>-prod"
   TOKEN=<pat-read-packages>`, ou deixe o pacote público no GitHub
   (Packages → Package settings).
3. **ArgoCD** (http://argocd.devops.local): `<app>-develop` fica *Synced /
   Healthy*.
4. **App**: `curl http://develop.<app>.<projeto>.local`. Se o `.local`
   demorar a resolver: `curl --resolve <host>:80:127.0.0.1 http://<host>`.
5. **Grafana** (http://grafana.devops.local): abra a pasta *Platform* e o
   dashboard *Platform / Apps*, e filtre por namespace e app. Também servem os
   dashboards padrão *Kubernetes / Compute Resources / Namespace (Pods)*.

> Antes do primeiro build, os apps ficam em `ImagePullBackOff`, porque a tag
> `latest` ainda não existe. Isso é esperado.

### 4.4 Promover para prod

```bash
TAG=$(yq '.image.tag' projects/crivo/apps/crivo-be/values-develop.yaml)
yq -i ".image.tag = \"$TAG\"" projects/crivo/apps/crivo-be/values-prod.yaml
git commit -am "deploy(crivo/prod): crivo-be → $TAG" && git push
```

## 5. Comandos

```bash
make help                 # todos os comandos
make setup | status | destroy
make start | stop | restart
make projects             # projetos, apps e ambientes descobertos
make project-apply PROJECT=<p>                 # deps + secrets + hosts de um projeto
make secrets  PROJECT=<p> ENV=<e>              # recria o app-secrets
make postgres PROJECT=<p> ENV=<e> [RESET_DATA=1]
make apply-argocd         # reaplica argocd/ + k8s/
make render-platform      # mostra argocd/ + k8s/ renderizados
make hosts                # regrava o bloco do /etc/hosts
make helm-lint            # valida todos os values-<env>.yaml
make helm-template PROJECT=<p> APP=<a> ENV=<e>
make ghcr NAMESPACES="ns1 ns2" [TOKEN=...]
make logs SERVICE=<app> NAMESPACE=<p>-<env>
```

## 6. Estrutura

```
.
├── setup.sh / destroy.sh / status.sh / Makefile
├── argocd/                       # AppProject + ApplicationSet genéricos (envsubst)
├── charts/app/                   # chart Helm genérico
├── k8s/                          # dashboards e manifests da plataforma
├── config/                       # k3d-config.tmpl.yaml, storage-class.yaml
├── scripts/
│   ├── lib-project.sh            # descoberta de projetos/apps/ambientes
│   ├── apply-project.sh          # namespaces + dependências + secrets
│   ├── apply-platform.sh         # argocd/ + k8s/
│   ├── apply-secrets.sh          # Secret app-secrets
│   ├── setup-postgres.sh / setup-redis.sh / setup-rabbitmq.sh
│   ├── hosts.sh                  # bloco isolado no /etc/hosts
│   └── 99-show-urls.sh
├── create-ghcr-secrets.sh
├── templates/                    # nestjs/, nextjs/, github/deploy.yml
└── projects/
    ├── crivo/
    └── nest-rabbitmq/
```

## 7. Problemas comuns

| Sintoma | Causa provável | Solução |
| ------- | -------------- | ------- |
| App não aparece no ArgoCD | `projects/` não foi pushado, ou falta `values-<env>.yaml` | `git push`; *Refresh* no ApplicationSet |
| `ImagePullBackOff` | a imagem ainda não foi publicada, ou o pacote é privado sem `ghcr-secret` | rodar o CI do app; `make ghcr …` |
| `CreateContainerConfigError` | falta um Secret do `envFrom` | `make project-apply PROJECT=<p>` |
| API reinicia em loop | segredo obrigatório ausente | conferir `secrets/<env>.env` e rodar `make secrets …` |
| `*.local` não resolve | cache mDNS do macOS | `make hosts`, ou `curl --resolve host:80:127.0.0.1` |
| Job `deploy` do CI falha no push | `INFRA_REPO_TOKEN` ausente ou sem escrita | recriar o PAT com *Contents: Read and write* |

## 8. Destruir

```bash
make destroy
```

Remove o cluster, o bloco do `/etc/hosts` e o contexto do kubeconfig. Antes de
apagar o `DATA_DIR`, ele pergunta.
