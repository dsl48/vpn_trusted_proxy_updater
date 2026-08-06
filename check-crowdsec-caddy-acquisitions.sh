#!/usr/bin/env bash
set -u

ok()       { printf '[OK]       %s\n' "$*"; }
info()     { printf '[INFO]     %s\n' "$*"; }
warn()     { printf '[WARN]     %s\n' "$*"; }
critical() { printf '[CRITICAL] %s\n' "$*"; }

printf '\n=== CrowdSec: выделенные Caddy acquisitions ===\n'

cdn_profile=0
panel_profile=0
selfsteal_profile=0
[[ -f /etc/cdn-trusted-proxies.conf || -d /etc/caddy/trusted-proxies.d ]] && cdn_profile=1
[[ -f /etc/crowdsec/remnawave-panel-profile.env ]] && panel_profile=1
[[ -f /etc/crowdsec/acquis.d/caddy-selfsteal.yaml ]] && selfsteal_profile=1

if ! command -v cscli >/dev/null 2>&1 || [[ ! -d /etc/crowdsec ]]; then
  if (( cdn_profile == 1 || panel_profile == 1 || selfsteal_profile == 1 )); then
    critical 'Профиль с Caddy найден, но CrowdSec не установлен'
  else
    info 'CrowdSec не установлен — проверка пропущена'
  fi
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

dedicated_caddy=()
caddy_journal=()
generic_syslog=()
cdn_access=()

for file in "${files[@]}"; do
  if [[ "$file" != /etc/crowdsec/acquis.d/setup.caddy.yaml ]] && \
     grep -Eq 'type:[[:space:]]*caddy([[:space:]]|$)' "$file" 2>/dev/null; then
    dedicated_caddy+=("$file")
  fi

  if grep -Fq '/var/log/caddy/access.log' "$file" 2>/dev/null; then
    cdn_access+=("$file")
  fi

  if grep -Eq 'source:[[:space:]]*journalctl' "$file" 2>/dev/null && \
     grep -Fq 'caddy.service' "$file" 2>/dev/null; then
    caddy_journal+=("$file")
  fi

  if grep -Eq '/var/log/(syslog|messages)' "$file" 2>/dev/null; then
    generic_syslog+=("$file")
  fi
done

if (( ${#dedicated_caddy[@]} == 0 )); then
  if (( cdn_profile == 1 || panel_profile == 1 || selfsteal_profile == 1 )); then
    critical 'Профиль Caddy найден, но выделенный acquisition с type: caddy отсутствует'
  else
    info 'Выделенные Caddy acquisitions не настроены — проверка не применяется'
    exit 0
  fi
else
  ok "Выделенные Caddy acquisitions: ${dedicated_caddy[*]}"
fi

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

if (( cdn_profile == 1 )); then
  case ${#cdn_access[@]} in
    0)
      critical 'CDN Origin: не настроен /var/log/caddy/access.log'
      ;;
    1)
      ok "CDN Origin: access log читается один раз: ${cdn_access[0]}"
      ;;
    *)
      critical "CDN Origin: access log читается несколькими файлами: ${cdn_access[*]}"
      ;;
  esac

  if command -v systemctl >/dev/null 2>&1 && \
     systemctl is-active --quiet crowdsec-cdn-allowlist-sync.path 2>/dev/null; then
    ok 'CDN Origin: автоматическая синхронизация CrowdSec allowlist активна'
  else
    warn 'CDN Origin: crowdsec-cdn-allowlist-sync.path не активен'
  fi

  if [[ -x /usr/local/sbin/sync-crowdsec-cdn-allowlist ]]; then
    ok 'CDN Origin: скрипт синхронизации allowlist установлен'
  else
    warn 'CDN Origin: скрипт синхронизации allowlist не установлен'
  fi
fi

if (( panel_profile == 1 )); then
  if grep -RqsF '/var/log/caddy/remnawave-panel-access.log' \
      /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d 2>/dev/null; then
    ok 'Remnawave Panel: выделенный access log подключён'
  else
    profile_log="$(awk -F= '$1=="CROWDSEC_PANEL_LOG" {sub(/^[^=]*=/, ""); print; exit}' \
      /etc/crowdsec/remnawave-panel-profile.env 2>/dev/null || true)"
    [[ -n "$profile_log" ]] && \
      info "Remnawave Panel использует нестандартный путь: $profile_log"
  fi
fi

if (( selfsteal_profile == 1 )); then
  ok 'VLESS selfsteal: caddy-selfsteal.yaml присутствует'
fi

metrics="$(cscli metrics show acquisition 2>/dev/null || true)"
if [[ -n "$metrics" ]]; then
  if grep -Fq '_SYSTEMD_UNIT=caddy.service' <<<"$metrics"; then
    critical 'Runtime-метрики подтверждают чтение journalctl caddy.service'
  fi
  if grep -Eq 'file:/var/log/(syslog|messages)' <<<"$metrics"; then
    warn 'Runtime-метрики подтверждают чтение общего syslog/messages'
  fi
  if grep -Fq '/var/log/caddy/' <<<"$metrics" || \
     grep -Fq 'docker:' <<<"$metrics"; then
    ok 'Runtime-метрики видят выделенный Caddy datasource'
  else
    warn 'В runtime-метриках пока нет выделенного Caddy datasource'
  fi
fi

printf '\nОжидаемая схема:\n'
printf '  выделенный file/docker access log -> type: caddy -> CrowdSec\n'
printf '  Caddy operational journal          -> не подключён\n'
printf '  generic syslog/messages             -> не подключён\n'
