#!/bin/sh
set -eu

REPO="dsl48/vpn_trusted_proxy_updater"
REF="${VPN_INSTALL_REF:-main}"
MAIN_URL="https://raw.githubusercontent.com/${REPO}/${REF}/install-crowdsec-cdn-origin.sh"
INTERVAL_URL="https://raw.githubusercontent.com/${REPO}/${REF}/configure-update-interval.sh"
POST_URL="https://raw.githubusercontent.com/${REPO}/${REF}/install-firewall-console.sh"
CLEANUP_URL="https://raw.githubusercontent.com/${REPO}/${REF}/cleanup-default-bouncer-registrations.sh"
VERIFY_URL="https://raw.githubusercontent.com/${REPO}/${REF}/verify-remediation-component.sh"
TMP_MAIN="$(mktemp /tmp/crowdsec-cdn-origin.XXXXXX)"
TMP_INTERVAL="$(mktemp /tmp/crowdsec-update-interval.XXXXXX)"
TMP_POST="$(mktemp /tmp/crowdsec-firewall-console.XXXXXX)"
TMP_CLEANUP="$(mktemp /tmp/crowdsec-bouncer-cleanup.XXXXXX)"
TMP_VERIFY="$(mktemp /tmp/crowdsec-remediation-check.XXXXXX)"

cleanup() {
  rm -f "$TMP_MAIN" "$TMP_INTERVAL" "$TMP_POST" "$TMP_CLEANUP" "$TMP_VERIFY"
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

if [ -z "${SSH_CONNECTION:-}" ] && [ -n "${SSH_CLIENT:-}" ]; then
  SSH_CONNECTION="$SSH_CLIENT"
fi
export SSH_CONNECTION="${SSH_CONNECTION:-}"

printf '%s\n' "[bootstrap] Загружаю основной установщик из ${REPO}@${REF}"
curl -fsSL --retry 3 --connect-timeout 15 "$MAIN_URL" -o "$TMP_MAIN"

printf '%s\n' "[bootstrap] Загружаю настройку частоты обновления CDN-списков"
curl -fsSL --retry 3 --connect-timeout 15 "$INTERVAL_URL" -o "$TMP_INTERVAL"

printf '%s\n' "[bootstrap] Загружаю этап firewall bouncer и CrowdSec Console"
curl -fsSL --retry 3 --connect-timeout 15 "$POST_URL" -o "$TMP_POST"

printf '%s\n' "[bootstrap] Загружаю очистку пакетных дублей bouncer"
curl -fsSL --retry 3 --connect-timeout 15 "$CLEANUP_URL" -o "$TMP_CLEANUP"

printf '%s\n' "[bootstrap] Загружаю проверку remediation component"
curl -fsSL --retry 3 --connect-timeout 15 "$VERIFY_URL" -o "$TMP_VERIFY"

chmod 0700 "$TMP_MAIN" "$TMP_INTERVAL" "$TMP_POST" "$TMP_CLEANUP" "$TMP_VERIFY"

# Выбор CDN отображается как [Y/n], пустой Enter означает yes.
sed -i \
  -e 's/\$prompt \[да\/нет\]: /\$prompt [Y\/n]: /' \
  -e '/read -r -p "\$prompt \[Y\/n\]: " answer/a\
    [ -n "$answer" ] || answer=yes' \
  -e 's/да|д|yes|y)/yes|y)/' \
  -e 's/нет|н|no|n)/no|n)/' \
  -e 's/Введите «да» или «нет»\./Введите yes или no./' \
  -e 's/Firewall bouncer намеренно не устанавливался автоматически\./Firewall bouncer устанавливается следующим этапом./' \
  "$TMP_MAIN"

if [ ! -r /dev/tty ]; then
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
fi

/bin/bash "$TMP_MAIN" </dev/tty >/dev/tty 2>&1
/bin/bash "$TMP_INTERVAL" </dev/tty >/dev/tty 2>&1
/bin/bash "$TMP_POST" </dev/tty >/dev/tty 2>&1
/bin/bash "$TMP_CLEANUP" </dev/tty >/dev/tty 2>&1
/bin/bash "$TMP_VERIFY" </dev/tty >/dev/tty 2>&1
