# Instalação

## Pré-requisitos

| Ferramenta | Versão mín. | Notas                                                |
| ---------- | ----------- | ---------------------------------------------------- |
| Docker     | 24+         | Roda o cluster k3d                                   |
| k3d        | 5.6+        | `brew install k3d`                                   |
| kubectl    | 1.28+       | `brew install kubectl`                               |
| Helm       | 3.12+       | `brew install helm`                                  |
| yq         | 4+          | `brew install yq` (usado nos scripts)                |
| make       | qualquer    | Já vem com Xcode CLT                                 |
| (opc.) k9s | qualquer    | UI de terminal pra K8s, `brew install k9s`           |

## Setup do zero

```bash
git clone git@github.com:geraldobl58/infra.git
cd infra

# 1. Cluster + ArgoCD + observabilidade + namespaces
make setup
# (vai pedir sudo pra editar /etc/hosts)

# 2. Preparar token do GHCR (para puxar imagens privadas)
cp .env.template .env
$EDITOR .env                          # preencher GITHUB_TOKEN
./create-ghcr-secrets.sh

# 3. Preparar secrets de cada ambiente
cp config/secrets.develop.env.example config/secrets.develop.env
$EDITOR config/secrets.develop.env
make secrets ENV=develop

cp config/secrets.prod.env.example config/secrets.prod.env
$EDITOR config/secrets.prod.env
make secrets ENV=prod

# 4. Aplicar manifests ArgoCD (já roda no make setup, mas pode reaplicar)
make apply-argocd

# 5. Verificar
make status
make argocd            # abre a UI no browser
```

## Operações comuns

```bash
make start             # liga o cluster (se foi parado com make stop)
make stop              # desliga o cluster mas mantém dados
make destroy           # destrói tudo (com confirmação)
make logs SERVICE=crivo-be NAMESPACE=crivo-develop
```

## Token do GitHub (GHCR)

Para puxar imagens privadas do GitHub Container Registry:

1. Crie um Personal Access Token em https://github.com/settings/tokens
2. Selecione os scopes: `read:packages`
3. Coloque no `.env` como `GITHUB_TOKEN=...`
4. Rode `./create-ghcr-secrets.sh`

O secret `ghcr-secret` é criado em `crivo-develop` e `crivo-prod`.

## Por que k3d e não Minikube/Kind?

- k3d sobe nodes em containers Docker, o que casa naturalmente com o
  pattern de ter o Postgres do app também em Docker (não precisamos
  reinventar networking).
- k3s é mais leve, ideal para Mac.
- Suporta múltiplos agents (workers) facilmente.
