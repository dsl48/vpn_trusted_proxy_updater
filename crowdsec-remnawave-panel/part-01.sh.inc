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
CADDY_ENV_FILE="/opt/remnawave/caddy/.env"
PANEL_DOMAIN=""
PANEL_DOMAIN_SOURCE=""

normalize_panel_domain() {
  python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import urlsplit

raw = sys.argv[1].strip()
if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
    raw = raw[1:-1].strip()
if not raw or raw == "*" or any(token in raw for token in ("${", "{$", "$(")):
    raise SystemExit(1)

candidate = raw if "://" in raw else "//" + raw
try:
    parsed = urlsplit(candidate)
    host = parsed.hostname
    port = parsed.port
except ValueError:
    raise SystemExit(1)
if not host:
    raise SystemExit(1)

host = host.rstrip(".").lower()
try:
    host = host.encode("idna").decode("ascii")
except UnicodeError:
    raise SystemExit(1)

labels = host.split(".")
if len(labels) < 2:
    raise SystemExit(1)
label_re = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
if any(not label_re.fullmatch(label) for label in labels):
    raise SystemExit(1)

print(host + (f":{port}" if port else ""))
PY
}

mapfile -t PANEL_DOMAIN_CANDIDATES < <(
  python3 - "$ENV_FILE" "$CADDY_ENV_FILE" <<'PY'
import os
import pathlib
import re
import sys

values = {}
for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    if not path.is_file():
        continue
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        values[key] = value

pattern = re.compile(
    r"\{\$([A-Za-z_][A-Za-z0-9_]*)\}"
    r"|\$\{([A-Za-z_][A-Za-z0-9_]*)\}"
    r"|\$([A-Za-z_][A-Za-z0-9_]*)"
)

def expand(value: str) -> str:
    current = value
    for _ in range(8):
        changed = False

        def repl(match):
            nonlocal changed
            name = next(group for group in match.groups() if group)
            replacement = values.get(name, os.environ.get(name))
            if replacement is None:
                return match.group(0)
            changed = True
            return replacement

        current = pattern.sub(repl, current)
        if not changed:
            break
    return current.strip()

for key in (
    "PANEL_DOMAIN",
    "FRONT_END_DOMAIN",
    "REMNAWAVE_PANEL_DOMAIN",
    "CADDY_SUB_DOMAIN",
    "SUB_PUBLIC_DOMAIN",
):
    value = values.get(key, "")
    if value:
        print(f"{key}\t{expand(value)}")
PY
)

for candidate_line in "${PANEL_DOMAIN_CANDIDATES[@]}"; do
  candidate_source="${candidate_line%%$'\t'*}"
  candidate_value="${candidate_line#*$'\t'}"
  normalized="$(normalize_panel_domain "$candidate_value" 2>/dev/null || true)"
  if [[ -n "$normalized" ]]; then
    PANEL_DOMAIN="$normalized"
    PANEL_DOMAIN_SOURCE="$candidate_source"
    break
  fi
  status WARN "$candidate_source не удалось использовать как домен панели: $candidate_value"
done

while [[ -z "$PANEL_DOMAIN" ]]; do
  read -r -p "Домен панели Remnawave без пути: " panel_domain_input
  PANEL_DOMAIN="$(normalize_panel_domain "$panel_domain_input" 2>/dev/null || true)"
  if [[ -z "$PANEL_DOMAIN" ]]; then
    status INFO "Введите hostname вида panel.example.com; URL https://panel.example.com/ тоже допустим"
  else
    PANEL_DOMAIN_SOURCE="ручной ввод"
  fi
done
status OK "Домен панели: $PANEL_DOMAIN (источник: $PANEL_DOMAIN_SOURCE)"

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
