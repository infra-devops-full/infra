#!/usr/bin/env bash
# =============================================================================
# rabbitmq-login.sh  (genérico) — URL e login do painel do RabbitMQ.
# O Ingress pede antes o login do GitHub (SSO); depois o RabbitMQ pede o
# usuário do painel, que é o MESMO em todos os projetos e ambientes
# (RABBITMQ_UI_USER / RABBITMQ_UI_PASSWORD do .env → Secret rabbitmq-ui).
# O usuário das apps (Secret rabbitmq) é outro e não entra no painel.
#
# Uso: ./scripts/rabbitmq-login.sh   (make rabbitmq-login)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

# Lê do cluster (o que está valendo), de qualquer namespace que tenha painel.
NS="$(kubectl get secret -A -l app=rabbitmq-ui -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
if [[ -z "$NS" ]]; then
  echo "❌ nenhum RabbitMQ com painel no cluster — rode make project-apply PROJECT=<p>"
  exit 1
fi
secret() { kubectl -n "$NS" get secret rabbitmq-ui -o jsonpath="{.data.$1}" | base64 -d; }

echo "URL:     https://$RABBITMQ_UI_HOST  (antes: login do GitHub)"
echo "Usuário: $(secret RABBITMQ_UI_USER)"
echo "Senha:   $(secret RABBITMQ_UI_PASSWORD)"
