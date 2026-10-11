#!/bin/bash
# Instala o ziri: o agente invisível no Mac e o app no iPhone.
#
#   ./install.sh            tudo (Mac + iPhone) e mostra o QR de pareamento
#   ./install.sh mac        só o agente do Mac
#   ./install.sh iphone     só o app do iPhone (com conta gratuita, a cada 7 dias)
#   ./install.sh pair       mostra o QR de pareamento de novo
#   ./install.sh uninstall  remove o agente e o app do Mac
set -euo pipefail
cd "$(dirname "$0")"

LOG=/usr/bin/log   # no zsh, `log` é um comando interno do shell
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DD="${TMPDIR:-/tmp}"; DD="${DD%/}/ziri-build"
DST=/Applications/ziri.app
AGENT=fi.ziri.mac.agent
LOCAL=Config/Local.xcconfig

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }
ask()  { local a; read -r -p "$1 " a </dev/tty; printf '%s' "$a"; }
# Linha N (1…total) de uma lista, perguntando qual; resposta fora disso encerra.
choose() {
  local prompt=$1 list=$2 total n
  total=$(grep -c . <<<"$list")
  n=$(ask "$prompt [1-$total]")
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || fail "opção inválida: \"$n\"."
  sed -n "${n}p" <<<"$list"
}

# --- pré-requisitos ---------------------------------------------------------

check_requirements() {
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 27 ] || fail "o ziri precisa do macOS 27 ou mais novo (este Mac tem $(sw_vers -productVersion))."
  xcodebuild -version >/dev/null 2>&1 \
    || fail "o Xcode não está instalado ou não está selecionado." \
            "Instale pela App Store e rode: sudo xcode-select -s /Applications/Xcode.app"
}

check_whatsapp() {
  [ -d "$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared" ] \
    || fail "não achei os dados do WhatsApp para Mac." \
            "Instale o WhatsApp pela App Store, entre na sua conta e espere o histórico sincronizar."
}

# --- assinatura -------------------------------------------------------------

# Times das contas Apple logadas no Xcode: "ID<tab>nome<tab>gratuito (1/0)".
xcode_teams() {
  defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
try:
    prefs = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
seen = set()
for teams in prefs.get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in teams:
        tid = t.get("teamID")
        if tid and tid not in seen:
            seen.add(tid)
            name = t.get("teamName", tid)
            free = 1 if t.get("isFreeProvisioningTeam") else 0
            print("%s\t%s\t%d" % (tid, name, free))
'
}

configure_signing() {
  [ -f "$LOCAL" ] && return
  bold "Assinatura"
  echo "O Xcode assina o ziri com a sua conta Apple (a gratuita serve)."
  local teams team count
  teams=$(xcode_teams)
  count=$(grep -c . <<<"$teams" || true)
  if [ "$count" -eq 0 ]; then
    fail "nenhuma conta Apple no Xcode." \
         "Abra o Xcode → Ajustes → Contas, entre com seu Apple ID e rode este script de novo."
  elif [ "$count" -eq 1 ]; then
    team=$(cut -f1 <<<"$teams")
    ok "usando o time $(cut -f2 <<<"$teams") ($team)"
  else
    echo "Há mais de um time no Xcode:"
    cut -f2 <<<"$teams" | nl -w2 -s') '
    team=$(choose "Qual usar?" "$teams" | cut -f1)
  fi
  # O bundle id pertence ao primeiro time que o registra; o prefixo leva o
  # time para não colidir com o de mais ninguém.
  local prefix
  prefix="fi.ziri.$(tr '[:upper:]' '[:lower:]' <<<"$team")"
  cat > "$LOCAL" <<EOF
// Gerado pelo ./install.sh. Fora do git.
DEVELOPMENT_TEAM = $team
ZIRI_BUNDLE_PREFIX = $prefix
EOF
  ok "configuração salva em $LOCAL"
}

# Erros de build com causa conhecida viram instrução; o resto vai para o log.
explain_build_failure() {
  local logfile=$1
  if grep -q "Developer Mode" "$logfile"; then
    fail "o Modo de Desenvolvedor está desligado no iPhone." \
         "No iPhone: Ajustes → Privacidade e Segurança → Modo de Desenvolvedor. Ele reinicia; rode o script de novo."
  elif grep -qE "No Account for Team|No signing certificate|requires a development team" "$logfile"; then
    fail "o Xcode não tem como assinar com o time de $LOCAL." \
         "Confira a conta em Xcode → Ajustes → Contas, ou apague $LOCAL para escolher de novo."
  elif grep -qE "maximum number of|limit.*App IDs" "$logfile"; then
    fail "a conta gratuita atingiu o limite de apps/App IDs da semana." \
         "Apague apps instalados pelo Xcode no iPhone ou espere alguns dias."
  fi
  grep "error:" "$logfile" | sort -u | head -10 >&2
  fail "a compilação falhou. Log completo: $logfile"
}

