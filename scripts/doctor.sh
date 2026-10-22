#!/usr/bin/env bash
# =============================================================================
# doctor.sh  (genérico) — confere tokens, variáveis e configuração ANTES de
# subir/atualizar a plataforma. Não altera nada.
#
#   ferramentas   docker rodando, k3d, kubectl, helm, yq, envsubst, gh
#   docker        memória disponível, Kubernetes do Docker Desktop ligado
#                 em paralelo (CPU desperdiçada)
#   .env          GITHUB_TOKEN: vazio é o certo p/ imagens públicas; se
#                 preenchido, tem de ser PAT classic aceito pelo GHCR
#   projetos      apps/values, image.repository, secrets/<env>.env x example.env
#   github        por appRepo: branch develop, secret INFRA_DEPLOY_KEY, deploy
#                 key no repo de infra, workflow presente
#   git (infra)   mudanças em projects/ sem commit/push (o ArgoCD lê do GitHub)
#
# Saída: 0 = ok (pode haver avisos), 1 = erro que vai quebrar o deploy.
#
# Uso:
#   ./scripts/doctor.sh            # tudo
#   ./scripts/doctor.sh --offline  # sem chamadas ao GitHub/GHCR
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ERRORS=0; WARNS=0
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARNS=$((WARNS+1)); }
err()  { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS+1)); }
hint() { echo -e "      → $1"; }
section() { echo ""; echo -e "${CYAN}▸ $1${NC}"; }

OFFLINE=false
[[ "${1:-}" == "--offline" ]] && OFFLINE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env é lido sem exportar para o resto do script: o GITHUB_TOKEN dele é do
# GHCR e não pode vazar para o gh (que usa o `gh auth login`).
ENV_TOKEN=""; ENV_USER=""
if [[ -f "$INFRA_ROOT/.env" ]]; then
  ENV_TOKEN="$(set -a; . "$INFRA_ROOT/.env" >/dev/null 2>&1; echo "${GITHUB_TOKEN:-}")"
  ENV_USER="$(set -a; . "$INFRA_ROOT/.env" >/dev/null 2>&1; echo "${GITHUB_USERNAME:-}")"
  INFRA_REPO_URL="$(set -a; . "$INFRA_ROOT/.env" >/dev/null 2>&1; echo "${INFRA_REPO_URL:-}")"
  INFRA_BRANCH="$(set -a; . "$INFRA_ROOT/.env" >/dev/null 2>&1; echo "${INFRA_BRANCH:-main}")"
fi
unset GITHUB_TOKEN GH_TOKEN
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

# --- Ferramentas -------------------------------------------------------------
section "Ferramentas"
for bin in docker k3d kubectl helm yq envsubst; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else err "$bin não encontrado"; hint "brew install $bin"; fi
done
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh autenticado ($(gh api user --jq .login 2>/dev/null))"
  else warn "gh não autenticado — checagens do GitHub serão puladas"; hint "gh auth login"; OFFLINE=true; fi
else
  warn "gh não encontrado — checagens do GitHub serão puladas"; hint "brew install gh"; OFFLINE=true
fi

# --- Docker ------------------------------------------------------------------
section "Docker"
if docker info >/dev/null 2>&1; then
  MEM_GB=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
  CPUS=$(docker info --format '{{.NCPU}}')
  ok "Docker rodando (${CPUS} CPUs, ${MEM_GB} GB)"
  [[ $MEM_GB -lt 7 ]] && { warn "Docker com ${MEM_GB} GB de RAM — recomendado ≥ 8 GB"; hint "Docker Desktop → Settings → Resources"; }
  if kubectl --context docker-desktop get nodes >/dev/null 2>&1; then
    warn "Kubernetes do Docker Desktop está LIGADO em paralelo ao k3d (consome CPU à toa)"
    hint "Docker Desktop → Settings → Kubernetes → desmarque 'Enable Kubernetes'"
  fi
  OTHER=$(k3d cluster list -o json 2>/dev/null | yq -p json -r '.[].name' 2>/dev/null | grep -vx "${CLUSTER_NAME:-devops-lab}" | xargs)
  [[ -n "$OTHER" ]] && { warn "outros clusters k3d rodando: $OTHER"; hint "k3d cluster stop <nome>"; }
