#!/usr/bin/env bash
# =============================================================================
# apply-secrets.sh  (genérico)
# -----------------------------------------------------------------------------
# Cria/atualiza o Secret `app-secrets` no namespace <projeto>-<env> a partir de
#
#   projects/<projeto>/secrets/<env>.env       (gitignored — valores reais)
#   projects/<projeto>/secrets/example.env     (versionado — fallback de lab)
#
# Formato: KEY=valor por linha, sem aspas (formato --from-env-file do kubectl).
# As apps consomem com:  envFrom: [{ secretRef: app-secrets, optional: true }]
#
# Uso:
#   ./scripts/apply-secrets.sh <projeto> <env>
# =============================================================================

set -euo pipefail

PROJ="${1:-}"
ENV_NAME="${2:-}"
if [[ -z "$PROJ" || -z "$ENV_NAME" ]]; then
  echo "Uso: $0 <projeto> <env>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$INFRA_ROOT/projects/$PROJ/secrets"
NS="${PROJ}-${ENV_NAME}"

FILE="$SECRETS_DIR/${ENV_NAME}.env"
if [[ ! -f "$FILE" ]]; then
  if [[ -f "$SECRETS_DIR/example.env" ]]; then
    echo "  ⚠️  $FILE não existe — usando example.env (valores de lab)"
    FILE="$SECRETS_DIR/example.env"
  else
    echo "  ℹ️  $PROJ não tem secrets/ — nada a fazer"
    exit 0
  fi
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# Remove comentários/linhas vazias antes de entregar ao kubectl.
CLEAN="$(mktemp)"; trap 'rm -f "$CLEAN"' EXIT
grep -Ev '^[[:space:]]*(#|$)' "$FILE" > "$CLEAN" || true

kubectl -n "$NS" create secret generic app-secrets \
  --from-env-file="$CLEAN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✅ app-secrets em $NS ($(wc -l < "$CLEAN" | tr -d ' ') chaves de $(basename "$FILE"))"
