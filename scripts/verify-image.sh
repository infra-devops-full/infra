#!/usr/bin/env bash
# =============================================================================
# verify-image.sh — confere se uma imagem foi assinada pelo CI da plataforma
# (mesma regra do Kyverno: k8s/kyverno-image-signatures.yaml) e mostra o SBOM
# atestado. Roda o cosign em container (nada para instalar).
#   make verify-image IMAGE=ghcr.io/<org>/<repo>/<app>:<tag>
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:?Uso: $0 <imagem:tag>}"
COSIGN="ghcr.io/sigstore/cosign/cosign:v2.6.5"
REGEX="$(INFRA_REPO_URL="${INFRA_REPO_URL:-https://github.com/infra-devops-full/infra.git}" \
  bash "$SCRIPT_DIR/apply-platform.sh" --render \
  | yq 'select(.kind == "ImageValidatingPolicy") | .spec.attestors[0].cosign.keyless.identities[0].subjectRegExp')"

echo "▸ assinatura de $IMAGE"
if OUT="$(docker run --rm "$COSIGN" verify "$IMAGE" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp "$REGEX" 2>/dev/null)"; then
  jq -r '.[] | "  ✅ assinada por \(.optional.Subject // "?")\n     commit \(.optional["1.3.6.1.4.1.57264.1.3"] // "?")"' <<<"$OUT" | sort -u
else
  echo "  ❌ sem assinatura válida do CI da plataforma"; exit 1
fi

echo "▸ SBOM atestado"
if ATT="$(docker run --rm "$COSIGN" verify-attestation "$IMAGE" --type spdxjson \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp "$REGEX" 2>/dev/null)"; then
  head -1 <<<"$ATT" | jq -r '.payload | @base64d | fromjson | .predicate.packages | "  ✅ \(length) pacotes listados"'
else
  echo "  ⚠ sem SBOM atestado (imagem anterior à assinatura no CI?)"
fi