else
  err "Docker não está rodando"; hint "abra o Docker Desktop"
fi

# --- .env --------------------------------------------------------------------
section ".env (repo de infra)"
if [[ ! -f "$INFRA_ROOT/.env" ]]; then
  warn ".env não existe — usando defaults"; hint "cp .env.template .env"
else
  ok ".env presente"
fi
case "$ENV_TOKEN" in
  ""|ghp_your_github_token_here)
    ok "GITHUB_TOKEN vazio — imagens públicas do GHCR baixam sem credencial (recomendado)" ;;
  github_pat_*)
    err "GITHUB_TOKEN é PAT fine-grained: o GHCR recusa e o pull das imagens falha com 403"
    hint "deixe GITHUB_TOKEN vazio (imagens públicas) ou use um PAT classic só com read:packages" ;;
  *)
    if $OFFLINE; then
      warn "GITHUB_TOKEN preenchido (não validado: modo offline)"
    else
      CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "${ENV_USER}:${ENV_TOKEN}" \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:${ENV_USER}/probe:pull")
      if [[ "$CODE" == "200" ]]; then
        ok "GITHUB_TOKEN aceito pelo GHCR"
        SCOPES=$(curl -s -o /dev/null -D - -H "Authorization: token ${ENV_TOKEN}" https://api.github.com/user \
          | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' | tr -d '\r')
        if [[ -n "$SCOPES" && "$SCOPES" != "read:packages" ]]; then
          warn "GITHUB_TOKEN tem escopos além do necessário: $SCOPES"
          hint "o cluster só precisa de read:packages — gere um PAT classic só com esse escopo"
        fi
      else
        err "GITHUB_TOKEN recusado pelo GHCR (HTTP $CODE) — o ghcr-secret não será criado"
        hint "deixe vazio (imagens públicas) ou gere PAT classic com read:packages"
      fi
    fi ;;
esac
[[ -n "$ENV_TOKEN" && "$ENV_TOKEN" != ghp_your_github_token_here && -z "$ENV_USER" ]] && \
  err "GITHUB_TOKEN preenchido sem GITHUB_USERNAME"

# --- Projetos ----------------------------------------------------------------
section "Projetos"
PROJS="$(project_names | xargs)"
[[ -z "$PROJS" ]] && warn "nenhum projeto em projects/"
for P in $PROJS; do
  APPS="$(project_apps "$P" | xargs)"; ENVS="$(project_envs "$P" | xargs)"
  if [[ -z "$APPS" ]]; then err "$P: nenhum app em projects/$P/apps/"; continue; fi
  if [[ -z "$ENVS" ]]; then err "$P: nenhum values-<env>.yaml"; continue; fi
  ok "$P — apps: $APPS | ambientes: $ENVS"
  for A in $APPS; do
    D="$(project_dir "$P")/apps/$A"
    [[ -f "$D/values.yaml" ]] || { err "$P/$A: falta values.yaml"; continue; }
    [[ -n "$(yq -r '.image.repository // ""' "$D/values.yaml")" ]] || err "$P/$A: image.repository vazio"
    for E in $ENVS; do
      [[ -f "$D/values-$E.yaml" ]] || warn "$P/$A: sem values-$E.yaml (não roda em $E)"
    done
  done
  # Segredos: cada <env>.env precisa ter todas as chaves do example.env.
  SD="$(project_dir "$P")/secrets"
  if [[ -f "$SD/example.env" ]]; then
    REQ="$(grep -Eo '^[A-Za-z_][A-Za-z0-9_]*=' "$SD/example.env" | tr -d = | sort -u)"
    for E in $ENVS; do
      if [[ -f "$SD/$E.env" ]]; then
        HAVE="$(grep -Eo '^[A-Za-z_][A-Za-z0-9_]*=' "$SD/$E.env" | tr -d = | sort -u)"
        MISSING="$(comm -23 <(echo "$REQ") <(echo "$HAVE") | xargs)"
        if [[ -n "$MISSING" ]]; then err "$P: secrets/$E.env sem as chaves: $MISSING"
        else ok "$P: secrets/$E.env completo"; fi
        grep -nE '^[A-Za-z_][A-Za-z0-9_]*="' "$SD/$E.env" >/dev/null && \
          warn "$P: secrets/$E.env tem valores entre aspas — o kubectl grava as aspas junto"
      else
        ok "$P: secrets/$E.env ausente → usa example.env (valores de lab)"
      fi
    done
  fi
done

# --- GitHub ------------------------------------------------------------------
section "GitHub (repos dos apps)"
slug() { sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##; s#/$##' <<<"$1"; }
if $OFFLINE; then
  warn "pulado (offline ou gh indisponível)"
else
  INFRA_REPO="$(slug "$(infra_repo_url)")"
  KEYS="$(gh api "repos/$INFRA_REPO/keys" --paginate --jq '.[] | "\(.title) \(.read_only)"' 2>/dev/null)"
  for P in $PROJS; do
    URL="$(_pq "$P" '.appRepo // ""')"
    [[ -z "$URL" ]] && { warn "$P: sem appRepo no project.yaml"; continue; }
    R="$(slug "$URL")"
    if ! gh api "repos/$R" >/dev/null 2>&1; then err "$P: repo $R não encontrado/sem acesso"; continue; fi
    PROBLEMS=0
    gh api "repos/$R/branches/develop" >/dev/null 2>&1 || { err "$R: sem branch develop"; PROBLEMS=1; }
    gh secret list --repo "$R" --json name --jq '.[].name' 2>/dev/null | grep -qx INFRA_DEPLOY_KEY \
      || { err "$R: sem secret INFRA_DEPLOY_KEY"; PROBLEMS=1; }
    grep -q "^ci-deploy:$R false$" <<<"$KEYS" \
      || { err "$R: sem deploy key com escrita em $INFRA_REPO"; PROBLEMS=1; }
    for B in develop main; do
      gh api "repos/$R/contents/.github/workflows/deploy.yml?ref=$B" >/dev/null 2>&1 \
        || warn "$R: workflow deploy.yml ausente em $B"
    done
    [[ $PROBLEMS -eq 0 ]] && ok "$R: develop + INFRA_DEPLOY_KEY + deploy key"
    [[ $PROBLEMS -eq 1 ]] && hint "make github PROJECT=$P"
  done
fi

# --- Git do repo de infra ----------------------------------------------------
section "Repo de infra (o ArgoCD lê do GitHub, não da sua máquina)"
if git -C "$INFRA_ROOT" rev-parse >/dev/null 2>&1; then
  DIRTY="$(git -C "$INFRA_ROOT" status --porcelain -- projects argocd charts k8s | wc -l | tr -d ' ')"
  [[ "$DIRTY" -gt 0 ]] && { warn "$DIRTY arquivo(s) sem commit em projects/argocd/charts/k8s"; hint "git add -A && git commit && git push"; }
  git -C "$INFRA_ROOT" fetch -q origin "${INFRA_BRANCH:-main}" 2>/dev/null
  AHEAD="$(git -C "$INFRA_ROOT" rev-list --count "origin/${INFRA_BRANCH:-main}..HEAD" 2>/dev/null || echo 0)"
  [[ "$AHEAD" -gt 0 ]] && { warn "$AHEAD commit(s) local(is) sem push"; hint "git push"; }
  [[ "$DIRTY" -eq 0 && "$AHEAD" -eq 0 ]] && ok "sincronizado com origin/${INFRA_BRANCH:-main}"
fi

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}✗ $ERRORS erro(s), $WARNS aviso(s) — corrija os erros antes do deploy.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Tudo certo${NC} ($WARNS aviso(s))."
