#!/usr/bin/env bash
# =============================================================================
# notify-test.sh — manda notificações de TESTE para os canais do Discord:
#   #alertas e #alertas-develop  alerta "TesteDeNotificacao" (some em 2 min,
#                                 e chega o "✅ Resolvido")
#   #deploys                      mensagem de deploy de um app de prod
# make notify-test
# =============================================================================
set -euo pipefail
AM_POD="$(kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager -o name | head -1)"
END="$(date -u -v+3M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+3 min' +%Y-%m-%dT%H:%M:%SZ)"
for ENV_NAME in prod develop; do
  # amtool já vem no container do Alertmanager: sem port-forward.
  kubectl -n monitoring exec "$AM_POD" -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 \
    alert add alertname=TesteDeNotificacao severity=warning project=teste env="$ENV_NAME" app=notify-test \
    --annotation=summary="Teste de notificação ($ENV_NAME) — pode ignorar" \
    --annotation=description="Enviado por make notify-test. Some sozinho em 2 minutos." \
    --annotation=runbook_url="https://github.com/infra-devops-full/infra/blob/main/docs/20-notificacoes.md" \
    --end="$END" >/dev/null
done
echo "✅ alertas de teste enviados ao Alertmanager (#alertas e #alertas-develop em ~30 s; resolvido em ~2-5 min)"

APP="$(kubectl get applications -n argocd -l devops-platform/kind=app,devops-platform/env=prod -o name | head -1 | sed 's#.*/##')"
if [[ -n "$APP" ]] && kubectl -n argocd get deploy argocd-notifications-controller >/dev/null 2>&1; then
  kubectl -n argocd rollout status deploy/argocd-notifications-controller --timeout=120s >/dev/null
  # A saída deste comando (log debug) contém a URL do webhook: nunca imprimir crua.
  OUT="$(kubectl -n argocd exec deploy/argocd-notifications-controller -- \
    argocd admin notifications template notify app-deployed "$APP" --recipient discord-deploys 2>&1 || true)"
  if grep -q 'Received response: HTTP/1.1 2' <<<"$OUT"; then
    echo "✅ mensagem de deploy de teste ($APP) enviada ao #deploys"
  else
    echo "❌ o #deploys não aceitou a mensagem:"
    grep -v '"level":"debug"' <<<"$OUT" | sed -E 's#https://(discord(app)?\.com)/api/webhooks/[^ "]+#https://\1/api/webhooks/***#g' | tail -5
    exit 1
  fi
else
  echo "↷ ArgoCD Notifications não instalado: make notifications"
fi