# --- Mac --------------------------------------------------------------------

install_mac() {
  bold "Mac"
  check_whatsapp
  step "compilando o agente…"
  local logfile="$DD/mac.log"
  mkdir -p "$DD"
  xcodebuild -project ZiriApp.xcodeproj -scheme ZiriMac -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" -allowProvisioningUpdates \
    build >"$logfile" 2>&1 || explain_build_failure "$logfile"
  local built="$DD/Build/Products/Release/ziri.app"

  # Versões antigas do ziri: o daemon `ziri serve` e o app de barra de menus.
  # Dois servidores anunciando _ziri._tcp deixariam o iPhone escolher qualquer um.
  if launchctl print "gui/$UID/fi.ziri.daemon" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/fi.ziri.daemon" 2>/dev/null || true
  fi
  rm -f "$HOME/Library/LaunchAgents/fi.ziri.daemon.plist"
  if pgrep -f "$DST/Contents/MacOS/ziri" >/dev/null && ! launchctl print "gui/$UID/$AGENT" >/dev/null 2>&1; then
    pkill -f "$DST/Contents/MacOS/ziri" || true
  fi

  step "instalando em $DST…"
  rm -rf "$DST"
  ditto "$built" "$DST"
  codesign --verify --deep --strict "$DST"
  # O SMAppService acha o plist do agente pelo bundle registrado; a cópia de
  # build sumiria com a pasta temporária.
  "$LSR" -u "$built" >/dev/null 2>&1 || true
  "$LSR" -f "$DST"

  local t0
  t0=$(date '+%Y-%m-%d %H:%M:%S')
  "$DST/Contents/MacOS/ziri"
  launchctl print "gui/$UID/$AGENT" >/dev/null 2>&1 \
    || fail "o agente não foi carregado." \
            "Se os Ajustes do Sistema abriram em Itens de Início, ligue o ziri em \"Permitir em segundo plano\"" \
            "e rode este script de novo."
  # Numa reinstalação, o agente ainda rodava o executável antigo.
  launchctl kickstart -k "gui/$UID/$AGENT"

  step "conferindo o agente… (se o macOS pedir acesso aos dados de outros apps, clique em Permitir)"
  local out=""
  for _ in $(seq 1 60); do
    sleep 1
    out=$("$LOG" show --start "$t0" --style compact --predicate 'subsystem == "fi.ziri.mac"' 2>/dev/null || true)
    grep -q "WhatsApp lido\|sem acesso\|erro na ingestão\|não subiu" <<<"$out" && break
  done
  if grep -q "não subiu" <<<"$out"; then
    fail "o agente não subiu: $(grep "não subiu" <<<"$out" | tail -1 | sed 's/.*não subiu: //')"
  elif grep -q "sem acesso" <<<"$out"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    fail "o macOS negou ao ziri a leitura dos dados do WhatsApp." \
         "Ligue o ziri em Ajustes do Sistema → Privacidade e Segurança → Acesso Total ao Disco" \
         "e rode: ./install.sh mac"
  elif ! grep -q "escutando" <<<"$out"; then
    fail "o agente não começou a escutar na rede local." \
         "Veja: $LOG show --last 5m --predicate 'subsystem == \"fi.ziri.mac\"'"
  elif ! grep -q "WhatsApp lido" <<<"$out"; then
    grep "erro na ingestão" <<<"$out" | tail -1 >&2 || true
    fail "o agente ainda não conseguiu ler o WhatsApp."
  fi
  ok "agente rodando, $(grep "WhatsApp lido" <<<"$out" | tail -1 | sed 's/.*WhatsApp lido: //')"
}

# --- iPhone -----------------------------------------------------------------

# iPhones pareados com este Mac: "identificador<tab>udid<tab>nome<tab>modo dev".
iphones() {
  local json="$DD/devices.json"
  mkdir -p "$DD"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || return 0
  /usr/bin/python3 - "$json" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    h, c, p = d["hardwareProperties"], d["connectionProperties"], d["deviceProperties"]
    if h.get("platform") == "iOS" and h.get("reality") == "physical" and c.get("pairingState") == "paired":
        print("\t".join([d["identifier"], h.get("udid", ""), p.get("name", "iPhone"), p.get("developerModeStatus", "")]))
EOF
}

