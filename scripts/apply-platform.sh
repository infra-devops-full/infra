#!/usr/bin/env bash
# =============================================================================
# apply-platform.sh  (genérico)
# -----------------------------------------------------------------------------
# Aplica os manifests genéricos da plataforma:
#   argocd/*.yaml  AppProject + ApplicationSet que descobrem os projetos no Git
#                  (renderizados com envsubst: ${INFRA_REPO_URL} ${INFRA_BRANCH})
#   k8s/*.yaml     manifests de plataforma (dashboards do Grafana, ...)
#
# Uso:
#   ./scripts/apply-platform.sh            # aplica
#   ./scripts/apply-platform.sh --render   # só mostra o que seria aplicado
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

INFRA_REPO_URL="$(infra_repo_url)"
INFRA_BRANCH="${INFRA_BRANCH:-main}"
export INFRA_REPO_URL INFRA_BRANCH

if [[ -z "$INFRA_REPO_URL" ]]; then
  echo "❌ INFRA_REPO_URL vazio (defina no .env ou configure o git remote origin)"
  exit 1
fi

render() {
  local f
  for f in "$INFRA_ROOT"/argocd/*.yaml; do
    echo "---"
    envsubst '${INFRA_REPO_URL} ${INFRA_BRANCH}' < "$f"
  done
  for f in "$INFRA_ROOT"/k8s/*.yaml; do
    echo "---"
    cat "$f"
  done
}

if [[ "${1:-}" == "--render" ]]; then
  render
  exit 0
fi

echo "▸ ArgoCD observando $INFRA_REPO_URL ($INFRA_BRANCH)"
render | kubectl apply -f -
echo "✅ Plataforma aplicada (argocd/ + k8s/)"
