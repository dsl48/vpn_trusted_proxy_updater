#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите через sudo" >&2
  exit 1
}

log() {
  printf '[bouncer-cleanup] %s\n' "$*"
}

command -v cscli >/dev/null 2>&1 || {
  echo "[bouncer-cleanup] ERROR: Не найден cscli" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "[bouncer-cleanup] ERROR: Не найден python3" >&2
  exit 1
}

RAW_OUTPUT="$(cscli bouncers list -o raw 2>/dev/null || true)"

mapfile -t DUPLICATES < <(
  BOUNCERS_RAW="$RAW_OUTPUT" python3 <<'PY'
import csv
import io
import os
import re

payload = os.environ.get('BOUNCERS_RAW', '')
for original in csv.DictReader(io.StringIO(payload)):
    row = {
        str(key).strip().lower().replace('-', '_'): (value or '').strip()
        for key, value in original.items()
        if key is not None
    }
    name = row.get('name', '')
    bouncer_type = row.get('type', '')
    if re.fullmatch(r'cs-firewall-bouncer-[0-9]+', name) and (
        not bouncer_type or bouncer_type == 'crowdsec-firewall-bouncer'
    ):
        print(name)
PY
)

if (( ${#DUPLICATES[@]} == 0 )); then
  log "Пакетные дубли bouncer не найдены"
  exit 0
fi

for name in "${DUPLICATES[@]}"; do
  log "Удаляю лишнюю регистрацию: $name"
  cscli bouncers delete "$name" >/dev/null
done

log "Оставлена управляемая регистрация cdn-origin-firewall-bouncer"
cscli bouncers list
