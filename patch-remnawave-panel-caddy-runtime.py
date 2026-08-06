#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys


def replace_regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    matches = list(re.finditer(pattern, text, flags=re.DOTALL))
    if len(matches) != 1:
        raise SystemExit(f"{label}: ожидалось одно совпадение, найдено {len(matches)}")
    match = matches[0]
    return text[:match.start()] + replacement + text[match.end():]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: ожидалось одно совпадение, найдено {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-remnawave-panel-caddy-runtime.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    detection = r'''CADDY_MODE=""
CADDYFILE=""
CADDY_CONTAINER=""
CADDY_CONTAINER_CONFIG=""
COMPOSE_DIR=""
COMPOSE_FILE=""
OVERRIDE_FILE=""
CADDY_COMPOSE_SERVICE=""
declare -a CADDY_CANDIDATES=()

add_caddy_candidate() {
  local candidate="$1" existing
  for existing in "${CADDY_CANDIDATES[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  CADDY_CANDIDATES+=("$candidate")
}

# Caddy на хосте: извлекаем --config из caddy.service и проверяем стандартный путь.
if has_cmd caddy && systemctl is-active --quiet caddy; then
  HOST_EXECSTART="$(systemctl show caddy.service -p ExecStart --value 2>/dev/null || true)"
  HOST_CONFIG_FROM_UNIT="$(python3 - "$HOST_EXECSTART" <<'PY'
import re
import sys

value = sys.argv[1]
patterns = (
    r'(?:^|[ ;])--config(?:=|[ ]+)(?:"([^"]+)"|\'([^\']+)\'|([^ ;}]+))',
    r'(?:^|[ ;])-c(?:=|[ ]+)(?:"([^"]+)"|\'([^\']+)\'|([^ ;}]+))',
)
for pattern in patterns:
    match = re.search(pattern, value)
    if match:
        print(next(group for group in match.groups() if group))
        break
PY
  )"
  for host_config in "$HOST_CONFIG_FROM_UNIT" /etc/caddy/Caddyfile; do
    [[ -n "$host_config" && -f "$host_config" ]] || continue
    host_config="$(readlink -f "$host_config")"
    add_caddy_candidate "host|-|$host_config|-|-|-|-"
  done
fi

# Caddy в Docker: ищем bind-mounted Caddyfile у работающих контейнеров.
DOCKER_INSPECT_TMP="$(mktemp)"
RUNNING_CONTAINER_IDS="$(docker ps -q)"
if [[ -n "$RUNNING_CONTAINER_IDS" ]]; then
  docker inspect $RUNNING_CONTAINER_IDS >"$DOCKER_INSPECT_TMP"
else
  printf '[]\n' >"$DOCKER_INSPECT_TMP"
fi
mapfile -t DOCKER_CADDY_CANDIDATES < <(
  python3 - "$DOCKER_INSPECT_TMP" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding='utf-8') as stream:
    containers = json.load(stream)

for container in containers:
    if not container.get('State', {}).get('Running'):
        continue
    name = container.get('Name', '').lstrip('/')
    config = container.get('Config') or {}
    image = str(config.get('Image') or '')
    executable = pathlib.PurePosixPath(str(container.get('Path') or '')).name
    if 'caddy' not in f'{name} {image} {executable}'.lower():
        continue

    labels = config.get('Labels') or {}
    workdir = labels.get('com.docker.compose.project.working_dir', '') or ''
    config_files = labels.get('com.docker.compose.project.config_files', '') or ''
    service = labels.get('com.docker.compose.service', '') or ''
    compose_file = ''
    if config_files:
        first = config_files.split(',', 1)[0].strip()
        candidate = pathlib.Path(first)
        if not candidate.is_absolute() and workdir:
            candidate = pathlib.Path(workdir) / candidate
        compose_file = str(candidate)

    seen = set()
    for mount in container.get('Mounts', []):
        if mount.get('Type') != 'bind':
            continue
        source_raw = mount.get('Source') or ''
        destination_raw = mount.get('Destination') or ''
        if not source_raw or not destination_raw:
            continue
        source = pathlib.Path(source_raw)
        destination = pathlib.PurePosixPath(destination_raw)
        mappings = []
        if source.is_file() and destination.name.lower() == 'caddyfile':
            mappings.append((source.resolve(), destination))
        elif source.is_dir():
            for filename in ('Caddyfile', 'caddyfile'):
                host_file = source / filename
                if host_file.is_file():
                    mappings.append((host_file.resolve(), destination / filename))
        for host_file, container_file in mappings:
            key = (str(host_file), str(container_file))
            if key in seen:
                continue
            seen.add(key)
            print('|'.join((
                'docker', name, str(host_file), str(container_file),
                workdir or '-', compose_file or '-', service or '-',
            )))
PY
)
rm -f "$DOCKER_INSPECT_TMP"
for candidate in "${DOCKER_CADDY_CANDIDATES[@]}"; do
  add_caddy_candidate "$candidate"
done

select_caddy_candidate() {
  local choice index candidate mode container host_file container_file workdir compose_file service
  if (( ${#CADDY_CANDIDATES[@]} == 1 )); then
    choice=1
  else
    printf '\nНайдены варианты Caddy:\n'
    index=1
    for candidate in "${CADDY_CANDIDATES[@]}"; do
      IFS='|' read -r mode container host_file container_file workdir compose_file service <<<"$candidate"
      if [[ "$mode" == host ]]; then
        printf '  %d — host: %s\n' "$index" "$host_file"
      else
        printf '  %d — Docker: %s, %s -> %s\n' "$index" "$container" "$host_file" "$container_file"
      fi
      ((index += 1))
    done
    while :; do
      read -r -p "Какой Caddy обслуживает панель? [1]: " choice
      choice="${choice:-1}"
      [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#CADDY_CANDIDATES[@]} )) && break
      status INFO "Введите номер от 1 до ${#CADDY_CANDIDATES[@]}"
    done
  fi

  candidate="${CADDY_CANDIDATES[choice-1]}"
  IFS='|' read -r CADDY_MODE CADDY_CONTAINER CADDYFILE CADDY_CONTAINER_CONFIG COMPOSE_DIR COMPOSE_FILE CADDY_COMPOSE_SERVICE <<<"$candidate"
  [[ "$CADDY_CONTAINER" == - ]] && CADDY_CONTAINER=""
  [[ "$CADDY_CONTAINER_CONFIG" == - ]] && CADDY_CONTAINER_CONFIG=""
  [[ "$COMPOSE_DIR" == - ]] && COMPOSE_DIR=""
  [[ "$COMPOSE_FILE" == - ]] && COMPOSE_FILE=""
  [[ "$CADDY_COMPOSE_SERVICE" == - ]] && CADDY_COMPOSE_SERVICE=""
}

manual_caddy_selection() {
  local runtime host_path inspect_result
  status WARN "Caddy не удалось определить автоматически"
  printf '\nГде запущен Caddy?\n'
  printf '  1 — На хосте через systemd\n'
  printf '  2 — В Docker\n'
  while :; do
    read -r -p "Выберите вариант: " runtime
    case "$runtime" in
      1|host)
        CADDY_MODE="host"
        read -r -p "Путь к Caddyfile на хосте: " host_path
        [[ -f "$host_path" ]] || { status INFO "Файл не найден: $host_path"; continue; }
        has_cmd caddy || die "бинарник caddy на хосте не найден"
        systemctl is-active --quiet caddy || die "caddy.service не активен"
        CADDYFILE="$(readlink -f "$host_path")"
        return 0
        ;;
      2|docker)
        CADDY_MODE="docker"
        docker ps --format '  {{.Names}}\t{{.Image}}' | grep -i caddy || true
        read -r -p "Имя Caddy-контейнера: " CADDY_CONTAINER
        [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == true ]] || {
          status INFO "Контейнер не найден или не запущен"
          continue
        }
        read -r -p "Путь к Caddyfile на хосте: " host_path
        [[ -f "$host_path" ]] || { status INFO "Файл не найден: $host_path"; continue; }
        CADDYFILE="$(readlink -f "$host_path")"
        inspect_result="$(docker inspect "$CADDY_CONTAINER" | python3 - "$CADDYFILE" <<'PY'
import json
import pathlib
import sys

host_file = pathlib.Path(sys.argv[1]).resolve()
container = json.load(sys.stdin)[0]
container_path = ''
for mount in container.get('Mounts', []):
    if mount.get('Type') != 'bind':
        continue
    source = pathlib.Path(mount.get('Source') or '').resolve()
    destination = pathlib.PurePosixPath(mount.get('Destination') or '/')
    if source == host_file:
        container_path = str(destination)
        break
    try:
        relative = host_file.relative_to(source)
    except ValueError:
        continue
    container_path = str(destination.joinpath(*relative.parts))
    break
if not container_path:
    raise SystemExit(1)
labels = (container.get('Config') or {}).get('Labels') or {}
workdir = labels.get('com.docker.compose.project.working_dir', '') or '-'
files = labels.get('com.docker.compose.project.config_files', '') or ''
compose_file = '-'
if files:
    first = files.split(',', 1)[0].strip()
    candidate = pathlib.Path(first)
    if not candidate.is_absolute() and workdir != '-':
        candidate = pathlib.Path(workdir) / candidate
    compose_file = str(candidate)
service = labels.get('com.docker.compose.service', '') or '-'
print('|'.join((container_path, workdir, compose_file, service)))
PY
        )" || {
          status INFO "$CADDYFILE не смонтирован в контейнер как bind mount"
          continue
        }
        IFS='|' read -r CADDY_CONTAINER_CONFIG COMPOSE_DIR COMPOSE_FILE CADDY_COMPOSE_SERVICE <<<"$inspect_result"
        [[ "$COMPOSE_DIR" == - ]] && COMPOSE_DIR=""
        [[ "$COMPOSE_FILE" == - ]] && COMPOSE_FILE=""
        [[ "$CADDY_COMPOSE_SERVICE" == - ]] && CADDY_COMPOSE_SERVICE=""
        return 0
        ;;
      *) status INFO "Введите 1 или 2" ;;
    esac
  done
}

if (( ${#CADDY_CANDIDATES[@]} > 0 )); then
  select_caddy_candidate
else
  manual_caddy_selection
fi

[[ -f "$CADDYFILE" ]] || die "Caddyfile не найден: $CADDYFILE"
if [[ "$CADDY_MODE" == host ]]; then
  status OK "Используется Caddy на хосте: $CADDYFILE"
else
  docker exec "$CADDY_CONTAINER" caddy version >/dev/null 2>&1 || \
    die "в контейнере $CADDY_CONTAINER не найден Caddy"
  docker exec "$CADDY_CONTAINER" test -f "$CADDY_CONTAINER_CONFIG" || \
    die "в контейнере не найден $CADDY_CONTAINER_CONFIG"
  if [[ -n "$COMPOSE_DIR" && -n "$COMPOSE_FILE" && -n "$CADDY_COMPOSE_SERVICE" ]]; then
    OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.crowdsec.yml"
  fi
  status OK "Используется Docker Caddy: $CADDY_CONTAINER"
  status INFO "Caddyfile: $CADDYFILE -> $CADDY_CONTAINER_CONFIG"
fi

cat <<'MODE' '''

    text = replace_regex_once(
        text,
        r'HOST_CADDY=0\n.*?\ncat <<\'MODE\'',
        detection,
        "автоопределение Caddy",
    )

    compose_override = r'''OVERRIDE_CHANGED=0
if [[ "$CADDY_MODE" == docker && -z "$DOCKER_LOG_SOURCE" ]]; then
  [[ -n "$COMPOSE_DIR" && -n "$COMPOSE_FILE" && -n "$OVERRIDE_FILE" && -n "$CADDY_COMPOSE_SERVICE" ]] || \
    die "у Docker Caddy нет bind mount /var/log/caddy, а Compose metadata не найдены; добавьте mount /var/log/caddy:/var/log/caddy и повторите запуск"
  if [[ -e "$OVERRIDE_FILE" ]]; then
    if grep -Fq '/var/log/caddy:/var/log/caddy' "$OVERRIDE_FILE"; then
      DOCKER_LOG_SOURCE="$LOG_DIR"
      status OK "Bind mount журналов уже описан в $OVERRIDE_FILE"
    else
      die "$OVERRIDE_FILE уже существует без /var/log/caddy; автоматическое объединение отключено"
    fi
  else
    cat >"$OVERRIDE_FILE" <<EOF_OVERRIDE
services:
  ${CADDY_COMPOSE_SERVICE}:
    volumes:
      - /var/log/caddy:/var/log/caddy
EOF_OVERRIDE
    chmod 0644 "$OVERRIDE_FILE"
    DOCKER_LOG_SOURCE="$LOG_DIR"
    OVERRIDE_CHANGED=1
    status APPLIED "Создан $OVERRIDE_FILE с bind mount журналов"
  fi
fi

install -d'''
    text = replace_regex_once(
        text,
        r'OVERRIDE_CHANGED=0\nif \[\[ "\$CADDY_MODE" == docker && -z "\$DOCKER_LOG_SOURCE" \]\]; then\n.*?\nfi\n\ninstall -d',
        compose_override,
        "Docker mount журналов",
    )

    old_rollback = r'''else
  cd "$COMPOSE_DIR"
  if [[ -f "$OVERRIDE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d >/dev/null 2>&1 || true
  else
    docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
  fi
fi'''
    new_rollback = r'''else
  if [[ -n "$COMPOSE_DIR" && -n "$COMPOSE_FILE" && -n "$OVERRIDE_FILE" ]]; then
    cd "$COMPOSE_DIR"
    if [[ -f "$OVERRIDE_FILE" ]]; then
      docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d >/dev/null 2>&1 || true
    else
      docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
    fi
  else
    docker exec "$CADDY_CONTAINER" caddy reload --config "$CADDY_CONTAINER_CONFIG" >/dev/null 2>&1 || true
  fi
fi'''
    text = replace_once(text, old_rollback, new_rollback, "rollback Docker Caddy")

    old_apply = r'''  else
    docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile || {
      rollback_now; die "Caddyfile в контейнере не прошёл проверку"
    }
    (
      cd "$COMPOSE_DIR"
      if [[ -f "$OVERRIDE_FILE" ]]; then
        docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d
      else
        docker compose -f "$COMPOSE_FILE" up -d
      fi
    ) || { rollback_now; die "не удалось применить Docker override Caddy"; }
    docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile || {
      rollback_now; die "Caddy после пересоздания не прошёл проверку"
    }
    docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile || {
      rollback_now; die "не удалось выполнить caddy reload в контейнере"
    }
  fi'''
    new_apply = r'''  else
    docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "Caddyfile в контейнере не прошёл проверку"
    }
    if (( OVERRIDE_CHANGED == 1 )); then
      (
        cd "$COMPOSE_DIR"
        docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d
      ) || { rollback_now; die "не удалось применить Docker mount журналов Caddy"; }
      for _ in {1..30}; do
        [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == true ]] && break
        sleep 1
      done
    fi
    docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "Caddy после применения настроек не прошёл проверку"
    }
    docker exec "$CADDY_CONTAINER" caddy reload --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "не удалось выполнить caddy reload в контейнере"
    }
  fi'''
    text = replace_once(text, old_apply, new_apply, "применение Docker Caddy")

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
