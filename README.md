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

## 2. Tokens e variáveis (tudo que precisa configurar)

Resumo do que configurar e onde. Nada disso vai para o Git: `.env` e
`secrets/<env>.env` são gitignored, e os tokens ficam nos secrets do GitHub.

| # | O quê | Onde | Obrigatório? |
| - | ----- | ---- | ------------ |
| 1 | `.env` da plataforma | este repo (infra), na sua máquina | sim |
| 2 | `INFRA_REPO_TOKEN` | **GitHub Secrets de cada repo de app** | sim, para o CI atualizar a tag |
| 3 | `GITHUB_TOKEN` (PAT classic `read:packages`) | `.env` da infra | só se alguma imagem for **privada** |
| 4 | variáveis não sensíveis do app | `projects/<p>/apps/<app>/values*.yaml` → `env:` | conforme o app |
| 5 | segredos do app | `projects/<p>/secrets/<env>.env` | conforme o app |

> **O repo do app não precisa de `.env` nem de outros secrets para o deploy.**
> O único secret que você cria nele é o `INFRA_REPO_TOKEN`. O push da imagem
> usa o `GITHUB_TOKEN` automático do Actions (o workflow já pede
> `packages: write`). As variáveis de runtime do app ficam **neste** repo
> (itens 4 e 5).

### 2.1 `.env` da plataforma (repo de infra)

```bash
cp .env.template .env
```

| Variável | Obrigatória | Default | Para quê |
| -------- | ----------- | ------- | -------- |
| `CLUSTER_NAME` | não | `devops-lab` | nome do cluster k3d |
| `DATA_DIR` | não | `$HOME/.devops-lab` | volumes do cluster **no disco do Mac**. Para usar o SSD externo: `/Volumes/Backup/devops-lab` |
| `INFRA_REPO_URL` | não | `git remote origin` | repo que o ArgoCD observa |
| `INFRA_BRANCH` | não | `main` | branch que o ArgoCD observa |
| `GITHUB_USERNAME` | só com `GITHUB_TOKEN` | — | seu usuário do GitHub (`geraldobl58`) |
| `GITHUB_TOKEN` | só p/ imagem privada | — | **PAT classic** com `read:packages` (item 2.3). Vira o `ghcr-secret` dos namespaces |

> Se suas imagens são públicas (o padrão para pacotes de repos públicos),
> deixe `GITHUB_TOKEN` vazio ou com o placeholder. Um token **inválido** é
> pior que nenhum: o pod envia a credencial e o GHCR responde 403 até para
> imagem pública. Por isso o `create-ghcr-secrets.sh` valida o token e não
> cria o secret se o GHCR recusar.

### 2.2 Secrets do GitHub em cada repo de app

| Secret | Valor | Comando |
| ------ | ----- | ------- |
| `INFRA_REPO_TOKEN` | PAT **fine-grained** com *Contents: Read and write* no repo de infra (item 2.3) | `gh secret set INFRA_REPO_TOKEN --repo <owner>/<repo-do-app>` |

Repos atuais:

```bash
gh secret set INFRA_REPO_TOKEN --repo geraldobl58/crivo
gh secret set INFRA_REPO_TOKEN --repo geraldobl58/microservice-with-nestjs-rabbitmq
gh secret list --repo geraldobl58/crivo      # conferir
```

O `gh secret set` pede o valor no terminal, então ele não fica no histórico do
shell. Sem esse secret, o job `build` publica a imagem, mas o `deploy` falha
com `INFRA_REPO_TOKEN ausente`, e nada muda no cluster.

Não são secrets, mas ficam no `deploy.yml` de cada app (bloco `env` e
`matrix.include`):

| Campo | Exemplo (crivo) |
| ----- | --------------- |
| `INFRA_REPO` | `infra-devops-full/infra` |
| `INFRA_PROJECT` | `crivo` |
| `DEPLOY_ENV` | `develop` |
| `matrix.include[].build-args` | `NEXT_PUBLIC_API_URL=http://crivo-be:8080` |
| `APPS` | `crivo-be crivo-fe` |

### 2.3 Como criar cada token

**`INFRA_REPO_TOKEN`** (PAT fine-grained, escrita no repo de infra):

1. https://github.com/settings/personal-access-tokens/new
2. **Resource owner**: `infra-devops-full` (a org dona do repo de infra). Se a
   org não aparecer, um admin dela precisa permitir PATs fine-grained em
   *Org Settings → Personal access tokens*.
3. **Repository access**: *Only select repositories* → `infra`.
4. **Permissions → Repository → Contents**: *Read and write*.
5. Gere o token e salve-o com `gh secret set` nos repos de app (item 2.2).
   O mesmo token serve para todos eles.

