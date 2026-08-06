#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-remnawave-panel-crowdsec-start.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    pattern = re.compile(
        r'''if grep -RqsF "\$HOST_LOG_PATH" /etc/crowdsec/acquis\.yaml /etc/crowdsec/acquis\.d 2>/dev/null; then\n'''
        r'''.*?'''
        r'''status OK "CrowdSec Security Engine запущен"''',
        flags=re.DOTALL,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            "запуск CrowdSec для панели: ожидалось одно совпадение, "
            f"найдено {len(matches)}"
        )

    replacement = r'''CROWDSEC_CONFIG="/etc/crowdsec/config.yaml"
LAPI_CREDENTIALS="/etc/crowdsec/local_api_credentials.yaml"
LAPI_HOST="127.0.0.1"
LAPI_LISTEN="${LAPI_HOST}:${LAPI_PORT}"
LAPI_CREDENTIALS_URL="http://${LAPI_LISTEN}"
LAPI_URL="${LAPI_CREDENTIALS_URL}/"

[[ -f "$CROWDSEC_CONFIG" ]] || die "не найден $CROWDSEC_CONFIG"
[[ -f "$LAPI_CREDENTIALS" ]] || die "не найден $LAPI_CREDENTIALS"

CROWDSEC_WAS_ACTIVE=0
if systemctl is-active --quiet crowdsec; then
  CROWDSEC_WAS_ACTIVE=1
fi

CROWDSEC_TX="$(mktemp -d /var/lib/crowdsec/remnawave-panel-start.XXXXXX)" || \
  die "не удалось создать транзакцию CrowdSec"
chmod 0700 "$CROWDSEC_TX"

backup_crowdsec_file() {
  local source="$1" destination="$2" label="$3"
  cp -a -- "$source" "$destination" || \
    die "$label: не удалось создать backup"
  cmp -s -- "$source" "$destination" || \
    die "$label: backup не совпадает с исходным файлом"
}

backup_crowdsec_file "$CROWDSEC_CONFIG" "$CROWDSEC_TX/config.yaml.before" \
  "CrowdSec config"
backup_crowdsec_file "$LAPI_CREDENTIALS" \
  "$CROWDSEC_TX/local_api_credentials.yaml.before" \
  "CrowdSec Local API credentials"
status BACKUP "Конфигурация CrowdSec сохранена: $CROWDSEC_TX"

ACQUIS_CHANGED=0
ACQUIS_WAS_PRESENT=0
if grep -RqsF "$HOST_LOG_PATH" \
  /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d 2>/dev/null; then
  status OK "Acquisition для Caddy log уже существует"
else
  if [[ -f "$ACQUIS_FILE" ]]; then
    backup_crowdsec_file "$ACQUIS_FILE" \
      "$CROWDSEC_TX/remnawave-panel-caddy.yaml.before" \
      "CrowdSec acquisition"
    ACQUIS_WAS_PRESENT=1
  fi
  cat >"$ACQUIS_FILE" <<EOF_ACQUIS
source: file
filenames:
  - $HOST_LOG_PATH
labels:
  type: caddy
EOF_ACQUIS
  chmod 0644 "$ACQUIS_FILE"
  ACQUIS_CHANGED=1
  status APPLIED "Создан acquisition: $ACQUIS_FILE"
fi

restore_crowdsec_files() {
  status RESTORE "Восстанавливаю конфигурацию CrowdSec"
  cp -a -- "$CROWDSEC_TX/config.yaml.before" "$CROWDSEC_CONFIG"
  cp -a -- "$CROWDSEC_TX/local_api_credentials.yaml.before" "$LAPI_CREDENTIALS"
  if (( ACQUIS_CHANGED == 1 )); then
    if (( ACQUIS_WAS_PRESENT == 1 )); then
      cp -a -- "$CROWDSEC_TX/remnawave-panel-caddy.yaml.before" "$ACQUIS_FILE"
    else
      rm -f -- "$ACQUIS_FILE"
    fi
  fi
  chown root:root "$CROWDSEC_CONFIG" "$LAPI_CREDENTIALS"
  chmod 0600 "$LAPI_CREDENTIALS"
}

CURRENT_LISTEN="$(python3 - "$CROWDSEC_CONFIG" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
match = re.search(r'^\s*listen_uri\s*:\s*([^#\s]+)', text, flags=re.MULTILINE)
if not match:
    raise SystemExit(1)
print(match.group(1).strip('"\''))
PY
)" || {
  restore_crowdsec_files
  die "не найден api.server.listen_uri в $CROWDSEC_CONFIG"
}

if (( CROWDSEC_WAS_ACTIVE == 0 )) || [[ "$CURRENT_LISTEN" != "$LAPI_LISTEN" ]]; then
  if ! python3 - "$LAPI_HOST" "$LAPI_PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((host, port))
except OSError as exc:
    print(f'{host}:{port} занят: {exc}', file=sys.stderr)
    raise SystemExit(1)
finally:
    sock.close()
PY
  then
    command -v ss >/dev/null 2>&1 && \
      ss -ltnp 2>/dev/null | grep -E ":(${LAPI_PORT}|8080)([[:space:]]|$)" >&2 || true
    restore_crowdsec_files
    die "порт CrowdSec Local API $LAPI_LISTEN занят"
  fi
fi

log "Настраиваю CrowdSec Local API на $LAPI_LISTEN до первого запуска"
if ! python3 - \
  "$CROWDSEC_CONFIG" \
  "$LAPI_CREDENTIALS" \
  "$LAPI_LISTEN" \
  "$LAPI_CREDENTIALS_URL" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
credentials_path = pathlib.Path(sys.argv[2])
listen_uri = sys.argv[3]
api_url = sys.argv[4]


def replace_single(path: pathlib.Path, key: str, value: str) -> None:
    text = path.read_text(encoding='utf-8')
    pattern = re.compile(
        rf'^(\s*{re.escape(key)}\s*:\s*).*$',
        flags=re.MULTILINE,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f'{path}: ожидалась одна строка {key}, найдено {len(matches)}'
        )
    updated = pattern.sub(lambda match: match.group(1) + value, text, count=1)
    temporary = path.with_name(path.name + '.remnawave-new')
    temporary.write_text(updated, encoding='utf-8')
    temporary.chmod(path.stat().st_mode & 0o777)
    temporary.replace(path)


replace_single(config_path, 'listen_uri', listen_uri)
replace_single(credentials_path, 'url', api_url)
PY
then
  restore_crowdsec_files
  die "не удалось настроить CrowdSec Local API"
fi

chown root:root "$CROWDSEC_CONFIG" "$LAPI_CREDENTIALS"
chmod 0600 "$LAPI_CREDENTIALS"

if ! crowdsec -t; then
  status ERROR "Конфигурация CrowdSec не прошла проверку"
  restore_crowdsec_files
  crowdsec -t >&2 || true
  die "CrowdSec config test завершился ошибкой"
fi
status OK "CrowdSec config test пройден"

systemctl enable crowdsec >/dev/null || {
  restore_crowdsec_files
  die "не удалось включить crowdsec.service в автозапуск"
}

if ! systemctl restart crowdsec; then
  status ERROR "CrowdSec не запустился; показываю диагностику"
  systemctl status crowdsec --no-pager -l >&2 || true
  journalctl -u crowdsec -n 160 --no-pager -l >&2 || true
  command -v ss >/dev/null 2>&1 && \
    ss -ltnp 2>/dev/null | grep -E ":(${LAPI_PORT}|8080)([[:space:]]|$)" >&2 || true
  restore_crowdsec_files
  if (( CROWDSEC_WAS_ACTIVE == 1 )); then
    systemctl restart crowdsec >/dev/null 2>&1 || true
  fi
  die "CrowdSec не запустился на $LAPI_LISTEN"
fi

LAPI_READY=0
for _ in {1..30}; do
  if python3 - "$LAPI_HOST" "$LAPI_PORT" <<'PY' >/dev/null 2>&1
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(1)
try:
    sock.connect((sys.argv[1], int(sys.argv[2])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
  then
    LAPI_READY=1
    break
  fi
  sleep 1
done

if (( LAPI_READY == 0 )) || \
   ! systemctl is-active --quiet crowdsec || \
   ! cscli machines list >/dev/null 2>&1; then
  status ERROR "CrowdSec запущен некорректно; показываю диагностику"
  systemctl status crowdsec --no-pager -l >&2 || true
  journalctl -u crowdsec -n 160 --no-pager -l >&2 || true
  restore_crowdsec_files
  systemctl stop crowdsec >/dev/null 2>&1 || true
  if (( CROWDSEC_WAS_ACTIVE == 1 )); then
    systemctl restart crowdsec >/dev/null 2>&1 || true
  fi
  die "CrowdSec Local API недоступен на $LAPI_LISTEN"
fi

status OK "CrowdSec Security Engine запущен"
status OK "CrowdSec Local API: $LAPI_URL"'''

    match = matches[0]
    text = text[: match.start()] + replacement + text[match.end() :]
    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
