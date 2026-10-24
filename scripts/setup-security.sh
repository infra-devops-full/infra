#!/usr/bin/env bash
# =============================================================================
# setup-security.sh  (genérico)
# -----------------------------------------------------------------------------
# Segurança da plataforma. Idempotente — roda no setup e de novo num cluster
# existente (make security).
#
#   1. cert-manager + CA local (config/security/platform-ca.yaml): todo Ingress
#      com a annotation cert-manager.io/cluster-issuer ganha certificado HTTPS.
#      A chave da CA tem backup em $PLATFORM_CA_DIR (fora do Git); ao recriar
#      o cluster ela é restaurada, e o navegador que confiou nela (make
#      trust-ca) continua confiando.
#   2. Kyverno (config/security/kyverno-values.yaml): políticas de admissão e
#      geração das NetworkPolicies de cada namespace de projeto.
#
# As políticas e regras ficam em k8s/kyverno-*.yaml (apply-platform.sh).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi
CFG="$INFRA_ROOT/config/security"

CERT_MANAGER_CHART_VERSION="v1.21.2"
KYVERNO_CHART_VERSION="3.9.2"   # Kyverno 1.19.2
CA_DIR="${PLATFORM_CA_DIR:-$HOME/.config/devops-platform/ca}"
CA_DIR="$(eval echo "$CA_DIR")"
CA_BACKUP="$CA_DIR/platform-ca-secret.yaml"
CA_CERT="$CA_DIR/platform-ca.crt"

step() { echo -e "\033[0;36m▸ $1\033[0m"; }
warn() { echo -e "  \033[1;33m⚠\033[0m $1"; }

mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
helm repo update jetstack kyverno >/dev/null

# 1. cert-manager
step "cert-manager $CERT_MANAGER_CHART_VERSION"
helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_CHART_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set resources.requests.cpu=10m --set resources.requests.memory=48Mi \
  --set webhook.resources.requests.cpu=10m --set webhook.resources.requests.memory=24Mi \
  --set cainjector.resources.requests.cpu=10m --set cainjector.resources.requests.memory=48Mi \
  --timeout 5m --wait >/dev/null

# Restaura a CA antes de criar o Certificate: o cert-manager adota o Secret
# existente (mesmo nome e annotations) em vez de gerar outra CA.
if [[ -f "$CA_BACKUP" ]] && ! kubectl get secret platform-ca -n cert-manager >/dev/null 2>&1; then
  step "Restaurando a CA de $CA_BACKUP"
  kubectl apply -f "$CA_BACKUP" >/dev/null
fi

step "CA local (ClusterIssuer platform-ca)"
kubectl apply -f "$CFG/platform-ca.yaml" >/dev/null
kubectl wait --for=condition=Ready certificate/platform-ca -n cert-manager --timeout=120s >/dev/null
kubectl wait --for=condition=Ready clusterissuer/platform-ca --timeout=60s >/dev/null

# Backup da CA (chave privada!) sem os campos que impedem recriar noutro cluster.
kubectl get secret platform-ca -n cert-manager -o yaml \
  | yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
  > "$CA_BACKUP.tmp"
mv "$CA_BACKUP.tmp" "$CA_BACKUP"
chmod 600 "$CA_BACKUP"

NEW_CERT="$(kubectl get secret platform-ca -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d)"
if [[ -f "$CA_CERT" ]] && [[ "$(cat "$CA_CERT")" != "$NEW_CERT" ]]; then
  warn "a CA MUDOU — o navegador vai desconfiar dos certificados até rodar \`make trust-ca\` de novo."
fi
echo "$NEW_CERT" > "$CA_CERT"
step "CA: backup em $CA_BACKUP, certificado público em $CA_CERT"

# 2. Kyverno
step "Kyverno $KYVERNO_CHART_VERSION"
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --create-namespace \
  -f "$CFG/kyverno-values.yaml" \
  --timeout 10m --wait >/dev/null

echo -e "\033[0;32m✅ Segurança: cert-manager + CA local e Kyverno prontos\033[0m"
