#!/usr/bin/env bash
# =============================================================================
# seal-secrets.sh  (genérico)
# -----------------------------------------------------------------------------
# Gera os SealedSecrets de um projeto — seguros para commitar — a partir dos
# valores reais em projects/<p>/secrets/<env>.env (gitignored).
#
# Para cada ambiente:
#   1. garante secrets/<env>.env (criado a partir do example.env, se houver);
#   2. gera senhas aleatórias que faltarem para as dependências do project.yaml:
#        DB_PASSWORD (database) · RABBITMQ_PASSWORD (rabbitmq) · REDIS_PASSWORD (redis)
#      e as grava no <env>.env (assim um novo `seal` mantém as mesmas senhas);
#   3. monta os Secrets e sela com config/sealed-secrets/cert.pem (sem cluster):
#        postgres     DATABASE_URL, DIRECT_URL, JDBC_URL, DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
#        rabbitmq     RABBITMQ_URL, RABBITMQ_HOST, RABBITMQ_PORT, RABBITMQ_USER, RABBITMQ_PASSWORD
#        redis        REDIS_URL, REDIS_HOST, REDIS_PORT, REDIS_PASSWORD
#        app-secrets  demais chaves do <env>.env
#   4. grava em projects/<p>/sealed/<env>/<secret>.yaml — o ArgoCD aplica e o
#      controller do cluster abre.
#
# Uso:
#   ./scripts/seal-secrets.sh <projeto> [env]      # sem env = todos
#
# Obs.: selar de novo gera arquivos diferentes (criptografia com chave de
# sessão aleatória) mesmo com os mesmos valores — commite quando quiser mudar.
# =============================================================================

set -euo pipefail

