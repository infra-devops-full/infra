#!/usr/bin/env bash
# =============================================================================
# lib-project.sh
# -----------------------------------------------------------------------------
# Biblioteca compartilhada: descoberta e leitura dos projetos em projects/.
#
# A estrutura de pastas é a fonte de verdade — a MESMA regra que o
# ApplicationSet genérico (argocd/applicationset.yaml) usa no Git:
#
#   projects/<projeto>/apps/<app>/values-<env>.yaml   → app <app> no env <env>
#
# O project.yaml declara só o que não dá pra inferir das pastas: dependências
# (database, redis, rabbitmq) e hosts extras.
#
# Uso: source "$(dirname …)/lib-project.sh"
# Requer: yq (mikefarah v4).
# =============================================================================

if [[ -z "${INFRA_ROOT:-}" ]]; then
  _LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  INFRA_ROOT="$(cd "$_LIB_DIR/.." && pwd)"
fi
PROJECTS_DIR="$INFRA_ROOT/projects"

_require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "❌ 'yq' (mikefarah v4) é necessário. Instale: brew install yq" >&2
    exit 1
  fi
}

project_dir()      { echo "$PROJECTS_DIR/$1"; }
project_manifest() { echo "$PROJECTS_DIR/$1/project.yaml"; }

# Projetos = pastas em projects/ com project.yaml.
project_names() {
  [[ -d "$PROJECTS_DIR" ]] || return 0
  for d in "$PROJECTS_DIR"/*/; do
    [[ -f "${d}project.yaml" ]] && basename "$d"
  done
}

# Lê um campo do project.yaml: _pq <projeto> '<yq-expr>'
_pq() {
  _require_yq
  yq -r "$2" "$(project_manifest "$1")"
}

# Apps = pastas em projects/<p>/apps/ (um por linha).
project_apps() {
  local d; for d in "$(project_dir "$1")"/apps/*/; do
    [[ -d "$d" ]] && basename "$d"
  done
}

# Ambientes = sufixos dos values-<env>.yaml de todos os apps (um por linha).
project_envs() {
  local f; for f in "$(project_dir "$1")"/apps/*/values-*.yaml; do
    [[ -f "$f" ]] || continue
    f="$(basename "$f" .yaml)"; echo "${f#values-}"
  done | sort -u
}

# O app <app> roda no ambiente <env>?  (existe values-<env>.yaml)
project_app_in_env() { [[ -f "$(project_dir "$1")/apps/$2/values-$3.yaml" ]]; }

# Namespaces: <projeto>-<env> (um por linha).
project_namespaces() {
  local env; for env in $(project_envs "$1"); do echo "$1-$env"; done
}

# Values efetivos de um app num ambiente (values.yaml + values-<env>.yaml).
project_app_values() {
  _require_yq
  local base; base="$(project_dir "$1")/apps/$2"
  yq ea '. as $i ireduce ({}; . * $i)' "$base/values.yaml" "$base/values-$3.yaml"
}

# Host do ingress de um app num ambiente: ingress.host dos values, ou
# <env>.<app>.<projeto>.local — mesma regra do helper "app.ingressHost" do
# chart. Vazio se ingress.enabled=false.
project_app_host() {
  local vals; vals="$(project_app_values "$1" "$2" "$3")"
  # Não usar `.ingress.enabled // true`: o `//` do yq trata false como ausente.
  [[ "$(yq -r '.ingress.enabled == false' <<<"$vals")" == "true" ]] && return 0
  local host; host="$(yq -r '.ingress.host // ""' <<<"$vals")"
  echo "${host:-$3.$2.$1.local}"
}

# Hosts de um ambiente (um por linha).
project_hosts() {
  local app; for app in $(project_apps "$1"); do
    project_app_in_env "$1" "$app" "$2" && project_app_host "$1" "$app" "$2"
  done
}

# Hosts extras declarados no project.yaml (ferramentas do projeto etc.).
project_extra_hosts() { _pq "$1" '.extraHosts // [] | .[]'; }

# --- Dependências ------------------------------------------------------------
project_db_enabled()  { [[ "$(_pq "$1" '.database != null')" == "true" ]]; }
project_db_user()     { _pq "$1" '.database.user // "postgres"'; }
project_db_password() { _pq "$1" '.database.password // "postgres"'; }
project_db_default()  { _pq "$1" '.database.defaultDb // "app"'; }
project_db_extras()   { _pq "$1" '.database.extraDbs // [] | join(" ")'; }

project_redis_enabled()  { [[ "$(_pq "$1" '.redis.enabled // false')" == "true" ]]; }
project_redis_password() { _pq "$1" '.redis.password // ""'; }

project_rabbitmq_enabled()  { [[ "$(_pq "$1" '.rabbitmq.enabled // false')" == "true" ]]; }
project_rabbitmq_user()     { _pq "$1" '.rabbitmq.user // "guest"'; }
project_rabbitmq_password() { _pq "$1" '.rabbitmq.password // "guest"'; }

# Repo de infra observado pelo ArgoCD: $INFRA_REPO_URL > git remote origin.
infra_repo_url() {
  local url="${INFRA_REPO_URL:-}"
  [[ -z "$url" ]] && url="$(git -C "$INFRA_ROOT" remote get-url origin 2>/dev/null || true)"
  echo "$url"
}
