# Instalação e operação do lab

## Pré-requisitos

```bash
brew install k3d kubectl helm yq gettext gh   # gettext traz o envsubst
brew install --cask docker                    # Docker Desktop (ou OrbStack/Colima)
brew install k9s                              # opcional
gh auth login                                 # admin do repo de infra e dos apps
```

No Docker Desktop: **desligue o Kubernetes embutido** (*Settings →
Kubernetes*) e reserve **6 CPUs e 8 a 10 GB** (*Settings → Resources*).

## Ordem de instalação

```bash
cp .env.template .env      # 1. configuração (GITHUB_TOKEN fica VAZIO)
make doctor                # 2. confere ferramentas, tokens, GitHub e Docker
make github                # 3. configura os repos dos apps (uma vez)
make setup                 # 4. cria e configura tudo (~10-15 min)
make status                # 5. confere
```

### O que o `make setup` faz, etapa por etapa

| Etapa | O que acontece | Script |
| ----- | -------------- | ------ |
| 0 | roda o `doctor` e **para** se houver erro (`SKIP_DOCTOR=1` ignora) | `doctor.sh` |
| 1 | cria o cluster k3d (1 server + `K3D_AGENTS`), com volumes em `DATA_DIR` | `config/k3d-config.tmpl.yaml` |
| 1.5 | instala o NGINX Ingress (`hostPort` 80/443, métricas ligadas) | `setup.sh` |
| 2 | namespaces `argocd` e `monitoring` | `setup.sh` |
| 3 | ArgoCD (sem Dex/notifications) + Ingress `argocd.devops.local` | `setup.sh` |
| 4 | Prometheus + Grafana enxutos, depois métricas do Ingress, Loki e Alloy | `setup.sh`, `setup-observability.sh` |
| 5 | para cada projeto: namespaces, dependências e secrets; depois o ArgoCD genérico e os dashboards | `apply-project.sh`, `apply-platform.sh` |
| 6 | bloco isolado no `/etc/hosts` | `hosts.sh` |
| 7 | testa as URLs das ferramentas | `setup.sh` |

## Variáveis do `.env`

| Variável | Default | Para quê |
| -------- | ------- | -------- |
| `CLUSTER_NAME` | `devops-lab` | nome do cluster |
| `K3D_AGENTS` | `1` | nodes além do server (cada um é um k3s inteiro, então mais CPU) |
| `DATA_DIR` | `$HOME/.devops-lab` | volumes do cluster no disco do Mac |
| `INFRA_REPO_URL` / `INFRA_BRANCH` | `git remote` / `main` | repo que o ArgoCD observa |
| `GITHUB_TOKEN` / `GITHUB_USERNAME` | **vazios** | só para imagens **privadas**: PAT *classic* com `read:packages` |

> Um `GITHUB_TOKEN` inválido é pior que nenhum: o pod envia a credencial e o
> GHCR responde 403 até para imagem pública. O `doctor` detecta.

## Operação do dia a dia

| Situação | Comando |
| -------- | ------- |
| parar o lab (libera CPU, mantém dados) | `make stop` |
| voltar | `make start` (aguarde 2 a 5 min, porque o Prometheus recoleta) |
| ver tudo | `make status`, `make apps`, `make pods` |
| projeto novo num cluster existente | `make project-apply PROJECT=<p>` |
| atualizar observabilidade/dashboards | `make observability` |
| reaplicar ArgoCD e dashboards | `make apply-argocd` |
| hosts | `make hosts` |
| apagar tudo | `make destroy` (pergunta antes de apagar `DATA_DIR`) |

Depois de **reiniciar o Docker**, os nodes do k3d voltam com outro IP. O
Prometheus leva alguns minutos para recoletar, e até lá o Grafana pode mostrar
"No data".

## Consumo de recursos

Com 1 agent, Prometheus a cada 60 s, Loki single-binary e ArgoCD sem Dex, o lab
inteiro fica bem abaixo do que era com 7 nodes. Detalhes na seção 9 do
[README](../README.md#9-cpu-e-memória). Para medir: `docker stats --no-stream`
e o dashboard *Kubernetes / Compute Resources / Cluster* no Grafana.
