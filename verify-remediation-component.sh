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

check_bouncer_raw() {
  local payload="$1"
  BOUNCERS_RAW="$payload" python3 - "$BOUNCER_NAME" <<'PY'
import csv
import datetime as dt
import io
import os
import sys

expected = sys.argv[1]
payload = os.environ.get('BOUNCERS_RAW', '')
reader = csv.DictReader(io.StringIO(payload))

for original in reader:
    row = {
        str(key).strip().lower().replace('-', '_'): (value or '').strip()
        for key, value in original.items()
        if key is not None
    }
    if row.get('name') != expected:
        continue

    # В raw-выводе CrowdSec колонка называется revoked, но для действующего
    # ключа содержит значение validated.
    state = row.get('revoked', '').lower()
    valid_ok = state in {'validated', 'valid', 'false', '0', 'no'}
    last_pull = row.get('last_pull', '')

    if not valid_ok or not last_pull:
        raise SystemExit(2)

    try:
        parsed = dt.datetime.fromisoformat(last_pull.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        age = (dt.datetime.now(dt.timezone.utc) - parsed.astimezone(dt.timezone.utc)).total_seconds()
        if age < -300 or age > 900:
            raise SystemExit(4)
    except ValueError:
        raise SystemExit(5)

    print(last_pull)
    raise SystemExit(0)

raise SystemExit(3)
PY
}

LAST_PULL=""
for _ in {1..24}; do
  RAW_OUTPUT="$(cscli bouncers list -o raw 2>/dev/null || true)"
  if LAST_PULL="$(check_bouncer_raw "$RAW_OUTPUT" 2>/dev/null)"; then
    break
  fi
  sleep 5
done

if [[ -z "$LAST_PULL" ]]; then
  printf '\nТекущие bouncers:\n' >&2
  cscli bouncers list >&2 || true
  printf '\nRaw-вывод для диагностики:\n' >&2
  cscli bouncers list -o raw >&2 || true
  printf '\nСтатус сервиса:\n' >&2
  systemctl status "$BOUNCER_SERVICE" --no-pager -l >&2 || true
  printf '\nПоследние логи bouncer:\n' >&2
  journalctl -u "$BOUNCER_SERVICE" -n 120 --no-pager -l >&2 || true
  die "Bouncer $BOUNCER_NAME не выполнил свежий валидный API pull"
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
После enrollment и перезапуска CrowdSec компонент должен появиться
в CrowdSec Console после очередной синхронизации данных.
DONE
