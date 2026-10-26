#!/usr/bin/env bash
# =============================================================================
# setup-delivery.sh  (genérico)
# -----------------------------------------------------------------------------
# Entrega progressiva: Argo Rollouts (controller + dashboard). Idempotente —
# roda no setup e de novo num cluster existente (make delivery).
#
# Com `rollout.enabled: true` nos values de um app, o chart gera um Rollout
# (canary pelo NGINX Ingress) em vez de um Deployment, e a análise
# (k8s/rollouts-analysis.yaml) consulta o Prometheus a cada passo: se a taxa
# de 5xx da versão nova passar do limite, o Rollout aborta e volta sozinho.
#
# Requer o kube-prometheus-stack (CRD ServiceMonitor) — roda depois do
# setup-observability.sh.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ROLLOUTS_CHART_VERSION="2.43.8"   # Argo Rollouts v1.10.1
# shellcheck source=lib-sso.sh
source "$SCRIPT_DIR/lib-sso.sh"

# Com o login único (make sso), o dashboard fica atrás do oauth2-proxy (só
# admins) e as ações (promote/abort/rollback) são liberadas.
SSO_VALUES=()
if sso_enabled; then
  SSO_TMP="$(mktemp -d)"; trap 'rm -rf "$SSO_TMP"' EXIT
  sso_render "$SSO_TMP" >/dev/null
  SSO_VALUES=(-f "$SSO_TMP/argo-rollouts.json")
fi

step() { echo -e "\033[0;36m▸ $1\033[0m"; }

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

step "Argo Rollouts $ROLLOUTS_CHART_VERSION"
helm upgrade --install argo-rollouts argo/argo-rollouts --version "$ROLLOUTS_CHART_VERSION" \
  --namespace argo-rollouts --create-namespace \
  -f "$INFRA_ROOT/config/delivery/argo-rollouts-values.yaml" ${SSO_VALUES[@]+"${SSO_VALUES[@]}"} \
  --timeout 5m --wait >/dev/null

# make rollouts/promote/abort usam só kubectl. O plugin `kubectl argo
# rollouts` é opcional (visualização em árvore no terminal).

echo -e "\033[0;32m✅ Argo Rollouts pronto (dashboard: https://rollouts.devops.local)\033[0m"
