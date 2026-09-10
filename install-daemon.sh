#!/bin/bash
# Instala o ziri como LaunchAgent: ingere a cada 5 min e serve na rede local.
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release

BIN="$PWD/.build/release/ziri"
PLIST="$HOME/Library/LaunchAgents/fi.ziri.daemon.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.ziri"
sed -e "s|__ZIRI_BIN__|$BIN|" -e "s|__HOME__|$HOME|g" launchd/fi.ziri.daemon.plist > "$PLIST"

launchctl bootout "gui/$UID/fi.ziri.daemon" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "✓ daemon instalado"
echo
"$BIN" status
echo
echo "Digite o código de pareamento acima no app do iPhone."
echo "Log: ~/.ziri/ziri.log    Remover: launchctl bootout gui/$UID/fi.ziri.daemon"
