#!/usr/bin/env bash
# =============================================================================
# autostart.sh  (macOS) — liga o cluster sozinho quando você faz login
# -----------------------------------------------------------------------------
# Instala um LaunchAgent do usuário (sem sudo) que roda
# `scripts/start-cluster.sh --login` no login: espera o Docker Desktop subir e
# liga o cluster na ordem certa. Log em ~/Library/Logs/devops-platform-start.log.
#
# Uso:
#   ./scripts/autostart.sh install   # make autostart
#   ./scripts/autostart.sh remove    # make autostart-off
#   ./scripts/autostart.sh status
# =============================================================================

set -euo pipefail

ACTION="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="local.devops-platform.start"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/devops-platform-start.log"

[[ "$(uname)" == "Darwin" ]] || { echo "autostart só existe para macOS (launchd)"; exit 1; }

case "$ACTION" in
  install)
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    # PATH do launchd é mínimo: k3d/kubectl/docker vêm do Homebrew e do Docker Desktop.
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/start-cluster.sh</string>
    <string>--login</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "✅ autostart instalado: o cluster sobe sozinho no próximo login (log: $LOG)"
    ;;
  remove)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✅ autostart removido (ligar na mão: make start)"
    ;;
  status)
    if [[ -f "$PLIST" ]]; then
      echo "autostart: instalado ($PLIST)"
      [[ -f "$LOG" ]] && { echo "--- últimas linhas de $LOG"; tail -5 "$LOG"; }
    else
      echo "autostart: não instalado (make autostart)"
    fi
    ;;
  *) echo "uso: $0 install|remove|status"; exit 1 ;;
esac
