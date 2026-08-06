#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}

log() {
  printf '[cdn-crowdsec] %s\n' "$*"
}

die() {
  printf '[cdn-crowdsec] ERROR: %s\n' "$*" >&2
  exit 1
}

for command in crowdsec cscli systemctl install grep find flock python3; do
  command -v "$command" >/dev/null 2>&1 || die "Не найдена команда: $command"
done

[[ -d /etc/crowdsec ]] || die "Не найден /etc/crowdsec"
getent passwd caddy >/dev/null 2>&1 || die "Не найден пользователь caddy"

ACQUIS_DIR=/etc/crowdsec/acquis.d
CADDY_ACQUIS="$ACQUIS_DIR/caddy.yaml"
SSHD_ACQUIS="$ACQUIS_DIR/sshd.yaml"
BACKUP_ROOT=/var/lib/crowdsec/cdn-origin-acquisition-backups
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
ALLOWLIST_NAME=vpn-cdn-infrastructure
SYNC_SCRIPT=/usr/local/sbin/sync-crowdsec-cdn-allowlist
SYNC_SERVICE=/etc/systemd/system/crowdsec-cdn-allowlist-sync.service
SYNC_PATH=/etc/systemd/system/crowdsec-cdn-allowlist-sync.path

install -d -m 0755 "$ACQUIS_DIR"
install -d -m 0700 "$BACKUP_DIR"
install -d -o caddy -g caddy -m 0750 /var/log/caddy
touch /var/log/caddy/access.log
chown caddy:caddy /var/log/caddy/access.log
chmod 0640 /var/log/caddy/access.log

for managed in caddy.yaml sshd.yaml; do
  if [[ -f "$ACQUIS_DIR/$managed" ]]; then
    cp -a "$ACQUIS_DIR/$managed" "$BACKUP_DIR/$managed"
  else
    : >"$BACKUP_DIR/$managed.missing"
  fi
done

rollback_acquisitions() {
  local rc=$?
  trap - ERR
  log "Откатываю изменения acquisition после ошибки"

  for managed in caddy.yaml sshd.yaml; do
    rm -f "$ACQUIS_DIR/$managed"
    if [[ -f "$BACKUP_DIR/$managed" ]]; then
      cp -a "$BACKUP_DIR/$managed" "$ACQUIS_DIR/$managed"
    fi
  done

  for name in setup.caddy.yaml setup.linux.yaml; do
    if [[ -f "$BACKUP_DIR/$name" ]]; then
      mv -f "$BACKUP_DIR/$name" "$ACQUIS_DIR/$name"
    fi
  done

  crowdsec -t >/dev/null 2>&1 || true
  systemctl restart crowdsec >/dev/null 2>&1 || true
  exit "$rc"
}
trap rollback_acquisitions ERR

quarantine_generated_acquisition() {
  local name="$1" reason="$2" src="$ACQUIS_DIR/$1"
  [[ -f "$src" ]] || return 0
  log "Отключаю generated acquisition $name: $reason"
  mv "$src" "$BACKUP_DIR/$name"
}

if [[ -f "$ACQUIS_DIR/setup.caddy.yaml" ]] && \
   grep -Eq 'source:[[:space:]]*journalctl' "$ACQUIS_DIR/setup.caddy.yaml" && \
   grep -Fq 'caddy.service' "$ACQUIS_DIR/setup.caddy.yaml"; then
  quarantine_generated_acquisition \
    setup.caddy.yaml \
    "операционные сообщения Caddy не должны анализироваться как access log"
fi

if [[ -f "$ACQUIS_DIR/setup.linux.yaml" ]] && \
   grep -Eq '/var/log/(syslog|messages)' "$ACQUIS_DIR/setup.linux.yaml"; then
  quarantine_generated_acquisition \
    setup.linux.yaml \
    "syslog содержит копии operational log Caddy и дублирует события"
fi

cat >"$CADDY_ACQUIS" <<'EOF_ACQUIS'
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
EOF_ACQUIS
chown root:root "$CADDY_ACQUIS"
chmod 0644 "$CADDY_ACQUIS"

ssh_source_found=0
while IFS= read -r -d '' file; do
  if grep -Eq '/var/log/(auth\.log|secure)' "$file" 2>/dev/null; then
    ssh_source_found=1
    break
  fi
  if grep -Eq 'source:[[:space:]]*journalctl' "$file" 2>/dev/null && \
     grep -Eq '(ssh|sshd)\.service' "$file" 2>/dev/null; then
    ssh_source_found=1
    break
  fi
done < <(
  find /etc/crowdsec -maxdepth 2 -type f \
    \( -name 'acquis.yaml' -o -path '/etc/crowdsec/acquis.d/*.yaml' \) \
    -print0 2>/dev/null
)

