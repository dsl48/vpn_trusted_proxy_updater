#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO="dsl48/vpn_trusted_proxy_updater"
SOURCE_COMMIT="e28517138c59cc4d7f0570747215233b31be8ecd"
PATCH_REF="${VPN_INSTALL_REF:-main}"
PATCH_FALLBACK_COMMIT="9c4fdb2a76a6638bf231a7e5e5121ce694fbf132"
RAW_BASE="https://raw.githubusercontent.com/${REPO}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}
[[ -r /dev/tty ]] || {
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl не установлен" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 необходим для подготовки базового мастера" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/baseline-security-bootstrap.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

SOURCE="$TMP_DIR/install-baseline-security-source.sh"
PATCHER="$TMP_DIR/patch-baseline-security.py"

printf '%s\n' "[bootstrap] Загружаю проверенную основу базового мастера"
curl -fsSL --retry 3 --connect-timeout 15 \
  "$RAW_BASE/$SOURCE_COMMIT/install-baseline-security.sh" \
  -o "$SOURCE"

printf '%s\n' "[bootstrap] Загружаю актуальные исправления базового мастера"
if ! curl -fsSL --retry 3 --connect-timeout 15 \
  "$RAW_BASE/$PATCH_REF/patch-baseline-security.py" \
  -o "$PATCHER"; then
  printf '%s\n' "[bootstrap] Не удалось получить patch из $PATCH_REF; использую закреплённую исправленную версию"
  curl -fsSL --retry 3 --connect-timeout 15 \
    "$RAW_BASE/$PATCH_FALLBACK_COMMIT/patch-baseline-security.py" \
    -o "$PATCHER"
fi

chmod 0700 "$SOURCE" "$PATCHER"
python3 "$PATCHER" "$SOURCE"
/bin/bash -n "$SOURCE"

printf '%s\n' "[bootstrap] Исправленная версия подготовлена; запускаю мастер"
exec /bin/bash "$SOURCE" "$@"
