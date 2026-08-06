#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="dsl48/vpn_trusted_proxy_updater"
REF="${VPN_INSTALL_REF:-main}"
ROOT_BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"
BASE_URL="$ROOT_BASE_URL/crowdsec-remnawave-panel"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl не установлен" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 необходим для подготовки профиля Remnawave Panel" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/remnawave-panel-crowdsec.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

PAYLOAD="$TMP_DIR/install-remnawave-panel.sh"
PATCHER="$TMP_DIR/patch-remnawave-panel-caddy-runtime.py"
ERREXIT_PATCHER="$TMP_DIR/patch-remnawave-panel-caddy-errexit.py"
APPLY_PATCHER="$TMP_DIR/patch-remnawave-panel-caddy-apply.py"
BACKUP_PATCHER="$TMP_DIR/patch-remnawave-panel-caddy-backup.py"
CROWDSEC_START_PATCHER="$TMP_DIR/patch-remnawave-panel-crowdsec-start.py"
: >"$PAYLOAD"
for part in 00 01 02 03 04 05; do
  printf '[bootstrap] Загружаю профиль панели: part-%s\n' "$part"
  curl -fsSL --retry 3 --connect-timeout 15 \
    "$BASE_URL/part-$part.sh.inc" >>"$PAYLOAD"
done

printf '[bootstrap] Загружаю модуль определения Caddy runtime\n'
curl -fsSL --retry 3 --connect-timeout 15 \
  "$ROOT_BASE_URL/patch-remnawave-panel-caddy-runtime.py" \
  -o "$PATCHER"
printf '[bootstrap] Загружаю исправление обработки Docker Caddy\n'
curl -fsSL --retry 3 --connect-timeout 15 \
  "$ROOT_BASE_URL/patch-remnawave-panel-caddy-errexit.py" \
  -o "$ERREXIT_PATCHER"
printf '[bootstrap] Загружаю безопасное применение конфигурации Caddy\n'
curl -fsSL --retry 3 --connect-timeout 15 \
  "$ROOT_BASE_URL/patch-remnawave-panel-caddy-apply.py" \
  -o "$APPLY_PATCHER"
printf '[bootstrap] Загружаю обязательный backup Caddyfile\n'
curl -fsSL --retry 3 --connect-timeout 15 \
  "$ROOT_BASE_URL/patch-remnawave-panel-caddy-backup.py" \
  -o "$BACKUP_PATCHER"
printf '[bootstrap] Загружаю безопасный запуск CrowdSec Local API\n'
curl -fsSL --retry 3 --connect-timeout 15 \
  "$ROOT_BASE_URL/patch-remnawave-panel-crowdsec-start.py" \
  -o "$CROWDSEC_START_PATCHER"
chmod 0700 \
  "$PAYLOAD" \
  "$PATCHER" \
  "$ERREXIT_PATCHER" \
  "$APPLY_PATCHER" \
  "$BACKUP_PATCHER" \
  "$CROWDSEC_START_PATCHER"
python3 "$PATCHER" "$PAYLOAD"
python3 "$ERREXIT_PATCHER" "$PAYLOAD"
python3 "$APPLY_PATCHER" "$PAYLOAD"
python3 "$BACKUP_PATCHER" "$PAYLOAD"
python3 "$CROWDSEC_START_PATCHER" "$PAYLOAD"
/bin/bash -n "$PAYLOAD"

printf '[bootstrap] Профиль Remnawave Panel собран и проверен\n'
exec /bin/bash "$PAYLOAD" "$@"
