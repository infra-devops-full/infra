#!/usr/bin/env bash
# =============================================================================
# setup-rabbitmq-portal.sh  (genérico) — seletor de ambiente do RabbitMQ
# -----------------------------------------------------------------------------
# https://rabbitmq.devops.local é um host só para todos os brokers:
#
#   /                      esta página: select "projeto / ambiente" (como as
#                          variáveis do Grafana) + o painel escolhido embaixo
#   /wlstore-develop/      management UI do RabbitMQ de wlstore-develop
#   /wlstore-prod/         ... (Ingress de cada namespace, setup-rabbitmq.sh)
#
# A lista vem de projects/*/project.yaml (rabbitmq.enabled e ui != false):
# rode de novo ao criar projeto ou ambiente (make project-apply já roda).
# Fica em `monitoring`, com SSO: qualquer membro logado vê a página; cada
# painel é protegido pelos grupos do projeto (admins + access.devs).
#
# Uso: ./scripts/setup-rabbitmq-portal.sh
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

NS=monitoring
HOST="$RABBITMQ_UI_HOST"

# <option> por projeto/ambiente com painel.
OPTIONS=""
for PROJ in $(project_names); do
  project_rabbitmq_ui "$PROJ" || continue
  for ENV_NAME in $(project_envs "$PROJ"); do
    OPTIONS+="          <option value=\"${PROJ}-${ENV_NAME}\">${PROJ} / ${ENV_NAME}</option>"$'\n'
  done
done
if [[ -z "$OPTIONS" ]]; then
  echo "↷ nenhum projeto com rabbitmq.ui — painel não criado"
  kubectl delete ingress,deploy,svc,cm -n "$NS" -l app=rabbitmq-portal --ignore-not-found >/dev/null
  exit 0
fi

INDEX_HTML="$(cat <<HTML
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>RabbitMQ</title>
  <style>
    :root { color-scheme: light dark; --bg:#f4f5f8; --fg:#1f2430; --muted:#5b6274; --bar:#fff; --line:#d9dce3; --accent:#ff6600; }
    @media (prefers-color-scheme: dark) { :root { --bg:#111217; --fg:#d8d9de; --muted:#9a9fae; --bar:#181b1f; --line:#2c3038; } }
    html, body { margin:0; height:100%; background:var(--bg); color:var(--fg); font:14px/1.4 system-ui, sans-serif; }
    body { display:flex; flex-direction:column; }
    header { display:flex; flex-wrap:wrap; align-items:center; gap:12px; padding:8px 16px; background:var(--bar); border-bottom:1px solid var(--line); }
    h1 { font-size:15px; margin:0; font-weight:600; }
    h1 span { color:var(--accent); }
    label { color:var(--muted); display:flex; align-items:center; gap:6px; }
    select { font:inherit; padding:4px 8px; border-radius:4px; border:1px solid var(--line); background:var(--bg); color:var(--fg); }
    a { color:var(--muted); margin-left:auto; }
    iframe { flex:1; width:100%; border:0; background:#fff; }
  </style>
</head>
<body>
  <header>
    <h1><span>●</span> RabbitMQ</h1>
    <label>Ambiente
      <select id="env">
${OPTIONS}      </select>
    </label>
    <a id="open" target="_blank" rel="noopener">abrir em nova aba ↗</a>
  </header>
  <iframe id="panel" title="RabbitMQ management"></iframe>
  <script>
    // Ambiente pela URL (#wlstore-prod) ou o último escolhido; o hash permite
    // mandar o link direto de um ambiente, como as variáveis do Grafana.
    const sel = document.getElementById("env");
    const valid = (v) => [...sel.options].some((o) => o.value === v);
    let saved = null;
    try { saved = localStorage.getItem("rabbitmq-env"); } catch (e) {}
    const initial = [location.hash.slice(1), saved].find(valid);
    if (initial) sel.value = initial;
    function show() {
      const url = "/" + sel.value + "/";
      document.getElementById("panel").src = url;
      document.getElementById("open").href = url;
      history.replaceState(null, "", "#" + sel.value);
      try { localStorage.setItem("rabbitmq-env", sel.value); } catch (e) {}
    }
    sel.addEventListener("change", show);
    show();
  </script>
</body>
</html>
HTML
)"

kubectl create configmap rabbitmq-portal -n "$NS" --from-literal=index.html="$INDEX_HTML" \
  --dry-run=client -o yaml | kubectl label --local -f - app=rabbitmq-portal -o yaml | kubectl apply -f -
SUM="$(printf '%s' "$INDEX_HTML" | shasum -a 256 | cut -c1-16)"

AUTH_ANN=""
if kubectl get svc oauth2-proxy -n auth >/dev/null 2>&1; then
  AUTH_ANN="    nginx.ingress.kubernetes.io/auth-url: \"http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth\"
    nginx.ingress.kubernetes.io/auth-signin: \"https://oauth2.devops.local/oauth2/start?rd=\$scheme://\$host\$escaped_request_uri\"
    nginx.ingress.kubernetes.io/auth-response-headers: X-Auth-Request-User,X-Auth-Request-Email"
fi

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rabbitmq-portal
  namespace: ${NS}
  labels:
    app: rabbitmq-portal
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq-portal
  template:
    metadata:
      labels:
        app: rabbitmq-portal
      annotations:
        devops-platform/config-checksum: "${SUM}"
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27.3-alpine
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 30
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          resources:
            limits: { cpu: 50m, memory: 32Mi }
            requests: { cpu: 5m, memory: 8Mi }
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
      volumes:
        - name: html
          configMap:
            name: rabbitmq-portal
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq-portal
  namespace: ${NS}
  labels:
    app: rabbitmq-portal
spec:
  selector:
    app: rabbitmq-portal
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rabbitmq-portal
  namespace: ${NS}
  labels:
    app: rabbitmq-portal
  annotations:
    cert-manager.io/cluster-issuer: platform-ca
    cert-manager.io/usages: digital signature,key encipherment,server auth
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
${AUTH_ANN}
spec:
  ingressClassName: nginx
  tls:
    - hosts: [${HOST}]
      secretName: rabbitmq-portal-tls
  rules:
    - host: ${HOST}
      http:
        paths:
          # Só a raiz: /<ns>/ são os Ingresses dos namespaces (caminho mais
          # longo ganha no ingress-nginx).
          - path: /
            pathType: Exact
            backend:
              service:
                name: rabbitmq-portal
                port:
                  name: http
EOF
kubectl rollout status -n "$NS" deploy/rabbitmq-portal --timeout=120s
echo "✅ Painel do RabbitMQ: https://${HOST}"
