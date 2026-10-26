#!/usr/bin/env bash
# =============================================================================
# rollback.sh  (genérico)
# -----------------------------------------------------------------------------
# Volta a versão de um projeto num ambiente PELO GIT (o jeito GitOps): troca o
# image.tag no values-<env>.yaml pela versão anterior, commita e dá push. O
# ArgoCD aplica; em prod, voltar para uma das últimas versões não passa pelo
# canary (rollbackWindow do Argo Rollouts), então é imediato.
#
# Sem --to, a versão anterior de CADA app é a última tag diferente da atual no
# histórico do arquivo (git log). Com --to, todos os apps vão para essa tag.
#
# Uso:
#   ./scripts/rollback.sh <projeto> <env> [--app <app>] [--to <tag>] [--yes]
#   make rollback PROJECT=crivo ENV=prod [APP=crivo-fe] [TO=1.3.0]
#
# Por que não o botão "Rollback" do ArgoCD? Com auto-sync ligado ele fica
# bloqueado: o Git é a fonte da verdade, e o ArgoCD desfaria o rollback no
# próximo sync. Ver docs/16-releases.md.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

PROJ="${1:-}"; ENV_NAME="${2:-}"
shift 2 2>/dev/null || true
ONLY_APP=""; TO=""; YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) ONLY_APP="$2"; shift 2 ;;
    --to)  TO="$2"; shift 2 ;;
    --yes) YES=true; shift ;;
    *) echo "Argumento desconhecido: $1"; exit 1 ;;
  esac
done
if [[ -z "$PROJ" || -z "$ENV_NAME" ]]; then
  echo "Uso: $0 <projeto> <env> [--app <app>] [--to <tag>] [--yes]"; exit 1
fi

cd "$INFRA_ROOT"
git fetch -q origin
git pull -q --rebase --autostash origin "$(git branch --show-current)"

# Commit do histórico do arquivo com a versão de destino: a primeira tag
# diferente da atual (sem --to) ou a tag pedida (--to). Imprime "<commit> <tag>".
find_target() {
  local file="$1" current="$2" wanted="$3" c tag
  while read -r c; do
    tag="$(git show "$c:$file" 2>/dev/null | yq '.image.tag' 2>/dev/null || true)"
    [[ -z "$tag" || "$tag" == "null" ]] && continue
    if [[ -n "$wanted" && "$tag" == "$wanted" ]] || [[ -z "$wanted" && "$tag" != "$current" ]]; then
      echo "$c $tag"; return
    fi
  done < <(git log --format=%H -- "$file")
}

declare -a FILES=() SUMMARY=()
for APP in $(project_apps "$PROJ"); do
  [[ -n "$ONLY_APP" && "$APP" != "$ONLY_APP" ]] && continue
  FILE="projects/$PROJ/apps/$APP/values-$ENV_NAME.yaml"
  [[ -f "$FILE" ]] || continue
  CURRENT="$(yq '.image.tag' "$FILE")"
  read -r FROM_COMMIT TARGET <<<"$(find_target "$FILE" "$CURRENT" "$TO")" || true
  TARGET="${TARGET:-$TO}"
  if [[ -z "$TARGET" ]]; then echo "↷ $APP: sem versão anterior no histórico"; continue; fi
  if [[ "$TARGET" == "$CURRENT" ]]; then echo "↷ $APP: já está em $CURRENT"; continue; fi
  printf "  %-18s %s  →  %s\n" "$APP" "$CURRENT" "$TARGET"
  FILES+=("$FILE"); SUMMARY+=("$APP@$TARGET")
  yq -i ".image.tag = \"$TARGET\"" "$FILE"
  # O link da release (changelog no ArgoCD) volta junto com a versão.
  if [[ -n "${FROM_COMMIT:-}" ]] && git show "$FROM_COMMIT:$FILE" | yq -e '.release' >/dev/null 2>&1; then
    REL="$(git show "$FROM_COMMIT:$FILE" | yq -o=json -I=0 '.release')"
    yq -i ".release = $REL" "$FILE"
  else
    yq -i 'del(.release)' "$FILE"
  fi
done

if [[ ${#FILES[@]} -eq 0 ]]; then echo "Nada para voltar."; exit 0; fi

if ! $YES; then
  read -r -p "Commitar e dar push deste rollback em $PROJ/$ENV_NAME? [s/N] " ans
  if [[ ! "$ans" =~ ^[sSyY]$ ]]; then
    git checkout -- "${FILES[@]}"; echo "Cancelado (arquivos restaurados)."; exit 1
  fi
fi

git commit -q -m "rollback($PROJ/$ENV_NAME): ${SUMMARY[*]}" -- "${FILES[@]}"
git push -q origin HEAD
echo "✅ rollback commitado: ${SUMMARY[*]}"

# Força o ArgoCD a ler o Git agora (senão, em até 3 min).
for APP_NAME in $(kubectl get applications -n argocd -o name 2>/dev/null | sed 's#.*/##' | grep -- "-$ENV_NAME\$" || true); do
  NS="$(kubectl get application "$APP_NAME" -n argocd -o jsonpath='{.spec.destination.namespace}')"
  [[ "$NS" == "$PROJ-$ENV_NAME" ]] && kubectl -n argocd annotate application "$APP_NAME" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
done
echo "   O ArgoCD já foi avisado (refresh). Acompanhe: make apps / make rollouts"
