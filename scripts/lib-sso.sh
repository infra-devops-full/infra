#!/usr/bin/env bash
# =============================================================================
# lib-sso.sh  (genérico) — biblioteca do login único (SSO). Use com `source`.
#
#   sso_enabled            0 se o GitHub OAuth App já foi configurado (Secret
#                          dex-github no namespace auth, vindo de
#                          config/auth/github-oauth.sealed.yaml)
#   sso_render <dir>       gera em <dir> os values (JSON, que o Helm aceita)
#                          de cada componente, a partir de
#                          config/auth/access.yaml + projects/*/project.yaml:
#                            dex.json  oauth2-proxy.json  argocd.json
#                            kube-prometheus-stack.json  argo-rollouts.json
#
# setup-observability.sh e setup-delivery.sh usam sso_render para incluir o
# login nos upgrades deles; setup-sso.sh orquestra tudo (make sso).
# =============================================================================

SSO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_INFRA_ROOT="$(cd "$SSO_LIB_DIR/.." && pwd)"

AUTH_HOST="auth.devops.local"
OAUTH2_HOST="oauth2.devops.local"

sso_enabled() {
  kubectl get secret dex-github -n auth >/dev/null 2>&1
}

sso_render() {
  local out="$1" ca projects
  mkdir -p "$out"
  ca="$(kubectl get configmap platform-ca -n argocd -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  if [[ -z "$ca" ]]; then
    echo "❌ ConfigMap platform-ca ausente (trust-manager). Rode: make security" >&2
    return 1
  fi
  projects="$(for f in "$SSO_INFRA_ROOT"/projects/*/project.yaml; do
    yq -o=json -I=0 "{\"name\": \"$(basename "$(dirname "$f")")\", \"devs\": (.access.devs // [])}" "$f"
  done | jq -s -c .)"

  ACCESS_JSON="$(yq -o=json -I=0 . "$SSO_INFRA_ROOT/config/auth/access.yaml")" \
  PROJECTS_JSON="$projects" CA_PEM="$ca" OUT="$out" \
  AUTH_HOST="$AUTH_HOST" OAUTH2_HOST="$OAUTH2_HOST" \
  SSO_TEST_MOCK="${SSO_TEST_MOCK:-}" python3 - <<'PY'
import json, os

acc = json.loads(os.environ["ACCESS_JSON"])
projects = json.loads(os.environ["PROJECTS_JSON"])
out, ca = os.environ["OUT"], os.environ["CA_PEM"]
auth, oauth2 = os.environ["AUTH_HOST"], os.environ["OAUTH2_HOST"]
issuer = f"https://{auth}"
admins = list(acc.get("admins", []))
orgs = list(acc.get("github", {}).get("orgs", []))
devs = sorted({g for p in projects for g in p["devs"]})

connectors = [{
    "type": "github", "id": "github", "name": "GitHub",
    "config": {
        "clientID": "$GITHUB_CLIENT_ID", "clientSecret": "$GITHUB_CLIENT_SECRET",
        "redirectURI": f"{issuer}/callback",
        # Só membros destas orgs entram; grupos = "<org>:<slug do time>".
        "orgs": [{"name": o} for o in orgs],
        "teamNameField": "slug",
        "useLoginAsID": True,
    },
}]
# Apenas para testar a plataforma sem GitHub (SSO_TEST_MOCK=1): login sem
# senha com o grupo "authors" como admin. NUNCA em uso real.
if os.environ.get("SSO_TEST_MOCK"):
    connectors.insert(0, {"type": "mockCallback", "id": "mock", "name": "Teste (sem senha)"})
    admins.append("authors")

def ingress(host, secret, extra=None):
    ann = {"cert-manager.io/cluster-issuer": "platform-ca",
           "cert-manager.io/usages": "digital signature,key encipherment,server auth",
           "nginx.ingress.kubernetes.io/ssl-redirect": "false"}
    ann.update(extra or {})
    return ann, [{"secretName": secret, "hosts": [host]}]

dex_ann, dex_tls = ingress(auth, "dex-tls")
json.dump({
    "config": {
        "issuer": issuer,
        "storage": {"type": "kubernetes", "config": {"inCluster": True}},
        "oauth2": {"skipApprovalScreen": True, "responseTypes": ["code"]},
        "connectors": connectors,
        "staticClients": [
            {"id": "argocd", "name": "ArgoCD", "secretEnv": "ARGOCD_CLIENT_SECRET",
             "redirectURIs": ["https://argocd.devops.local/auth/callback"]},
            {"id": "grafana", "name": "Grafana", "secretEnv": "GRAFANA_CLIENT_SECRET",
             "redirectURIs": ["https://grafana.devops.local/login/generic_oauth"]},
            {"id": "oauth2-proxy", "name": "Ferramentas da plataforma", "secretEnv": "OAUTH2_PROXY_CLIENT_SECRET",
             "redirectURIs": [f"https://{oauth2}/oauth2/callback"]},
        ],
    },
    "envFrom": [{"secretRef": {"name": "dex-github"}}, {"secretRef": {"name": "dex-clients"}}],
    "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "128Mi"}},
    "ingress": {"enabled": True, "className": "nginx", "annotations": dex_ann,
                "hosts": [{"host": auth, "paths": [{"path": "/", "pathType": "Prefix"}]}], "tls": dex_tls},
}, open(f"{out}/dex.json", "w"), indent=1)

