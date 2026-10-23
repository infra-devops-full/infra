#!/usr/bin/env bash
# =============================================================================
# setup-redis.sh  (genérico)
# -----------------------------------------------------------------------------
# Cria Redis em um namespace (com senha):
#   - Service redis  (6379)
#   - Deployment redis com emptyDir (volátil — mesmo trade-off do Postgres)
#
# A senha e a conexão ficam no Secret `redis` (REDIS_URL, REDIS_HOST, REDIS_PORT,
# REDIS_PASSWORD), criado a partir do SealedSecret do projeto (`make seal`).
# As apps consomem via envFrom: [{ secretRef: redis }].
#
# Uso:
#   ./scripts/setup-redis.sh --namespace <ns>
# =============================================================================

set -euo pipefail

NS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

if [[ -z "$NS" ]]; then
  echo "Uso: $0 --namespace <ns>"
  exit 1
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
kubectl get secret redis -n "$NS" >/dev/null 2>&1 || {
  echo "❌ Secret redis não existe em $NS — rode \`make seal PROJECT=<p>\` e \`make project-apply PROJECT=<p>\`"
  exit 1
}

# Hash do Secret no template do pod: se a senha mudar (make seal), o
# Deployment muda e o Kubernetes recria o pod com a credencial nova.
SECRET_SUM="$(kubectl get secret redis -n "$NS" -o jsonpath='{.data}' | shasum -a 256 | cut -c1-16)"

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
      annotations:
        devops-platform/secret-checksum: "${SECRET_SUM}"
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          # Senha do Secret selado (REDIS_PASSWORD), expandida pelo Kubernetes
          # (o \$ escapa o bash: quem resolve o \$(VAR) é o kubelet).
          command: ["redis-server", "--requirepass", "\$(REDIS_PASSWORD)"]
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
