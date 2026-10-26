# Login único (SSO) com GitHub

## O que muda

Hoje cada ferramenta tem uma senha própria (admin do ArgoCD, admin do
Grafana), e Prometheus, Alertmanager e o dashboard do Argo Rollouts não têm
login. Com o SSO:

- **um login só** (a sua conta do GitHub) para todas as ferramentas;
- **só membros das orgs** da plataforma entram;
- o que cada um pode fazer vem dos **times do GitHub**: entrou ou saiu do
  time, a permissão muda no próximo login, sem mexer em nenhuma ferramenta.

```
navegador ──► ArgoCD / Grafana ─────────────┐
          ──► Prometheus / Alertmanager ──► oauth2-proxy ──┤
          ──► dashboard do Argo Rollouts                    ▼
                                      Dex (auth.devops.local) ──► GitHub
                                       "você é geraldobl58, dos times
                                        infra-devops-full:platform-admins, ..."
```

- **Dex** é o provedor OIDC da plataforma: fala com o GitHub e entrega para
  as ferramentas quem é o usuário e de quais times ele é.
- **oauth2-proxy** é o porteiro das ferramentas que não têm login próprio. O
  NGINX Ingress pergunta a ele antes de deixar a requisição passar
  (annotation `auth-url`).

## Perfis

| Perfil | Quem (time do GitHub) | ArgoCD | Grafana | Prometheus / Alertmanager | Dashboard do Rollouts |
| ------ | --------------------- | ------ | ------- | ------------------------- | --------------------- |
| **admin** | `config/auth/access.yaml` → `admins` (hoje `infra-devops-full:platform-admins`) | tudo | Admin | sim | sim, com promote/abort/rollback |
| **dev do projeto** | `projects/<p>/project.yaml` → `access.devs` (ex.: `crivo-sync:devs`) | sync, ações do Rollout (abort/promote/retry) e logs **só nos apps do projeto**; leitura no resto | Editor | sim | não (usa as ações do ArgoCD) |
| **leitura** | qualquer outro membro das orgs | só ver | Viewer | não | não |

O dashboard do Argo Rollouts não tem permissão por usuário: quem entra age
com a permissão dele, em todos os namespaces. Por isso só admins entram.
Devs abortam e promovem o canary pelo ArgoCD (Rollout → ⋮ → Actions),
onde o perfil limita ao projeto.

**Acesso de emergência:** o `admin` local do ArgoCD (senha no `make status`)
e o `admin` do Grafana continuam funcionando, para quando o GitHub ou o Dex
estiverem fora.

## Configurar (uma vez)

### 1. Times no GitHub

| Org | Time | Quem |
| --- | ---- | ---- |
| `infra-devops-full` | `platform-admins` | você (e quem opera a plataforma) |
| `crivo-sync` | `devs` | quem desenvolve o crivo |
| `whitelabel-store` | `devs` | quem desenvolve o wlstore |

Pela interface (*Org → Teams → New team*) ou pelo terminal (precisa do
escopo `admin:org`: `gh auth refresh -s admin:org`):

```bash
gh api orgs/infra-devops-full/teams -f name=platform-admins -f privacy=closed
gh api -X PUT orgs/infra-devops-full/teams/platform-admins/memberships/<seu-usuario>
gh api orgs/crivo-sync/teams -f name=devs -f privacy=closed
gh api orgs/whitelabel-store/teams -f name=devs -f privacy=closed
```

O projeto `nest-rabbitmq` está numa conta pessoal (sem times): só admins
operam. Para dar devs a ele, mova o repo para uma org (como foi feito com o
crivo) e preencha `access.devs` no `project.yaml`.

### 2. OAuth App no GitHub

Em https://github.com/organizations/infra-devops-full/settings/applications/new:

| Campo | Valor |
| ----- | ----- |
| Application name | DevOps Platform (lab) |
| Homepage URL | `https://argocd.devops.local` |
| Authorization callback URL | `https://auth.devops.local/callback` |

Depois de criar: copie o **Client ID** e gere um **Client secret**.

> O GitHub aceita `*.local` porque quem segue o redirecionamento é o seu
> navegador, não o GitHub.

### 3. Selar as credenciais e aplicar

