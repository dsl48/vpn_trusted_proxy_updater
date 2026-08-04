#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите через sudo" >&2
  exit 1
}

log() {
  printf '[firewall-console] %s\n' "$*"
}

die() {
  printf '[firewall-console] ERROR: %s\n' "$*" >&2
  exit 1
}

ask_yes_no_default_yes() {
  local prompt="$1" answer
  while true; do
    read -r -p "$prompt [Y/n]: " answer
    answer="${answer:-yes}"
    case "${answer,,}" in
      yes|y) return 0 ;;
      no|n) return 1 ;;
      *) printf 'Введите yes или no.\n' ;;
    esac
  done
}

command -v apt-get >/dev/null 2>&1 || die "Поддерживаются Debian/Ubuntu"
command -v cscli >/dev/null 2>&1 || die "CrowdSec Security Engine не установлен"
systemctl is-active --quiet crowdsec || die "Сервис crowdsec не запущен"

log "Определяю используемый firewall backend"

if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
  log "Не найдены iptables/nftables; устанавливаю iptables для определения backend"
  apt-get update
  apt-get install -y --no-install-recommends iptables
fi

FIREWALL_MODE=""
BOUNCER_PACKAGE=""

if command -v iptables >/dev/null 2>&1; then
  IPTABLES_VERSION="$(iptables -V 2>&1 || true)"
  if grep -qi 'nf_tables' <<<"$IPTABLES_VERSION"; then
    FIREWALL_MODE="nftables"
    BOUNCER_PACKAGE="crowdsec-firewall-bouncer-nftables"
  else
    FIREWALL_MODE="iptables"
    BOUNCER_PACKAGE="crowdsec-firewall-bouncer-iptables"
  fi
elif command -v nft >/dev/null 2>&1; then
  FIREWALL_MODE="nftables"
  BOUNCER_PACKAGE="crowdsec-firewall-bouncer-nftables"
else
  die "Не удалось определить nftables или iptables"
fi

log "Определён backend: $FIREWALL_MODE"
log "Устанавливаю пакет: $BOUNCER_PACKAGE"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get install -y "$BOUNCER_PACKAGE"; then
  log "Пакет сообщил ошибку post-install; проверяю наличие установленного bouncer"
fi

command -v crowdsec-firewall-bouncer >/dev/null 2>&1 || \
  die "Бинарный файл crowdsec-firewall-bouncer не установлен"

systemctl stop crowdsec-firewall-bouncer >/dev/null 2>&1 || true

BOUNCER_NAME="cdn-origin-firewall-bouncer"
BOUNCER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(36))
PY
)"

cscli bouncers delete "$BOUNCER_NAME" --ignore-missing >/dev/null 2>&1 || true
cscli bouncers add "$BOUNCER_NAME" --key "$BOUNCER_KEY" >/dev/null

install -d -o root -g root -m 0700 /etc/crowdsec/bouncers
BOUNCER_BASE=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
BOUNCER_LOCAL=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local

cat >"$BOUNCER_LOCAL" <<EOF_CONFIG
api_url: http://127.0.0.1:8080/
api_key: $BOUNCER_KEY
mode: $FIREWALL_MODE
update_frequency: 10s
scenarios_containing:
  - ssh
scopes:
  - Ip
  - Range
deny_action: DROP
deny_log: false
EOF_CONFIG

if [[ "$FIREWALL_MODE" == "nftables" ]]; then
  cat >>"$BOUNCER_LOCAL" <<'EOF_NFT'
nftables_hooks:
  - input
EOF_NFT
fi

chown root:root "$BOUNCER_LOCAL"
chmod 0600 "$BOUNCER_LOCAL"

if [[ ! -f "$BOUNCER_BASE" ]]; then
  install -o root -g root -m 0600 "$BOUNCER_LOCAL" "$BOUNCER_BASE"
fi

unset BOUNCER_KEY

systemctl daemon-reload
systemctl enable crowdsec-firewall-bouncer >/dev/null
if ! systemctl restart crowdsec-firewall-bouncer; then
  journalctl -u crowdsec-firewall-bouncer -n 100 --no-pager -l >&2 || true
  die "Firewall bouncer не запустился"
fi

systemctl is-active --quiet crowdsec-firewall-bouncer || \
  die "Firewall bouncer не активен"

log "Firewall bouncer установлен и запущен"
log "Применяются только решения SSH-сценариев; HTTP-решения не блокируются на firewall"

if ask_yes_no_default_yes "Подключить CrowdSec к панели app.crowdsec.net?"; then
  cat <<'INFO'

Enrollment key связывает этот Security Engine с вашей учётной записью
в CrowdSec Console. Ключ можно скопировать в app.crowdsec.net:
Security Engines → Add Security Engine.

После выполнения команды сервер появится в панели в статусе ожидания.
Нужно открыть его и нажать «Accept enroll».
INFO

  read -r -s -p "Enroll key: " ENROLL_KEY
  printf '\n'
  ENROLL_KEY="$(printf '%s' "$ENROLL_KEY" | tr -d '[:space:]')"
  [[ -n "$ENROLL_KEY" ]] || die "Enroll key пуст"

  ENROLL_OUTPUT=""
  if ! ENROLL_OUTPUT="$(cscli console enroll "$ENROLL_KEY" 2>&1)"; then
    printf '%s\n' "$ENROLL_OUTPUT" >&2
    if grep -qiE 'already.*enroll|already enrolled' <<<"$ENROLL_OUTPUT"; then
      log "Security Engine уже подключён к CrowdSec Console"
    else
      die "Не удалось выполнить cscli console enroll"
    fi
  else
    printf '%s\n' "$ENROLL_OUTPUT"
    cat <<'ACCEPT'

Откройте app.crowdsec.net → Security Engines и нажмите «Accept enroll».
После подтверждения вернитесь в терминал.
ACCEPT
    read -r -p "После принятия подключения нажмите Enter для перезапуска CrowdSec..." _
    systemctl restart crowdsec
    systemctl is-active --quiet crowdsec || die "CrowdSec не запустился после enrollment"
    log "CrowdSec перезапущен после enrollment"
  fi
else
  log "Подключение к CrowdSec Console пропущено"
fi

printf '\nПроверка компонентов:\n'
systemctl --no-pager --full status crowdsec-firewall-bouncer 2>/dev/null | sed -n '1,12p' || true
printf '\nЗарегистрированные bouncers:\n'
cscli bouncers list || true
printf '\nНастройки CrowdSec Console:\n'
cscli console status || true

cat <<DONE

Настройка firewall bouncer завершена.
Backend: $FIREWALL_MODE
Пакет: $BOUNCER_PACKAGE
Фильтр решений: только SSH-сценарии
DONE
