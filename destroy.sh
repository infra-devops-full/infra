#!/bin/bash

# DevOps Lab Ninja - Destruir Ambiente
# ========================================
# Remove completamente o Lab Ninja local:
# - Deleta cluster k3d
# - Remove entradas do /etc/hosts
# - Limpa contexto do kubeconfig

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"; set +a
fi
CLUSTER_NAME="${CLUSTER_NAME:-devops-lab}"
DATA_DIR="${DATA_DIR:-$HOME/.devops-lab}"
DATA_DIR="$(eval echo "$DATA_DIR")"

cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║    _   _                    ____ _                 _ _    ║
║   | \ | | _____  _____    / ___| | ___  _   _  __| | |   ║
║   |  \| |/ _ \ \/ / _ \  | |   | |/ _ \| | | |/ _` | |   ║
║   | |\  |  __/>  < (_) | | |___| | (_) | |_| | (_| | |__ ║
║   |_| \_|\___/_/\_\___/   \____|_|\___/ \__,_|\__,_|____|║
║                                                           ║
║   🥷 Destroy Lab Ninja                              ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
echo -e "${RED}⚠️  AVISO: Esta ação irá destruir completamente o Lab!${NC}"
echo ""
echo -e "${YELLOW}Será removido:${NC}"
echo "  • Cluster Kubernetes (k3d)"
echo "  • Todos os pods e deployments"
echo "  • Dados do Prometheus e Grafana"
echo "  • ArgoCD e todas as aplicações"
echo "  • Entradas do /etc/hosts"
echo "  • Contexto do kubeconfig"
echo ""
echo -e "${CYAN}O que NÃO será removido:${NC}"
echo "  • Código fonte deste repositório"
echo "  • Configurações do Helm (charts)"
echo "  • Imagens Docker em cache"
echo ""
read -p "Tem certeza que deseja continuar? (yes/N): " -r
echo

if [[ ! $REPLY =~ ^(yes|YES)$ ]]; then
    echo -e "${GREEN}✓ Operação cancelada${NC}"
    exit 0
fi

echo ""
echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║           INICIANDO DESTRUIÇÃO DO LAB               ║${NC}"
echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ==============================================================================
# Verificar se cluster existe
# ==============================================================================
if ! k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo -e "${YELLOW}⚠️  Cluster '$CLUSTER_NAME' não encontrado${NC}"
    echo -e "${BLUE}ℹ️  Continuando com limpeza de configurações...${NC}"
else
    # Mostrar resumo antes de deletar
    echo -e "${CYAN}📊 Resumo do que será deletado:${NC}"
    echo ""
    
    echo -e "${BLUE}Namespaces:${NC}"
    kubectl get namespaces --no-headers 2>/dev/null | grep -E "devops-|argocd|monitoring" | awk '{print "  • " $1}' || echo "  (nenhum encontrado)"
    echo ""
    
    echo -e "${BLUE}Applications ArgoCD:${NC}"
    APP_COUNT=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$APP_COUNT" -gt "0" ]; then
        echo "  • Total: $APP_COUNT aplicações"
    else
        echo "  (nenhuma encontrada)"
    fi
    echo ""
    
    echo -e "${BLUE}Pods Total:${NC}"
    POD_COUNT=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  • Total: $POD_COUNT pods"
    echo ""
    
    # Deletar cluster
    echo -e "${RED}🗑️  Deletando cluster k3d...${NC}"
    k3d cluster delete "$CLUSTER_NAME"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Cluster deletado com sucesso${NC}"
    else
        echo -e "${RED}✗ Erro ao deletar cluster${NC}"
    fi
fi

echo ""

# ==============================================================================
# Limpar /etc/hosts
# ==============================================================================
echo -e "${YELLOW}🧹 Limpando /etc/hosts...${NC}"

# Remove só o bloco "# >>> devops-platform >>>" (entradas suas ficam intactas)
bash "$SCRIPT_DIR/scripts/hosts.sh" remove || \
    echo -e "${YELLOW}⚠️  Não foi possível limpar o /etc/hosts${NC}"

echo ""

# ==============================================================================
# Limpar kubeconfig
# ==============================================================================
echo -e "${YELLOW}🧹 Limpando contexto do kubeconfig...${NC}"

# Verificar se contexto existe
if kubectl config get-contexts 2>/dev/null | grep -q "k3d-$CLUSTER_NAME"; then
    kubectl config delete-context "k3d-$CLUSTER_NAME" 2>/dev/null || true
    echo -e "${GREEN}✓ Contexto removido do kubeconfig${NC}"
else
    echo -e "${BLUE}  Nenhum contexto encontrado${NC}"
fi

echo ""

# ==============================================================================
# Opcional: Limpar volumes (pergunta antes)
# ==============================================================================
if [ -d "$DATA_DIR" ]; then
    echo -e "${YELLOW}📦 Volumes persistentes encontrados em: $DATA_DIR${NC}"
    read -p "Deseja remover os volumes também? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}🗑️  Removendo volumes...${NC}"
        sudo rm -rf "$DATA_DIR"
        echo -e "${GREEN}✓ Volumes removidos${NC}"
    else
        echo -e "${BLUE}ℹ️  Volumes mantidos (podem ser reutilizados no próximo setup)${NC}"
    fi
fi

# A chave do Sealed Secrets NUNCA é apagada aqui: sem ela, o próximo cluster
# não abre os segredos commitados em projects/*/sealed/.
SEALED_KEYS_DIR="$(eval echo "${SEALED_KEYS_DIR:-$HOME/.config/devops-platform/sealed-secrets}")"
if [ -f "$SEALED_KEYS_DIR/keys.yaml" ]; then
    echo -e "${BLUE}🔑 Chave do Sealed Secrets preservada em $SEALED_KEYS_DIR (restaurada no próximo make setup)${NC}"
fi

echo ""

# ==============================================================================
# Finalização
# ==============================================================================
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║          ✨  LAB DESTRUÍDO COM SUCESSO!  ✨         ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}📋 RESUMO DA LIMPEZA:${NC}"
echo -e "  ${GREEN}✓${NC} Cluster k3d removido"
echo -e "  ${GREEN}✓${NC} Entradas do /etc/hosts limpas"
echo -e "  ${GREEN}✓${NC} Contexto do kubeconfig removido"
echo ""
echo -e "${CYAN}🔄 Para recriar o ambiente:${NC}"
echo -e "  ${GREEN}make setup${NC}"
echo ""
echo -e "${BLUE}💡 Dica: O código fonte e configurações foram preservados${NC}"
echo ""
