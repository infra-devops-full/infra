#!/usr/bin/env bash
# =============================================================================
# setup-rabbitmq.sh  (genérico)
# -----------------------------------------------------------------------------
# Cria RabbitMQ (com management UI) em um namespace. Usuário e senha vêm do
# Secret `rabbitmq` (RABBITMQ_URL, RABBITMQ_HOST, RABBITMQ_PORT, RABBITMQ_USER,
# RABBITMQ_PASSWORD), criado a partir do SealedSecret do projeto (`make seal`).
#   - Service rabbitmq (5672 AMQP, 15672 management, 15692 métricas Prometheus)
#   - ServiceMonitor (dashboard "Infra / RabbitMQ" no Grafana)
#   - Deployment rabbitmq com emptyDir (volátil — mesmo trade-off do Postgres)
#
#   - Ingress do painel web (opcional, --host): HTTPS com a CA da plataforma
#     e, com --allowed-groups, login do SSO na frente (oauth2-proxy). Depois
#     do SSO o RabbitMQ pede o usuário/senha dele: make rabbitmq-login.
#
# As apps consomem a conexão via envFrom: [{ secretRef: rabbitmq }].
# Management UI sem Ingress: kubectl port-forward -n <ns> svc/rabbitmq 15672:15672
#
# Uso:
#   ./scripts/setup-rabbitmq.sh --namespace <ns> [--host <h> [--allowed-groups <g1,g2>]]
# =============================================================================

set -euo pipefail

NS=""
HOST=""
ALLOWED_GROUPS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --allowed-groups) ALLOWED_GROUPS="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

if [[ -z "$NS" ]]; then
  echo "Uso: $0 --namespace <ns>"
  exit 1
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
kubectl get secret rabbitmq -n "$NS" >/dev/null 2>&1 || {
  echo "❌ Secret rabbitmq não existe em $NS — rode \`make seal PROJECT=<p>\` e \`make project-apply PROJECT=<p>\`"
  exit 1
}

# Hash do Secret no template do pod: se a senha mudar (make seal), o
# Deployment muda e o Kubernetes recria o pod com a credencial nova.
SECRET_SUM="$(kubectl get secret rabbitmq -n "$NS" -o jsonpath='{.data}' | shasum -a 256 | cut -c1-16)"

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
    - name: metrics
      port: 15692
      targetPort: 15692
  selector:
    app: rabbitmq
EOF

# Métricas do plugin rabbitmq_prometheus (já ligado na imagem oficial). Só se
# o Prometheus Operator existir (CRD do kube-prometheus-stack).
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: rabbitmq
  namespace: ${NS}
  labels:
    app: rabbitmq
spec:
  selector:
    matchLabels:
      app: rabbitmq
  endpoints:
    - port: metrics
      interval: 60s
EOF
fi

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
      annotations:
        devops-platform/secret-checksum: "${SECRET_SUM}"
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
            - containerPort: 15692
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

# Painel web no Ingress. Sem o ingress-nginx (cluster mínimo), fica só o
# port-forward. A NetworkPolicy allow-from-ingress-nginx do namespace já libera.
if [[ -n "$HOST" ]] && kubectl get ingressclass nginx >/dev/null 2>&1; then
  AUTH_ANN=""
  # SSO só se o oauth2-proxy existir (make sso); sem ele, o login do RabbitMQ.
  if [[ -n "$ALLOWED_GROUPS" ]] && kubectl get svc oauth2-proxy -n auth >/dev/null 2>&1; then
    AUTH_ANN="    nginx.ingress.kubernetes.io/auth-url: \"http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth?allowed_groups=${ALLOWED_GROUPS}\"
    nginx.ingress.kubernetes.io/auth-signin: \"https://oauth2.devops.local/oauth2/start?rd=\$scheme://\$host\$escaped_request_uri\"
    nginx.ingress.kubernetes.io/auth-response-headers: X-Auth-Request-User,X-Auth-Request-Email"
  fi
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rabbitmq
  namespace: ${NS}
  labels:
    app: rabbitmq
  annotations:
    cert-manager.io/cluster-issuer: platform-ca
    cert-manager.io/usages: digital signature,key encipherment,server auth
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
${AUTH_ANN}
spec:
  ingressClassName: nginx
  tls:
    - hosts: [${HOST}]
      secretName: rabbitmq-tls
  rules:
    - host: ${HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rabbitmq
                port:
                  name: management
EOF
elif [[ -z "$HOST" ]]; then
  kubectl delete ingress rabbitmq -n "$NS" --ignore-not-found >/dev/null
fi

echo "⏳ Aguardando rabbitmq ficar pronto..."
kubectl rollout status -n "$NS" deploy/rabbitmq --timeout=180s
echo "✅ RabbitMQ pronto em $NS${HOST:+ — painel: https://$HOST}"
