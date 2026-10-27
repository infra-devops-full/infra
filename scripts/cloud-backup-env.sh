#!/usr/bin/env bash
# =============================================================================
# cloud-backup-env.sh — liga os backups dos bancos ao bucket criado pelo
# Terraform, para o cluster do contexto atual do kubectl (make cloud-backup-env).
#
# Lê os outputs (bucket, endpoint, chave restrita ao bucket) e grava
# ~/.config/devops-platform/backup/<contexto>.env (600, fora do Git), que a
# lib-backup.sh carrega quando o cluster não é k3d. docs/23-nuvem.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD="${1:-digitalocean}"
BACKUP_CONF_DIR="$(eval echo "${BACKUP_CONF_DIR:-$HOME/.config/devops-platform/backup}")"

CTX="$(kubectl config current-context)"
if [[ "$CTX" == k3d-* ]]; then
  echo "❌ o contexto atual é o lab ($CTX): no k3d os backups ficam no container local."
  HINT="$(bash "$SCRIPT_DIR/terraform.sh" tf "$CLOUD" output -raw kubeconfig_command 2>/dev/null || true)"
  echo "   Antes: ${HINT:-doctl kubernetes cluster kubeconfig save <cluster>}  (troca o contexto para o cluster da nuvem)"
  exit 1
fi

out() { bash "$SCRIPT_DIR/terraform.sh" tf "$CLOUD" output -raw "$1"; }

F="$BACKUP_CONF_DIR/$CTX.env"
mkdir -p "$BACKUP_CONF_DIR" && chmod 700 "$BACKUP_CONF_DIR"
(umask 077
 {
   echo "# Gerado por make cloud-backup-env ($(date +%F)) a partir do Terraform ($CLOUD)."
   echo "BACKUP_S3_ENDPOINT=$(out backup_s3_endpoint)"
   echo "BACKUP_BUCKET=$(out backup_bucket)"
   echo "BACKUP_S3_ACCESS_KEY_ID=$(out backup_access_key_id)"
   echo "BACKUP_S3_SECRET_ACCESS_KEY=$(out backup_secret_access_key)"
 } >"$F")
echo "✅ backups de $CTX → $(grep BACKUP_BUCKET "$F" | cut -d= -f2) ($F). Próximo: make data"
