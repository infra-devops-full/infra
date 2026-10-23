# Visão geral e arquitetura

## O que é esta plataforma

Uma **plataforma interna de deploy** (*Internal Developer Platform*): um
Kubernetes local onde qualquer aplicação entra declarando o mínimo. O "como
publicar, observar e proteger" é igual para todas e fica centralizado neste
repositório.

| Camada | Ferramenta | Papel |
| ------ | ---------- | ----- |
| Cluster | **k3d** (k3s em Docker) | Kubernetes leve rodando no Mac |
| Entrada | **NGINX Ingress** | recebe o HTTP e roteia por host/path para os apps |
| Deploy | **ArgoCD** | GitOps: faz o cluster ficar igual ao Git |
| Empacotamento | **Helm** (`charts/app`) | um chart genérico para todos os apps |
| Métricas | **Prometheus** + kube-state-metrics + cAdvisor | CPU, memória, requests, status |
| Logs | **Loki** + **Alloy** | logs de todos os pods, consultáveis por projeto/app |
| Visualização | **Grafana** | dashboard *Platform / Apps* |
| CI | **GitHub Actions** | testes, build, scan e publicação de imagem |
| Registry | **GHCR** | imagens `ghcr.io/<owner>/<repo>/<app>` |
| Segurança | **Trivy**, **CodeQL**, **Dependabot**, **Sealed Secrets** | CVEs, análise de código, dependências, segredos criptografados no Git |

## Os dois mundos do repositório

```
infra/
├── (genérico)  argocd/  charts/app/  k8s/  scripts/  config/  templates/
└── projects/   crivo/  nest-rabbitmq/  wlstore/   ← só o que é de cada app
```

- **Genérico** não cita nenhum projeto. Muda raramente, e muda para todos.
- **`projects/<nome>/`** tem só configuração: dependências (`project.yaml`),
  valores de cada app por ambiente (`apps/<app>/values-<env>.yaml`), logo e
  segredos de lab.

Adicionar um projeto = criar uma pasta. Nada no genérico muda (veja
[03-projetos.md](03-projetos.md)).

## O caminho de uma mudança até produção

```
 dev                  repo do app (GitHub)                    repo de infra          cluster
 ───                  ────────────────────                    ─────────────          ───────
 commit ─► PR ─► CI: lint + testes + build + Trivy
               merge na develop ─► CI: imagem sha-abc123 ─► GHCR
                                    └─ commit image.tag ───► values-develop.yaml
                                                                   │ ArgoCD detecta
                                                                   ▼
                                                            <projeto>-develop (teste)
               PR develop → main (check `ci` obrigatório)
               merge na main ─► CI: imagem ─► commit ───────► values-prod.yaml
                                                                   ▼
                                                            <projeto>-prod
```

Pontos importantes:

1. **O cluster nunca é alterado "na mão"** pelo deploy. Quem aplica é o
   ArgoCD, a partir do Git. Isso é **GitOps**.
2. **O repo do app não tem acesso ao cluster.** Ele só publica a imagem e
   commita a tag no repo de infra (deploy key com escrita só nesse repo).
3. **Rollback = reverter o commit** de deploy no repo de infra.
4. **Cada ambiente é um namespace** (`crivo-develop`, `crivo-prod`), com o
   próprio banco, mensageria e segredos.

## O que roda dentro de um namespace de projeto

```
namespace wlstore-develop
├── Deployment/Service/Ingress de cada app   ← ArgoCD (charts/app)
├── postgres, rabbitmq, redis                ← plataforma (apply-project.sh)
└── Secrets: postgres, rabbitmq, redis, app-secrets  ← SealedSecrets do Git (make seal)
            ghcr-secret (opcional)
```

Os apps leem as conexões dos Secrets via `envFrom`. Veja
[03-projetos.md](03-projetos.md#secrets-que-a-plataforma-cria).

## Domínios

| | develop | prod |
| - | ------- | ---- |
| front do projeto | `develop.crivo.local` | `crivo.local` |
| API (host derivado) | `develop.crivo-be.crivo.local` | `crivo-be.crivo.local` |
| microfrontend | `develop.wlstore.local/catalog` | `wlstore.local/catalog` |
| ferramentas | `argocd.devops.local`, `grafana.devops.local`, `prometheus.devops.local` | |

## Limites deste lab (o que muda em produção real)

| Aqui | Em produção |
| ---- | ----------- |
| Postgres/Redis/RabbitMQ com `emptyDir` (dados voláteis) | banco gerenciado (RDS, Cloud SQL) ou operador com backup |
| Sealed Secrets com a chave num arquivo local de backup | External Secrets + Vault/Secrets Manager; chave em cofre/HSM |
| HTTP sem TLS, domínios `.local` | cert-manager + Let's Encrypt, DNS real |
| develop e prod no mesmo cluster | clusters separados |
| sem alertas (só dashboards) | Alertmanager com Slack/PagerDuty e SLOs |

O roteiro para fechar essas lacunas está em
[10-roteiro-de-estudo.md](10-roteiro-de-estudo.md).
