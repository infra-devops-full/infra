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
#   github        por appRepo/appRepos: branch develop, secret INFRA_DEPLOY_KEY, deploy
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
for bin in docker k3d kubectl helm yq envsubst kubeseal jq; do
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
        ok "$P: secrets/$E.env ausente (o \`make seal\` cria a partir do example.env)"
      fi
    done
  fi
done

# --- Segredos (Sealed Secrets) -------------------------------------------------
section "Segredos (Sealed Secrets)"
CERT="$INFRA_ROOT/config/sealed-secrets/cert.pem"
KEYS="$(eval echo "${SEALED_KEYS_DIR:-$HOME/.config/devops-platform/sealed-secrets}")/keys.yaml"
if [[ -f "$CERT" ]]; then ok "chave pública: config/sealed-secrets/cert.pem"
else err "config/sealed-secrets/cert.pem não existe"; hint "make sealed-secrets (com o cluster no ar)"; fi
if [[ -f "$KEYS" ]]; then ok "backup da chave privada: $KEYS"
else warn "sem backup da chave privada — sem ele, um cluster novo não abre os segredos do Git"; hint "make sealed-secrets"; fi
if kubectl get deploy -n kube-system sealed-secrets-controller >/dev/null 2>&1 && [[ -f "$CERT" ]]; then
  if [[ "$(kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --fetch-cert 2>/dev/null)" == "$(cat "$CERT")" ]]; then
    ok "a chave do cluster é a mesma do cert.pem commitado"
  else
    err "a chave do cluster é DIFERENTE do cert.pem — os SealedSecrets do Git não abrem"; hint "restaure a chave (make sealed-secrets) ou sele de novo (make seal PROJECT=<p>)"
  fi
fi
for P in $PROJS; do
  grep -qE '^[[:space:]]+password:' "$(project_manifest "$P")" && \
    { err "$P: project.yaml tem senha em texto puro — remova (as senhas vão em secrets/<env>.env + make seal)"; }
  NEEDS=false
  { project_db_enabled "$P" || project_redis_enabled "$P" || project_rabbitmq_enabled "$P" || [[ -f "$(project_dir "$P")/secrets/example.env" ]]; } && NEEDS=true
  $NEEDS || continue
  for E in $(project_envs "$P"); do
    D="$(project_dir "$P")/sealed/$E"
    if [[ -n "$(ls "$D"/*.yaml 2>/dev/null)" ]]; then ok "$P/$E: $(ls "$D"/*.yaml | xargs -n1 basename | sed 's/.yaml//' | xargs)"
    else err "$P/$E: sem SealedSecrets em sealed/$E/"; hint "make seal PROJECT=$P && git add projects/$P/sealed"; fi
  done
done

# --- HTTPS e políticas -------------------------------------------------------
section "Kubernetes, HTTPS e políticas"
WANT_K8S="$(sed -nE 's#^image: rancher/k3s:v([0-9]+\.[0-9]+).*#\1#p' "$INFRA_ROOT/config/k3d-config.tmpl.yaml")"
if HAVE_K8S="$(kubectl version -o json 2>/dev/null | yq -r '.serverVersion.major + "." + (.serverVersion.minor | sub("[^0-9]", ""))' 2>/dev/null)" && [[ -n "$HAVE_K8S" && "$HAVE_K8S" != "." ]]; then
  if [[ "$HAVE_K8S" == "$WANT_K8S" ]]; then ok "Kubernetes $HAVE_K8S (o mesmo do config/k3d-config.tmpl.yaml)"
  else warn "cluster em Kubernetes $HAVE_K8S, mas o template pede $WANT_K8S"; hint "recriar: make destroy && make setup (a chave do Sealed Secrets e a CA são restauradas)"; fi

  CA_DIR="$(eval echo "${PLATFORM_CA_DIR:-$HOME/.config/devops-platform/ca}")"
  if kubectl get clusterissuer platform-ca -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    ok "cert-manager: ClusterIssuer platform-ca pronto"
    if [[ -f "$CA_DIR/platform-ca-secret.yaml" ]]; then ok "backup da CA: $CA_DIR"
    else warn "sem backup da CA — recriar o cluster gera outra CA e o navegador volta a desconfiar"; hint "make security"; fi
    if [[ -f "$CA_DIR/platform-ca.crt" ]] && [[ "$(uname)" == "Darwin" ]]; then
      if security verify-cert -c "$CA_DIR/platform-ca.crt" >/dev/null 2>&1; then ok "a CA é confiada pelo macOS (https sem aviso no navegador)"
      else warn "a CA não é confiada pelo macOS — o navegador avisa nos https://*.local"; hint "make trust-ca (pede a senha do Mac)"; fi
    fi
  else
    warn "cert-manager/CA não instalados — Ingress sem HTTPS válido"; hint "make security"
  fi

  if kubectl get deploy -n kyverno kyverno-admission-controller >/dev/null 2>&1; then
    NPOL="$(kubectl get validatingpolicies,generatingpolicies --no-headers 2>/dev/null | grep -c platform- || true)"
    if [[ "$NPOL" -ge 5 ]]; then ok "Kyverno: $NPOL políticas da plataforma"
    else warn "Kyverno sem as políticas da plataforma ($NPOL)"; hint "make apply-argocd"; fi
    for P in $PROJS; do
      for E in $(project_envs "$P"); do
        NS="$P-$E"
        kubectl get ns "$NS" >/dev/null 2>&1 || continue
        if kubectl get networkpolicy default-deny-ingress -n "$NS" >/dev/null 2>&1; then ok "$NS: NetworkPolicies e Pod Security ativos"
        else warn "$NS: sem NetworkPolicies da plataforma"; hint "make project-apply PROJECT=$P (põe os labels do namespace)"; fi
      done
    done
  else
    warn "Kyverno não instalado — sem NetworkPolicies nem políticas de admissão"; hint "make security && make apply-argocd"
  fi
