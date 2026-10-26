#!/usr/bin/env bash
# =============================================================================
# setup-sso.sh  (genérico) — login único (SSO) com GitHub via Dex. Idempotente.
# make sso. Detalhes: docs/18-login-sso.md
#
#   Dex          https://auth.devops.local   (OIDC; conector GitHub)
#   oauth2-proxy https://oauth2.devops.local (porteiro das UIs sem login próprio)
#   ArgoCD       OIDC no Dex + RBAC por grupo (admins / dev do projeto / leitura)
#   Grafana      OAuth genérico no Dex, papel pelo grupo (Admin/Editor/Viewer)
#   Prometheus, Alertmanager, dashboard do Rollouts  atrás do oauth2-proxy
#
# Pré-requisito: o OAuth App do GitHub selado em
# config/auth/github-oauth.sealed.yaml (make sso-github). Sem ele, o script
# explica o que fazer e sai sem mudar nada.
# Segredos entre Dex e os clientes (ArgoCD, Grafana, oauth2-proxy) são gerados
# aqui, ficam só no cluster e são recriados se o cluster for recriado.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-sso.sh
source "$SCRIPT_DIR/lib-sso.sh"

DEX_CHART_VERSION="0.26.0"            # Dex 2.46.0
OAUTH2_PROXY_CHART_VERSION="10.7.1"   # oauth2-proxy 7.15.5
SEALED="$INFRA_ROOT/config/auth/github-oauth.sealed.yaml"

step() { echo -e "\033[0;36m▸ $1\033[0m"; }
installed_chart_version() {
  helm list -n "$2" -f "^$1\$" -o json | jq -r '.[0].chart // empty' | sed -E 's/^.*-(v?[0-9]+\.[0-9]+\.[0-9]+.*)$/\1/'
}

kubectl create namespace auth --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 1. Credenciais do GitHub (OAuth App), seladas no Git.
if [[ -f "$SEALED" ]]; then
  kubectl apply -f "$SEALED" >/dev/null
  for _ in $(seq 1 30); do sso_enabled && break; sleep 2; done
fi
if ! sso_enabled; then
  if [[ -n "${SSO_TEST_MOCK:-}" ]]; then
    kubectl -n auth create secret generic dex-github \
      --from-literal=GITHUB_CLIENT_ID=teste --from-literal=GITHUB_CLIENT_SECRET=teste >/dev/null
  else
    echo -e "\033[1;33m⚠ Login único ainda não configurado: falta o OAuth App do GitHub.\033[0m"
    echo "  1. Crie em https://github.com/organizations/infra-devops-full/settings/applications/new"
    echo "     Homepage URL:               https://argocd.devops.local"
    echo "     Authorization callback URL: https://auth.devops.local/callback"
    echo "  2. make sso-github   (cola o Client ID e um Client secret; gera o arquivo selado)"
    echo "  3. git add config/auth/github-oauth.sealed.yaml && git commit && git push"
    echo "  4. make sso"
    exit 0
  fi
fi

# 2. Segredos dos clientes do Dex (só no cluster).
rand() { openssl rand -hex 16; }
if ! kubectl get secret dex-clients -n auth >/dev/null 2>&1; then
  step "Gerando os segredos dos clientes do Dex"
  kubectl -n auth create secret generic dex-clients \
    --from-literal=ARGOCD_CLIENT_SECRET="$(rand)" \
    --from-literal=GRAFANA_CLIENT_SECRET="$(rand)" \
    --from-literal=OAUTH2_PROXY_CLIENT_SECRET="$(rand)" >/dev/null
fi
get() { kubectl get secret dex-clients -n auth -o jsonpath="{.data.$1}" | base64 -d; }
kubectl -n argocd create secret generic argocd-oidc --from-literal=clientSecret="$(get ARGOCD_CLIENT_SECRET)" \
  --dry-run=client -o yaml | kubectl label --local -f - app.kubernetes.io/part-of=argocd -o yaml | kubectl apply -f - >/dev/null
kubectl -n monitoring create secret generic grafana-oidc \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$(get GRAFANA_CLIENT_SECRET)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
COOKIE="$(kubectl get secret oauth2-proxy -n auth -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 -d || true)"
kubectl -n auth create secret generic oauth2-proxy --from-literal=client-id=oauth2-proxy \
  --from-literal=client-secret="$(get OAUTH2_PROXY_CLIENT_SECRET)" \
  --from-literal=cookie-secret="${COOKIE:-$(rand)}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 3. Values de todos os componentes (config/auth/access.yaml + projects/).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sso_render "$TMP"

helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests >/dev/null 2>&1 || true
helm repo update dex oauth2-proxy prometheus-community argo >/dev/null

step "Dex $DEX_CHART_VERSION (https://$AUTH_HOST)"
helm upgrade --install dex dex/dex --version "$DEX_CHART_VERSION" -n auth \
  -f "$TMP/dex.json" --timeout 5m --wait >/dev/null
# Config nova do Dex (orgs, clientes) só é lida na subida.
kubectl -n auth rollout restart deploy/dex >/dev/null && kubectl -n auth rollout status deploy/dex --timeout=120s >/dev/null

step "oauth2-proxy $OAUTH2_PROXY_CHART_VERSION (https://$OAUTH2_HOST)"
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy --version "$OAUTH2_PROXY_CHART_VERSION" -n auth \
  -f "$TMP/oauth2-proxy.json" --timeout 5m --wait >/dev/null

step "ArgoCD: login GitHub + RBAC"
helm upgrade argocd argo/argo-cd --version "$(installed_chart_version argocd argocd)" -n argocd \
  --reuse-values -f "$TMP/argocd.json" --timeout 5m --wait >/dev/null
kubectl -n argocd rollout restart deploy/argocd-server >/dev/null

step "Grafana, Prometheus e Alertmanager: login"
bash "$SCRIPT_DIR/setup-observability.sh" --only-kps >/dev/null

step "Dashboard do Argo Rollouts: login (só admins) e ações liberadas"
bash "$SCRIPT_DIR/setup-delivery.sh" >/dev/null

echo -e "\033[0;32m✅ Login único pronto.\033[0m Entre em https://argocd.devops.local → \"LOG IN VIA GITHUB\""
echo "   Se for a primeira vez: make hosts (auth.devops.local e oauth2.devops.local)"
