#!/usr/bin/env bash
# =============================================================================
# setup-postgres.sh  (genérico)
# -----------------------------------------------------------------------------
# Cria PostgreSQL em um namespace:
#   - Secret postgres  (DATABASE_URL, DIRECT_URL) para as apps via envFrom
#   - ConfigMap postgres-init (cria bancos extras, se houver)
#   - Service postgres (ClusterIP, 5432)
#   - Deployment postgres com volume emptyDir (volátil)
#
# emptyDir vs PVC: o local-path provisioner do k3d no macOS mapeia pra um
# path no host; o Finder/Spotlight injeta arquivos AppleDouble (._*) ali e
# Postgres trava com "Operation not permitted". emptyDir evita esse problema
# 100%. Em troca, dados são perdidos no restart do pod — mas migrations +
# seed são reprodutíveis.
#
# Uso:
#   ./scripts/setup-postgres.sh --namespace <ns> [opções]
#
# Opções:
#   --namespace <ns>        (obrigatório) namespace alvo (ex.: meuapp-develop)
#   --user <user>           usuário do Postgres          (default: postgres)
#   --password <pass>       senha do Postgres            (default: postgres)
#   --db <name>             banco principal (POSTGRES_DB)(default: app)
#   --extra-dbs "a b c"     bancos extras a criar (lista separada por espaço)
#   --reset                 apaga o deployment antes de recriar
# =============================================================================

set -euo pipefail

NS=""
PG_USER="postgres"
PG_PASS="postgres"
PG_DB="app"
EXTRA_DBS=""
RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --user)      PG_USER="$2"; shift 2 ;;
    --password)  PG_PASS="$2"; shift 2 ;;
    --db)        PG_DB="$2"; shift 2 ;;
    --extra-dbs) EXTRA_DBS="$2"; shift 2 ;;
    --reset)     RESET=true; shift ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

if [[ -z "$NS" ]]; then
  echo "Uso: $0 --namespace <ns> [--user u --password p --db name --extra-dbs \"a b\"] [--reset]"
  exit 1
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

if $RESET; then
  echo "🗑️  Reset solicitado, apagando deployment..."
  kubectl delete deploy postgres -n "$NS" --ignore-not-found --wait=true
fi

# Conexão para as apps (envFrom: [{ secretRef: postgres }]), em dois formatos:
#   DATABASE_URL / DIRECT_URL  postgresql://… (Prisma, Node). DIRECT_URL = mesma
#                              URL: no cluster não há pooler no caminho.
#   JDBC_URL + DB_*            Java/Spring. Para outro banco do mesmo Postgres
#                              (extraDbs), monte no values:
#                              jdbc:postgresql://$(DB_HOST):$(DB_PORT)/<banco>
DB_HOST="postgres.${NS}.svc.cluster.local"
DB_URL="postgresql://${PG_USER}:${PG_PASS}@${DB_HOST}:5432/${PG_DB}?schema=public"
kubectl -n "$NS" create secret generic postgres \
  --from-literal=DATABASE_URL="$DB_URL" \
  --from-literal=DIRECT_URL="$DB_URL" \
  --from-literal=JDBC_URL="jdbc:postgresql://${DB_HOST}:5432/${PG_DB}" \
  --from-literal=DB_HOST="$DB_HOST" \
  --from-literal=DB_PORT="5432" \
  --from-literal=DB_NAME="$PG_DB" \
  --from-literal=DB_USER="$PG_USER" \
  --from-literal=DB_PASSWORD="$PG_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

# Monta o bloco SQL de bancos extras
EXTRA_SQL=""
for db in $EXTRA_DBS; do
  EXTRA_SQL+="      CREATE DATABASE ${db};\n"
  EXTRA_SQL+="      GRANT ALL PRIVILEGES ON DATABASE ${db} TO \"\$POSTGRES_USER\";\n"
done

# ConfigMap com init scripts (cria bancos extras)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: ${NS}
data:
  init-extra-dbs.sh: |
    #!/bin/bash
    set -e
    psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" --dbname "\$POSTGRES_DB" <<-EOSQL
$(printf "%b" "$EXTRA_SQL")
    EOSQL
EOF

# Service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${NS}
  labels:
    app: postgres
spec:
  type: ClusterIP
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
  selector:
    app: postgres
EOF

# Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: ${NS}
  labels:
    app: postgres
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_USER
              value: ${PG_USER}
            - name: POSTGRES_PASSWORD
              value: ${PG_PASS}
            - name: POSTGRES_DB
              value: ${PG_DB}
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "${PG_USER}"]
            initialDelaySeconds: 10
            periodSeconds: 5
          resources:
            limits: { cpu: 500m, memory: 512Mi }
            requests: { cpu: 50m, memory: 128Mi }
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          # emptyDir em vez de PVC pra evitar arquivos AppleDouble (._*)
          # que macOS injeta no path do local-path provisioner do k3d.
          # Trade-off: dados são voláteis (perdidos no restart do pod),
          # mas seed + migrations são reprodutíveis. Para lab é aceitável.
          emptyDir:
            sizeLimit: 2Gi
        - name: init
          configMap:
            name: postgres-init
            defaultMode: 0755
EOF

echo "⏳ Aguardando postgres ficar pronto..."
kubectl rollout status -n "$NS" deploy/postgres --timeout=180s
echo "✅ Postgres pronto em $NS"
