#!/usr/bin/env bash
# =============================================================================
# setup-data.sh  (genérico)
# -----------------------------------------------------------------------------
# Dados persistentes: o que os bancos dos projetos precisam. Idempotente —
# roda no setup (antes dos projetos) e de novo num cluster existente
# (make data).
#
#   1. storage de backup (S3 num container fora do cluster, lib-backup.sh)
#   2. operador CloudNativePG (cria e cuida dos Postgres: réplicas, failover)
#   3. plugin Barman Cloud (WAL contínuo + backup base no S3)
#
# Os bancos em si são criados por setup-postgres.sh, por projeto/ambiente.
# Requer o cert-manager (setup-security.sh) e o CRD PodMonitor
# (setup-observability.sh). docs/21-banco-de-dados.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-backup.sh
source "$SCRIPT_DIR/lib-backup.sh"

CNPG_CHART_VERSION="0.29.1"      # CloudNativePG 1.30.1
BARMAN_CHART_VERSION="0.8.1"     # plugin-barman-cloud v0.15.1

step() { echo -e "\033[0;36m▸ $1\033[0m"; }

step "Storage de backup ($(backup_where), fora do cluster)"
backup_store_up

helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null

step "CloudNativePG $CNPG_CHART_VERSION"
helm upgrade --install cnpg cnpg/cloudnative-pg --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system --create-namespace \
  -f "$INFRA_ROOT/config/data/cloudnative-pg-values.yaml" \
  --timeout 5m --wait >/dev/null

step "Plugin Barman Cloud $BARMAN_CHART_VERSION"
helm upgrade --install barman-cloud cnpg/plugin-barman-cloud --version "$BARMAN_CHART_VERSION" \
  --namespace cnpg-system \
  -f "$INFRA_ROOT/config/data/plugin-barman-cloud-values.yaml" \
  --timeout 5m --wait >/dev/null

echo -e "\033[0;32m✅ Dados persistentes prontos (backups: $(backup_where))\033[0m"
