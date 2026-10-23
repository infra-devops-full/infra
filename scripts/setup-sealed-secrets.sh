#!/usr/bin/env bash
# =============================================================================
# setup-sealed-secrets.sh  (genérico)
# -----------------------------------------------------------------------------
# Instala o controller do Sealed Secrets e cuida da CHAVE dele. Idempotente.
#
# Sealed Secrets: os Secrets vão para o Git CRIPTOGRAFADOS com a chave pública
# do cluster (config/sealed-secrets/cert.pem, versionada). Só o controller,
# com a chave privada, consegue abrir.
#
# A chave privada é o ponto crítico: perdê-la (ex.: `make destroy`) torna
# todos os arquivos selados ilegíveis. Por isso este script:
#   1. RESTAURA a chave de $SEALED_KEYS_DIR antes de instalar o controller
#      (o controller adota a chave existente em vez de gerar outra);
#   2. instala o controller (sem renovação automática de chave);
#   3. faz BACKUP da chave em $SEALED_KEYS_DIR (fora do Git, fora do DATA_DIR);
#   4. grava a chave pública em config/sealed-secrets/cert.pem — é com ela que
#      o `make seal` criptografa, sem precisar do cluster.
#
# SEALED_KEYS_DIR (default ~/.config/devops-platform/sealed-secrets) NUNCA é
# apagado pelo `make destroy`. Guarde uma cópia em local seguro (gerenciador
# de senhas, cofre): sem ela, um cluster novo não abre os segredos do Git.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi

CHART_VERSION="2.20.0"   # controller 0.40.0
NS="kube-system"
NAME="sealed-secrets-controller"
KEYS_DIR="${SEALED_KEYS_DIR:-$HOME/.config/devops-platform/sealed-secrets}"
KEYS_DIR="$(eval echo "$KEYS_DIR")"
KEY_FILE="$KEYS_DIR/keys.yaml"
CERT_FILE="$INFRA_ROOT/config/sealed-secrets/cert.pem"
LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"

step() { echo -e "\033[0;36m▸ $1\033[0m"; }
warn() { echo -e "  \033[1;33m⚠\033[0m $1"; }

mkdir -p "$KEYS_DIR" "$(dirname "$CERT_FILE")"
chmod 700 "$KEYS_DIR"

# 1. Restaura a chave (se houver backup e o cluster ainda não tiver chave).
if [[ -f "$KEY_FILE" ]] && [[ -z "$(kubectl get secret -n "$NS" -l "$LABEL" -o name 2>/dev/null)" ]]; then
  step "Restaurando a chave do Sealed Secrets de $KEY_FILE"
  kubectl apply -f "$KEY_FILE" >/dev/null
fi

# 2. Controller.
step "Sealed Secrets controller (chart $CHART_VERSION)"
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update sealed-secrets >/dev/null
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets --version "$CHART_VERSION" \
  --namespace "$NS" \
  --set fullnameOverride="$NAME" \
  --set keyrenewperiod=0 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=200m --set resources.limits.memory=128Mi \
  --timeout 5m --wait >/dev/null

# 3. Backup da(s) chave(s), sem os campos que impedem recriar noutro cluster.
for _ in $(seq 1 30); do
  [[ -n "$(kubectl get secret -n "$NS" -l "$LABEL" -o name 2>/dev/null)" ]] && break; sleep 2
done
kubectl get secret -n "$NS" -l "$LABEL" -o yaml \
  | yq 'del(.items[].metadata.resourceVersion, .items[].metadata.uid, .items[].metadata.creationTimestamp, .items[].metadata.managedFields, .metadata)' \
  > "$KEY_FILE.tmp"
mv "$KEY_FILE.tmp" "$KEY_FILE"
chmod 600 "$KEY_FILE"
step "Backup da chave em $KEY_FILE ($(yq '.items | length' "$KEY_FILE") chave(s))"

# 4. Chave pública (versionada).
NEW_CERT="$(kubeseal --controller-name "$NAME" --controller-namespace "$NS" --fetch-cert)"
if [[ -f "$CERT_FILE" ]] && [[ "$(cat "$CERT_FILE")" != "$NEW_CERT" ]]; then
  warn "a chave pública MUDOU — os arquivos em projects/*/sealed/ foram selados com outra chave."
  warn "rode \`make seal PROJECT=<p>\` para cada projeto e commite (ou restaure a chave antiga)."
fi
echo "$NEW_CERT" > "$CERT_FILE"
step "Chave pública em config/sealed-secrets/cert.pem (commite este arquivo)"

echo -e "\033[0;32m✅ Sealed Secrets pronto\033[0m"
