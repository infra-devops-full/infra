# CI/CD, qualidade e segurança

## Branches e ambientes

```
feature/x ──PR──► develop ──PR──► main ──release──► prod
   │                 │              │                 │
PR: test+build    push: test +   merge: só      versão 1.4.0 com a mesma
(validação)       build + deploy  CodeQL         imagem de develop
                  em develop     (candidato)     (docs/16-releases.md)
```

- **develop** = ambiente de teste. Merge ou push direto disparam o deploy em
  `<projeto>-develop`.
- **main** = produção. Só entra por PR, com o check `ci` verde (proteção
  configurada pelo `make github`).
- No **repo de infra** não há branch por ambiente: develop e prod são arquivos
  (`values-develop.yaml`, `values-prod.yaml`) na `main`.

### Uma execução por mudança

| Evento | `🚀 Build & Deploy` (deploy.yml) | CodeQL |
| ------ | ------------------ | ------ |
| PR feature → develop | test + build (valida) | — |
| push/merge na develop | test + build + deploy em develop | — |
| PR develop → main | **não roda** | roda (default setup do GitHub) |
| merge na main | **não roda** (main = candidato a release) | roda |
| **release** (Run workflow) | `release.yml`: versão, changelog, mesma imagem → prod | — |

- **PR develop → main não roda o pipeline:** o head do PR é o mesmo commit
  que o push na develop já testou e buildou. A proteção da main exige o check
  `ci` *daquele commit*, e ele já existe (checks são por commit, não por
  evento). Por isso também não dá para abrir PR de uma feature direto para a
  main: o `ci` nunca aparece. O caminho é sempre feature → develop → main.
- **Prod só recebe releases** (`release.yml`): a versão reaproveita a
  imagem já testada na develop ("build once, deploy many"). Detalhes, hotfix
  e rollback em [16-releases.md](16-releases.md).
- **CodeQL** é a varredura de segurança do código, configurada pelo
  `make github` (*default setup*). O GitHub roda no PR e no push da branch
  padrão; não é configurável no default setup, e vale o custo.

## O pipeline de cada app

[`templates/github/deploy.yml`](../templates/github/deploy.yml), copiado para
`.github/workflows/deploy.yml` de cada repo:

| Job | O que faz | Barra? |
| --- | --------- | ------ |
| **plan** | compara os arquivos alterados com o `paths` de cada app e escolhe **só os afetados** | — |
| **test** | prepara a toolchain (`setup`: node, pnpm ou java) e roda o `test` do app | **sim** |
| **build** | imagem amd64 → **Trivy** (relatório; gate opcional) → imagem multi-arch → GHCR (só em push) | se o `TRIVY_GATE` estiver ligado |
| **deploy** | commita `image.tag = sha-<commit>` no `values-develop.yaml` do repo de infra (deploy key); prod recebe versões pelo `release.yml` | — |
| **ci** | resume plan, test e build num check só: o que a `main` exige (o do push na develop vale para o PR develop → main) | **sim** |

Buildam **todos** os apps: `workflow_dispatch`, o primeiro push de uma branch
e mudanças em `.github/workflows/`.

### `APPS_JSON`: a configuração de cada app

```json
{
  "app": "catalog-service",
  "context": "./wlstore-be",
  "dockerfile": "./wlstore-be/Dockerfile",
  "build-args": "SERVICE=catalog-service",
  "paths": ["wlstore-be/catalog-service/", "wlstore-be/wlstore-common/", "wlstore-be/pom.xml"],
  "setup": "java",
  "test": "cd wlstore-be && mvn -B -ntp -pl catalog-service -am test"
}
```

| Campo | Para quê |
| ----- | -------- |
| `app` | nome da pasta em `projects/<p>/apps/` e da imagem |
| `context` / `dockerfile` / `build-args` | o `docker build` (várias args: separe com `\n`) |
| `paths` | prefixos que, alterados, afetam o app (inclua libs compartilhadas e o lockfile) |
| `setup` | `node` (npm fixo 11.6.2), `pnpm` (10.29.3), `java` (Temurin 21 + cache Maven) ou `""` |
| `test` | lint + testes, rodado na raiz do repo. **Valide localmente antes**: teste que já falha trava todos os deploys |

Os testes Java usam **Testcontainers** (Postgres e RabbitMQ reais) e por isso
rodam direto no runner, que tem Docker.

## Templates de Dockerfile

| Template | Para | Detalhe |
| -------- | ---- | ------- |
| `templates/nestjs/` | NestJS (npm) | multi-stage, `npm prune`, usuário `node` |
| `templates/nextjs/` | Next.js (npm) | `NEXT_PUBLIC_*` via `build-args` (embutido no build) |
| `templates/nx-nextjs/` | monorepo Nx + pnpm | `APP=` escolhe o app; `BUILD_ENV=` para variáveis de build |
| `templates/spring-maven/` | multi-módulo Maven | `SERVICE=` escolhe o módulo; Maven roda **nativo** no build multi-arch (`--platform=$BUILDPLATFORM`) |

As imagens são **multi-arch** (amd64 + arm64): os nodes do k3d no Mac são arm64.

## Segurança

| Controle | Onde ver | Como ligar |
| -------- | -------- | ---------- |
| **Trivy** (CVEs na imagem) | aba **Security → Code scanning** do repo, ferramenta *Trivy*, categoria `trivy-<app>` | já no workflow |
| **Gate do Trivy** | job build falha | `gh variable set TRIVY_GATE --body CRITICAL --repo <owner>/<repo>` |
| **CodeQL** (análise estática) | Security → Code scanning, ferramenta *CodeQL* | `make github` |
| **Dependabot alerts + security updates** | Security → Dependabot; PRs de correção para a `main` | `make github` |
| **Dependabot version updates** | PRs semanais agrupados para a `develop` | `.github/dependabot.yml` ([template](../templates/github/dependabot.yml)) |
| **Secret scanning + push protection** | bloqueia push com token ou senha | `make github` |

O **Trivy começou só reportando**, porque as imagens atuais têm CVEs CRITICAL
com correção (`next`, `tomcat-embed`, `handlebars`, `proxy-addr`). O fluxo é:
o Dependabot abre o PR, o CI testa, você faz o merge, a aba Security zera, e
então o gate é ligado.

### Ver as vulnerabilidades localmente

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:0.69.1 image --severity CRITICAL,HIGH --ignore-unfixed <imagem>
```

## Credenciais do pipeline

| Credencial | Onde | Quem cria |
| ---------- | ---- | --------- |
| `INFRA_DEPLOY_KEY` | secret do repo do app | `make github` (deploy key SSH com escrita **só** no repo de infra) |
| `GITHUB_TOKEN` do Actions | automático | o GitHub; o workflow pede `packages: write` para publicar no GHCR |
| `TRIVY_GATE` | variável do repo (opcional) | você |

Nenhum token pessoal é usado no CI.

## CI do repo de infra

[`.github/workflows/validate.yml`](../.github/workflows/validate.yml) roda em
push e PR: `make helm-lint`, render de `argocd/` e `k8s/`, `shellcheck` dos
scripts e `actionlint` dos templates. Os commits de deploy levam `[skip ci]`. A
`main` da infra não é protegida, porque o CI dos apps faz push direto nela.
