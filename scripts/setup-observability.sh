#!/usr/bin/env bash
# =============================================================================
# setup-observability.sh  (genérico)
# -----------------------------------------------------------------------------
# Stack de observabilidade e alertas. Idempotente — roda no setup e pode ser
# rodado de novo num cluster existente (make observability).
#
#   1. kube-prometheus-stack: Prometheus, Alertmanager e Grafana
#      (config/observability/kube-prometheus-stack-values.yaml).
#   2. Métricas do NGINX Ingress (requests, status, latência por app) +
#      ServiceMonitor — sem instrumentar os apps. É o SLI dos SLOs.
#   3. Métricas do ArgoCD (alertas de app Degraded/OutOfSync).
#   4. Loki single-binary (config/observability/loki-values.yaml).
#   5. Grafana Alloy coletando os logs dos pods dos projetos
#      (config/observability/alloy-values.yaml).
#
# Dashboards, datasource Loki e regras de SLO/alertas ficam em k8s/
# (apply-platform.sh).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="$INFRA_ROOT/config/observability"
# shellcheck source=lib-sso.sh
source "$SCRIPT_DIR/lib-sso.sh"

# --only-kps: só o kube-prometheus-stack (usado pelo setup-sso.sh).
ONLY_KPS=false
[[ "${1:-}" == "--only-kps" ]] && ONLY_KPS=true

# Login único configurado (make sso)? Então Grafana/Prometheus/Alertmanager
# sobem com ele — senão um `make observability` desligaria o login.
SSO_VALUES=()
if sso_enabled; then
  SSO_TMP="$(mktemp -d)"; trap 'rm -rf "$SSO_TMP"' EXIT
  sso_render "$SSO_TMP" >/dev/null
  SSO_VALUES=(-f "$SSO_TMP/kube-prometheus-stack.json")
fi
# Webhooks do Discord configurados (make notifications)? Alertmanager notifica.
if kubectl get secret alertmanager-webhooks -n monitoring >/dev/null 2>&1; then
  SSO_VALUES+=(-f "$INFRA_ROOT/config/notifications/alertmanager-values.yaml")
fi

KPS_CHART_VERSION="92.11.0"
LOKI_CHART_VERSION="7.3.0"
ALLOY_CHART_VERSION="1.13.0"

step() { echo -e "\033[0;36m▸ $1\033[0m"; }

# Versão do chart já instalado: o --reuse-values só liga flags, sem trocar a
# versão do Ingress/ArgoCD por baixo dos panos.
installed_chart_version() {
  helm list -n "$2" -f "^$1\$" -o json | jq -r '.[0].chart // empty' | sed -E 's/^.*-(v?[0-9]+\.[0-9]+\.[0-9]+.*)$/\1/'
}

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update prometheus-community grafana ingress-nginx argo jetstack >/dev/null

step "kube-prometheus-stack $KPS_CHART_VERSION (Prometheus, Alertmanager, Grafana)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  -f "$CFG/kube-prometheus-stack-values.yaml" ${SSO_VALUES[@]+"${SSO_VALUES[@]}"} \
  --timeout 10m --wait >/dev/null
$ONLY_KPS && exit 0

step "NGINX Ingress: métricas + ServiceMonitor"
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --version "$(installed_chart_version ingress-nginx kube-system)" \
  --namespace kube-system --reuse-values \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=true \
  --timeout 5m --wait >/dev/null

step "ArgoCD: métricas + ServiceMonitor"
helm upgrade argocd argo/argo-cd \
  --version "$(installed_chart_version argocd argocd)" \
  --namespace argocd --reuse-values \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=true \
  --set server.metrics.enabled=true \
  --set server.metrics.serviceMonitor.enabled=true \
  --set repoServer.metrics.enabled=true \
  --set repoServer.metrics.serviceMonitor.enabled=true \
  --timeout 5m --wait >/dev/null

# Validade dos certificados (painel "Certificados vencendo" do Início). O
# cert-manager sobe antes do Prometheus (setup-security.sh); o ServiceMonitor
# só pode ser criado agora.
if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  step "cert-manager: ServiceMonitor"
  helm upgrade cert-manager jetstack/cert-manager \
    --version "$(installed_chart_version cert-manager cert-manager)" \
    --namespace cert-manager --reuse-values \
    --set prometheus.enabled=true \
    --set prometheus.servicemonitor.enabled=true \
    --timeout 5m --wait >/dev/null
fi

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

echo -e "\033[0;32m✅ Observabilidade: Prometheus/Alertmanager/Grafana, métricas do Ingress e do ArgoCD, Loki e Alloy prontos\033[0m"
