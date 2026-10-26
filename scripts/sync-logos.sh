#!/usr/bin/env bash
# =============================================================================
# sync-logos.sh — baixa o logo de cada projeto declarado em
# projects/<p>/project.yaml → `logo: <url>` para projects/<p>/logo.png, o
# arquivo que o Grafana exibe (via GitHub). make logos [PROJECT=<p>]
#
# Trocar o logo = mudar a URL no project.yaml, `make logos` e commitar o PNG.
# Não edite o logo pela interface do Grafana: a mudança fica só no banco dele
# e não vale para os outros projetos nem para um cluster novo.
# Ex.: avatar da org no GitHub → https://avatars.githubusercontent.com/u/<id>?v=4
#      (gh api orgs/<org> -q .avatar_url)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

for P in ${1:-$(project_names)}; do
  URL="$(_pq "$P" '.logo // ""')"
  [[ -z "$URL" ]] && { echo "↷ $P: sem logo: no project.yaml (mantém o logo.png atual)"; continue; }
  OUT="$(project_dir "$P")/logo.png"
  TMP="$(mktemp)"
  # GitHub avatars aceitam ?s=<tamanho>; 256 px basta para o painel.
  case "$URL" in *avatars.githubusercontent.com*) URL="${URL%%\?*}?s=256&v=4" ;; esac
  curl -fsSL "$URL" -o "$TMP"
  # Sempre PNG 256x256 (o GitHub serve SVG como texto e o navegador não exibe).
  sips -s format png -z 256 256 "$TMP" --out "$OUT" >/dev/null
  rm -f "$TMP"
  echo "✅ $P: ${OUT#"$(dirname "$SCRIPT_DIR")"/} ← $URL"
done
echo "Commite os PNG: o Grafana lê o logo do GitHub (aparece em até ~5 min, cache do GitHub)."
