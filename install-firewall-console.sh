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
command -v python3 >/dev/null 2>&1 || die "Не найден python3"
systemctl is-active --quiet crowdsec || die "Сервис crowdsec не запущен"

# Переносим Local API с часто используемого 8080 на редкий loopback-порт.
LAPI_HOST="127.0.0.1"
LAPI_PORT="${CROWDSEC_LAPI_PORT:-18888}"
[[ "$LAPI_PORT" =~ ^[0-9]+$ ]] || die "Некорректный CROWDSEC_LAPI_PORT: $LAPI_PORT"
(( LAPI_PORT >= 1024 && LAPI_PORT <= 65535 )) || \
  die "Порт CrowdSec Local API должен быть в диапазоне 1024-65535"

LAPI_LISTEN="${LAPI_HOST}:${LAPI_PORT}"
LAPI_CREDENTIALS_URL="http://${LAPI_LISTEN}"
LAPI_URL="${LAPI_CREDENTIALS_URL}/"
CROWDSEC_CONFIG="/etc/crowdsec/config.yaml"
LAPI_CREDENTIALS="/etc/crowdsec/local_api_credentials.yaml"

[[ -f "$CROWDSEC_CONFIG" ]] || die "Не найден $CROWDSEC_CONFIG"
[[ -f "$LAPI_CREDENTIALS" ]] || die "Не найден $LAPI_CREDENTIALS"

CURRENT_LISTEN="$(
  awk '
    /^[[:space:]]*listen_uri:[[:space:]]*/ {
      sub(/^[[:space:]]*listen_uri:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*/, "")
      gsub(/["'"'"'[:space:]]/, "")
      print
      exit
    }
  ' "$CROWDSEC_CONFIG"
)"
[[ -n "$CURRENT_LISTEN" ]] || die "Не найден api.server.listen_uri в $CROWDSEC_CONFIG"

if [[ "$CURRENT_LISTEN" != "$LAPI_LISTEN" ]]; then
  if ! python3 - "$LAPI_HOST" "$LAPI_PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((host, port))
except OSError as exc:
    raise SystemExit(f'порт {host}:{port} занят: {exc}')
finally:
    sock.close()
PY
  then
    die "Нельзя перенести CrowdSec Local API на $LAPI_LISTEN"
  fi
fi

LAPI_BACKUP_DIR="/var/lib/crowdsec/lapi-port-backups/$(date +%Y%m%d-%H%M%S)"
install -d -o root -g root -m 0700 "$LAPI_BACKUP_DIR"
cp -a "$CROWDSEC_CONFIG" "$LAPI_BACKUP_DIR/config.yaml"
cp -a "$LAPI_CREDENTIALS" "$LAPI_BACKUP_DIR/local_api_credentials.yaml"

rollback_lapi() {
  log "Откатываю настройки CrowdSec Local API"
  cp -a "$LAPI_BACKUP_DIR/config.yaml" "$CROWDSEC_CONFIG"
  cp -a "$LAPI_BACKUP_DIR/local_api_credentials.yaml" "$LAPI_CREDENTIALS"
  systemctl restart crowdsec >/dev/null 2>&1 || true
}

log "Настраиваю CrowdSec Local API на $LAPI_LISTEN"
python3 - \
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
    pattern = re.compile(rf'^(\s*{re.escape(key)}\s*:\s*).*$',
                         flags=re.MULTILINE)
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f'{path}: ожидалась одна строка {key}, найдено {len(matches)}'
        )
    updated = pattern.sub(lambda match: match.group(1) + value, text, count=1)
    tmp = path.with_name(path.name + '.new')
    tmp.write_text(updated, encoding='utf-8')
    tmp.chmod(path.stat().st_mode & 0o777)
    tmp.replace(path)

replace_single(config_path, 'listen_uri', listen_uri)
replace_single(credentials_path, 'url', api_url)
PY

chown root:root "$CROWDSEC_CONFIG" "$LAPI_CREDENTIALS"
chmod 0600 "$LAPI_CREDENTIALS"

if ! systemctl restart crowdsec; then
  rollback_lapi
  die "CrowdSec не запустился после изменения Local API порта"
fi

for _ in {1..30}; do
  if python3 - "$LAPI_HOST" "$LAPI_PORT" <<'PY'
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
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet crowdsec || \
   ! cscli machines list >/dev/null 2>&1; then
  journalctl -u crowdsec -n 100 --no-pager -l >&2 || true
  rollback_lapi
  die "CrowdSec Local API недоступен на $LAPI_LISTEN"
fi

log "CrowdSec Local API работает на $LAPI_LISTEN"
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