o2_ann, o2_tls = ingress(oauth2, "oauth2-proxy-tls")
json.dump({
    "config": {"existingSecret": "oauth2-proxy"},
    "extraArgs": {
        "provider": "oidc", "oidc-issuer-url": issuer, "provider-display-name": "GitHub",
        "provider-ca-file": "/etc/platform-ca/ca.crt",
        "redirect-url": f"https://{oauth2}/oauth2/callback",
        "scope": "openid profile email groups", "oidc-groups-claim": "groups",
        "code-challenge-method": "S256",
        "cookie-domain": ".devops.local", "whitelist-domain": ".devops.local",
        "cookie-secure": "true", "cookie-samesite": "lax",
        "reverse-proxy": "true", "set-xauthrequest": "true",
        "skip-provider-button": "true", "email-domain": "*",
        # O padrão (force) faz o Dex mostrar uma tela de "aprovar acesso" a cada login.
        "approval-prompt": "auto",
        "upstream": "static://202",
    },
    "extraVolumes": [{"name": "platform-ca", "configMap": {"name": "platform-ca"}}],
    "extraVolumeMounts": [{"name": "platform-ca", "mountPath": "/etc/platform-ca", "readOnly": True}],
    "resources": {"requests": {"cpu": "10m", "memory": "24Mi"}, "limits": {"memory": "96Mi"}},
    "ingress": {"enabled": True, "className": "nginx", "path": "/oauth2", "pathType": "Prefix",
                "hosts": [oauth2], "annotations": o2_ann, "tls": o2_tls},
}, open(f"{out}/oauth2-proxy.json", "w"), indent=1)

# ArgoCD: OIDC no Dex; admins → role:admin; todo logado → leitura. O perfil
# "dev" de cada projeto vem do AppProject (charts/argocd-project).
oidc = "\n".join([
    "name: GitHub", f"issuer: {issuer}", "clientID: argocd",
    "clientSecret: $argocd-oidc:clientSecret",
    "requestedScopes: [openid, profile, email, groups]",
    "rootCA: |", *["  " + l for l in ca.strip().splitlines()],
])
json.dump({"configs": {
    "cm": {"url": "https://argocd.devops.local", "oidc.config": oidc, "admin.enabled": True},
    "rbac": {"policy.default": "role:readonly", "scopes": "[groups, email]",
             "policy.csv": "".join(f"g, {g}, role:admin\n" for g in admins)},
}}, open(f"{out}/argocd.json", "w"), indent=1)

def q(g):
    return "'" + g.replace("'", "") + "'"
def any_of(groups):
    return " || ".join(f"contains(groups[*], {q(g)})" for g in groups) or "`false`"
role_path = f"({any_of(admins)}) && 'Admin' || ({any_of(devs)}) && 'Editor' || 'Viewer'"

def protect(groups):
    # Sem %-encoding: o webhook do ingress-nginx recusa "%" na auth-url, e
    # ":"/"," são válidos na query.
    allowed = ",".join(groups)
    return {
        "nginx.ingress.kubernetes.io/auth-url":
            f"http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth?allowed_groups={allowed}",
        "nginx.ingress.kubernetes.io/auth-signin":
            f"https://{oauth2}/oauth2/start?rd=$scheme://$host$escaped_request_uri",
        "nginx.ingress.kubernetes.io/auth-response-headers": "X-Auth-Request-User,X-Auth-Request-Email",
    }

json.dump({
    "grafana": {
        "envFromSecret": "grafana-oidc",
        "extraConfigmapMounts": [{"name": "platform-ca", "mountPath": "/etc/platform-ca",
                                   "configMap": "platform-ca", "readOnly": True}],
        "grafana.ini": {
            "server": {"root_url": "https://grafana.devops.local"},
            "auth": {"oauth_auto_login": False},
            "auth.generic_oauth": {
                "enabled": True, "name": "GitHub", "icon": "github",
                "client_id": "grafana", "scopes": "openid profile email groups",
                "auth_url": f"{issuer}/auth", "token_url": f"{issuer}/token",
                "api_url": f"{issuer}/userinfo", "use_pkce": True,
                "allow_sign_up": True, "tls_client_ca": "/etc/platform-ca/ca.crt",
                "login_attribute_path": "preferred_username", "groups_attribute_path": "groups",
                "role_attribute_path": role_path, "role_attribute_strict": False,
            },
        },
    },
    "prometheus": {"ingress": {"annotations": protect(admins + devs)}},
    "alertmanager": {"ingress": {"annotations": protect(admins + devs)}},
}, open(f"{out}/kube-prometheus-stack.json", "w"), indent=1)

# Dashboard do Argo Rollouts: sem RBAC próprio (age com a permissão dele em
# todos os namespaces) → só admins, e aí as ações ficam liberadas.
json.dump({"dashboard": {"readonly": False, "ingress": {"annotations": protect(admins)}}},
          open(f"{out}/argo-rollouts.json", "w"), indent=1)
print(f"SSO: admins={admins} devs={devs} orgs={orgs}")
PY
}