**`GITHUB_TOKEN` do `.env`** (PAT **classic**, só para imagens privadas):

1. https://github.com/settings/tokens/new?scopes=read:packages
2. Marque só `read:packages` e gere.
3. Cole em `GITHUB_TOKEN=` no `.env` e rode `make ghcr NAMESPACES="<p>-develop <p>-prod"`
   (ou `make project-apply PROJECT=<p>`).

> O GHCR **não aceita PAT fine-grained** (`github_pat_…`) para pull. Precisa
> ser classic (`ghp_…`).

### 2.4 Variáveis de ambiente dos apps (runtime)

Ficam neste repo, separadas por sensibilidade:

| Tipo | Onde | Versionado? | Como chega no pod |
| ---- | ---- | ----------- | ----------------- |
| Não sensível, igual em todo ambiente | `apps/<app>/values.yaml` → `env:` | sim | env do container |
| Não sensível, por ambiente (URLs, flags) | `apps/<app>/values-<env>.yaml` → `env:` | sim | env do container (sobrescreve) |
| Segredo (JWT, Stripe, API keys) | `projects/<p>/secrets/<env>.env` | **não** | Secret `app-secrets` → `envFrom` |
| Segredo de lab (fictício) | `projects/<p>/secrets/example.env` | sim | fallback quando falta o `<env>.env` |
| Conexões (Postgres/Redis/RabbitMQ) | geradas pela plataforma a partir do `project.yaml` | — | Secrets `postgres` / `redis` / `rabbitmq` → `envFrom` |

Depois de mudar um `secrets/<env>.env`:

```bash
make secrets PROJECT=crivo ENV=develop              # recria o app-secrets
make rollout SERVICE=crivo-be NAMESPACE=crivo-develop # pods leem env só no start
```

Variáveis de cada projeto atual:

| Projeto / app | `env:` (values) | `secrets/<env>.env` | Da plataforma |
| ------------- | --------------- | ------------------- | ------------- |
| crivo / crivo-be | `PORT`, `NODE_ENV`, `SWAGGER_ENABLED`, `MESSAGING_PROVIDER`, `REMINDER_HOURS_BEFORE`, `PUBLIC_APP_URL`, `CORS_ORIGINS` | `JWT_SECRET`, `JWT_EXPIRES_IN_SECONDS`, `REFRESH_TOKEN_EXPIRES_IN_SECONDS`, `INBOUND_WEBHOOK_TOKEN`, `BULL_BOARD_*`, `EVOLUTION_*`, `META_*`, `DEEPSEEK_*`, `AI_TIMEOUT_MS`, `CLOUDINARY_*`, `STRIPE_*`, `SMTP_*`, `MAIL_FROM` (lista completa em [`example.env`](projects/crivo/secrets/example.env)) | `DATABASE_URL`, `DIRECT_URL`, `REDIS_URL` |
| crivo / crivo-fe | `PORT`, `NODE_ENV` | — | — (a URL da API é embutida no build: `NEXT_PUBLIC_API_URL=http://crivo-be:8080`) |
| nest-rabbitmq / products | `PORT`, `NODE_ENV` | — | `RABBITMQ_URL`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD` |

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
3. Crie o secret `INFRA_REPO_TOKEN` no repo do app (veja a
   [seção 2.2](#22-secrets-do-github-em-cada-repo-de-app) e a
   [seção 2.3](#23-como-criar-cada-token)):
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

### 5.1 Plataforma (`make`)

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
```

### 5.2 Kubernetes do dia a dia

Nos atalhos, `SERVICE` é o nome do app (a pasta em `apps/`, por exemplo
`crivo-be`) e `NAMESPACE` é `<projeto>-<env>` (por exemplo `crivo-develop`).

