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

secret() { kubectl -n "$NS" get secret rabbitmq -o jsonpath="{.data.$1}" | base64 -d; }

if project_rabbitmq_ui "$PROJ"; then
  echo "URL:     https://$(project_rabbitmq_host "$PROJ" "$ENV_NAME")  (antes: login do GitHub)"
else
  echo "URL:     http://localhost:15672  (kubectl -n $NS port-forward svc/rabbitmq 15672:15672)"
fi
echo "Usuário: $(secret RABBITMQ_USER)"
echo "Senha:   $(secret RABBITMQ_PASSWORD)"
