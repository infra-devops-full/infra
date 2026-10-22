#!/bin/bash
# =============================================================================
# 99-show-urls.sh  (genérico) — URLs de acesso da plataforma e dos projetos
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

echo "🚀 DevOps Platform - URLs de Acesso"
echo "===================================="
echo ""

echo -e "${GREEN}🎯 Ferramentas:${NC}"
echo -e "  ${BLUE}ArgoCD:${NC}      http://argocd.devops.local   (admin)"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "n/d")
echo "               senha: $ARGOCD_PASS"
echo -e "  ${BLUE}Grafana:${NC}     http://grafana.devops.local   (admin / devops.local2026)"
echo -e "  ${BLUE}Prometheus:${NC}  http://prometheus.devops.local"
echo -e "  ${BLUE}AlertMgr:${NC}    http://alertmanager.devops.local"
echo ""

echo -e "${GREEN}🌐 Projetos:${NC}"
for PROJ in $(project_names); do
  echo -e "  ${YELLOW}$PROJ${NC}"
  for ENV_NAME in $(project_envs "$PROJ"); do
    echo -e "    ${BLUE}$ENV_NAME:${NC}"
    for h in $(project_hosts "$PROJ" "$ENV_NAME"); do
      echo "      http://$h"
    done
  done
done
echo ""

echo -e "${YELLOW}📦 Pods por namespace:${NC}"
for NS in argocd monitoring $(for p in $(project_names); do project_namespaces "$p"; done); do
  n=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  $NS: $n pods"
done
echo ""
echo -e "${GREEN}✅ Plataforma rodando!${NC}"
