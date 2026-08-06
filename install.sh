#!/bin/sh
set -eu

REPO="dsl48/vpn_trusted_proxy_updater"
REF="${VPN_INSTALL_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl не установлен" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: запускайте через sudo sh" >&2
  exit 1
fi

if [ ! -r /dev/tty ]; then
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
fi

if [ -z "${SSH_CONNECTION:-}" ] && [ -n "${SSH_CLIENT:-}" ]; then
  SSH_CONNECTION="$SSH_CLIENT"
fi
export SSH_CONNECTION="${SSH_CONNECTION:-}"

TMP_DIR="$(mktemp -d /tmp/server-security.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

download() {
  name="$1"
  rm -f "$TMP_DIR/$name"
  printf '%s\n' "[bootstrap] Загружаю $name из ${REPO}@${REF}"
  curl -fsSL --retry 3 --connect-timeout 15 \
    "$BASE_URL/$name" -o "$TMP_DIR/$name"
  chmod 0700 "$TMP_DIR/$name"
}

run_tty() {
  /bin/bash "$@" </dev/tty >/dev/tty 2>&1
}

pause_menu() {
  printf '\nНажмите Enter, чтобы вернуться в главное меню...' >/dev/tty
  IFS= read -r _ </dev/tty || true
}

show_menu() {
  cat >/dev/tty <<'MENU'

════════════════════════════════════════════════════════════
              ПРОВЕРКА И ЗАЩИТА СЕРВЕРА
════════════════════════════════════════════════════════════

  1 — Проверка базовой безопасности
      Read-only аудит ОС, SSH, сети, firewall, Docker и средств защиты.

  2 — Установка базовых настроек безопасности
      Усиление ОС, SSH, sysctl, firewall и автоматических обновлений.

  3 — Установка TrafficGuard
      Отсекает известные сети сканеров на уровне iptables/ipset,
      до передачи соединения SSH, Caddy, Xray и другим сервисам.

  4 — Установка CrowdSec
      Анализирует журналы, выявляет атаки и динамически блокирует
      источники через firewall bouncer.

  0 — Выход
MENU
}

run_audit() {
  download check-basic-security.sh
  download check-basic-security-extended.sh
  run_tty "$TMP_DIR/check-basic-security-extended.sh" \
    "$TMP_DIR/check-basic-security.sh"
}

run_baseline_install() {
  cat >/dev/tty <<'MESSAGE'

Установка базовых настроек безопасности пока не включена.
Этот пункт будет настраивать SSH, sysctl, firewall и автоматические
обновления только после утверждения безопасного профиля для VPN-нод.
Никаких изменений в систему не внесено.
MESSAGE
}

run_traffic_guard_install() {
  download install-traffic-guard.sh
  run_tty "$TMP_DIR/install-traffic-guard.sh"
}

run_crowdsec_install() {
  download install-crowdsec-bootstrap.sh
  run_tty "$TMP_DIR/install-crowdsec-bootstrap.sh"
}

while :; do
  show_menu
  printf '\nВыберите действие [1]: ' >/dev/tty
  IFS= read -r MAIN_ACTION </dev/tty
  MAIN_ACTION="${MAIN_ACTION:-1}"

  case "$MAIN_ACTION" in
    1|check|audit)
      if ! run_audit; then
        printf '\nПроверка завершилась с технической ошибкой.\n' >/dev/tty
      fi
      pause_menu
      ;;
    2|baseline|basic)
      run_baseline_install
      pause_menu
      ;;
    3|traffic-guard|trafficguard)
      if ! run_traffic_guard_install; then
        printf '\nУстановка TrafficGuard завершилась с ошибкой.\n' >/dev/tty
      fi
      pause_menu
      ;;
    4|crowdsec)
      if ! run_crowdsec_install; then
        printf '\nУстановка CrowdSec завершилась с ошибкой.\n' >/dev/tty
      fi
      pause_menu
      ;;
    0|exit|quit)
      printf 'Выход.\n' >/dev/tty
      exit 0
      ;;
    *)
      printf 'Введите 0, 1, 2, 3 или 4.\n' >/dev/tty
      pause_menu
      ;;
  esac
done
