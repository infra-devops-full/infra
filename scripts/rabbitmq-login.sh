#!/usr/bin/env bash
# =============================================================================
# rabbitmq-login.sh  (genérico) — URL, usuário e senha do painel do RabbitMQ
# de um projeto/ambiente. O Ingress pede antes o login do GitHub (SSO); depois
# o RabbitMQ pede o usuário/senha dele, que estão no Secret `rabbitmq`.
#
# Uso: ./scripts/rabbitmq-login.sh <projeto> <ambiente>   (make rabbitmq-login)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

PROJ="${1:?Uso: $0 <projeto> <ambiente>}"
ENV_NAME="${2:?Uso: $0 <projeto> <ambiente>}"
NS="${PROJ}-${ENV_NAME}"

if ! project_rabbitmq_enabled "$PROJ"; then
  echo "❌ $PROJ não tem rabbitmq.enabled no project.yaml"; exit 1
fi
if ! grep -qx "$ENV_NAME" <(project_envs "$PROJ"); then
  echo "❌ ambiente '$ENV_NAME' não existe em $PROJ (há: $(project_envs "$PROJ" | xargs))"; exit 1
fi

secret() { kubectl -n "$NS" get secret rabbitmq -o jsonpath="{.data.$1}" | base64 -d; }

if project_rabbitmq_ui "$PROJ"; then
  echo "URL:     https://$RABBITMQ_UI_HOST/$NS/  (antes: login do GitHub)"
else
  echo "URL:     http://localhost:15672  (kubectl -n $NS port-forward svc/rabbitmq 15672:15672)"
fi
echo "Usuário: $(secret RABBITMQ_USER)"
echo "Senha:   $(secret RABBITMQ_PASSWORD)"