| Tarefa | Atalho | `kubectl` equivalente |
| ------ | ------ | --------------------- |
| Pods de todos os projetos | `make pods` | `kubectl get pods -A` |
| Pods de um namespace | `make pods NAMESPACE=crivo-develop` | `kubectl get pods -n crivo-develop -o wide` |
| Apps do ArgoCD (sync/health) | `make apps` | `kubectl get applications -n argocd` |
| Logs (follow) | `make logs SERVICE=crivo-be NAMESPACE=crivo-develop` | `kubectl logs -n crivo-develop deploy/crivo-be -f --tail=100` |
| Logs do container que caiu | — | `kubectl logs -n crivo-develop deploy/crivo-be --previous` |
| Por que o pod não sobe | `make describe SERVICE=crivo-be NAMESPACE=crivo-develop` | `kubectl describe pod -n crivo-develop -l app.kubernetes.io/name=crivo-be` |
| Eventos recentes | `make events NAMESPACE=crivo-develop` | `kubectl get events -n crivo-develop --sort-by=.lastTimestamp` |
| Reiniciar app / reler env e secrets | `make rollout SERVICE=crivo-be NAMESPACE=crivo-develop` | `kubectl rollout restart deploy/crivo-be -n crivo-develop` |
| Shell no container | `make shell SERVICE=crivo-be NAMESPACE=crivo-develop` | `kubectl exec -it -n crivo-develop deploy/crivo-be -- sh` |
| Acessar Postgres local | `make pf SERVICE=postgres NAMESPACE=crivo-develop PORT=5432 LOCAL=5433` | `kubectl port-forward -n crivo-develop svc/postgres 5433:5432` |
| UI do RabbitMQ | `make pf SERVICE=rabbitmq NAMESPACE=nest-rabbitmq-develop PORT=15672` | `kubectl port-forward -n nest-rabbitmq-develop svc/rabbitmq 15672:15672` |
| ArgoCD reler o Git agora | `make refresh` (ou `APP=crivo-be-develop`) | `kubectl -n argocd annotate application crivo-be-develop argocd.argoproj.io/refresh=hard --overwrite` |
| CPU/memória | — | `kubectl top pods -n crivo-develop` (o setup desliga o metrics-server; use o Grafana) |

Mais comandos `kubectl` úteis:

```bash
# Contexto / cluster
kubectl config current-context                 # deve ser k3d-devops-lab
kubectl get nodes -o wide
kubectl get ns -l devops-platform/project      # namespaces dos projetos

# Visão geral de um namespace
kubectl get all -n crivo-develop               # deploy, rs, pods, svc
kubectl get ingress -A                         # hosts publicados
kubectl get secrets -n crivo-develop           # postgres, redis, app-secrets...

# Inspecionar um Secret (decodificado)
kubectl get secret app-secrets -n crivo-develop -o json | jq -r '.data | map_values(@base64d)'

# Imagem e tag que estão rodando
kubectl get deploy -n crivo-develop -o custom-columns='APP:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'

# Histórico e rollback manual (o ArgoCD desfaz no próximo sync; o
# rollback "de verdade" é voltar a tag no values-<env>.yaml)
kubectl rollout history deploy/crivo-be -n crivo-develop
kubectl rollout undo deploy/crivo-be -n crivo-develop

# Escalar (o ArgoCD com selfHeal volta para o replicaCount do values)
kubectl scale deploy/crivo-be -n crivo-develop --replicas=2

# Testar de dentro do cluster (DNS dos Services)
kubectl run tmp --rm -it --image=curlimages/curl -n crivo-develop -- curl -s http://crivo-be:8080/health

# Logs do ArgoCD quando um app não aparece/sincroniza
kubectl logs -n argocd deploy/argocd-applicationset-controller --tail=50
kubectl logs -n argocd statefulset/argocd-application-controller --tail=50
```

> No GitOps, mudanças feitas direto com `kubectl` (scale, set image, edit)
> são revertidas pelo ArgoCD (`selfHeal: true`). Para mudar de verdade, altere
> os arquivos em `projects/` e faça commit.

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
| `ImagePullBackOff` + `403 Forbidden` | `ghcr-secret` com token inválido (ex.: PAT fine-grained). O kubelet envia o secret até para imagem pública | apagar o secret (`kubectl -n <ns> delete secret ghcr-secret`) ou recriar com PAT classic (`make ghcr …`) |
| `ImagePullBackOff` + `no match for platform in manifest` | imagem só `amd64`; os nodes do k3d no Mac Apple Silicon são `arm64` | o workflow do template já publica `linux/amd64,linux/arm64`; rode o CI de novo |
| `ImagePullBackOff` + `not found` | a imagem/tag ainda não foi publicada | rodar o CI do app |
| `CreateContainerConfigError` | falta um Secret do `envFrom` | `make project-apply PROJECT=<p>` |
| API reinicia em loop | segredo obrigatório ausente | conferir `secrets/<env>.env` e rodar `make secrets …` |
| `*.local` não resolve | cache mDNS do macOS | `make hosts`, ou `curl --resolve host:80:127.0.0.1` |
| Job `deploy` do CI: `Input required and not supplied: token` / `INFRA_REPO_TOKEN ausente` | secret `INFRA_REPO_TOKEN` não criado no repo do app | `gh secret set INFRA_REPO_TOKEN --repo <owner>/<app>` |
| Job `deploy` do CI falha no push | o PAT não tem escrita no repo de infra | PAT fine-grained com *Contents: Read and write* no repo de infra (dono: a org `infra-devops-full`) |

## 8. Destruir

```bash
make destroy
```

Remove o cluster, o bloco do `/etc/hosts` e o contexto do kubeconfig. Antes de
apagar o `DATA_DIR`, ele pergunta.
