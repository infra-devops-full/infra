#!/usr/bin/env bash
# =============================================================================
# setup-observability.sh  (genérico)
# -----------------------------------------------------------------------------
# Complementa o kube-prometheus-stack com o que o dashboard "Platform / Apps"
# usa além de CPU/memória. Idempotente — roda no setup e pode ser rodado de
# novo num cluster existente (make observability).
#
#   1. Métricas do NGINX Ingress (requests, status, latência por app) +
#      ServiceMonitor — sem instrumentar os apps.
#   2. Loki single-binary (config/observability/loki-values.yaml).
#   3. Grafana Alloy coletando os logs dos pods dos projetos
#      (config/observability/alloy-values.yaml).
#
# O datasource Loki do Grafana e o dashboard ficam em k8s/ (apply-platform.sh).
# Requer o kube-prometheus-stack instalado (CRD ServiceMonitor).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="$INFRA_ROOT/config/observability"

LOKI_CHART_VERSION="7.3.0"
ALLOY_CHART_VERSION="1.13.0"

step() { echo -e "\033[0;36m▸ $1\033[0m"; }

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana ingress-nginx >/dev/null

# hostPort 80/443: maxSurge=0 troca o pod sem disputar as portas (senão trava).
step "NGINX Ingress: métricas + ServiceMonitor"
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace kube-system --reuse-values \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=true \
  --set controller.updateStrategy.rollingUpdate.maxSurge=0 \
  --set controller.updateStrategy.rollingUpdate.maxUnavailable=1 \
  --timeout 5m --wait >/dev/null

step "Loki $LOKI_CHART_VERSION (single-binary)"
helm upgrade --install loki grafana/loki --version "$LOKI_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  -f "$CFG/loki-values.yaml" \
  --timeout 10m --wait >/dev/null

step "Grafana Alloy $ALLOY_CHART_VERSION (coleta de logs)"
helm upgrade --install alloy grafana/alloy --version "$ALLOY_CHART_VERSION" \
  --namespace monitoring \
  -f "$CFG/alloy-values.yaml" \
  --timeout 5m --wait >/dev/null

echo -e "\033[0;32m✅ Observabilidade: métricas do Ingress, Loki e Alloy prontos\033[0m"