PROJ="${1:-}"; ONLY_ENV="${2:-}"
[[ -n "$PROJ" ]] || { echo "Uso: $0 <projeto> [env]"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

CERT="$INFRA_ROOT/config/sealed-secrets/cert.pem"
command -v kubeseal >/dev/null || { echo "❌ kubeseal não encontrado: brew install kubeseal"; exit 1; }
[[ -f "$CERT" ]] || { echo "❌ $CERT não existe: rode \`make sealed-secrets\` com o cluster no ar"; exit 1; }
[[ -f "$(project_manifest "$PROJ")" ]] || { echo "❌ projects/$PROJ/project.yaml não encontrado"; exit 1; }

PDIR="$(project_dir "$PROJ")"
RESERVED="DB_PASSWORD RABBITMQ_PASSWORD REDIS_PASSWORD"

# Lê KEY de um .env (sem executar o arquivo).
envget() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# Garante KEY no .env: mantém se existir, senão gera e grava.
ensure_password() {
  local file="$1" key="$2" val
  val="$(envget "$file" "$key")"
  if [[ -z "$val" ]]; then
    val="$(openssl rand -hex 16)"
    printf '\n# gerado por make seal em %s\n%s=%s\n' "$(date +%F)" "$key" "$val" >> "$file"
  fi
}

# kubectl create secret --dry-run | kubeseal  →  arquivo selado
seal() {
  local name="$1" ns="$2" out="$3"; shift 3
  kubectl create secret generic "$name" -n "$ns" "$@" --dry-run=client -o yaml \
    | kubeseal --cert "$CERT" --format yaml --namespace "$ns" > "$out.tmp"
  mv "$out.tmp" "$out"
  echo "  🔒 ${out#"$INFRA_ROOT"/}"
}

ENVS="$ONLY_ENV"; [[ -n "$ENVS" ]] || ENVS="$(project_envs "$PROJ" | xargs)"
for ENV_NAME in $ENVS; do
  NS="${PROJ}-${ENV_NAME}"
  ENV_FILE="$PDIR/secrets/$ENV_NAME.env"
  OUT_DIR="$PDIR/sealed/$ENV_NAME"
  mkdir -p "$PDIR/secrets" "$OUT_DIR"
  echo "▸ $PROJ / $ENV_NAME  (namespace $NS)"

  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$PDIR/secrets/example.env" ]]; then cp "$PDIR/secrets/example.env" "$ENV_FILE"
    else printf '# Segredos de %s/%s (gitignored). Selados por `make seal`.\n' "$PROJ" "$ENV_NAME" > "$ENV_FILE"; fi
    echo "  📄 criado secrets/$ENV_NAME.env (edite os valores reais e rode make seal de novo)"
  fi
  chmod 600 "$ENV_FILE"

  # --- postgres --------------------------------------------------------------
  if project_db_enabled "$PROJ"; then
    ensure_password "$ENV_FILE" DB_PASSWORD
    U="$(project_db_user "$PROJ")"; DB="$(project_db_default "$PROJ")"; P="$(envget "$ENV_FILE" DB_PASSWORD)"
    H="postgres.${NS}.svc.cluster.local"
    URL="postgresql://${U}:${P}@${H}:5432/${DB}?schema=public"
    seal postgres "$NS" "$OUT_DIR/postgres.yaml" \
      --from-literal=DATABASE_URL="$URL" --from-literal=DIRECT_URL="$URL" \
      --from-literal=JDBC_URL="jdbc:postgresql://${H}:5432/${DB}" \
      --from-literal=DB_HOST="$H" --from-literal=DB_PORT=5432 --from-literal=DB_NAME="$DB" \
      --from-literal=DB_USER="$U" --from-literal=DB_PASSWORD="$P"
  else rm -f "$OUT_DIR/postgres.yaml"; fi

  # --- rabbitmq --------------------------------------------------------------
  if project_rabbitmq_enabled "$PROJ"; then
    ensure_password "$ENV_FILE" RABBITMQ_PASSWORD
    U="$(project_rabbitmq_user "$PROJ")"; P="$(envget "$ENV_FILE" RABBITMQ_PASSWORD)"
    H="rabbitmq.${NS}.svc.cluster.local"
    seal rabbitmq "$NS" "$OUT_DIR/rabbitmq.yaml" \
      --from-literal=RABBITMQ_URL="amqp://${U}:${P}@${H}:5672" \
      --from-literal=RABBITMQ_HOST="$H" --from-literal=RABBITMQ_PORT=5672 \
      --from-literal=RABBITMQ_USER="$U" --from-literal=RABBITMQ_PASSWORD="$P"
  else rm -f "$OUT_DIR/rabbitmq.yaml"; fi

  # --- redis -----------------------------------------------------------------
  if project_redis_enabled "$PROJ"; then
    ensure_password "$ENV_FILE" REDIS_PASSWORD
    P="$(envget "$ENV_FILE" REDIS_PASSWORD)"; H="redis.${NS}.svc.cluster.local"
    seal redis "$NS" "$OUT_DIR/redis.yaml" \
      --from-literal=REDIS_URL="redis://default:${P}@${H}:6379" \
      --from-literal=REDIS_HOST="$H" --from-literal=REDIS_PORT=6379 --from-literal=REDIS_PASSWORD="$P"
  else rm -f "$OUT_DIR/redis.yaml"; fi

  # --- app-secrets: o resto do .env ------------------------------------------
  CLEAN="$(mktemp)"
  grep -Ev '^[[:space:]]*(#|$)' "$ENV_FILE" | grep -vE "^($(echo "$RESERVED" | tr ' ' '|'))=" > "$CLEAN" || true
  if [[ -s "$CLEAN" ]]; then
    seal app-secrets "$NS" "$OUT_DIR/app-secrets.yaml" --from-env-file="$CLEAN"
  else rm -f "$OUT_DIR/app-secrets.yaml"; fi
  rm -f "$CLEAN"

  rmdir "$OUT_DIR" 2>/dev/null || true
done

echo "✅ Selado. Commite projects/$PROJ/sealed/ — os .env continuam só na sua máquina."