else
  warn "cluster fora do ar — pulando"
fi

# --- Entrega progressiva -----------------------------------------------------
section "Entrega progressiva (Argo Rollouts)"
if kubectl get deploy -n argo-rollouts argo-rollouts >/dev/null 2>&1; then
  ok "Argo Rollouts instalado (dashboard: https://rollouts.devops.local)"
  if kubectl get clusteranalysistemplate platform-canary-error-rate >/dev/null 2>&1; then ok "análise padrão: platform-canary-error-rate"
  else warn "ClusterAnalysisTemplate platform-canary-error-rate ausente — canaries sem análise"; hint "make apply-argocd"; fi
  while read -r NS NAME PHASE; do
    [[ -z "$NAME" ]] && continue
    case "$PHASE" in
      Healthy) ;;
      Degraded) warn "$NS/$NAME: canary ABORTADO (versão estável no ar)"; hint "corrija e publique outra versão, ou make retry SERVICE=$NAME NAMESPACE=$NS" ;;
      Paused|Progressing) ok "$NS/$NAME: canary em andamento ($PHASE)" ;;
      *) warn "$NS/$NAME: $PHASE" ;;
    esac
  done < <(kubectl get rollouts -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
elif kubectl version >/dev/null 2>&1; then
  if grep -qs "enabled: true" <(grep -A1 -h "^rollout:" "$INFRA_ROOT"/projects/*/apps/*/values*.yaml); then
    err "há apps com rollout.enabled, mas o Argo Rollouts não está instalado"; hint "make delivery"
  else warn "Argo Rollouts não instalado"; hint "make delivery"; fi
fi

# --- GitHub ------------------------------------------------------------------
section "GitHub (repos dos apps)"
slug() { sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##; s#/$##' <<<"$1"; }
if $OFFLINE; then
  warn "pulado (offline ou gh indisponível)"
else
  INFRA_REPO="$(slug "$(infra_repo_url)")"
  KEYS="$(gh api "repos/$INFRA_REPO/keys" --paginate --jq '.[] | "\(.title) \(.read_only)"' 2>/dev/null)"
  for P in $PROJS; do
    URLS="$(project_app_repos "$P")"
    [[ -z "$URLS" ]] && { warn "$P: sem appRepo/appRepos no project.yaml"; continue; }
    for URL in $URLS; do
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
    # Qualidade e segurança (avisos: o deploy funciona sem, mas sem proteção).
    SEC=0
    gh api "repos/$R/branches/main/protection" --jq '.required_status_checks.contexts[]?' 2>/dev/null | grep -qx ci \
      || { warn "$R: main não exige o check \`ci\` (PR com teste falhando pode ser mergeado)"; SEC=1; }
    [[ "$(gh api "repos/$R/code-scanning/default-setup" --jq .state 2>/dev/null)" == "configured" ]] \
      || { warn "$R: CodeQL não configurado"; SEC=1; }
    gh api "repos/$R/vulnerability-alerts" >/dev/null 2>&1 \
      || { warn "$R: alertas do Dependabot desligados"; SEC=1; }
    [[ $SEC -eq 0 ]] && ok "$R: check ci obrigatório + CodeQL + Dependabot"
    [[ $PROBLEMS -eq 1 || $SEC -eq 1 ]] && hint "make github PROJECT=$P"
    done
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
