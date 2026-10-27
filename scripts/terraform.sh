#!/usr/bin/env bash
# =============================================================================
# terraform.sh  (genérico) — Terraform da nuvem, com ou sem Terraform instalado.
# -----------------------------------------------------------------------------
#   terraform.sh check  [cloud]     fmt + validate + tflint + trivy (sem credenciais; o CI roda isto)
#   terraform.sh fmt    [cloud]     formata os .tf
#   terraform.sh tf     <cloud> <args...>   terraform <args> (init, plan, apply, output...)
#
# cloud = pasta em terraform/ (padrão: digitalocean). Usa terraform/tofu do
# PATH se houver; senão a imagem Docker com versão fixa. Credenciais só por
# variável de ambiente (DIGITALOCEAN_TOKEN, SPACES_*, AWS_*). docs/23-nuvem.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "$SCRIPT_DIR/../terraform" && pwd)"

TF_IMAGE="hashicorp/terraform:1.16.5"
TFLINT_IMAGE="ghcr.io/terraform-linters/tflint:v0.64.0"
TRIVY_IMAGE="aquasec/trivy:0.75.0"

CMD="${1:-check}"; shift || true

step() { echo -e "\033[0;36m▸ $1\033[0m"; }

# terraform <dir> <args...>: binário local ou container.
tf() {
  local dir="$1"; shift
  if command -v terraform >/dev/null 2>&1; then (cd "$dir" && terraform "$@")
  elif command -v tofu >/dev/null 2>&1; then (cd "$dir" && tofu "$@")
  else
    local envs=() v
    for v in DIGITALOCEAN_TOKEN SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY \
             AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_api_allowed_cidrs; do
      [[ -n "${!v:-}" ]] && envs+=(-e "$v")
    done
    docker run --rm -i ${envs[@]+"${envs[@]}"} -v "$TF_ROOT:/tf" -w "/tf/${dir#"$TF_ROOT"/}" "$TF_IMAGE" "$@"
  fi
}

cloud_dir() {
  local d="$TF_ROOT/${1:-digitalocean}"
  [[ -d "$d" ]] || { echo "❌ terraform/${1:-digitalocean} não existe" >&2; exit 1; }
  echo "$d"
}

case "$CMD" in
  fmt)
    tf "$(cloud_dir "${1:-}")" fmt -recursive
    ;;

  check)
    D="$(cloud_dir "${1:-}")"; N="$(basename "$D")"
    step "terraform fmt ($N)"
    tf "$D" fmt -check -recursive -diff
    step "terraform validate ($N)"
    tf "$D" init -backend=false -input=false >/dev/null
    tf "$D" validate
    step "tflint ($N)"
    docker run --rm -v "$TF_ROOT:/tf" -w "/tf/$N" "$TFLINT_IMAGE" --config=/tf/.tflint.hcl --init >/dev/null
    docker run --rm -v "$TF_ROOT:/tf" -w "/tf/$N" "$TFLINT_IMAGE" --config=/tf/.tflint.hcl
    # Análise de segurança da infraestrutura como código (bucket público,
    # API aberta, falta de criptografia...). Falha só em HIGH/CRITICAL.
    step "trivy config ($N)"
    docker run --rm -v "$TF_ROOT:/tf" "$TRIVY_IMAGE" config --quiet \
      --severity HIGH,CRITICAL --exit-code 1 --tf-vars "/tf/$N/terraform.tfvars.example" "/tf/$N"
    echo -e "\033[0;32m✅ Terraform ($N) OK: formatado, válido, sem avisos do tflint nem achados HIGH/CRITICAL\033[0m"
    ;;

  tf)
    D="$(cloud_dir "${1:-}")"; shift || true
    tf "$D" "$@"
    ;;

  *) echo "Uso: $0 <check|fmt|tf> [cloud] [args...]"; exit 1 ;;
esac
