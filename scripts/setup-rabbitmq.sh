#!/usr/bin/env bash
# =============================================================================
# setup-rabbitmq.sh  (genérico)
# -----------------------------------------------------------------------------
# Cria RabbitMQ (com management UI) em um namespace:
#   - Secret rabbitmq  (RABBITMQ_URL, RABBITMQ_HOST, RABBITMQ_PORT, RABBITMQ_USER,
#                       RABBITMQ_PASSWORD)
#   - Service rabbitmq (5672 AMQP, 15672 management)
#   - Deployment rabbitmq com emptyDir (volátil — mesmo trade-off do Postgres)
#
# As apps consomem a conexão via envFrom: [{ secretRef: rabbitmq }].
# Management UI: kubectl port-forward -n <ns> svc/rabbitmq 15672:15672
#
# Uso:
#   ./scripts/setup-rabbitmq.sh --namespace <ns> [--user u] [--password p]
# =============================================================================

set -euo pipefail

NS=""
RMQ_USER="guest"
RMQ_PASS="guest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --user)      RMQ_USER="$2"; shift 2 ;;
    --password)  RMQ_PASS="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

if [[ -z "$NS" ]]; then
  echo "Uso: $0 --namespace <ns> [--user u --password p]"
  exit 1
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

kubectl -n "$NS" create secret generic rabbitmq \
  --from-literal=RABBITMQ_URL="amqp://${RMQ_USER}:${RMQ_PASS}@rabbitmq.${NS}.svc.cluster.local:5672" \
  --from-literal=RABBITMQ_HOST="rabbitmq.${NS}.svc.cluster.local" \
  --from-literal=RABBITMQ_PORT="5672" \
  --from-literal=RABBITMQ_USER="${RMQ_USER}" \
  --from-literal=RABBITMQ_PASSWORD="${RMQ_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: ${NS}
  labels:
    app: rabbitmq
spec:
  type: ClusterIP
  ports:
    - name: amqp
      port: 5672
      targetPort: 5672
    - name: management
      port: 15672
      targetPort: 15672
  selector:
    app: rabbitmq
EOF

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rabbitmq
  namespace: ${NS}
  labels:
    app: rabbitmq
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
        - name: rabbitmq
          image: rabbitmq:3.13-management-alpine
          env:
            - name: RABBITMQ_DEFAULT_USER
              valueFrom: { secretKeyRef: { name: rabbitmq, key: RABBITMQ_USER } }
            - name: RABBITMQ_DEFAULT_PASS
              valueFrom: { secretKeyRef: { name: rabbitmq, key: RABBITMQ_PASSWORD } }
          ports:
            - containerPort: 5672
            - containerPort: 15672
          readinessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "ping"]
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 10
          resources:
            limits: { cpu: 500m, memory: 512Mi }
            requests: { cpu: 50m, memory: 256Mi }
          volumeMounts:
            - name: data
              mountPath: /var/lib/rabbitmq
      volumes:
        - name: data
          emptyDir:
            sizeLimit: 1Gi
EOF

echo "⏳ Aguardando rabbitmq ficar pronto..."
kubectl rollout status -n "$NS" deploy/rabbitmq --timeout=180s
echo "✅ RabbitMQ pronto em $NS"
