#!/usr/bin/env bash
# =============================================================================
# setup-tracing.sh  (genérico)
# -----------------------------------------------------------------------------
# Tracing distribuído. Idempotente — roda no setup (depois da observabilidade)
# e de novo num cluster existente (make tracing).
#
#   Tempo                    guarda os traces (72h) e gera métricas deles
#   OpenTelemetry Operator   injeta o agente (Java/Node.js) nos apps com
#                            `tracing.enabled` — sem mudar código
#
# O Alloy (setup-observability.sh) recebe os spans dos apps e repassa ao
# Tempo; o Instrumentation (k8s/otel-instrumentation.yaml) e o datasource
# (k8s/grafana-datasource-tempo.yaml) entram pelo apply-platform.sh.
# Requer o cert-manager (webhook do operador). docs/22-tracing.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="$INFRA_ROOT/config/tracing"

TEMPO_CHART_VERSION="3.1.0"      # Tempo 3.1.0 (grafana-community; o grafana/tempo foi depreciado)
OTEL_OPERATOR_CHART_VERSION="0.127.0"   # operator 0.162.0

step() { echo -e "\033[0;36m▸ $1\033[0m"; }

helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update grafana-community open-telemetry >/dev/null

step "Tempo $TEMPO_CHART_VERSION"
helm upgrade --install tempo grafana-community/tempo --version "$TEMPO_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  -f "$CFG/tempo-values.yaml" \
  --timeout 5m --wait >/dev/null

step "OpenTelemetry Operator $OTEL_OPERATOR_CHART_VERSION"
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --version "$OTEL_OPERATOR_CHART_VERSION" \
  --namespace opentelemetry-operator-system --create-namespace \
  -f "$CFG/opentelemetry-operator-values.yaml" \
  --timeout 5m --wait >/dev/null

# Num cluster existente, o Instrumentation entra já (no setup, o
# apply-platform.sh aplica k8s/ logo depois).
if kubectl get crd instrumentations.opentelemetry.io >/dev/null 2>&1; then
  kubectl apply --server-side --field-manager=devops-platform --force-conflicts \
    -f "$INFRA_ROOT/k8s/otel-instrumentation.yaml" >/dev/null
fi

echo -e "\033[0;32m✅ Tracing pronto: Tempo + OpenTelemetry Operator (ligue com tracing.enabled nos values; Grafana → Explore → Tempo)\033[0m"
