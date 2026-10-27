#!/usr/bin/env bash
# =============================================================================
# setup-postgres.sh  (genérico)
# -----------------------------------------------------------------------------
# Postgres de um namespace, gerenciado pelo CloudNativePG (setup-data.sh):
#
#   Cluster postgres          N instâncias em PVC (prod: primário + réplica)
#   Service postgres          sempre aponta para o primário (é o DB_HOST dos apps)
#   Database postgres-<db>    bancos extras (database.extraDbs)
#   ObjectStore backup        S3 de backup (lib-backup.sh): WAL contínuo
#   ScheduledBackup           backup base diário (03:00 BRT) + um ao criar
#   PodMonitor postgres       métricas no Prometheus (alertas Postgres*)
#
# Usuário, senha e banco vêm do Secret `postgres` (make seal); o operador
# recebe uma cópia no formato que ele lê (Secret postgres-credentials).
#
# Banco novo (não existe Cluster):
#   - há backup deste namespace no S3 → RESTAURA o mais recente (é o que faz um
#     `make destroy && make setup` voltar com os dados);
#   - não há → banco vazio (initdb); as migrations dos apps criam o schema.
# Cada Cluster grava os backups num serverName próprio
# (postgres-<data-hora>): o arquivo de um banco restaurado nunca mistura com
# o de origem.
#
# Uso:
#   ./scripts/setup-postgres.sh --namespace <ns> [opções]
#
#   --namespace <ns>       (obrigatório) ex.: crivo-develop
#   --extra-dbs "a b"      bancos extras
#   --instances <n>        réplicas (padrão 1)
#   --storage <tam>        disco de cada instância (padrão 1Gi)
#   --retention <dur>      quanto tempo manter backups (padrão 7d)
#   --reset                apaga o Cluster (e os discos) antes de recriar
#   --fresh                banco novo VAZIO, mesmo havendo backup
#   --from <serverName>    restaura deste serverName (padrão: o mais recente)
#   --target-time <ts>     restaura até este instante (PITR), ex.
#                          "2026-10-26 14:30:00-03"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-backup.sh
source "$SCRIPT_DIR/lib-backup.sh"

PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"
PLUGIN="barman-cloud.cloudnative-pg.io"

NS=""; EXTRA_DBS=""; INSTANCES=1; STORAGE=1Gi; RETENTION=7d
RESET=false; FRESH=false; FROM=""; TARGET_TIME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)   NS="$2"; shift 2 ;;
    --extra-dbs)   EXTRA_DBS="$2"; shift 2 ;;
    --instances)   INSTANCES="$2"; shift 2 ;;
    --storage)     STORAGE="$2"; shift 2 ;;
    --retention)   RETENTION="$2"; shift 2 ;;
    --reset)       RESET=true; shift ;;
    --fresh)       FRESH=true; shift ;;
    --from)        FROM="$2"; shift 2 ;;
    --target-time) TARGET_TIME="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

if [[ -z "$NS" ]]; then
  echo "Uso: $0 --namespace <ns> [--extra-dbs \"a b\"] [--instances n] [--reset] [--fresh]"
  exit 1
fi

kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || {
  echo "❌ CloudNativePG não instalado — rode \`make data\`"; exit 1; }
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
kubectl get secret postgres -n "$NS" >/dev/null 2>&1 || {
  echo "❌ Secret postgres não existe em $NS — rode \`make seal PROJECT=<p>\` e \`make project-apply PROJECT=<p>\`"
  exit 1
}

secret_key() { kubectl get secret postgres -n "$NS" -o jsonpath="{.data.$1}" | base64 -d; }
DB_USER="$(secret_key DB_USER)"
DB_NAME="$(secret_key DB_NAME)"

# --- modelo antigo (Deployment com emptyDir) ----------------------------------
# Os dados dele eram voláteis; o Service "postgres" passa a ser do operador.
if kubectl get deploy postgres -n "$NS" >/dev/null 2>&1; then
  echo "  ↻ removendo o Postgres antigo (Deployment com emptyDir) de $NS"
  kubectl delete deploy postgres -n "$NS" --wait=true >/dev/null
  kubectl delete configmap postgres-init -n "$NS" --ignore-not-found >/dev/null
fi
if kubectl get svc postgres -n "$NS" >/dev/null 2>&1 && \
   [[ -z "$(kubectl get svc postgres -n "$NS" -o jsonpath='{.metadata.labels.cnpg\.io/cluster}')" ]]; then
  kubectl delete svc postgres -n "$NS" >/dev/null
fi

# --- reset --------------------------------------------------------------------
wait_gone() {
  local i
  for i in $(seq 1 90); do
    [[ -z "$(kubectl get pods,pvc -n "$NS" -l cnpg.io/cluster=postgres -o name 2>/dev/null)" ]] && return 0
    sleep 2
  done
  echo "❌ pods/PVCs do Postgres antigo ainda existem em $NS"; return 1
}
if $RESET && kubectl get cluster postgres -n "$NS" >/dev/null 2>&1; then
  echo "  🗑️  apagando o Cluster postgres de $NS (os backups no S3 ficam)"
  kubectl delete cluster postgres -n "$NS" --wait=true >/dev/null
  # O delete volta antes de o Kubernetes remover pods e discos; um Cluster
  # novo com o mesmo nome adotaria os discos antigos.
  wait_gone
fi

# --- segredos para o operador -------------------------------------------------
read -r S3_KEY S3_SECRET < <(backup_credentials)
kubectl create secret generic backup-s3 -n "$NS" \
  --from-literal=ACCESS_KEY_ID="$S3_KEY" --from-literal=ACCESS_SECRET_KEY="$S3_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# cnpg.io/reload: senha nova (make seal) → o operador troca a do usuário no banco.