BOUNCER_NAME="cdn-origin-firewall-bouncer"
BOUNCER_SERVICE="crowdsec-firewall-bouncer"
BOUNCER_DIR="/etc/crowdsec/bouncers"
BOUNCER_BASE="$BOUNCER_DIR/crowdsec-firewall-bouncer.yaml"
BOUNCER_LOCAL="$BOUNCER_DIR/crowdsec-firewall-bouncer.yaml.local"

# Важно для повторной установки: пакетный postinst запускает сервис сразу.
# Поэтому сначала останавливаем старый процесс и заранее готовим рабочий
# api_url/api_key, а уже потом обновляем пакет.
systemctl stop "$BOUNCER_SERVICE" >/dev/null 2>&1 || true
install -d -o root -g root -m 0700 "$BOUNCER_DIR"

BOUNCER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(36))
PY
)"

cscli bouncers delete "$BOUNCER_NAME" --ignore-missing >/dev/null 2>&1 || true
cscli bouncers add "$BOUNCER_NAME" --key "$BOUNCER_KEY" >/dev/null

cat >"$BOUNCER_LOCAL" <<EOF_CONFIG
api_url: $LAPI_URL
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
unset BOUNCER_KEY

log "Устанавливаю пакет: $BOUNCER_PACKAGE"
export DEBIAN_FRONTEND=noninteractive
APT_INSTALL_FAILED=0
if ! apt-get install -y "$BOUNCER_PACKAGE"; then
  APT_INSTALL_FAILED=1
  log "Пакет сообщил ошибку post-install; запускаю восстановление поверх подготовленной конфигурации"
fi

command -v crowdsec-firewall-bouncer >/dev/null 2>&1 || \
  die "Бинарный файл crowdsec-firewall-bouncer не установлен"
[[ -f "$BOUNCER_BASE" ]] || die "Не найден базовый конфиг $BOUNCER_BASE"

if ! crowdsec-firewall-bouncer -c "$BOUNCER_BASE" -t; then
  die "Итоговая конфигурация firewall bouncer не прошла проверку"
fi

systemctl daemon-reload
systemctl enable "$BOUNCER_SERVICE" >/dev/null
if ! systemctl restart "$BOUNCER_SERVICE"; then
  journalctl -u "$BOUNCER_SERVICE" -n 120 --no-pager -l >&2 || true
  die "Firewall bouncer не запустился после подготовки новой конфигурации"
fi

systemctl is-active --quiet "$BOUNCER_SERVICE" || \
  die "Firewall bouncer не активен"

# Если apt/dpkg ранее оборвался на postinst, теперь сервис уже исправен и
# повторная конфигурация пакета должна завершиться успешно.
DPKG_AUDIT="$(dpkg --audit 2>&1 || true)"
if (( APT_INSTALL_FAILED == 1 )) || [[ -n "${DPKG_AUDIT//[[:space:]]/}" ]]; then
  log "Завершаю прерванную настройку пакетов"
  if ! dpkg --configure -a; then
    log "dpkg --configure -a не завершился; исправляю зависимости через apt-get -f install"
    apt-get -f install -y || die "Не удалось исправить состояние пакетов"
    dpkg --configure -a || die "Не удалось завершить настройку пакетов"
  fi
fi

DPKG_AUDIT="$(dpkg --audit 2>&1 || true)"
if [[ -n "${DPKG_AUDIT//[[:space:]]/}" ]]; then
  printf '%s\n' "$DPKG_AUDIT" >&2
  die "После установки dpkg сообщает о незавершённых пакетах"
fi

# postinst мог перезапустить сервис ещё раз; подтверждаем финальное состояние.
systemctl restart "$BOUNCER_SERVICE"
systemctl is-active --quiet "$BOUNCER_SERVICE" || \
  die "Firewall bouncer не активен после завершения dpkg"

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
    systemctl restart "$BOUNCER_SERVICE"
    systemctl is-active --quiet crowdsec || die "CrowdSec не запустился после enrollment"
    systemctl is-active --quiet "$BOUNCER_SERVICE" || die "Firewall bouncer не запустился после enrollment"
    log "CrowdSec и firewall bouncer перезапущены после enrollment"
  fi
else
  log "Подключение к CrowdSec Console пропущено"
fi

printf '\nПроверка компонентов:\n'
systemctl --no-pager --full status "$BOUNCER_SERVICE" 2>/dev/null | sed -n '1,12p' || true
printf '\nCrowdSec Local API:\n'
printf '%s\n' "$LAPI_URL"
printf '\nЗарегистрированные bouncers:\n'
cscli bouncers list || true
printf '\nНастройки CrowdSec Console:\n'
cscli console status || true

cat <<DONE

Настройка firewall bouncer завершена.
CrowdSec Local API: $LAPI_URL
Backend: $FIREWALL_MODE
Пакет: $BOUNCER_PACKAGE
Фильтр решений: только SSH-сценарии
DONE
