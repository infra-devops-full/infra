#!/usr/bin/env bash
# =============================================================================
# seal-sso.sh — sela as credenciais do OAuth App do GitHub (login único) em
# config/auth/github-oauth.sealed.yaml, que pode ir para o Git. make sso-github
#
# Pede o Client ID e o Client secret (o secret não aparece na tela nem fica
# em arquivo/histórico) e criptografa com a chave pública do cluster
# (config/sealed-secrets/cert.pem), para o namespace auth.
# =============================================================================
set -euo pipefail
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT="$INFRA_ROOT/config/sealed-secrets/cert.pem"
OUT="$INFRA_ROOT/config/auth/github-oauth.sealed.yaml"
[[ -f "$CERT" ]] || { echo "❌ $CERT não existe: make sealed-secrets"; exit 1; }

read -r -p "GitHub OAuth App — Client ID: " CID
read -r -s -p "GitHub OAuth App — Client secret: " CSECRET; echo
[[ -n "$CID" && -n "$CSECRET" ]] || { echo "❌ os dois são obrigatórios"; exit 1; }

kubectl create secret generic dex-github -n auth \
  --from-literal=GITHUB_CLIENT_ID="$CID" --from-literal=GITHUB_CLIENT_SECRET="$CSECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" --format yaml --namespace auth > "$OUT"
unset CSECRET
echo "✅ ${OUT#"$INFRA_ROOT"/} gerado (criptografado: pode commitar)."
echo "   Agora: git add ${OUT#"$INFRA_ROOT"/} && git commit && git push; depois make sso"
