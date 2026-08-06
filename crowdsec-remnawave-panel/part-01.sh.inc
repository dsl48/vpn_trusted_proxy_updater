            print(f"{display_host}:{port}->{container_port}")
' 2>/dev/null || true)"
if [[ -n "$PUBLIC_BINDINGS" ]]; then
  status WARN "У Remnawave обнаружены не-loopback публикации портов:"
  printf '%s\n' "$PUBLIC_BINDINGS"
  ask_no "Продолжить без исправления публикаций Docker?" || \
    die "остановлено: сервисы Remnawave рекомендуется публиковать только на 127.0.0.1"
else
  status OK "Порты Remnawave не опубликованы напрямую в интернет"
fi

ENV_FILE="/opt/remnawave/.env"
PANEL_DOMAIN=""
if [[ -f "$ENV_FILE" ]]; then
  PANEL_DOMAIN="$(python3 - "$ENV_FILE" <<'PY'
import pathlib
import sys

for raw in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() == "FRONT_END_DOMAIN":
        print(value.strip().strip("\"'"))
        break
PY
  )"
fi
PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
PANEL_DOMAIN="${PANEL_DOMAIN%%/*}"
if [[ -z "$PANEL_DOMAIN" ]]; then
  read -r -p "Домен панели Remnawave: " PANEL_DOMAIN
  PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
  PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
  PANEL_DOMAIN="${PANEL_DOMAIN%%/*}"
fi
[[ "$PANEL_DOMAIN" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "некорректный домен панели"
status OK "Домен панели: $PANEL_DOMAIN"

HOST_CADDY=0
DOCKER_CADDY=0
[[ -f /etc/caddy/Caddyfile ]] && has_cmd caddy && HOST_CADDY=1
[[ -f /opt/remnawave/caddy/Caddyfile ]] && \
  docker inspect caddy >/dev/null 2>&1 && DOCKER_CADDY=1

if (( HOST_CADDY == 0 && DOCKER_CADDY == 0 )); then
  die "не найден поддерживаемый Caddy: /etc/caddy/Caddyfile или официальный /opt/remnawave/caddy/Caddyfile"
elif (( HOST_CADDY == 1 && DOCKER_CADDY == 1 )); then
  printf '\nНайдены два варианта Caddy:\n'
  printf '  1 — Caddy на хосте: /etc/caddy/Caddyfile\n'
  printf '  2 — Caddy в Docker: /opt/remnawave/caddy/Caddyfile\n'
  read -r -p "Какой Caddy обслуживает панель? [1]: " CADDY_CHOICE
  CADDY_CHOICE="${CADDY_CHOICE:-1}"
else
  CADDY_CHOICE=$(( HOST_CADDY == 1 ? 1 : 2 ))
fi

CADDY_MODE=""
CADDYFILE=""
CADDY_CONTAINER=""
COMPOSE_DIR=""
COMPOSE_FILE=""
OVERRIDE_FILE=""
if [[ "$CADDY_CHOICE" == 1 ]]; then
  CADDY_MODE="host"
  CADDYFILE="/etc/caddy/Caddyfile"
  systemctl is-active --quiet caddy || die "caddy.service не активен"
  status OK "Используется Caddy на хосте"
elif [[ "$CADDY_CHOICE" == 2 ]]; then
  CADDY_MODE="docker"
  CADDYFILE="/opt/remnawave/caddy/Caddyfile"
  CADDY_CONTAINER="caddy"
  COMPOSE_DIR="/opt/remnawave/caddy"
  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"
  [[ -f "$COMPOSE_FILE" ]] || die "не найден $COMPOSE_FILE"
  docker inspect "$CADDY_CONTAINER" >/dev/null 2>&1 || die "контейнер caddy не найден"
  [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null)" == true ]] || \
    die "контейнер caddy не запущен"
  status OK "Используется официальный Caddy в Docker"
else
  die "неизвестный вариант Caddy"
fi

cat <<'MODE'

Как Caddy получает внешний HTTP-трафик?
  1 — Напрямую от клиентов
  2 — Через Cloudflare, CDN или внешний reverse proxy

При прямом подключении firewall bouncer будет применять SSH- и HTTP-решения.
За CDN firewall bouncer будет применять только SSH-решения, потому что
сетевой уровень видит адрес прокси, а не реальный IP клиента.
MODE
read -r -p "Режим внешнего трафика [1]: " TRAFFIC_CHOICE
TRAFFIC_CHOICE="${TRAFFIC_CHOICE:-1}"
case "$TRAFFIC_CHOICE" in
  1) PANEL_TRAFFIC_MODE="direct" ;;
  2) PANEL_TRAFFIC_MODE="proxy" ;;
  *) die "введите 1 или 2" ;;
esac

# Определяем существующий bind mount /var/log/caddy для Docker.
DOCKER_LOG_SOURCE=""
if [[ "$CADDY_MODE" == docker ]]; then
  DOCKER_LOG_SOURCE="$(
    docker inspect "$CADDY_CONTAINER" | python3 -c '
import json, sys
