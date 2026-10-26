#!/usr/bin/env bash
# =============================================================================
# seal-notifications.sh — sela as URLs dos webhooks do Discord (são senhas:
# quem tem a URL posta no canal). make notifications-webhooks
#   config/notifications/alertmanager-webhooks.sealed.yaml  (#alertas, #alertas-develop)
#   config/notifications/argocd-notifications.sealed.yaml   (#deploys)
# As URLs não aparecem na tela nem ficam em arquivo/histórico.
# =============================================================================
set -euo pipefail
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT="$INFRA_ROOT/config/sealed-secrets/cert.pem"
OUT="$INFRA_ROOT/config/notifications"
[[ -f "$CERT" ]] || { echo "❌ $CERT não existe: make sealed-secrets"; exit 1; }

ask() { local v; read -r -s -p "$1: " v; echo >&2; echo "$v"; }
ALERTAS="$(ask 'Webhook do #alertas (prod e plataforma)')"
DEVELOP="$(ask 'Webhook do #alertas-develop (Enter = mesmo do #alertas)')"
DEPLOYS="$(ask 'Webhook do #deploys')"
DEVELOP="${DEVELOP:-$ALERTAS}"
for u in "$ALERTAS" "$DEVELOP" "$DEPLOYS"; do
  [[ "$u" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/ ]] || { echo "❌ URL de webhook do Discord inválida"; exit 1; }
done

seal() { kubeseal --cert "$CERT" --format yaml --namespace "$1"; }
kubectl create secret generic alertmanager-webhooks -n monitoring \
  --from-literal=alertas="$ALERTAS" --from-literal=alertas-develop="$DEVELOP" \
  --dry-run=client -o yaml | seal monitoring > "$OUT/alertmanager-webhooks.sealed.yaml"
kubectl create secret generic argocd-notifications-secret -n argocd \
  --from-literal=discord-deploys-url="$DEPLOYS" \
  --dry-run=client -o yaml | seal argocd > "$OUT/argocd-notifications.sealed.yaml"
unset ALERTAS DEVELOP DEPLOYS
echo "✅ config/notifications/*.sealed.yaml gerados (criptografados: pode commitar)."
echo "   Agora: make notifications && make notify-test"
