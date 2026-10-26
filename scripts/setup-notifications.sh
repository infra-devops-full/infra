#!/usr/bin/env bash
# =============================================================================
# setup-notifications.sh — notificações no Discord. make notifications
#   alertas  → Alertmanager (config/notifications/alertmanager-values.yaml)
#   deploys  → ArgoCD Notifications (config/notifications/argocd-notifications-values.yaml)
# As URLs dos webhooks vêm dos SealedSecrets em config/notifications/
# (make notifications-webhooks). Sem eles, explica o que fazer e sai.
# docs/20-notificacoes.md
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$(cd "$SCRIPT_DIR/.." && pwd)/config/notifications"
step() { echo -e "\033[0;36m▸ $1\033[0m"; }
installed_chart_version() {
  helm list -n "$2" -f "^$1\$" -o json | jq -r '.[0].chart // empty' | sed -E 's/^.*-(v?[0-9]+\.[0-9]+\.[0-9]+.*)$/\1/'
}

for f in "$CFG"/*.sealed.yaml; do [[ -f "$f" ]] && kubectl apply -f "$f" >/dev/null; done
wait_secret() { for _ in $(seq 1 30); do kubectl get secret "$1" -n "$2" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

if ! wait_secret alertmanager-webhooks monitoring || ! wait_secret argocd-notifications-secret argocd; then
  echo -e "\033[1;33m⚠ Notificações não configuradas: faltam os webhooks.\033[0m"
  echo "  1. No Discord, crie os canais #alertas, #alertas-develop e #deploys e um webhook em cada"
  echo "     (canal → Editar canal → Integrações → Webhooks → Novo webhook → Copiar URL)"
  echo "  2. make notifications-webhooks   (cola as URLs; não aparecem na tela; gera os arquivos selados)"
  echo "  3. git add config/notifications/*.sealed.yaml && git commit && git push"
  echo "  4. make notifications && make notify-test"
  exit 0
fi

step "Alertmanager: alertas → #alertas / #alertas-develop"
bash "$SCRIPT_DIR/setup-observability.sh" --only-kps >/dev/null

step "ArgoCD Notifications: deploys → #deploys"
helm upgrade argocd argo/argo-cd --version "$(installed_chart_version argocd argocd)" -n argocd \
  --reuse-values -f "$CFG/argocd-notifications-values.yaml" --timeout 5m --wait >/dev/null
kubectl -n argocd rollout restart deploy/argocd-notifications-controller >/dev/null

echo -e "\033[0;32m✅ Notificações prontas.\033[0m Teste: make notify-test"
