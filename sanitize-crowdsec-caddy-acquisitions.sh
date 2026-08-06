#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}

log() {
  printf '[caddy-acquisitions] %s\n' "$*"
}

die() {
  printf '[caddy-acquisitions] ERROR: %s\n' "$*" >&2
  exit 1
}

for command in crowdsec systemctl install grep find; do
  command -v "$command" >/dev/null 2>&1 || die "Не найдена команда: $command"
done

ACQUIS_DIR=/etc/crowdsec/acquis.d
BACKUP_ROOT=/var/lib/crowdsec/caddy-acquisition-backups
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
SSHD_ACQUIS="$ACQUIS_DIR/sshd.yaml"

[[ -d /etc/crowdsec ]] || die "Не найден /etc/crowdsec"
install -d -m 0755 "$ACQUIS_DIR"
install -d -m 0700 "$BACKUP_DIR"

has_dedicated_caddy=0
while IFS= read -r -d '' file; do
  [[ "$file" == "$ACQUIS_DIR/setup.caddy.yaml" ]] && continue
  if grep -Eq 'type:[[:space:]]*caddy([[:space:]]|$)' "$file" 2>/dev/null; then
    has_dedicated_caddy=1
    break
  fi
done < <(
  find /etc/crowdsec -maxdepth 2 -type f \
    \( -name 'acquis.yaml' -o -path '/etc/crowdsec/acquis.d/*.yaml' \) \
    -print0 2>/dev/null
)

[[ "$has_dedicated_caddy" -eq 1 ]] || \
  die "Не найден выделенный file/docker acquisition с type: caddy"

for managed in sshd.yaml; do
  if [[ -f "$ACQUIS_DIR/$managed" ]]; then
    cp -a "$ACQUIS_DIR/$managed" "$BACKUP_DIR/$managed"
  else
    : >"$BACKUP_DIR/$managed.missing"
  fi
done

rollback() {
  local rc=$?
  trap - ERR
  log "Откатываю изменения acquisition после ошибки"

  rm -f "$SSHD_ACQUIS"
  if [[ -f "$BACKUP_DIR/sshd.yaml" ]]; then
    cp -a "$BACKUP_DIR/sshd.yaml" "$SSHD_ACQUIS"
  fi

  for name in setup.caddy.yaml setup.linux.yaml; do
    if [[ -f "$BACKUP_DIR/$name" ]]; then
      mv -f "$BACKUP_DIR/$name" "$ACQUIS_DIR/$name"
    fi
  done

  crowdsec -t >/dev/null 2>&1 || true
  systemctl restart crowdsec >/dev/null 2>&1 || true
  exit "$rc"
}
trap rollback ERR

quarantine() {
  local name="$1" reason="$2" src="$ACQUIS_DIR/$1"
  [[ -f "$src" ]] || return 0
  log "Отключаю generated acquisition $name: $reason"
  mv "$src" "$BACKUP_DIR/$name"
}

if [[ -f "$ACQUIS_DIR/setup.caddy.yaml" ]] && \
   grep -Eq 'source:[[:space:]]*journalctl' "$ACQUIS_DIR/setup.caddy.yaml" && \
   grep -Fq 'caddy.service' "$ACQUIS_DIR/setup.caddy.yaml"; then
  quarantine \
    setup.caddy.yaml \
    "выделенный access log уже настроен; operational journal Caddy исключается"
fi

if [[ -f "$ACQUIS_DIR/setup.linux.yaml" ]] && \
   grep -Eq '/var/log/(syslog|messages)' "$ACQUIS_DIR/setup.linux.yaml"; then
  quarantine \
    setup.linux.yaml \
    "generic syslog/messages может повторно содержать operational log Caddy"
fi

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
    echo "[caddy-acquisitions] ERROR: после отключения setup.linux.yaml не найден SSH log source" >&2
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
  if grep -Eq 'source:[[:space:]]*journalctl' "$file" 2>/dev/null && \
     grep -Fq 'caddy.service' "$file" 2>/dev/null; then
    remaining_bad+=("$file (journalctl caddy.service)")
  fi
  if grep -Eq '/var/log/(syslog|messages)' "$file" 2>/dev/null; then
    remaining_bad+=("$file (generic syslog/messages)")
  fi
done < <(
  find /etc/crowdsec -maxdepth 2 -type f \
    \( -name 'acquis.yaml' -o -path '/etc/crowdsec/acquis.d/*.yaml' \) \
    -print0 2>/dev/null
)

if (( ${#remaining_bad[@]} > 0 )); then
  printf '[caddy-acquisitions] ERROR: остаются источники operational log Caddy:\n' >&2
  printf '  %s\n' "${remaining_bad[@]}" >&2
  false
fi

crowdsec -t
systemctl enable crowdsec >/dev/null
systemctl restart crowdsec
systemctl is-active --quiet crowdsec

trap - ERR

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
  -printf '%T@ %p\n' | sort -nr | awk 'NR>20 {print $2}' | xargs -r rm -rf

log "Готово: CrowdSec использует выделенные Caddy access acquisitions"
log "Generated journal/syslog acquisitions сохранены в $BACKUP_DIR, если существовали"
