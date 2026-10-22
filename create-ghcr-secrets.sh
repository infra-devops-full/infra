#!/bin/bash
# ============================================================================
# create-ghcr-secrets.sh  (genérico)
# ----------------------------------------------------------------------------
# Cria o secret `ghcr-secret` (docker-registry) em um ou mais namespaces, para
# permitir pull de imagens privadas do GitHub Container Registry.
#
# Uso:
#   ./create-ghcr-secrets.sh --namespaces "ns1 ns2" [--token <TOKEN>] [--user <USER>]
#   ./create-ghcr-secrets.sh --namespaces "ns1 ns2"     # token/user via .env ou env
#
# O token é lido, em ordem: --token  >  $GITHUB_TOKEN  >  .env (GITHUB_TOKEN).
# O usuário:                 --user   >  $GITHUB_USERNAME  >  .env.
#
# Compat: sem --namespaces, usa a variável de ambiente GHCR_NAMESPACES
# (lista separada por espaço). Sem isso, erro.
# ============================================================================

set -e

REGISTRY="ghcr.io"
NAMESPACES_STR="${GHCR_NAMESPACES:-}"
TOKEN=""
USERNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespaces) NAMESPACES_STR="$2"; shift 2 ;;
    --token)      TOKEN="$2"; shift 2 ;;
    --user)       USERNAME="$2"; shift 2 ;;
    # compat: primeiro arg posicional é o token
    *) if [[ -z "$TOKEN" ]]; then TOKEN="$1"; shift; else echo "Arg desconhecido: $1"; exit 1; fi ;;
  esac
done

# Carregar .env (token/username/namespaces)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "📂 Carregando variáveis do .env..."
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

TOKEN="${TOKEN:-${GITHUB_TOKEN:-}}"
USERNAME="${USERNAME:-${GITHUB_USERNAME:-}}"
NAMESPACES_STR="${NAMESPACES_STR:-${GHCR_NAMESPACES:-}}"

if [ -z "$NAMESPACES_STR" ]; then
  echo "❌ Nenhum namespace informado. Use --namespaces \"ns1 ns2\" ou GHCR_NAMESPACES."
  exit 1
fi

if [ -z "$TOKEN" ]; then
  echo "❌ GitHub Token não fornecido (--token, \$GITHUB_TOKEN ou .env)."
  echo ""
  echo "📝 Para criar um token: https://github.com/settings/tokens"
  echo "   Scopes necessários: read:packages"
  exit 1
fi

if [ -z "$USERNAME" ]; then
  echo "❌ GitHub username não definido (--user, \$GITHUB_USERNAME ou .env)."
  exit 1
fi

read -r -a NAMESPACES <<< "$NAMESPACES_STR"

# Valida o token no GHCR ANTES de criar o secret. Credencial inválida é pior
# que nenhuma: o kubelet envia o ghcr-secret mesmo para imagens públicas e o
# pull falha com 403. O GHCR só aceita PAT *classic* com read:packages —
# PAT fine-grained (github_pat_...) é recusado.
GHCR_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -u "${USERNAME}:${TOKEN}" \
  "https://${REGISTRY}/token?service=${REGISTRY}&scope=repository:${USERNAME}/probe:pull" || echo "000")
if [[ "$GHCR_STATUS" != "200" ]]; then
  echo "❌ O GHCR recusou o token (HTTP $GHCR_STATUS) — ghcr-secret NÃO foi criado."
  [[ "$TOKEN" == github_pat_* ]] && \
    echo "   Esse é um PAT fine-grained; o GHCR só aceita PAT classic."
  echo "   Crie um PAT classic com o scope read:packages: https://github.com/settings/tokens/new?scopes=read:packages"
  echo "   Imagens públicas não precisam de ghcr-secret."
  # Remove secrets inválidos antigos, que bloqueariam até imagens públicas.
  for NS in "${NAMESPACES[@]}"; do
    kubectl delete secret ghcr-secret -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  done
  exit 1
fi

echo "🔐 Criando ghcr-secret em: ${NAMESPACES[*]}"
echo ""

for NS in "${NAMESPACES[@]}"; do
  echo "📦 Namespace: $NS"
  kubectl get namespace "$NS" &> /dev/null || kubectl create namespace "$NS"
  kubectl delete secret ghcr-secret -n "$NS" &> /dev/null || true
  kubectl create secret docker-registry ghcr-secret \
    --docker-server="$REGISTRY" \
    --docker-username="$USERNAME" \
    --docker-password="$TOKEN" \
    --namespace="$NS"
  echo "  ✅ ghcr-secret criado"
  echo ""
done

echo "🎉 Secrets criados em todos os namespaces."
