#!/usr/bin/env bash
set -u

ok()       { printf '[OK]       %s\n' "$*"; }
info()     { printf '[INFO]     %s\n' "$*"; }
warn()     { printf '[WARN]     %s\n' "$*"; }
critical() { printf '[CRITICAL] %s\n' "$*"; }

printf '\n=== CrowdSec: acquisition для CDN Origin ===\n'

if [[ ! -f /etc/cdn-trusted-proxies.conf && \
      ! -d /etc/caddy/trusted-proxies.d ]]; then
  info 'Признаки профиля CDN Origin не найдены — проверка пропущена'
  exit 0
fi

if ! command -v cscli >/dev/null 2>&1 || [[ ! -d /etc/crowdsec ]]; then
  critical 'Профиль CDN Origin найден, но CrowdSec не установлен'
  exit 0
fi

files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done < <(
  find /etc/crowdsec -maxdepth 2 -type f \
    \( -name 'acquis.yaml' -o -path '/etc/crowdsec/acquis.d/*.yaml' \) \
    -print0 2>/dev/null
)

if (( ${#files[@]} == 0 )); then
  critical 'Не найдено ни одного acquisition-файла CrowdSec'
  exit 0
fi

caddy_access=()
caddy_journal=()
generic_syslog=()

for file in "${files[@]}"; do
  if grep -Fq '/var/log/caddy/access.log' "$file" 2>/dev/null; then
    caddy_access+=("$file")
  fi

  if grep -Eq 'source:[[:space:]]*journalctl' "$file" 2>/dev/null && \
     grep -Fq 'caddy.service' "$file" 2>/dev/null; then
    caddy_journal+=("$file")
  fi

  if grep -Eq '/var/log/(syslog|messages)' "$file" 2>/dev/null; then
    generic_syslog+=("$file")
  fi
done

case ${#caddy_access[@]} in
  0)
    critical 'Не настроен file acquisition /var/log/caddy/access.log'
    ;;
  1)
    ok "Caddy access log читается один раз: ${caddy_access[0]}"
    ;;
  *)
    critical "Caddy access log читается несколькими acquisition-файлами: ${caddy_access[*]}"
    ;;
esac

if (( ${#caddy_journal[@]} == 0 )); then
  ok 'journalctl caddy.service не подключён к CrowdSec'
else
  critical "Operational log Caddy подключён через journalctl: ${caddy_journal[*]}"
fi

if (( ${#generic_syslog[@]} == 0 )); then
  ok 'Общий /var/log/syslog или /var/log/messages не подключён'
else
  warn "Общий syslog может повторно подавать сообщения Caddy: ${generic_syslog[*]}"
fi

if command -v systemctl >/dev/null 2>&1 && \
   systemctl is-active --quiet crowdsec-cdn-allowlist-sync.path 2>/dev/null; then
  ok 'Автоматическая синхронизация CrowdSec CDN allowlist активна'
else
  warn 'crowdsec-cdn-allowlist-sync.path не активен'
fi

if [[ -x /usr/local/sbin/sync-crowdsec-cdn-allowlist ]]; then
  ok 'Скрипт синхронизации CDN allowlist установлен'
else
  warn 'Скрипт синхронизации CDN allowlist не установлен'
fi

metrics="$(cscli metrics show acquisition 2>/dev/null || true)"
if [[ -n "$metrics" ]]; then
  if grep -Fq '_SYSTEMD_UNIT=caddy.service' <<<"$metrics"; then
    critical 'Runtime-метрики подтверждают чтение journalctl caddy.service'
  fi
  if grep -Eq 'file:/var/log/(syslog|messages)' <<<"$metrics"; then
    warn 'Runtime-метрики подтверждают чтение общего syslog/messages'
  fi
  if grep -Fq 'file:/var/log/caddy/access.log' <<<"$metrics"; then
    ok 'Runtime-метрики видят /var/log/caddy/access.log'
  else
    warn 'В runtime-метриках пока нет /var/log/caddy/access.log'
  fi
fi

printf '\nОжидаемая схема CDN Origin:\n'
printf '  Caddy access log -> CrowdSec parser\n'
printf '  Caddy operational journal -> не подключён\n'
printf '  VPN/XHTTP handle с log_skip -> не попадает в access log\n'
