#!/usr/bin/env bash
# =============================================================================
# setup-redis.sh  (genérico)
# -----------------------------------------------------------------------------
# Cria Redis em um namespace:
#   - Secret redis   (REDIS_URL, REDIS_HOST, REDIS_PORT, REDIS_PASSWORD)
#   - Service redis  (6379)
#   - Deployment redis com emptyDir (volátil — mesmo trade-off do Postgres)
#
# As apps consomem a conexão via envFrom: [{ secretRef: redis }].
#
# Uso:
#   ./scripts/setup-redis.sh --namespace <ns> [--password p]
# =============================================================================

set -euo pipefail

NS=""
REDIS_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --password)  REDIS_PASS="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

if [[ -z "$NS" ]]; then
  echo "Uso: $0 --namespace <ns> [--password p]"
  exit 1
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

HOST="redis.${NS}.svc.cluster.local"
if [[ -n "$REDIS_PASS" ]]; then
  URL="redis://default:${REDIS_PASS}@${HOST}:6379"
  ARGS='["redis-server", "--requirepass", "$(REDIS_PASSWORD)"]'
else
  URL="redis://${HOST}:6379"
  ARGS='["redis-server"]'
fi

kubectl -n "$NS" create secret generic redis \
  --from-literal=REDIS_URL="$URL" \
  --from-literal=REDIS_HOST="$HOST" \
  --from-literal=REDIS_PORT="6379" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NS}
  labels:
    app: redis
spec:
  type: ClusterIP
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
  selector:
    app: redis
EOF

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NS}
  labels:
    app: redis
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          command: ${ARGS}
          env:
            - name: REDIS_PASSWORD
              valueFrom: { secretKeyRef: { name: redis, key: REDIS_PASSWORD } }
          ports:
            - containerPort: 6379
          readinessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            limits: { cpu: 300m, memory: 256Mi }
            requests: { cpu: 20m, memory: 32Mi }
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir:
            sizeLimit: 512Mi
EOF

echo "⏳ Aguardando redis ficar pronto..."
kubectl rollout status -n "$NS" deploy/redis --timeout=120s
echo "✅ Redis pronto em $NS"