if [[ "$ssh_source_found" -eq 0 ]]; then
  ssh_files=()
  [[ -f /var/log/auth.log ]] && ssh_files+=(/var/log/auth.log)
  [[ -f /var/log/secure ]] && ssh_files+=(/var/log/secure)
  (( ${#ssh_files[@]} > 0 )) || {
    echo "[cdn-crowdsec] ERROR: после отключения setup.linux.yaml не найден SSH log source" >&2
    false
  }

  {
    echo 'filenames:'
    for file in "${ssh_files[@]}"; do
      printf '  - %s\n' "$file"
    done
    echo 'labels:'
    echo '  type: syslog'
    echo 'source: file'
  } >"$SSHD_ACQUIS"
  chown root:root "$SSHD_ACQUIS"
  chmod 0644 "$SSHD_ACQUIS"
  log "Создан отдельный SSH acquisition: $SSHD_ACQUIS"
fi

remaining_bad=()
while IFS= read -r -d '' file; do
  [[ "$file" == "$CADDY_ACQUIS" ]] && continue

  if grep -Eq 'source:[[:space:]]*journalctl' "$file" && \
     grep -Fq 'caddy.service' "$file"; then
    remaining_bad+=("$file (journalctl caddy.service)")
  fi

  if grep -Eq '/var/log/(syslog|messages)' "$file"; then
    remaining_bad+=("$file (generic syslog/messages)")
  fi
done < <(
  find /etc/crowdsec -maxdepth 2 -type f \
    \( -name 'acquis.yaml' -o -path '/etc/crowdsec/acquis.d/*.yaml' \) \
    -print0 2>/dev/null
)

if (( ${#remaining_bad[@]} > 0 )); then
  printf '[cdn-crowdsec] ERROR: остаются источники, способные повторно подать operational log Caddy:\n' >&2
  printf '  %s\n' "${remaining_bad[@]}" >&2
  false
fi

log "Проверяю конфигурацию CrowdSec"
crowdsec -t

log "Перезапускаю CrowdSec с детерминированными acquisition"
systemctl enable crowdsec
systemctl restart crowdsec
systemctl is-active --quiet crowdsec

trap - ERR

cat >"$SYNC_SCRIPT" <<'EOF_SYNC'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

LIST_NAME=vpn-cdn-infrastructure
LOCK_FILE=/run/lock/crowdsec-cdn-allowlist.lock

command -v cscli >/dev/null 2>&1 || {
  echo "[cdn-allowlist] ERROR: cscli не найден" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "[cdn-allowlist] ERROR: python3 не найден" >&2
  exit 1
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

work="$(mktemp -d /tmp/crowdsec-cdn-allowlist.XXXXXX)"
trap 'rm -rf "$work"' EXIT

python3 - "$work/allowlist.csv" <<'PY'
import csv
import ipaddress
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
inputs = [
    pathlib.Path('/etc/caddy/trusted-proxies.d/yandex.cidr'),
    pathlib.Path('/etc/caddy/trusted-proxies.d/beeline.cidr'),
    pathlib.Path('/etc/crowdsec/cdn-origin-admins.txt'),
]

values = set()
for path in inputs:
    if not path.is_file():
        continue
    for raw in path.read_text(encoding='utf-8', errors='ignore').splitlines():
        value = raw.strip()
        if not value or value.startswith('#'):
            continue
        try:
            parsed = ipaddress.ip_network(value, strict=False)
        except ValueError as exc:
            raise SystemExit(f'{path}: некорректный IP/CIDR {value!r}: {exc}')
        values.add(str(parsed))

if not values:
    raise SystemExit('Нет CDN-диапазонов или доверенных адресов для allowlist')

def key(value: str):
    network = ipaddress.ip_network(value, strict=False)
    return network.version, int(network.network_address), network.prefixlen

with output.open('w', encoding='utf-8', newline='') as handle:
    writer = csv.writer(handle)
    writer.writerow(['value', 'expiration', 'comment'])
    for value in sorted(values, key=key):
        writer.writerow([value, '', 'CDN edge or trusted administrator'])
PY

cscli allowlists delete "$LIST_NAME" >/dev/null 2>&1 || true
cscli allowlists create "$LIST_NAME" \
  -d "Selected CDN providers and trusted administrators" >/dev/null
cscli allowlists import "$LIST_NAME" -i "$work/allowlist.csv" >/dev/null

echo "[cdn-allowlist] CrowdSec allowlist синхронизирован"
EOF_SYNC
chown root:root "$SYNC_SCRIPT"
chmod 0700 "$SYNC_SCRIPT"

cat >"$SYNC_SERVICE" <<EOF_SERVICE
[Unit]
Description=Synchronize CrowdSec allowlist with CDN trusted proxy ranges
After=crowdsec.service cdn-trusted-proxies.service
Requires=crowdsec.service

[Service]
Type=oneshot
ExecStart=$SYNC_SCRIPT
User=root
Group=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
EOF_SERVICE

cat >"$SYNC_PATH" <<'EOF_PATH'
[Unit]
Description=Watch CDN trusted proxy ranges for CrowdSec allowlist sync

[Path]
PathChanged=/etc/caddy/trusted-proxies.d
PathChanged=/etc/crowdsec/cdn-origin-admins.txt
Unit=crowdsec-cdn-allowlist-sync.service

[Install]
WantedBy=multi-user.target
EOF_PATH

chown root:root "$SYNC_SERVICE" "$SYNC_PATH"
chmod 0644 "$SYNC_SERVICE" "$SYNC_PATH"

systemctl daemon-reload
systemctl enable --now crowdsec-cdn-allowlist-sync.path
systemctl start crowdsec-cdn-allowlist-sync.service
systemctl is-active --quiet crowdsec-cdn-allowlist-sync.path || \
  die "Path unit синхронизации allowlist не активен"

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -printf '%T@ %p\n' | sort -nr | awk 'NR>20 {print $2}' | xargs -r rm -rf

log "Готово"
log "Caddy анализируется только из /var/log/caddy/access.log"
log "setup.caddy.yaml и setup.linux.yaml сохранены в $BACKUP_DIR, если они существовали"
log "CrowdSec allowlist синхронизируется при изменении CDN-диапазонов"

cscli metrics show acquisition || true
cscli allowlists inspect "$ALLOWLIST_NAME" || true
