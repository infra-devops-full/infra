#!/usr/bin/env bash
# =============================================================================
# hosts.sh  (genérico) — gerencia as entradas da plataforma no /etc/hosts
# -----------------------------------------------------------------------------
# Todas as entradas ficam ISOLADAS num bloco delimitado por marcadores; nada
# fora do bloco é tocado:
#
#   # >>> devops-platform >>>
#   127.0.0.1 argocd.devops.local
#   ...
#   # <<< devops-platform <<<
#
# Hosts dos apps: ingress.host dos values, ou <env>.<app>.<projeto>.local
# (em prod, sem prefixo: <app>.<projeto>.local).
#
# Uso:
#   ./scripts/hosts.sh show     # mostra o bloco que seria gravado
#   ./scripts/hosts.sh apply    # (re)grava o bloco (sudo)
#   ./scripts/hosts.sh remove   # remove o bloco (sudo)
#
# HOSTS_FILE pode ser sobrescrito para testes (default /etc/hosts).
# =============================================================================

set -euo pipefail

ACTION="${1:-show}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
BEGIN="# >>> devops-platform >>>"
END="# <<< devops-platform <<<"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-project.sh
source "$SCRIPT_DIR/lib-project.sh"

# sudo só quando o arquivo não é gravável pelo usuário (ex.: /etc/hosts).
SUDO=""
[[ -w "$HOSTS_FILE" ]] || SUDO="sudo"

render_block() {
  echo "$BEGIN"
  echo "# Ferramentas"
  for h in argocd grafana prometheus alertmanager; do
    echo "127.0.0.1 ${h}.devops.local"
  done
  for PROJ in $(project_names); do
    echo "# Projeto: $PROJ"
    {
      for ENV_NAME in $(project_envs "$PROJ"); do project_hosts "$PROJ" "$ENV_NAME"; done
      project_extra_hosts "$PROJ"
    } | awk 'NF && !seen[$0]++ { print "127.0.0.1 " $0 }'
  done
  echo "$END"
}

remove_block() {
  # Remove o bloco atual e também resquícios de versões antigas do setup
  # (que gravavam sem marcadores). *.devops.local é domínio da plataforma.
  $SUDO sed -i '' \
    -e "/^${BEGIN}\$/,/^${END}\$/d" \
    -e '/# DevOps Lab/d' \
    -e '/# DevOps Platform/d' \
    -e '/[[:space:]][a-z0-9.-]*\.devops\.local$/d' \
    "$HOSTS_FILE"
}

flush_dns() {
  # macOS trata .local como mDNS/Bonjour; limpar o cache evita resolução velha.
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

case "$ACTION" in
  show)
    render_block
    ;;
  apply)
    BLOCK="$(render_block)"
    remove_block
    echo "$BLOCK" | $SUDO tee -a "$HOSTS_FILE" >/dev/null
    [[ "$HOSTS_FILE" == /etc/hosts ]] && flush_dns
    echo "✅ $HOSTS_FILE atualizado ($(grep -c '^127' <<<"$BLOCK") hosts)"
    ;;
  remove)
    remove_block
    [[ "$HOSTS_FILE" == /etc/hosts ]] && flush_dns
    echo "✅ bloco devops-platform removido de $HOSTS_FILE"
    ;;
  *)
    echo "Uso: $0 <show|apply|remove>"
    exit 1
    ;;
esac
