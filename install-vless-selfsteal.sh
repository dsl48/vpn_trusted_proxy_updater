#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите через sudo" >&2
  exit 1
}

log() {
  printf '[vless-selfsteal] %s\n' "$*"
}

die() {
  printf '[vless-selfsteal] ERROR: %s\n' "$*" >&2
  exit 1
}

command -v apt-get >/dev/null 2>&1 || die "Поддерживаются Debian/Ubuntu"
command -v caddy >/dev/null 2>&1 || die "Caddy должен быть установлен заранее"
command -v systemctl >/dev/null 2>&1 || die "Не найден systemctl"
[[ -f /etc/caddy/Caddyfile ]] || die "Не найден /etc/caddy/Caddyfile"
getent passwd caddy >/dev/null 2>&1 || die "Не найден пользователь caddy"
systemctl is-active --quiet caddy || die "Сервис caddy не запущен"

printf '\nУстановка CrowdSec для прямой ноды VLESS + selfsteal на Caddy.\n'
printf 'Укажите адрес сайта из заголовка site block в /etc/caddy/Caddyfile.\n'
read -r -p "Домен/адрес selfsteal-сайта: " SELFSTEAL_SITE
SELFSTEAL_SITE="$(printf '%s' "$SELFSTEAL_SITE" | tr -d '[:space:]')"
[[ -n "$SELFSTEAL_SITE" ]] || die "Домен/адрес selfsteal-сайта не задан"

SSH_ADMIN_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  SSH_ADMIN_IP="${SSH_CONNECTION%% *}"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
  SSH_ADMIN_IP="${SSH_CLIENT%% *}"
fi

printf '\nIP текущего SSH-подключения: %s\n' "${SSH_ADMIN_IP:-не определён}"
read -r -p "Дополнительные доверенные IP через пробел или запятую [нет]: " EXTRA_ADMIN_IPS
export DEBIAN_FRONTEND=noninteractive
log "Устанавливаю зависимости"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl jq python3 util-linux iproute2 gnupg apt-transport-https

ADMIN_IPS="$(python3 - "$SSH_ADMIN_IP" "$EXTRA_ADMIN_IPS" <<'PY'
import ipaddress
import re
import sys

values = []
for source in sys.argv[1:]:
    for value in re.split(r'[\s,;]+', source.strip()):
        if not value:
            continue
        try:
            parsed = ipaddress.ip_address(value)
        except ValueError as exc:
            raise SystemExit(f'Некорректный административный IP {value!r}: {exc}')
        normalized = str(parsed)
        if normalized not in values:
            values.append(normalized)
print(' '.join(values))
PY
)" || die "Не удалось проверить административные IP"
if ! command -v cscli >/dev/null 2>&1; then
  log "Добавляю официальный репозиторий CrowdSec"
  tmp_repo="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 15 https://install.crowdsec.net -o "$tmp_repo"
  sh "$tmp_repo"
  rm -f "$tmp_repo"
fi

cat >/etc/apt/preferences.d/crowdsec <<'EOF_PIN'
Package: *
Pin: release o=packagecloud.io/crowdsec/crowdsec,a=any,n=any,c=main
Pin-Priority: 1001
EOF_PIN

apt-get update
log "Устанавливаю CrowdSec Security Engine"
apt-get install -y crowdsec

log "Устанавливаю коллекции Linux, SSH и Caddy"
cscli hub update
for collection in \
  crowdsecurity/linux \
  crowdsecurity/sshd \
  crowdsecurity/caddy \
  crowdsecurity/base-http-scenarios \
  crowdsecurity/http-cve \
  crowdsecurity/whitelist-good-actors; do
  cscli collections install "$collection" >/dev/null
done

CADDYFILE=/etc/caddy/Caddyfile
LOG_DIR=/var/log/caddy
ACCESS_LOG="$LOG_DIR/selfsteal-access.log"
BACKUP_DIR="/var/lib/crowdsec/vless-selfsteal-backups/$(date +%Y%m%d-%H%M%S)"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile"

log "Настраиваю отдельный JSON access log для selfsteal-сайта"
install -d -o caddy -g caddy -m 0750 "$LOG_DIR"
touch "$ACCESS_LOG"
chown caddy:caddy "$ACCESS_LOG"
chmod 0640 "$ACCESS_LOG"

python3 - "$CADDYFILE" "$SELFSTEAL_SITE" "$ACCESS_LOG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
selector = sys.argv[2]
log_path = sys.argv[3]
start_marker = '# BEGIN CROWDSEC VLESS SELFSTEAL LOG'
end_marker = '# END CROWDSEC VLESS SELFSTEAL LOG'
text = path.read_text(encoding='utf-8')
lines = text.splitlines(keepends=True)

def brace_delta(line: str) -> int:
    delta = 0
    quote = None
    escaped = False
    for char in line:
        if escaped:
            escaped = False
            continue
        if char == '\\' and quote is not None:
            escaped = True
            continue
        if quote is not None:
            if char == quote:
                quote = None
            continue
        if char in {'"', "'", '`'}:
            quote = char
            continue
        if char == '#':
            break
        if char == '{':
            delta += 1
        elif char == '}':
            delta -= 1
    return delta

def normalize(token: str) -> str:
    token = token.strip().strip(',')
    token = re.sub(r'^https?://', '', token, flags=re.I)
    if token.startswith('['):
        end = token.find(']')
        if end != -1:
            return token[1:end]
    if token.count(':') == 1:
        host, port = token.rsplit(':', 1)
        if port.isdigit():
            token = host
    return token.rstrip('.')

