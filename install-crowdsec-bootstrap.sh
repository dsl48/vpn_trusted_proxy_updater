#!/usr/bin/env bash
set -euo pipefail

REPO="dsl48/vpn_trusted_proxy_updater"
LEGACY_BOOTSTRAP_COMMIT="9effc4730be57ac198197536e449d8519670fb08"
LEGACY_URL="https://raw.githubusercontent.com/${REPO}/${LEGACY_BOOTSTRAP_COMMIT}/install.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl не установлен" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 необходим для подготовки CrowdSec bootstrap" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/crowdsec-bootstrap.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

SOURCE="$TMP_DIR/install-source.sh"
PATCHED="$TMP_DIR/install-crowdsec.sh"

curl -fsSL --retry 3 --connect-timeout 15 \
  "$LEGACY_URL" -o "$SOURCE"

python3 - "$SOURCE" "$PATCHED" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
text = source.read_text(encoding="utf-8")

menu_marker = "printf '\\nПроверка и защита сервера\\n' >/dev/tty"
tmp_marker = 'TMP_DIR="$(mktemp -d /tmp/server-security.XXXXXX)"'
audit_marker = 'if [ "$MODE" = "audit" ]; then'
profile_marker = "printf '\\nКуда устанавливаются базовые средства защиты?\\n' >/dev/tty"

menu_start = text.find(menu_marker)
tmp_start = text.find(tmp_marker, menu_start)
if menu_start < 0 or tmp_start < 0:
    raise SystemExit("Не удалось найти старое главное меню CrowdSec bootstrap")
text = text[:menu_start] + 'MODE="install"\n\n' + text[tmp_start:]

audit_start = text.find(audit_marker)
profile_start = text.find(profile_marker, audit_start)
if audit_start < 0 or profile_start < 0:
    raise SystemExit("Не удалось отделить audit-ветку CrowdSec bootstrap")
text = text[:audit_start] + text[profile_start:]

text = text.replace(
    "printf '  1 — Панель управления (пока не реализовано)\\n' >/dev/tty",
    "printf '  1 — Панель Remnawave + Caddy\\n' >/dev/tty",
    1,
)

old_panel_choice = '''    1|panel)
      printf '\\nУстановка на панель управления пока не реализована.\\n' >/dev/tty
      exit 0
      ;;
'''
new_panel_choice = '''    1|panel|remnawave-panel)
      PROFILE="remnawave-panel"
      break
      ;;
'''
if text.count(old_panel_choice) != 1:
    raise SystemExit("Не найден старый пункт панели CrowdSec")
text = text.replace(old_panel_choice, new_panel_choice, 1)

case_marker = '''case "$PROFILE" in
  cdn-origin)
'''
panel_case = '''case "$PROFILE" in
  remnawave-panel)
    download install-crowdsec-remnawave-panel.sh
    download patch-firewall-console-remnawave.py

    run_tty "$TMP_DIR/install-crowdsec-remnawave-panel.sh"

    PANEL_PROFILE_STATE=/etc/crowdsec/remnawave-panel-profile.env
    [ -f "$PANEL_PROFILE_STATE" ] || {
      echo "ERROR: профиль панели не создал $PANEL_PROFILE_STATE" >&2
      exit 1
    }
    . "$PANEL_PROFILE_STATE"
    : "${CROWDSEC_PANEL_TRAFFIC_MODE:?Не определён режим трафика панели}"

    python3 "$TMP_DIR/patch-firewall-console-remnawave.py" \\
      "$TMP_DIR/install-firewall-console.sh"
    /bin/bash -n "$TMP_DIR/install-firewall-console.sh"

    export CROWDSEC_INSTALL_PROFILE=remnawave-panel
    export CROWDSEC_PANEL_TRAFFIC_MODE
    run_tty "$TMP_DIR/install-firewall-console.sh"
    unset CROWDSEC_INSTALL_PROFILE

    CROWDSEC_BOUNCER_NAME=remnawave-panel-firewall-bouncer \\
      run_tty "$TMP_DIR/cleanup-default-bouncer-registrations.sh"
    CROWDSEC_BOUNCER_NAME=remnawave-panel-firewall-bouncer \\
      run_tty "$TMP_DIR/verify-remediation-component.sh"
    ;;

  cdn-origin)
'''
if text.count(case_marker) != 1:
    raise SystemExit("Не найден case профилей CrowdSec")
text = text.replace(case_marker, panel_case, 1)

target.write_text(text, encoding="utf-8")
PY

chmod 0700 "$PATCHED"
/bin/sh -n "$PATCHED"

printf '\nОткрываю установку CrowdSec. После её завершения вы вернётесь в главное меню.\n'
VPN_INSTALL_REF="${VPN_INSTALL_REF:-main}" /bin/sh "$PATCHED"
