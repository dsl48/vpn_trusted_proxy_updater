#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите через sudo" >&2
  exit 1
}

log() {
  printf '[remediation-check] %s\n' "$*"
}

die() {
  printf '[remediation-check] ERROR: %s\n' "$*" >&2
  exit 1
}

BOUNCER_NAME="${CROWDSEC_BOUNCER_NAME:-cdn-origin-firewall-bouncer}"
BOUNCER_SERVICE="crowdsec-firewall-bouncer"

command -v cscli >/dev/null 2>&1 || die "Не найден cscli"
command -v python3 >/dev/null 2>&1 || die "Не найден python3"

systemctl is-active --quiet crowdsec || die "Сервис crowdsec не запущен"
systemctl is-enabled --quiet "$BOUNCER_SERVICE" || \
  die "$BOUNCER_SERVICE не включён в автозапуск"

log "Перезапускаю CrowdSec и firewall bouncer для обновления метаданных"
systemctl restart crowdsec
systemctl restart "$BOUNCER_SERVICE"

systemctl is-active --quiet crowdsec || die "CrowdSec не запустился"
systemctl is-active --quiet "$BOUNCER_SERVICE" || {
  journalctl -u "$BOUNCER_SERVICE" -n 100 --no-pager -l >&2 || true
  die "$BOUNCER_SERVICE не запустился"
}

check_bouncer_json() {
  local payload="$1"
  BOUNCERS_JSON="$payload" python3 - "$BOUNCER_NAME" <<'PY'
import json
import os
import sys

expected = sys.argv[1]
try:
    data = json.loads(os.environ.get('BOUNCERS_JSON', ''))
except Exception:
    raise SystemExit(1)

objects = []
def walk(value):
    if isinstance(value, dict):
        objects.append(value)
        for item in value.values():
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)
walk(data)

def get(obj, *names):
    lowered = {str(k).lower().replace('-', '_'): v for k, v in obj.items()}
    for name in names:
        key = name.lower().replace('-', '_')
        if key in lowered:
            return lowered[key]
    return None

for obj in objects:
    name = get(obj, 'name')
    if name != expected:
        continue
    valid = get(obj, 'valid', 'is_valid')
    last_pull = get(obj, 'last_api_pull', 'last_pull', 'last_api_pull_at')
    valid_ok = valid is True or str(valid).lower() in {'true', 'yes', '1', 'valid'}
    pull_ok = last_pull not in (None, '', '0001-01-01T00:00:00Z')
    if valid_ok and pull_ok:
        print(last_pull)
        raise SystemExit(0)
    raise SystemExit(2)

raise SystemExit(3)
PY
}

LAST_PULL=""
for _ in {1..24}; do
  JSON_OUTPUT="$(cscli bouncers list -o json 2>/dev/null || true)"
  if LAST_PULL="$(check_bouncer_json "$JSON_OUTPUT" 2>/dev/null)"; then
    break
  fi
  sleep 5
done

if [[ -z "$LAST_PULL" ]]; then
  printf '\nТекущие bouncers:\n' >&2
  cscli bouncers list >&2 || true
  printf '\nСтатус сервиса:\n' >&2
  systemctl status "$BOUNCER_SERVICE" --no-pager -l >&2 || true
  printf '\nПоследние логи bouncer:\n' >&2
  journalctl -u "$BOUNCER_SERVICE" -n 120 --no-pager -l >&2 || true
  die "Bouncer $BOUNCER_NAME не выполнил валидный API pull"
fi

log "Bouncer зарегистрирован и подключён"
log "Последний API pull: $LAST_PULL"

printf '\nЗарегистрированные bouncers:\n'
cscli bouncers list

printf '\nЛокальные метрики bouncer:\n'
cscli metrics show bouncers 2>/dev/null || \
  printf 'Метрики ещё не накоплены — это нормально сразу после установки.\n'

printf '\nСтатус CrowdSec Console:\n'
cscli console status 2>/dev/null || true

cat <<'DONE'

Локальная регистрация remediation component подтверждена.
После enrollment и перезапуска CrowdSec компонент обычно появляется
в CrowdSec Console в течение нескольких минут.
DONE
