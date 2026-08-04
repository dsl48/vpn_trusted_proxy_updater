#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите через sudo" >&2
  exit 1
}

log() {
  printf '[vless-selfsteal] %s\n' "$*"
}

die() {
  printf '[vless-selfsteal] ERROR: %s\n' "$*" >&2
  exit 1
}

ask_caddy_runtime() {
  local default_choice="$1" answer
  printf '\nГде запущен Caddy?\n'
  printf '  1 — На хосте через systemd\n'
  printf '  2 — В Docker\n'
  while true; do
    read -r -p "Выберите вариант [$default_choice]: " answer
    answer="${answer:-$default_choice}"
    case "${answer,,}" in
      1|host|systemd) CADDY_RUNTIME="host"; return 0 ;;
      2|docker) CADDY_RUNTIME="docker"; return 0 ;;
      *) printf 'Введите 1 или 2.\n' ;;
    esac
  done
}

command -v apt-get >/dev/null 2>&1 || die "Поддерживаются Debian/Ubuntu"
command -v systemctl >/dev/null 2>&1 || die "Не найден systemctl"
if ! command -v python3 >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends python3
fi

DEFAULT_RUNTIME=1
if command -v docker >/dev/null 2>&1 && \
   docker info >/dev/null 2>&1 && \
   [[ -f /opt/remnanode/selfsteal/Caddyfile ]]; then
  DEFAULT_RUNTIME=2
fi
ask_caddy_runtime "$DEFAULT_RUNTIME"

CADDYFILE=""
CADDY_CONTAINER=""
CADDY_CONTAINER_CONFIG=""
ACCESS_LOG=""
ACQUISITION_DESCRIPTION=""

if [[ "$CADDY_RUNTIME" == "host" ]]; then
  command -v caddy >/dev/null 2>&1 || die "Caddy не установлен на хосте"
  CADDYFILE="/etc/caddy/Caddyfile"
  [[ -f "$CADDYFILE" ]] || die "Не найден $CADDYFILE"
  getent passwd caddy >/dev/null 2>&1 || die "Не найден пользователь caddy"
  systemctl is-active --quiet caddy || die "Сервис caddy не запущен"
