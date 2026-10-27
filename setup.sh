#!/bin/bash
set -e

# ==============================================================================
# DevOps Platform - Setup Unificado (genérico, orientado a projetos)
# ==============================================================================
# 1. Cria cluster k3d
# 2. Instala NGINX Ingress Controller
# 3. Instala ArgoCD (GitOps)
# 4. Instala Prometheus + Grafana (observabilidade)
# 5. Para cada projeto em projects/<nome>/: namespaces <nome>-<env>,
#    dependências (Postgres/Redis/RabbitMQ), ghcr-secret e app-secrets
#    (scripts/apply-project.sh)
# 6. Plataforma genérica: argocd/ (ApplicationSet que descobre os projetos no
#    Git) e k8s/ (dashboards) — scripts/apply-platform.sh
# 7. /etc/hosts num bloco isolado (scripts/hosts.sh)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$SCRIPT_DIR"

# Carrega .env (DATA_DIR, CLUSTER_NAME, GITHUB_TOKEN, GITHUB_USERNAME, ...)
if [ -f "$INFRA_ROOT/.env" ]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-devops-lab}"
DATA_DIR="${DATA_DIR:-$HOME/.devops-lab}"
# Expande eventual $HOME literal vindo do .env
DATA_DIR="$(eval echo "$DATA_DIR")"
K3D_AGENTS="${K3D_AGENTS:-1}"
export CLUSTER_NAME DATA_DIR K3D_AGENTS

# shellcheck source=scripts/lib-project.sh
source "$SCRIPT_DIR/scripts/lib-project.sh"

cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║   DevOps Platform - Kubernetes Local (GitOps)             ║
║   k3d + NGINX Ingress + ArgoCD + Prometheus/Grafana       ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
echo -e "${CYAN}Configuração:${NC}"
echo "  • Cluster:   $CLUSTER_NAME"
echo "  • DATA_DIR:  $DATA_DIR"
echo "  • Agents:    $K3D_AGENTS (+1 server)"
echo "  • Projetos:  $(project_names | paste -sd ', ' -)"
echo ""

# Confere tokens, variáveis e GitHub antes de gastar 15 min de setup.
if [[ "${SKIP_DOCTOR:-0}" != "1" ]]; then
  if ! bash "$SCRIPT_DIR/scripts/doctor.sh"; then
    echo -e "${RED}Corrija os erros acima (ou rode com SKIP_DOCTOR=1 para ignorar).${NC}"
    exit 1
  fi
  echo ""
fi

read -p "Iniciar setup? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Setup cancelado.${NC}"
    exit 0
fi

log_step() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}
log_substep() { echo -e "${CYAN}▸ $1${NC}"; }

# ==============================================================================
# ETAPA 1: Cluster k3d
# ==============================================================================
log_step "ETAPA 1/7: Cluster Kubernetes (k3d)"

if k3d cluster list | grep -q "$CLUSTER_NAME"; then
    echo -e "${YELLOW}⚠️  Cluster '$CLUSTER_NAME' já existe, prosseguindo...${NC}"
else
    log_substep "Preparando volumes em $DATA_DIR ..."
    mkdir -p "$DATA_DIR"/{data,postgres,prometheus,grafana}

    log_substep "Renderizando k3d-config (envsubst)..."
    RENDERED_K3D="$(mktemp -t k3d-config.XXXXXX.yaml)"
    envsubst '${CLUSTER_NAME} ${DATA_DIR} ${K3D_AGENTS}' \
      < "$INFRA_ROOT/config/k3d-config.tmpl.yaml" > "$RENDERED_K3D"

    log_substep "Criando cluster k3d..."
    k3d cluster create --config="$RENDERED_K3D"
    rm -f "$RENDERED_K3D"

    sleep 10
    kubectl get nodes -o wide
fi

# ==============================================================================
# ETAPA 1.5: NGINX Ingress Controller
# ==============================================================================
log_step "ETAPA 1.5/7: NGINX Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
# Service LoadBalancer: o servicelb do k3s (pods svclb-*) escuta 80/443 em
# todo node e encaminha ao controller. Sem hostPort no controller — os dois
# juntos disputam as portas no node onde o controller roda.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace kube-system \
  --set controller.publishService.enabled=true \
  --set controller.service.type=LoadBalancer \
  --set controller.watchIngressWithoutClass=true \
  --set controller.metrics.enabled=true \
  --set 'controller.nodeSelector.kubernetes\.io/os=linux' \
  --timeout 5m --wait

kubectl wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=ingress-nginx \
  --namespace=kube-system --timeout=120s 2>/dev/null || echo "NGINX ainda inicializando..."
echo -e "${GREEN}✓ NGINX Ingress Controller instalado${NC}"

# ==============================================================================
# ETAPA 2: Namespaces de infra
# ==============================================================================
log_step "ETAPA 2/7: Namespaces de infra, HTTPS e políticas"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# cert-manager + CA local (HTTPS dos Ingress) e Kyverno (políticas e
# NetworkPolicies dos projetos). Antes do ArgoCD/Grafana, cujos Ingress já
# pedem certificado.
bash "$SCRIPT_DIR/scripts/setup-security.sh"

# ==============================================================================
# ETAPA 3: ArgoCD
# ==============================================================================
log_step "ETAPA 3/7: ArgoCD"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set server.extraArgs[0]="--insecure" \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP \
  --set controller.metrics.enabled=true \
  --set server.metrics.enabled=true \
  --set repoServer.metrics.enabled=true \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --timeout 10m --wait

