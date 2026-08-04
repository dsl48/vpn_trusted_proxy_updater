#!/bin/sh
set -eu

REPO="dsl48/vpn_trusted_proxy_updater"
REF="${VPN_INSTALL_REF:-main}"
URL="https://raw.githubusercontent.com/${REPO}/${REF}/install-crowdsec-cdn-origin.sh"
TMP="$(mktemp /tmp/crowdsec-cdn-origin.XXXXXX)"

cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT HUP INT TERM

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl не установлен" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: запускайте через sudo sh" >&2
  exit 1
fi

printf '%s\n' "[bootstrap] Загружаю установщик из ${REPO}@${REF}"
curl -fsSL --retry 3 --connect-timeout 15 "$URL" -o "$TMP"
chmod 0700 "$TMP"

if [ ! -r /dev/tty ]; then
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
fi

exec /bin/bash "$TMP" </dev/tty >/dev/tty 2>&1