install_iphone() {
  bold "iPhone"
  local list count device
  list=$(iphones)
  count=$(grep -c . <<<"$list" || true)
  if [ "$count" -eq 0 ]; then
    fail "nenhum iPhone pareado com este Mac." \
         "Conecte o iPhone por cabo, desbloqueie, toque em Confiar e rode: ./install.sh iphone"
  elif [ "$count" -eq 1 ]; then
    device=$list
  else
    echo "Há mais de um iPhone pareado:"
    cut -f3 <<<"$list" | nl -w2 -s') '
    device=$(choose "Em qual instalar?" "$list")
  fi
  local id udid name devmode
  IFS=$'\t' read -r id udid name devmode <<<"$device"
  [ "$devmode" = "enabled" ] \
    || fail "o Modo de Desenvolvedor está desligado em \"$name\"." \
            "No iPhone: Ajustes → Privacidade e Segurança → Modo de Desenvolvedor. Ele reinicia; rode: ./install.sh iphone"

  step "compilando para \"$name\"… (o iPhone precisa estar desbloqueado)"
  local logfile="$DD/iphone.log"
  xcodebuild -project ZiriApp.xcodeproj -scheme ZiriApp -configuration Release \
    -destination "platform=iOS,id=$udid" -derivedDataPath "$DD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    build >"$logfile" 2>&1 || explain_build_failure "$logfile"
  local app="$DD/Build/Products/Release-iphoneos/ZiriApp.app"
  local bundle
  bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")

  step "instalando…"
  xcrun devicectl device install app --device "$id" "$app" >"$DD/install.log" 2>&1 \
    || { tail -5 "$DD/install.log" >&2; fail "não consegui instalar no iPhone."; }

  # Com conta gratuita, o iOS só abre o app depois que a pessoa confia no
  # desenvolvedor — uma vez por conta.
  if ! xcrun devicectl device process launch --device "$id" "$bundle" >"$DD/launch.log" 2>&1; then
    echo
    echo "  O iPhone ainda não confia nos apps da sua conta. No iPhone:"
    echo "  Ajustes → Geral → VPN e Gerenciamento de Dispositivos → seu Apple ID → Confiar."
    echo "  Depois abra o ziri uma vez para ele pedir acesso à rede local."
    echo
  else
    ok "ziri aberto no iPhone — permita o acesso à rede local quando ele pedir"
  fi
  local team
  team=$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$LOCAL")
  if xcode_teams | grep -q "^$team"$'\t'".*"$'\t'"1\$"; then
    echo "  Conta gratuita: o app para de abrir em 7 dias. Para renovar, rode ./install.sh iphone"
  fi
}

# --- pareamento e remoção ---------------------------------------------------

show_pairing() {
  [ -x "$DST/Contents/MacOS/ziri" ] || fail "o ziri não está instalado neste Mac. Rode: ./install.sh mac"
  bold "Pareamento"
  echo "Aponte a Câmera do iPhone para o QR code e toque em \"Abrir no ziri\"."
  echo
  "$DST/Contents/MacOS/ziri" --pair
}

uninstall() {
  bold "Removendo o ziri deste Mac"
  [ -x "$DST/Contents/MacOS/ziri" ] && "$DST/Contents/MacOS/ziri" --uninstall
  launchctl bootout "gui/$UID/$AGENT" 2>/dev/null || true
  rm -rf "$DST"
  ok "agente e app removidos"
  if [ -d "$HOME/.ziri" ]; then
    local a
    a=$(ask "Apagar também as mensagens copiadas e a chave de pareamento (~/.ziri)? [s/N]")
    if [[ "$a" =~ ^[sS] ]]; then rm -rf "$HOME/.ziri"; ok "~/.ziri apagado"; fi
  fi
  echo "No iPhone, apague o app ziri: o índice da Siri vai junto."
}

# ----------------------------------------------------------------------------

check_requirements
case "${1:-all}" in
  all)       configure_signing; install_mac; echo; install_iphone; echo; show_pairing ;;
  mac)       configure_signing; install_mac ;;
  iphone)    configure_signing; install_iphone ;;
  pair)      show_pairing ;;
  uninstall) uninstall ;;
  *)         sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