kubectl wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --namespace=argocd --timeout=300s 2>/dev/null || echo "ArgoCD ainda inicializando..."

log_substep "Ingress do ArgoCD..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    cert-manager.io/cluster-issuer: platform-ca
    cert-manager.io/usages: "digital signature,key encipherment,server auth"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  tls:
  - hosts: [argocd.devops.local]
    secretName: argocd-server-tls
  rules:
  - host: argocd.devops.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "não-disponível")
echo -e "${GREEN}✓ ArgoCD instalado - admin / $ARGOCD_PASSWORD${NC}"

# ==============================================================================
# ETAPA 4: Observabilidade (Prometheus + Grafana)
# ==============================================================================
log_step "ETAPA 4/7: Observabilidade (Prometheus, Grafana, Loki)"

# Prometheus/Alertmanager/Grafana (config/observability/*-values.yaml),
# métricas do Ingress e do ArgoCD, Loki e Alloy. O mesmo script roda no
# `make observability` para atualizar um cluster existente.
bash "$SCRIPT_DIR/scripts/setup-observability.sh"

# Argo Rollouts (canary com análise no Prometheus) — precisa do CRD
# ServiceMonitor do kube-prometheus-stack.
bash "$SCRIPT_DIR/scripts/setup-delivery.sh"

# Postgres gerenciado (CloudNativePG) + backup num S3 fora do cluster. Vem
# antes dos projetos: cada banco nasce restaurando o último backup, se houver.
bash "$SCRIPT_DIR/scripts/setup-data.sh"

kubectl wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=grafana \
  --namespace=monitoring --timeout=300s 2>/dev/null || echo "Grafana ainda inicializando..."
echo -e "${GREEN}✓ Grafana instalado - admin / devops.local2026${NC}"

# ==============================================================================
# ETAPA 5: Projetos (namespaces, dependências, secrets) + plataforma GitOps
# ==============================================================================
log_step "ETAPA 5/7: Projetos e ArgoCD"

# Sealed Secrets antes dos projetos: as dependências (Postgres, Redis,
# RabbitMQ) leem as credenciais dos Secrets que o controller abre.
bash "$SCRIPT_DIR/scripts/setup-sealed-secrets.sh"

# Primeiro o que o ArgoCD não cria (secrets/dependências), depois o
# ApplicationSet — assim os pods já nascem com os Secrets disponíveis.
for PROJ in $(project_names); do
  bash "$SCRIPT_DIR/scripts/apply-project.sh" "$PROJ"
done

bash "$SCRIPT_DIR/scripts/apply-platform.sh"

# Login único (GitHub via Dex). Sem o OAuth App selado
# (config/auth/github-oauth.sealed.yaml), só explica como configurar.
bash "$SCRIPT_DIR/scripts/setup-sso.sh"

# Notificações no Discord (alertas e deploys). Sem os webhooks selados
# (config/notifications/*.sealed.yaml), só explica como configurar.
bash "$SCRIPT_DIR/scripts/setup-notifications.sh"

# ==============================================================================
# ETAPA 6: /etc/hosts (bloco isolado entre marcadores devops-platform)
# ==============================================================================
log_step "ETAPA 6/7: DNS Local (/etc/hosts)"

bash "$SCRIPT_DIR/scripts/hosts.sh" apply

# ==============================================================================
# ETAPA 7: Verificação
# ==============================================================================
log_step "ETAPA 7/7: Verificação Final"

kubectl wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=ingress-nginx \
  --namespace=kube-system --timeout=60s 2>/dev/null || echo "NGINX ainda inicializando..."
sleep 5

for CHECK in "argocd.devops.local ArgoCD" "grafana.devops.local Grafana" "prometheus.devops.local Prometheus" "alertmanager.devops.local AlertManager"; do
    HOST=$(echo "$CHECK" | cut -d' ' -f1); NAME=$(echo "$CHECK" | cut -d' ' -f2)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --resolve "${HOST}:80:127.0.0.1" "http://${HOST}" 2>/dev/null)
    if [[ "$HTTP_CODE" =~ ^(200|301|302|303|307|404)$ ]]; then
        echo -e "${GREEN}✓ ${NAME} acessível (HTTP ${HTTP_CODE})${NC}"
    else
        echo -e "${YELLOW}⚠️  ${NAME} ainda inicializando (HTTP ${HTTP_CODE})${NC}"
    fi
done

echo ""
echo -e "${GREEN}✨  SETUP CONCLUÍDO  ✨${NC}"
echo ""
echo -e "  🎯 ArgoCD       → https://argocd.devops.local   (admin / $ARGOCD_PASSWORD)"
echo -e "  📊 Grafana      → https://grafana.devops.local   (admin / devops.local2026)"
echo -e "  🔍 Prometheus   → https://prometheus.devops.local"
echo -e "  🚨 AlertManager → https://alertmanager.devops.local"
echo -e "  🚦 Rollouts     → https://rollouts.devops.local"
echo ""
CA_CERT_FILE="$(eval echo "${PLATFORM_CA_DIR:-$HOME/.config/devops-platform/ca}")/platform-ca.crt"
if [[ "$(uname)" == "Darwin" ]] && ! security verify-cert -c "$CA_CERT_FILE" >/dev/null 2>&1; then
    echo -e "${YELLOW}🔒 Para o navegador confiar no https://*.local: make trust-ca${NC} (uma vez; http continua funcionando)"
    echo ""
fi
echo -e "${CYAN}Projetos aplicados:${NC} $(project_names | paste -sd ', ' -)"
echo -e "${CYAN}Próximos passos:${NC} make status | k9s | make destroy"
echo ""
