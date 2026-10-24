#!/usr/bin/env bash
# =============================================================================
# github-bootstrap.sh  (genérico)
# -----------------------------------------------------------------------------
# Configura no GitHub tudo que a esteira de um projeto precisa. Idempotente.
# Para cada repo de app do projeto (projects/<p>/project.yaml → appRepo, ou
# appRepos quando cada app/time tem o seu repo):
#
#   1. branch `develop` no repo do app (criada a partir da main)
#   2. deploy key SSH: pública no REPO DE INFRA (com escrita), privada como
#      secret INFRA_DEPLOY_KEY no repo do app — é como o CI commita a tag.
#      Não expira e só dá acesso ao repo de infra.
#   3. remove o secret antigo INFRA_REPO_TOKEN (substituído pela deploy key)
#   4. protege a `main` do app: só entra por PR (merge de develop = deploy prod)
#      e com o check `ci` do workflow verde (lint + testes + build + scan)
#   5. segurança do repo: CodeQL (análise estática), Dependabot (alertas e PRs
#      de correção de CVE) e secret scanning com push protection
#
# Requer: gh autenticado como admin do repo de infra e dos repos dos apps
# (gh auth login), ssh-keygen, yq.
#
# Uso:
#   ./scripts/github-bootstrap.sh                 # todos os projetos
#   ./scripts/github-bootstrap.sh crivo           # só um (ou vários)
#   ./scripts/github-bootstrap.sh --rotate crivo  # gera deploy key nova
#   ./scripts/github-bootstrap.sh --no-protect    # não mexe na proteção da main
#   ./scripts/github-bootstrap.sh --dry-run       # só mostra o que faria
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

ROTATE=false; PROTECT=true; DRY=false; PROJECTS=()
for a in "$@"; do
  case "$a" in
    --rotate)     ROTATE=true ;;
    --no-protect) PROTECT=false ;;
    --dry-run)    DRY=true ;;
    -h|--help)    sed -n '2,27p' "$0"; exit 0 ;;
    -*)           echo "Opção desconhecida: $a"; exit 1 ;;
    *)            PROJECTS+=("$a") ;;
  esac
done

