#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR="/var/lib/server-security"
TX_ROOT="$STATE_DIR/transactions"
PROFILE_STATE="/etc/crowdsec/remnawave-panel-profile.env"
LOG_DIR="/var/log/caddy"
DEFAULT_LOG_PATH="$LOG_DIR/remnawave-panel-access.log"
ACQUIS_FILE="/etc/crowdsec/acquis.d/remnawave-panel-caddy.yaml"
ALLOWLIST_NAME="remnawave-panel-trusted"
LAPI_PORT="${CROWDSEC_LAPI_PORT:-18888}"
SSH_CONNECTION="${SSH_CONNECTION:-${SSH_CLIENT:-}}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}
[[ -r /dev/tty ]] || {
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
}

log() { printf '[remnawave-panel] %s\n' "$*"; }
status() { printf '[%-10s] %s\n' "$1" "$2"; }
die() { printf '[remnawave-panel] ERROR: %s\n' "$*" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

normalize_answer() {
  local answer="$1"
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  printf '%s' "${answer,,}"
}

ask_yes() {
  local prompt="$1" answer
  while :; do
    read -r -p "$prompt [Y/n]: " answer
    answer="$(normalize_answer "$answer")"
    case "$answer" in
      ''|y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) status INFO "Введите yes или no" ;;
    esac
  done
}

ask_no() {
  local prompt="$1" answer
  while :; do
    read -r -p "$prompt [y/N]: " answer
    answer="$(normalize_answer "$answer")"
    case "$answer" in
      y|yes|д|да) return 0 ;;
      ''|n|no|н|нет) return 1 ;;
      *) status INFO "Введите yes или no" ;;
    esac
  done
}

for cmd in apt-get curl python3 docker systemctl; do
  has_cmd "$cmd" || die "не найдена обязательная команда: $cmd"
done

docker info >/dev/null 2>&1 || die "Docker недоступен"
mkdir -p "$TX_ROOT"
chmod 0700 "$STATE_DIR" "$TX_ROOT"

cat <<'INTRO'

════════════════════════════════════════════════════════════
       CROWDSEC ДЛЯ ПАНЕЛИ REMNAWAVE + CADDY
════════════════════════════════════════════════════════════

Профиль проверит контейнер Remnawave, настроит JSON access log Caddy,
установит CrowdSec Security Engine и коллекции Linux/Caddy. Firewall
bouncer будет установлен следующим этапом после проверки журналов.

Nginx и Traefik этим профилем не поддерживаются.
INTRO

mapfile -t REMNAWAVE_CONTAINERS < <(
  docker ps --format '{{.Names}}\t{{.Image}}' |
    awk -F '\t' '$2 ~ /^remnawave\/backend([:@]|$)/ {print $1}'
)

if (( ${#REMNAWAVE_CONTAINERS[@]} == 0 )); then
  die "не найден запущенный контейнер remnawave/backend"
elif (( ${#REMNAWAVE_CONTAINERS[@]} == 1 )); then
  REMNAWAVE_CONTAINER="${REMNAWAVE_CONTAINERS[0]}"
else
  printf '\nНайдено несколько контейнеров Remnawave:\n'
  printf '  %s\n' "${REMNAWAVE_CONTAINERS[@]}"
  read -r -p "Имя контейнера панели: " REMNAWAVE_CONTAINER
  [[ " ${REMNAWAVE_CONTAINERS[*]} " == *" $REMNAWAVE_CONTAINER "* ]] || \
    die "выбранный контейнер не найден"
fi
status OK "Найдена панель Remnawave: $REMNAWAVE_CONTAINER"

PUBLIC_BINDINGS="$(docker inspect "$REMNAWAVE_CONTAINER" | python3 -c '
import json, sys
obj = json.load(sys.stdin)[0]
ports = (obj.get("NetworkSettings") or {}).get("Ports") or {}
for container_port, bindings in ports.items():
    for binding in bindings or []:
        host = (binding or {}).get("HostIp", "")
        port = (binding or {}).get("HostPort", "")
        if host not in {"127.0.0.1", "::1"}:
            display_host = host or "0.0.0.0"
