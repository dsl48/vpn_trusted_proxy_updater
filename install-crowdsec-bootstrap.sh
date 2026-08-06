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

target.write_text(text, encoding="utf-8")
PY

chmod 0700 "$PATCHED"
/bin/sh -n "$PATCHED"

printf '\nОткрываю установку CrowdSec. После её завершения вы вернётесь в главное меню.\n'
VPN_INSTALL_REF="${VPN_INSTALL_REF:-main}" /bin/sh "$PATCHED"