```bash
make sso-github     # cola o Client ID e o secret (não aparece na tela)
git add config/auth/github-oauth.sealed.yaml && git commit -m "feat(sso): oauth app" && git push
make hosts          # auth.devops.local e oauth2.devops.local (uma vez)
make sso
```

O arquivo selado só abre no cluster (Sealed Secrets), então pode ir para o
Git, e o `make setup` de um cluster novo já sobe com login.

### 4. Primeiro login

Em https://argocd.devops.local → **LOG IN VIA GITHUB**. Na tela do GitHub,
autorize o app. Se uma org tiver **restrição de apps de terceiros**, clique
em **Grant** (ou **Request**) ao lado dela. Sem isso o Dex não vê os times
daquela org e você entra só como leitura.

## Dar ou tirar acesso

| Quero | Faço |
| ----- | ---- |
| alguém novo como dev do crivo | adicionar ao time `crivo-sync/devs` no GitHub |
| um time novo como dev de um projeto | `access.devs` no `projects/<p>/project.yaml` + push (o ArgoCD aplica no AppProject) e `make sso` (Grafana) |
| outra org poder entrar | `github.orgs` em `config/auth/access.yaml` + `make sso` |
| mais um time admin | `admins` em `config/auth/access.yaml` + `make sso` |
| tirar o acesso de alguém | remover do time/org no GitHub (vale no próximo login; a sessão atual expira) |

## Como funciona por dentro

| Peça | Para quê |
| ---- | -------- |
| `config/auth/access.yaml` | orgs que entram e times admin |
| `projects/<p>/project.yaml` → `access.devs` | times dev de cada projeto (viram o papel `dev` do AppProject) |
| `scripts/lib-sso.sh` | gera os values de Dex, oauth2-proxy, ArgoCD, Grafana, Prometheus/Alertmanager e Rollouts a partir dos dois acima |
| `scripts/setup-sso.sh` | `make sso`: segredos internos, Dex, oauth2-proxy e upgrade das ferramentas |
| `scripts/seal-sso.sh` | `make sso-github`: sela o OAuth App |
| trust-manager (`config/security/trust-bundle.yaml`) | ConfigMap `platform-ca` em todo namespace: os pods confiam no HTTPS da CA local |
| CoreDNS (`config/security/coredns-custom.yaml`) | `*.devops.local` dentro do cluster aponta para o Ingress: ArgoCD e Grafana falam com o Dex pelo mesmo endereço do navegador |

O `setup-observability.sh` e o `setup-delivery.sh` incluem os values de SSO
quando ele está configurado, então um `make observability` não desliga o
login.

## Problemas comuns

| Sintoma | Causa | Solução |
| ------- | ----- | ------- |
| `make sso` só mostra instruções | OAuth App não selado | passos 2 e 3 |
| Dex: "Internal Server Error — Authentication failed"; log do Dex (`kubectl -n auth logs deploy/dex`): `user not in org or application not authorized to read org data` | o OAuth App não tem acesso às orgs (restrição de apps de terceiros) | como dono da org: https://github.com/settings/connections/applications/<Client ID> → **Grant** em cada org; ou *Org → Settings → Third-party access → OAuth app policy* |
| log do Dex: `bad_verification_code` | voltou ou recarregou a página no meio do login (o código do GitHub vale uma vez) | começar o login de novo |
| dashboard do Rollouts: "Failed to fetch" | sem sessão (login falhou ou expirou): as chamadas da página são redirecionadas para o login | recarregar a página e entrar de novo |
| GitHub: "redirect_uri is not associated with this application" | callback URL diferente | `https://auth.devops.local/callback`, exatamente |
| entrou, mas só com leitura | time não reconhecido: org sem *Grant* para o app, ou time com outro nome | GitHub → Settings → Applications → o app → Grant na org; conferir o slug do time |
| ArgoCD: "failed to verify token" / erro de certificado | pod sem a CA ou sem DNS interno | `make security` (trust-manager + CoreDNS) e `make sso` |
| Prometheus/Rollouts: erro 500 | oauth2-proxy fora do ar | `kubectl -n auth get pods`; `make sso` |
| precisa entrar com o GitHub fora | — | `admin` local do ArgoCD e do Grafana |
