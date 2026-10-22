#!/usr/bin/env bash
# =============================================================================
# apply-project.sh  (genérico)
# -----------------------------------------------------------------------------
# Prepara no cluster o que o ArgoCD NÃO cria para um projeto. Idempotente.
#
#   1. namespaces <projeto>-<env>     (um por values-<env>.yaml encontrado)
#   2. dependências declaradas no project.yaml: Postgres, Redis, RabbitMQ
#   3. ghcr-secret                    (se GITHUB_TOKEN disponível)
#   4. Secret app-secrets             (projects/<p>/secrets/<env>.env)
#
# Os apps em si são criados pelo ApplicationSet genérico (argocd/) assim que
# os arquivos do projeto estão no Git. O /etc/hosts é atualizado à parte:
# ./scripts/hosts.sh apply
#
# Uso:
#   ./scripts/apply-project.sh <projeto>
# =============================================================================

set -euo pipefail

PROJ="${1:-}"
if [[ -z "$PROJ" ]]; then
  echo "Uso: $0 <projeto>"
  exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "${CYAN}▸ [$PROJ] $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

if [[ ! -f "$(project_manifest "$PROJ")" ]]; then
  echo "❌ projects/$PROJ/project.yaml não encontrado"
  exit 1
fi

ENVS="$(project_envs "$PROJ" | xargs)"
if [[ -z "$ENVS" ]]; then
  echo "❌ nenhum projects/$PROJ/apps/<app>/values-<env>.yaml encontrado"
  exit 1
fi
NAMESPACES="$(project_namespaces "$PROJ" | xargs)"

# 1. Namespaces ---------------------------------------------------------------
step "namespaces: $NAMESPACES"
for NS in $NAMESPACES; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" devops-platform/project="$PROJ" --overwrite >/dev/null
done

# 2. Dependências -------------------------------------------------------------
for NS in $NAMESPACES; do
  if project_db_enabled "$PROJ"; then
    step "Postgres em $NS"
    bash "$SCRIPT_DIR/setup-postgres.sh" --namespace "$NS" \
      --user "$(project_db_user "$PROJ")" \
      --password "$(project_db_password "$PROJ")" \
      --db "$(project_db_default "$PROJ")" \
      --extra-dbs "$(project_db_extras "$PROJ")"
  fi
  if project_redis_enabled "$PROJ"; then
    step "Redis em $NS"
    bash "$SCRIPT_DIR/setup-redis.sh" --namespace "$NS" \
      --password "$(project_redis_password "$PROJ")"
  fi
  if project_rabbitmq_enabled "$PROJ"; then
    step "RabbitMQ em $NS"
    bash "$SCRIPT_DIR/setup-rabbitmq.sh" --namespace "$NS" \
      --user "$(project_rabbitmq_user "$PROJ")" \
      --password "$(project_rabbitmq_password "$PROJ")"
  fi
done

# 3. ghcr-secret --------------------------------------------------------------
if [[ -n "${GITHUB_TOKEN:-}" && "${GITHUB_TOKEN}" != ghp_your_github_token_here ]]; then
  step "ghcr-secret"
  bash "$INFRA_ROOT/create-ghcr-secrets.sh" --namespaces "$NAMESPACES" >/dev/null || \
    echo -e "  ${YELLOW}⚠️  falha ao criar ghcr-secret (confira GITHUB_TOKEN/GITHUB_USERNAME)${NC}"
else
  echo -e "  ${YELLOW}⚠️  GITHUB_TOKEN ausente: imagens privadas do GHCR não vão baixar.${NC}"
  echo -e "     make ghcr NAMESPACES=\"$NAMESPACES\" TOKEN=<token>"
fi

# 4. Secrets das apps ---------------------------------------------------------
for ENV_NAME in $ENVS; do
  step "app-secrets ($ENV_NAME)"
  bash "$SCRIPT_DIR/apply-secrets.sh" "$PROJ" "$ENV_NAME"
done

echo -e "${GREEN}✅ Projeto '$PROJ' preparado — o ArgoCD cria os apps a partir do Git${NC}"