kubectl create secret generic postgres-credentials -n "$NS" --type=kubernetes.io/basic-auth \
  --from-literal=username="$DB_USER" --from-literal=password="$(secret_key DB_PASSWORD)" \
  --dry-run=client -o yaml | kubectl label --local -f - cnpg.io/reload=true -o yaml | \
  kubectl apply -f - >/dev/null

# --- bootstrap: existente, restauração ou vazio --------------------------------
EXISTS=false
kubectl get cluster postgres -n "$NS" >/dev/null 2>&1 && EXISTS=true

if $EXISTS; then
  SERVER="$(kubectl get cluster postgres -n "$NS" -o jsonpath='{.spec.plugins[0].parameters.serverName}')"
  MODE="existente"
else
  SERVER="postgres-$(date -u +%Y%m%d%H%M%S)"
  if ! $FRESH && [[ -z "$FROM" ]]; then
    FROM="$(backup_servers "$NS" | tail -1)"
  fi
  if ! $FRESH && [[ -n "$FROM" ]]; then MODE="restauração"; else MODE="vazio"; FROM=""; fi
fi

# Restaurar até um instante (PITR). Um `if`, não `$([[ ]] && ...)` dentro da
# atribuição: com set -e, o teste falso ali encerrava o script em silêncio.
RECOVERY_TARGET=""
if [[ -n "$TARGET_TIME" ]]; then
  RECOVERY_TARGET="$(printf '\n      recoveryTarget: { targetTime: "%s" }' "$TARGET_TIME")"
fi

case "$MODE" in
  restauração)
    echo "  ♻️  restaurando $NS do backup $FROM${TARGET_TIME:+ até $TARGET_TIME}"
    BOOTSTRAP="  bootstrap:
    recovery:
      source: origem
      database: ${DB_NAME}
      owner: ${DB_USER}
      secret: { name: postgres-credentials }${RECOVERY_TARGET}
  externalClusters:
    - name: origem
      plugin:
        name: ${PLUGIN}
        parameters: { barmanObjectName: backup, serverName: ${FROM} }" ;;
  vazio)
    BOOTSTRAP="  bootstrap:
    initdb:
      database: ${DB_NAME}
      owner: ${DB_USER}
      secret: { name: postgres-credentials }" ;;
  existente)
    # bootstrap só vale na criação: mantém o que o Cluster já tem.
    BOOTSTRAP="$(kubectl get cluster postgres -n "$NS" -o json | \
      yq -p json -o yaml '{"bootstrap": .spec.bootstrap, "externalClusters": .spec.externalClusters} | del(.[] | select(. == null))' | \
      sed 's/^/  /')" ;;
esac

{
cat <<EOF
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: backup
  namespace: ${NS}
spec:
  retentionPolicy: "${RETENTION}"
  configuration:
    destinationPath: s3://${BACKUP_BUCKET}/${NS}/
    endpointURL: $(backup_endpoint)
    s3Credentials:
      accessKeyId: { name: backup-s3, key: ACCESS_KEY_ID }
      secretAccessKey: { name: backup-s3, key: ACCESS_SECRET_KEY }
    wal: { compression: gzip }
    data: { compression: gzip }
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: ${NS}
spec:
  instances: ${INSTANCES}
  imageName: ${PG_IMAGE}
  storage: { size: ${STORAGE} }
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { memory: 512Mi }
${BOOTSTRAP}
  managed:
    services:
      # "postgres" = primário (leitura e escrita): o DB_HOST dos Secrets.
      # O operador cria também postgres-rw, postgres-ro (réplicas) e postgres-r.
      additional:
        - selectorType: rw
          serviceTemplate:
            metadata: { name: postgres }
  plugins:
    - name: ${PLUGIN}
      isWALArchiver: true
      parameters: { barmanObjectName: backup, serverName: ${SERVER} }
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-diario
  namespace: ${NS}
spec:
  cluster: { name: postgres }
  schedule: "0 0 6 * * *"     # segundo minuto hora (UTC) → 03:00 em Brasília
  immediate: true             # um backup base logo que o Cluster nasce
  backupOwnerReference: self
  method: plugin
  pluginConfiguration: { name: ${PLUGIN} }
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: postgres
  namespace: ${NS}
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels: { cnpg.io/cluster: postgres }
  podMetricsEndpoints:
    - port: metrics
EOF
for db in $EXTRA_DBS; do
cat <<EOF
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: postgres-${db}
  namespace: ${NS}
spec:
  name: ${db}
  owner: ${DB_USER}
  cluster: { name: postgres }
EOF
done
} | kubectl apply --server-side --field-manager=devops-platform --force-conflicts -f - >/dev/null

echo "⏳ Aguardando o Postgres de $NS ($MODE, $INSTANCES instância(s))..."
for _ in $(seq 1 30); do
  kubectl get cluster postgres -n "$NS" -o jsonpath='{.status.conditions}' 2>/dev/null | grep -q '"Ready"' && break
  sleep 2
done
kubectl wait cluster/postgres -n "$NS" --for=condition=Ready --timeout=600s >/dev/null || {
  echo "❌ Postgres de $NS não ficou pronto: kubectl get cluster,pods -n $NS (ou make db-status PROJECT=<p> ENV=<e>)"
  exit 1
}
echo "✅ Postgres pronto em $NS (backups: s3://${BACKUP_BUCKET}/${NS}/${SERVER})"