run() { if $DRY; then echo -e "    ${CYAN}[dry-run]${NC} $*" >&2; else "$@"; fi; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"; set +a
fi
# O GITHUB_TOKEN do .env é a credencial de pull do GHCR, não a do gh. Se
# ficasse no ambiente, o gh usaria ele no lugar do seu login (gh auth login).
unset GITHUB_TOKEN GH_TOKEN
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

for bin in gh ssh-keygen yq; do
  command -v "$bin" >/dev/null || { echo "❌ '$bin' não encontrado"; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "❌ gh não autenticado: gh auth login"; exit 1; }

# owner/repo a partir de uma URL do GitHub (https ou ssh).
slug() { sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##; s#/$##' <<<"$1"; }

INFRA_REPO="$(slug "$(infra_repo_url)")"
[[ -n "$INFRA_REPO" ]] || { echo "❌ repo de infra não identificado (INFRA_REPO_URL / git remote)"; exit 1; }

echo -e "${CYAN}Repo de infra:${NC} $INFRA_REPO"
[[ "$(gh api "repos/$INFRA_REPO" --jq .permissions.admin)" == "true" ]] || {
  echo "❌ seu usuário do gh não é admin de $INFRA_REPO (necessário p/ deploy keys)"; exit 1; }
# Orgs novas vêm com deploy keys desligadas (política da org). Sem isso o
# cadastro da chave falha com 422 "Deploy keys are disabled for this repository".
INFRA_OWNER="${INFRA_REPO%%/*}"
if [[ "$(gh api "users/$INFRA_OWNER" --jq .type)" == "Organization" ]]; then
  if [[ "$(gh api "orgs/$INFRA_OWNER" --jq .deploy_keys_enabled_for_repositories)" == "false" ]]; then
    echo -e "  ${YELLOW}⚠${NC} a org $INFRA_OWNER está com deploy keys desligadas — habilitando..."
    if $DRY; then
      echo -e "    ${CYAN}[dry-run]${NC} gh api -X PATCH orgs/$INFRA_OWNER -F deploy_keys_enabled_for_repositories=true" >&2
    elif ! OUT="$(gh api -X PATCH "orgs/$INFRA_OWNER" -F deploy_keys_enabled_for_repositories=true 2>&1)"; then
      fail "não consegui habilitar deploy keys na org $INFRA_OWNER: $(sed -n 's/.*"message":"\([^"]*\)".*/\1/p' <<<"$OUT" | head -1)"
      echo "      Opção 1 (terminal): dê ao gh o escopo de admin da org e rode de novo:"
      echo "        gh auth refresh -h github.com -s admin:org && make github"
      echo "      Opção 2 (navegador): https://github.com/organizations/$INFRA_OWNER/settings"
      echo "        → habilite 'Deploy keys' para os repositórios da org e rode make github"
      exit 1
    else
      ok "deploy keys habilitadas na org $INFRA_OWNER"
    fi
  fi
fi

if gh api "repos/$INFRA_REPO/branches/${INFRA_BRANCH:-main}/protection" >/dev/null 2>&1; then
  warn "a branch ${INFRA_BRANCH:-main} de $INFRA_REPO tem proteção — garanta que deploy keys podem fazer push nela"
fi

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  while IFS= read -r p; do PROJECTS+=("$p"); done < <(project_names)
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILED=0

# Configura um repo de app (owner/repo). Retorna 1 se algo falhou.
setup_repo() {
  local APP_REPO="$1" DEFAULT SHA TITLE KEY_ID HAS_SECRET KEYFILE OUT b
  echo "  repo do app: $APP_REPO"

  if [[ "$(gh api "repos/$APP_REPO" --jq .permissions.admin 2>/dev/null)" != "true" ]]; then
    fail "sem admin em $APP_REPO (ou repo não existe)"; return 1
  fi

  # 1. Branch develop --------------------------------------------------------
  DEFAULT="$(gh api "repos/$APP_REPO" --jq .default_branch)"
  if gh api "repos/$APP_REPO/branches/develop" >/dev/null 2>&1; then
    ok "branch develop já existe"
  else
    SHA="$(gh api "repos/$APP_REPO/git/ref/heads/$DEFAULT" --jq .object.sha)"
    run gh api -X POST "repos/$APP_REPO/git/refs" -f ref=refs/heads/develop -f sha="$SHA" >/dev/null
    ok "branch develop criada a partir de $DEFAULT (${SHA:0:7})"
  fi

  # 2. Deploy key + secret ---------------------------------------------------
  TITLE="ci-deploy:$APP_REPO"
  KEY_ID="$(gh api "repos/$INFRA_REPO/keys" --paginate --jq ".[] | select(.title == \"$TITLE\") | .id" | head -1)"
  HAS_SECRET=false
  gh secret list --repo "$APP_REPO" --json name --jq '.[].name' | grep -qx INFRA_DEPLOY_KEY && HAS_SECRET=true

  if [[ -n "$KEY_ID" ]] && $HAS_SECRET && ! $ROTATE; then
    ok "deploy key e secret INFRA_DEPLOY_KEY já configurados (use --rotate p/ gerar nova)"
  else
    [[ -n "$KEY_ID" ]] && run gh api -X DELETE "repos/$INFRA_REPO/keys/$KEY_ID" >/dev/null
    KEYFILE="$TMP/${APP_REPO//\//_}"
    ssh-keygen -q -t ed25519 -N "" -C "$TITLE" -f "$KEYFILE"
    if $DRY; then
      run gh api -X POST "repos/$INFRA_REPO/keys" -f title="$TITLE" -f key="<chave pública>" -F read_only=false
    elif ! OUT="$(gh api -X POST "repos/$INFRA_REPO/keys" -f title="$TITLE" -f key="$(cat "$KEYFILE.pub")" -F read_only=false 2>&1)"; then
      fail "GitHub recusou a deploy key: $(grep -o '"message":"[^"]*"' <<<"$OUT" | tail -1 | cut -d'"' -f4)"
      rm -f "$KEYFILE" "$KEYFILE.pub"; return 1
    fi
    if $DRY; then
      echo -e "    ${CYAN}[dry-run]${NC} gh secret set INFRA_DEPLOY_KEY --repo $APP_REPO < chave-privada"
    else
      gh secret set INFRA_DEPLOY_KEY --repo "$APP_REPO" < "$KEYFILE"
    fi
    rm -f "$KEYFILE" "$KEYFILE.pub"
    ok "deploy key '$TITLE' (escrita) em $INFRA_REPO + secret INFRA_DEPLOY_KEY em $APP_REPO"
  fi

  # 3. Secret antigo ---------------------------------------------------------
  if gh secret list --repo "$APP_REPO" --json name --jq '.[].name' | grep -qx INFRA_REPO_TOKEN; then
    run gh secret delete INFRA_REPO_TOKEN --repo "$APP_REPO"
    ok "secret antigo INFRA_REPO_TOKEN removido"
  fi

  # 4. Proteção da main ------------------------------------------------------
  if $PROTECT; then
    run gh api -X PUT "repos/$APP_REPO/branches/$DEFAULT/protection" --input - >/dev/null <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["ci"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
    ok "$DEFAULT protegida: só PR com check \`ci\` verde, sem force push (admin pode furar em emergência)"
  fi

  # 5. Segurança do repo -------------------------------------------------------
  # Dependabot: alertas de CVE nas dependências + PRs automáticos de correção.
  run gh api -X PUT "repos/$APP_REPO/vulnerability-alerts" >/dev/null
  run gh api -X PUT "repos/$APP_REPO/automated-security-fixes" >/dev/null
  ok "Dependabot: alertas + PRs de correção de vulnerabilidade"
  # Secret scanning + push protection (padrão em repo público; garante ligado).
  run gh api -X PATCH "repos/$APP_REPO" --input - >/dev/null <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
  ok "secret scanning + push protection (bloqueia push com token/senha)"
  # CodeQL no modo "default setup": o GitHub detecta as linguagens e analisa
  # cada push/PR, sem workflow próprio. Resultados na aba Security.
  if [[ "$(gh api "repos/$APP_REPO/code-scanning/default-setup" --jq .state 2>/dev/null)" == "configured" ]]; then
    ok "CodeQL já configurado"
  elif OUT="$(run gh api -X PATCH "repos/$APP_REPO/code-scanning/default-setup" -f state=configured 2>&1)"; then
    ok "CodeQL (análise estática) configurado"
  else
    warn "CodeQL não configurado: $(grep -o '"message":"[^"]*"' <<<"$OUT" | cut -d'"' -f4)"
  fi

  # Workflow presente? ---------------------------------------------------------
  for b in develop "$DEFAULT"; do
    if gh api "repos/$APP_REPO/contents/.github/workflows/deploy.yml?ref=$b" >/dev/null 2>&1; then
      ok ".github/workflows/deploy.yml presente em $b"
    else
      warn ".github/workflows/deploy.yml ainda não está em $b (copie de templates/github/deploy.yml e faça push)"
    fi
  done
}

for PROJ in "${PROJECTS[@]}"; do
  echo ""
  echo -e "${CYAN}━━ Projeto: $PROJ${NC}"
  if [[ ! -f "$(project_manifest "$PROJ")" ]]; then fail "projects/$PROJ/project.yaml não existe"; FAILED=1; continue; fi
  REPOS=()
  while IFS= read -r u; do REPOS+=("$u"); done < <(project_app_repos "$PROJ")
  if [[ ${#REPOS[@]} -eq 0 ]]; then warn "sem appRepo/appRepos no project.yaml — pulei"; continue; fi
  for APP_URL in "${REPOS[@]}"; do
    setup_repo "$(slug "$APP_URL")" || FAILED=1
  done
done

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}✅ GitHub configurado.${NC} Fluxo: feature → PR develop (deploy develop) → PR main (deploy prod)."
else
  echo -e "${RED}❌ Alguns projetos falharam (veja acima).${NC}"
  exit 1
fi