selector_norm = normalize(selector)
depth = 0
blocks = []
for index, line in enumerate(lines):
    before = depth
    delta = brace_delta(line)
    if before == 0 and delta > 0:
        header = line.split('{', 1)[0].strip()
        if header and not header.startswith('('):
            tokens = [normalize(item) for item in re.split(r'[\s,]+', header) if item]
            if selector_norm in tokens:
                target_depth = before + delta
                running = target_depth
                end_index = None
                for cursor in range(index + 1, len(lines)):
                    running += brace_delta(lines[cursor])
                    if running == 0:
                        end_index = cursor
                        break
                if end_index is None:
                    raise SystemExit('Не найдена закрывающая скобка site block')
                blocks.append((index, end_index))
    depth += delta

if len(blocks) != 1:
    raise SystemExit(
        f'Для {selector!r} ожидался один site block, найдено {len(blocks)}. '
        'Укажите адрес точно так, как он написан перед фигурной скобкой.'
    )

start, end = blocks[0]
managed_start = managed_end = None
for index in range(start + 1, end):
    if start_marker in lines[index]:
        managed_start = index
    if managed_start is not None and end_marker in lines[index]:
        managed_end = index
        break
if (managed_start is None) != (managed_end is None):
    raise SystemExit('Найден повреждённый управляемый блок CrowdSec в Caddyfile')
if managed_start is not None:
    del lines[managed_start:managed_end + 1]
    end -= managed_end - managed_start + 1

closing_indent = re.match(r'\s*', lines[end]).group(0)
indent = closing_indent + '    '
block = [
    f'{indent}{start_marker}\n',
    f'{indent}log crowdsec_selfsteal {{\n',
    f'{indent}    output file {log_path} {{\n',
    f'{indent}        mode 0640\n',
    f'{indent}        roll_size 50MiB\n',
    f'{indent}        roll_keep 10\n',
    f'{indent}        roll_keep_for 720h\n',
    f'{indent}    }}\n',
    f'{indent}    format json\n',
    f'{indent}}}\n',
    f'{indent}{end_marker}\n',
]
lines[end:end] = block
new_path = path.with_name(path.name + '.crowdsec-new')
new_path.write_text(''.join(lines), encoding='utf-8')
new_path.chmod(path.stat().st_mode & 0o777)
new_path.replace(path)
PY

rollback_caddy() {
  log "Откатываю Caddyfile"
  cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || true
  systemctl reload caddy >/dev/null 2>&1 || true
}

if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
  rollback_caddy
  die "Caddy не принял конфигурацию access log"
fi

if ! systemctl reload caddy; then
  rollback_caddy
  die "Не удалось выполнить graceful reload Caddy"
fi
systemctl is-active --quiet caddy || {
  rollback_caddy
  die "Caddy не активен после reload"
}

log "Подключаю Caddy JSON log к CrowdSec"
install -d -o root -g root -m 0755 /etc/crowdsec/acquis.d
cat >/etc/crowdsec/acquis.d/caddy-selfsteal.yaml <<EOF_ACQUIS
filenames:
  - $ACCESS_LOG
labels:
  type: caddy
EOF_ACQUIS
chown root:root /etc/crowdsec/acquis.d/caddy-selfsteal.yaml
chmod 0644 /etc/crowdsec/acquis.d/caddy-selfsteal.yaml

log "Проверяю и перезапускаю CrowdSec"
crowdsec -t
systemctl enable crowdsec >/dev/null
systemctl restart crowdsec
systemctl is-active --quiet crowdsec || {
  journalctl -u crowdsec -n 120 --no-pager -l >&2 || true
  die "CrowdSec не запустился"
}

if [[ -n "$ADMIN_IPS" ]]; then
  ALLOWLIST_NAME="vless-selfsteal-admins"
  if ! cscli allowlists inspect "$ALLOWLIST_NAME" >/dev/null 2>&1; then
    cscli allowlists create "$ALLOWLIST_NAME" \
      -d "Administrative IPs for VLESS selfsteal node" >/dev/null
  fi

  for admin_ip in $ADMIN_IPS; do
    ADD_OUTPUT=""
    if ! ADD_OUTPUT="$(cscli allowlists add "$ALLOWLIST_NAME" "$admin_ip" \
      -d "Trusted administrator" 2>&1)"; then
      if grep -qiE 'already|exist|duplicate' <<<"$ADD_OUTPUT"; then
        log "Административный IP уже в AllowList: $admin_ip"
      else
        printf '%s\n' "$ADD_OUTPUT" >&2
        die "Не удалось добавить $admin_ip в AllowList"
      fi
    else
      log "Добавлен административный IP в AllowList: $admin_ip"
    fi
  done
else
  log "Административные IP не заданы; AllowList не создавался"
fi

printf '\nСостояние порта 443:\n'
ss -lntp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:443([[:space:]]|$)' || \
  printf 'Слушатель TCP/443 не найден. Проверьте Xray/RemnaNode отдельно.\n'

printf '\nAcquisition CrowdSec:\n'
cscli metrics show acquisition 2>/dev/null || true

cat <<DONE

Базовая настройка VLESS + selfsteal завершена.
Selfsteal site: $SELFSTEAL_SITE
Caddy JSON log: $ACCESS_LOG
Acquisition: /etc/crowdsec/acquis.d/caddy-selfsteal.yaml
Резервная копия Caddyfile: $BACKUP_DIR/Caddyfile
Следующий этап: firewall bouncer с решениями SSH + HTTP.
DONE
