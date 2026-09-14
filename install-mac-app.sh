#!/bin/bash
# Instala o ziri para Mac em /Applications do jeito que a Siri aceita.
#
# A ordem importa. Abrir o app no mesmo instante em que o LaunchServices o
# registra faz a auditoria do linkd falhar ("Could not create application
# record … -10814"), e o linkd não repete a auditoria sozinho: sem ela não há
# metadata do App Intents, e cada doação ao índice espera 5s e volta vazia —
# a indexação parece travada. Por isso: registrar, esperar a auditoria, e só
# então abrir.
set -euo pipefail
cd "$(dirname "$0")"

LOG=/usr/bin/log   # no zsh, `log` é um comando interno do shell
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DD=/tmp/ziri-dd-mac-release
BUILT="$DD/Build/Products/Release/ziri.app"
DST=/Applications/ziri.app

xcodegen generate --quiet
echo "→ compilando (Release)…"
xcodebuild -project ZiriApp.xcodeproj -scheme ZiriMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" -allowProvisioningUpdates \
  build > /tmp/ziri-mac-release.log 2>&1 \
  || { grep "error:" /tmp/ziri-mac-release.log | sort -u; exit 1; }

if pgrep -f "$DST/Contents/MacOS/ziri" >/dev/null; then
  echo "→ encerrando a versão em execução…"
  osascript -e 'tell application id "fi.ziri.mac" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do sleep 1; pgrep -f "$DST/Contents/MacOS/ziri" >/dev/null || break; done
fi

echo "→ instalando em $DST…"
rm -rf "$DST"
ditto "$BUILT" "$DST"
codesign --verify --deep --strict "$DST"

# Dois registros do mesmo bundle id deixam o linkd livre para escolher a cópia
# de build, que some quando o DerivedData é limpo.
"$LSR" -u "$BUILT" >/dev/null 2>&1 || true

T0=$(date '+%Y-%m-%d %H:%M:%S')
"$LSR" -f "$DST"
echo "→ esperando a auditoria do linkd…"
AUDIT=""
for _ in $(seq 1 20); do
  sleep 2
  AUDIT=$("$LOG" show --start "$T0" --style compact \
    --predicate 'process == "linkd" AND eventMessage CONTAINS "fi.ziri.mac" AND (eventMessage CONTAINS "Audit" OR eventMessage CONTAINS "application record")' \
    2>/dev/null | grep -v "^Timestamp" || true)
  grep -q "Finished task: Audit" <<<"$AUDIT" && break
done
if grep -q -- "-10814" <<<"$AUDIT"; then
  echo "✗ o linkd não conseguiu registrar o app (-10814). Rode este script de novo." >&2
  exit 1
fi
# Reinstalar um app que o linkd já conhece, com a mesma metadata, costuma não
# gerar auditoria nova. A prova de saúde de verdade vem depois de abrir.
grep -q "Finished task: Audit" <<<"$AUDIT" \
  && echo "✓ auditoria concluída" \
  || echo "· sem auditoria nova (o linkd já conhecia esta versão)"

T1=$(date '+%Y-%m-%d %H:%M:%S')
open "$DST"

# O sintoma da metadata ausente aparece nos primeiros segundos da primeira
# rodada: o linkd esgota a espera de 5s por pedido.
echo "→ conferindo o linkd depois de abrir…"
sleep 12
TIMEOUTS=$("$LOG" show --start "$T1" --style compact \
  --predicate 'process == "linkd" AND eventMessage CONTAINS "Timeout waiting for metadata for fi.ziri.mac"' \
  2>/dev/null | grep -vc "^Timestamp" || true)
if [ "${TIMEOUTS:-0}" -gt 0 ]; then
  echo "✗ o linkd está sem a metadata do ziri ($TIMEOUTS esperas esgotadas): a indexação não vai andar." >&2
  echo "  Encerre o ziri e rode este script de novo." >&2
  exit 1
fi

echo "✓ ziri aberto na barra de menus. Acompanhe com:"
echo "  /usr/bin/log stream --predicate 'subsystem == \"fi.ziri.mac\"'"