else
  command -v docker >/dev/null 2>&1 || die "Docker не установлен"
  docker info >/dev/null 2>&1 || die "Docker daemon недоступен"

  read -r -p \
    "Путь к Caddyfile на хосте [/opt/remnanode/selfsteal/Caddyfile]: " \
    CADDYFILE
  CADDYFILE="${CADDYFILE:-/opt/remnanode/selfsteal/Caddyfile}"
  [[ -f "$CADDYFILE" ]] || die "Не найден Caddyfile: $CADDYFILE"
  CADDYFILE="$(readlink -f "$CADDYFILE")"

  DOCKER_INSPECT_TMP="$(mktemp)"
  RUNNING_CONTAINER_IDS="$(docker ps -q)"
  if [[ -n "$RUNNING_CONTAINER_IDS" ]]; then
    docker inspect $RUNNING_CONTAINER_IDS >"$DOCKER_INSPECT_TMP"
  else
    printf '[]\n' >"$DOCKER_INSPECT_TMP"
  fi

  mapfile -t CADDY_MOUNT_MATCHES < <(
    python3 - "$CADDYFILE" "$DOCKER_INSPECT_TMP" <<'PY'
import json
import pathlib
import sys

host_file = pathlib.Path(sys.argv[1]).resolve()
with open(sys.argv[2], encoding='utf-8') as stream:
    containers = json.load(stream)

for container in containers:
    if not container.get('State', {}).get('Running'):
        continue
    name = container.get('Name', '').lstrip('/')
    for mount in container.get('Mounts', []):
        if mount.get('Type') != 'bind':
            continue
        source = pathlib.Path(mount.get('Source', '')).resolve()
        destination = pathlib.PurePosixPath(mount.get('Destination', '/'))
        if source == host_file:
            print(f'{name}|{destination}')
            break
        try:
            relative = host_file.relative_to(source)
        except ValueError:
            continue
        print(f'{name}|{destination.joinpath(*relative.parts)}')
        break
PY
  )
  rm -f "$DOCKER_INSPECT_TMP"

  DEFAULT_CONTAINER=""
  DEFAULT_CONTAINER_CONFIG="/etc/caddy/Caddyfile"
  if (( ${#CADDY_MOUNT_MATCHES[@]} == 1 )); then
    DEFAULT_CONTAINER="${CADDY_MOUNT_MATCHES[0]%%|*}"
    DEFAULT_CONTAINER_CONFIG="${CADDY_MOUNT_MATCHES[0]#*|}"
    log "Контейнер найден по bind mount: $DEFAULT_CONTAINER"
  elif (( ${#CADDY_MOUNT_MATCHES[@]} > 1 )); then
    printf '\nCaddyfile смонтирован в несколько контейнеров:\n'
    printf '  %s\n' "${CADDY_MOUNT_MATCHES[@]}"
  else
    mapfile -t CADDY_LIKE < <(
      docker ps --format '{{.Names}}|{{.Image}}' | \
        awk 'BEGIN{IGNORECASE=1} /caddy/ {print}'
    )
    if (( ${#CADDY_LIKE[@]} == 1 )); then
      DEFAULT_CONTAINER="${CADDY_LIKE[0]%%|*}"
      log "Предполагаемый Caddy-контейнер: $DEFAULT_CONTAINER"
    elif (( ${#CADDY_LIKE[@]} > 0 )); then
      printf '\nРаботающие контейнеры, похожие на Caddy:\n'
      printf '  %s\n' "${CADDY_LIKE[@]}"
    fi
  fi

  while true; do
    if [[ -n "$DEFAULT_CONTAINER" ]]; then
      read -r -p "Имя Caddy-контейнера [$DEFAULT_CONTAINER]: " CADDY_CONTAINER
      CADDY_CONTAINER="${CADDY_CONTAINER:-$DEFAULT_CONTAINER}"
    else
      read -r -p "Имя Caddy-контейнера: " CADDY_CONTAINER
    fi
    [[ -n "$CADDY_CONTAINER" ]] || {
      printf 'Имя контейнера не может быть пустым.\n'
      continue
    }
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == "true" ]]; then
      break
    fi
    printf 'Контейнер %s не найден или не запущен.\n' "$CADDY_CONTAINER"
  done

  CADDY_MOUNT_FOUND=0
  for match in "${CADDY_MOUNT_MATCHES[@]}"; do
    if [[ "${match%%|*}" == "$CADDY_CONTAINER" ]]; then
      DEFAULT_CONTAINER_CONFIG="${match#*|}"
      CADDY_MOUNT_FOUND=1
      break
    fi
  done
  (( CADDY_MOUNT_FOUND == 1 )) || \
    die "$CADDYFILE не смонтирован в контейнер $CADDY_CONTAINER как bind mount"

  read -r -p \
    "Путь к Caddyfile внутри контейнера [$DEFAULT_CONTAINER_CONFIG]: " \
    CADDY_CONTAINER_CONFIG
  CADDY_CONTAINER_CONFIG="${CADDY_CONTAINER_CONFIG:-$DEFAULT_CONTAINER_CONFIG}"

  docker exec "$CADDY_CONTAINER" test -f "$CADDY_CONTAINER_CONFIG" || \
    die "В контейнере не найден $CADDY_CONTAINER_CONFIG"
  docker exec "$CADDY_CONTAINER" caddy version >/dev/null 2>&1 || \
    die "В контейнере $CADDY_CONTAINER не найден Caddy"
  docker logs --tail 1 "$CADDY_CONTAINER" >/dev/null 2>&1 || \
    die "Docker API не позволяет читать логи контейнера $CADDY_CONTAINER"
fi

printf '\nУстановка CrowdSec для прямой ноды VLESS + selfsteal на Caddy.\n'
printf 'Укажите адрес сайта из заголовка site block в выбранном Caddyfile.\n'
read -r -p "Домен/адрес selfsteal-сайта: " SELFSTEAL_SITE
SELFSTEAL_SITE="$(printf '%s' "$SELFSTEAL_SITE" | tr -d '[:space:]')"
[[ -n "$SELFSTEAL_SITE" ]] || die "Домен/адрес selfsteal-сайта не задан"

SSH_ADMIN_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  SSH_ADMIN_IP="${SSH_CONNECTION%% *}"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
  SSH_ADMIN_IP="${SSH_CLIENT%% *}"
fi

printf '\nIP текущего SSH-подключения: %s\n' "${SSH_ADMIN_IP:-не определён}"
read -r -p "Дополнительные доверенные IP через пробел или запятую [нет]: " EXTRA_ADMIN_IPS

export DEBIAN_FRONTEND=noninteractive
log "Устанавливаю зависимости"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl jq python3 util-linux iproute2 gnupg apt-transport-https

ADMIN_IPS="$(python3 - "$SSH_ADMIN_IP" "$EXTRA_ADMIN_IPS" <<'PY'
import ipaddress
import re
import sys

values = []
for source in sys.argv[1:]:
    for value in re.split(r'[\s,;]+', source.strip()):
        if not value:
            continue
        try:
            parsed = ipaddress.ip_address(value)
        except ValueError as exc:
            raise SystemExit(f'Некорректный административный IP {value!r}: {exc}')
        normalized = str(parsed)
        if normalized not in values:
            values.append(normalized)
print(' '.join(values))
PY
)" || die "Не удалось проверить административные IP"

if ! command -v cscli >/dev/null 2>&1; then
  log "Добавляю официальный репозиторий CrowdSec"
  tmp_repo="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 15 https://install.crowdsec.net -o "$tmp_repo"
  sh "$tmp_repo"
  rm -f "$tmp_repo"
fi

cat >/etc/apt/preferences.d/crowdsec <<'EOF_PIN'
Package: *
Pin: release o=packagecloud.io/crowdsec/crowdsec,a=any,n=any,c=main
Pin-Priority: 1001
EOF_PIN

apt-get update
log "Устанавливаю CrowdSec Security Engine"
apt-get install -y crowdsec

log "Устанавливаю коллекции Linux, SSH и Caddy"
cscli hub update
for collection in \
  crowdsecurity/linux \
  crowdsecurity/sshd \
  crowdsecurity/caddy \
  crowdsecurity/base-http-scenarios \
  crowdsecurity/http-cve \
  crowdsecurity/whitelist-good-actors; do
  cscli collections install "$collection" >/dev/null
done

if [[ "$CADDY_RUNTIME" == "docker" ]]; then
  CROWDSEC_SERVICE_USER="$(systemctl show crowdsec -p User --value 2>/dev/null || true)"
  if [[ -n "$CROWDSEC_SERVICE_USER" && "$CROWDSEC_SERVICE_USER" != "root" ]]; then
    DOCKER_SOCKET_GROUP="$(stat -c '%G' /var/run/docker.sock 2>/dev/null || true)"
    if [[ -z "$DOCKER_SOCKET_GROUP" || "$DOCKER_SOCKET_GROUP" == "UNKNOWN" ]]; then
      die "Не удалось определить группу /var/run/docker.sock"
    fi
    if ! id -nG "$CROWDSEC_SERVICE_USER" | tr ' ' '\n' | \
         grep -Fxq "$DOCKER_SOCKET_GROUP"; then
      log "Добавляю пользователя $CROWDSEC_SERVICE_USER в группу $DOCKER_SOCKET_GROUP"
      usermod -aG "$DOCKER_SOCKET_GROUP" "$CROWDSEC_SERVICE_USER"
    fi
  fi
fi

BACKUP_DIR="/var/lib/crowdsec/vless-selfsteal-backups/$(date +%Y%m%d-%H%M%S)"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile"

if [[ "$CADDY_RUNTIME" == "host" ]]; then
  LOG_DIR=/var/log/caddy
  ACCESS_LOG="$LOG_DIR/selfsteal-access.log"
  log "Настраиваю отдельный JSON access log для selfsteal-сайта"
  install -d -o caddy -g caddy -m 0750 "$LOG_DIR"
  touch "$ACCESS_LOG"
  chown caddy:caddy "$ACCESS_LOG"
  chmod 0640 "$ACCESS_LOG"
  CADDY_LOG_MODE="file"
  CADDY_LOG_TARGET="$ACCESS_LOG"
else
  log "Настраиваю JSON access log в stdout Caddy-контейнера"
  CADDY_LOG_MODE="stdout"
  CADDY_LOG_TARGET="stdout"
fi

python3 - \
  "$CADDYFILE" \
  "$SELFSTEAL_SITE" \
  "$CADDY_LOG_MODE" \
  "$CADDY_LOG_TARGET" \
  "$CADDY_RUNTIME" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
selector = sys.argv[2]
log_mode = sys.argv[3]
log_target = sys.argv[4]
runtime = sys.argv[5]
start_marker = '# BEGIN CROWDSEC VLESS SELFSTEAL LOG'
end_marker = '# END CROWDSEC VLESS SELFSTEAL LOG'
text = path.read_text(encoding='utf-8')
lines = text.splitlines(keepends=True)

def brace_delta(line: str) -> int:
    delta = 0
    quote = None
    escaped = False
    for char in line:
        if escaped:
            escaped = False
            continue
        if char == '\\' and quote is not None:
            escaped = True
            continue
        if quote is not None:
            if char == quote:
                quote = None
            continue
        if char in {'"', "'", '`'}:
            quote = char
            continue
        if char == '#':
            break
        if char == '{':
            delta += 1
        elif char == '}':
            delta -= 1
    return delta

def normalize(token: str) -> str:
    token = token.strip().strip(',')
    token = re.sub(r'^https?://', '', token, flags=re.I)
    if token.startswith('['):
        end = token.find(']')
        if end != -1:
            return token[1:end]
    if token.count(':') == 1:
        host, port = token.rsplit(':', 1)
        if port.isdigit():
            token = host
    return token.rstrip('.')

selector_norm = normalize(selector)
depth = 0
blocks = []
for index, line in enumerate(lines):
    before = depth
    delta = brace_delta(line)
    if before == 0 and delta > 0:
        header = line.split('{', 1)[0].strip()
        if header and not header.startswith('('):
            tokens = [normalize(item) for item in re.split(r'[\s,]+', header) if item]
            if selector_norm in tokens:
                running = before + delta
                end_index = None
                for cursor in range(index + 1, len(lines)):
                    running += brace_delta(lines[cursor])
                    if running == 0:
                        end_index = cursor
                        break
                if end_index is None:
                    raise SystemExit('Не найдена закрывающая скобка site block')
                blocks.append((index, end_index))
    depth += delta

if len(blocks) != 1:
    raise SystemExit(
        f'Для {selector!r} ожидался один site block, найдено {len(blocks)}. '
        'Укажите адрес точно так, как он написан перед фигурной скобкой.'
    )

start, end = blocks[0]
managed_start = managed_end = None
for index in range(start + 1, end):
    if start_marker in lines[index]:
        managed_start = index
    if managed_start is not None and end_marker in lines[index]:
        managed_end = index
        break
if (managed_start is None) != (managed_end is None):
    raise SystemExit('Найден повреждённый управляемый блок CrowdSec в Caddyfile')
if managed_start is not None:
    del lines[managed_start:managed_end + 1]
    end -= managed_end - managed_start + 1

closing_indent = re.match(r'\s*', lines[end]).group(0)
indent = closing_indent + '    '
block = [
    f'{indent}{start_marker}\n',
    f'{indent}log crowdsec_selfsteal {{\n',
]
if log_mode == 'file':
    block.extend([
        f'{indent}    output file {log_target} {{\n',
        f'{indent}        mode 0640\n',
        f'{indent}        roll_size 50MiB\n',
        f'{indent}        roll_keep 10\n',
        f'{indent}        roll_keep_for 720h\n',
        f'{indent}    }}\n',
    ])
elif log_mode == 'stdout':
    block.append(f'{indent}    output stdout\n')
else:
    raise SystemExit(f'Неизвестный режим логирования: {log_mode}')
block.extend([
    f'{indent}    format json\n',
    f'{indent}}}\n',
    f'{indent}{end_marker}\n',
])

lines[end:end] = block
updated = ''.join(lines)
new_path = path.with_name(path.name + '.crowdsec-new')
new_path.write_text(updated, encoding='utf-8')
new_path.chmod(path.stat().st_mode & 0o777)
if runtime == 'docker':
    # A Caddyfile is often bind-mounted as a single file. Replacing its inode
    # would leave the running container attached to the old file, so Docker
    # mode updates the existing inode in place.
    path.write_text(updated, encoding='utf-8')
    path.chmod(new_path.stat().st_mode & 0o777)
    new_path.unlink()
else:
    new_path.replace(path)
PY

validate_caddy() {
  if [[ "$CADDY_RUNTIME" == "host" ]]; then
    caddy validate --config "$CADDYFILE" --adapter caddyfile
  else
    docker exec "$CADDY_CONTAINER" \
      caddy validate --config "$CADDY_CONTAINER_CONFIG" --adapter caddyfile
  fi
}

reload_caddy() {
  if [[ "$CADDY_RUNTIME" == "host" ]]; then
    systemctl reload caddy
    systemctl is-active --quiet caddy
    return
  fi

  if docker exec "$CADDY_CONTAINER" \
       caddy reload --config "$CADDY_CONTAINER_CONFIG" --adapter caddyfile; then
    return 0
  fi

  log "Admin API Caddy недоступен; выполняю reload контейнера сигналом SIGUSR1"
  docker kill --signal=USR1 "$CADDY_CONTAINER" >/dev/null
  sleep 2
  [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER")" == "true" ]]
}

rollback_caddy() {
  log "Откатываю Caddyfile"
  if [[ "$CADDY_RUNTIME" == "docker" ]]; then
    cat "$BACKUP_DIR/Caddyfile" >"$CADDYFILE"
  else
    cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"
  fi
  validate_caddy >/dev/null 2>&1 || true
  reload_caddy >/dev/null 2>&1 || true
}

if ! validate_caddy; then
  rollback_caddy
  die "Caddy не принял конфигурацию access log"
fi

if ! reload_caddy; then
  rollback_caddy
  die "Не удалось применить Caddyfile"
fi

log "Подключаю Caddy JSON log к CrowdSec"
install -d -o root -g root -m 0755 /etc/crowdsec/acquis.d
if [[ "$CADDY_RUNTIME" == "host" ]]; then
  cat >/etc/crowdsec/acquis.d/caddy-selfsteal.yaml <<EOF_ACQUIS
filenames:
  - $ACCESS_LOG
labels:
  type: caddy
EOF_ACQUIS
  ACQUISITION_DESCRIPTION="$ACCESS_LOG"
else
  cat >/etc/crowdsec/acquis.d/caddy-selfsteal.yaml <<EOF_ACQUIS
source: docker
container_name:
  - $CADDY_CONTAINER
follow_stdout: true
follow_stderr: false
labels:
  type: caddy
EOF_ACQUIS
  ACQUISITION_DESCRIPTION="docker://$CADDY_CONTAINER"
fi
chown root:root /etc/crowdsec/acquis.d/caddy-selfsteal.yaml
chmod 0644 /etc/crowdsec/acquis.d/caddy-selfsteal.yaml

log "Проверяю и перезапускаю CrowdSec"
crowdsec -t
systemctl enable crowdsec >/dev/null
systemctl restart crowdsec
systemctl is-active --quiet crowdsec || {
  journalctl -u crowdsec -n 120 --no-pager -l >&2 || true
  die "CrowdSec не запустился"
}

if [[ "$CADDY_RUNTIME" == "docker" && \
      -n "${CROWDSEC_SERVICE_USER:-}" && \
      "$CROWDSEC_SERVICE_USER" != "root" ]]; then
  runuser -u "$CROWDSEC_SERVICE_USER" -- \
    docker logs --tail 1 "$CADDY_CONTAINER" >/dev/null 2>&1 || \
    die "Пользователь $CROWDSEC_SERVICE_USER не может читать Docker logs"
fi

if [[ -n "$ADMIN_IPS" ]]; then
  ALLOWLIST_NAME="vless-selfsteal-admins"
  if ! cscli allowlists inspect "$ALLOWLIST_NAME" >/dev/null 2>&1; then
    cscli allowlists create "$ALLOWLIST_NAME" \
      -d "Administrative IPs for VLESS selfsteal node" >/dev/null
  fi

  for admin_ip in $ADMIN_IPS; do
    ADD_OUTPUT=""
    if ! ADD_OUTPUT="$(cscli allowlists add "$ALLOWLIST_NAME" "$admin_ip" \
      -d "Trusted administrator" 2>&1)"; then
      if grep -qiE 'already|exist|duplicate' <<<"$ADD_OUTPUT"; then
        log "Административный IP уже в AllowList: $admin_ip"
      else
        printf '%s\n' "$ADD_OUTPUT" >&2
        die "Не удалось добавить $admin_ip в AllowList"
      fi
    else
      log "Добавлен административный IP в AllowList: $admin_ip"
    fi
  done
else
  log "Административные IP не заданы; AllowList не создавался"
fi

printf '\nСостояние порта 443:\n'
ss -lntp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)' || \
  printf 'Слушатель TCP/443 не найден. Проверьте Xray/RemnaNode отдельно.\n'

printf '\nAcquisition CrowdSec:\n'
cscli metrics show acquisition 2>/dev/null || true

cat <<DONE

Базовая настройка VLESS + selfsteal завершена.
Caddy runtime: $CADDY_RUNTIME
Caddyfile на хосте: $CADDYFILE
Selfsteal site: $SELFSTEAL_SITE
Acquisition: $ACQUISITION_DESCRIPTION
Конфиг acquisition: /etc/crowdsec/acquis.d/caddy-selfsteal.yaml
Резервная копия Caddyfile: $BACKUP_DIR/Caddyfile
Следующий этап: firewall bouncer с решениями SSH + HTTP.
DONE
