#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запустите через sudo" >&2; exit 1; }

log(){ printf '[installer] %s\n' "$*"; }
die(){ printf '[installer] ERROR: %s\n' "$*" >&2; exit 1; }

ask_yes_no() {
  local prompt="$1" answer
  while true; do
    read -r -p "$prompt [да/нет]: " answer
    case "${answer,,}" in
      да|д|yes|y) return 0 ;;
      нет|н|no|n) return 1 ;;
      *) printf 'Введите «да» или «нет».\n' ;;
    esac
  done
}

command -v apt-get >/dev/null || die "Поддерживаются Debian/Ubuntu"
command -v caddy >/dev/null || die "Caddy должен быть установлен заранее"
[[ -f /etc/caddy/Caddyfile ]] || die "Не найден /etc/caddy/Caddyfile"
getent passwd caddy >/dev/null || die "Не найден пользователь caddy"

USE_YANDEX=0
USE_BEELINE=0

printf '\nВыберите CDN-провайдеров, чьи адреса будут доверенными для Caddy.\n'
if ask_yes_no "Собирать списки с Яндекс CDN?"; then
  USE_YANDEX=1
fi
if ask_yes_no "Собирать списки с Билайн CDN?"; then
  USE_BEELINE=1
fi

[[ "$USE_YANDEX" -eq 1 || "$USE_BEELINE" -eq 1 ]] || \
  die "Не выбран ни один CDN-провайдер"

BEELINE_USER=""
BEELINE_PASSWORD=""
if [[ "$USE_BEELINE" -eq 1 ]]; then
  cat <<'INFO'

Для получения актуального списка узлов Beeline CDN нужна учётная запись
личного кабинета Beeline CDN. Она используется только локально для получения
временного API-токена и запроса официального списка CDN-адресов.
Данные сохраняются в /etc/cdn-trusted-proxies.conf с правами 0600 root:root.
INFO
  read -r -p "Email Beeline CDN: " BEELINE_USER
  read -r -s -p "Пароль Beeline CDN: " BEELINE_PASSWORD
  printf '\n'
  [[ -n "$BEELINE_USER" && -n "$BEELINE_PASSWORD" ]] || \
    die "Email или пароль Beeline CDN пуст"
fi

export DEBIAN_FRONTEND=noninteractive
log "Устанавливаю зависимости"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl jq python3 util-linux gnupg apt-transport-https

if ! command -v cscli >/dev/null 2>&1; then
  log "Добавляю официальный репозиторий CrowdSec"
  tmp_repo="$(mktemp)"
  curl -fsSL https://install.crowdsec.net -o "$tmp_repo"
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

log "Устанавливаю коллекции CrowdSec"
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

log "Настраиваю права Caddy access log"
install -d -o caddy -g caddy -m 0750 /var/log/caddy
touch /var/log/caddy/access.log
chown caddy:caddy /var/log/caddy/access.log
chmod 0640 /var/log/caddy/access.log
find /var/log/caddy -maxdepth 1 -type f \
  \( -name 'access.log' -o -name 'access-*.log' -o -name 'access-*.log.gz' \) \
  -exec chown caddy:caddy {} + -exec chmod 0640 {} + 2>/dev/null || true

CROWDSEC_SERVICE_USER="$(systemctl show crowdsec.service -p User --value 2>/dev/null || true)"
if [[ -n "$CROWDSEC_SERVICE_USER" && "$CROWDSEC_SERVICE_USER" != root ]] && \
   getent passwd "$CROWDSEC_SERVICE_USER" >/dev/null; then
  usermod -aG caddy "$CROWDSEC_SERVICE_USER"
fi

install -d -m 0755 /etc/crowdsec/acquis.d
if ! grep -RqsF '/var/log/caddy/access.log' \
  /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d 2>/dev/null; then
  cat >/etc/crowdsec/acquis.d/caddy.yaml <<'EOF_ACQUIS'
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
EOF_ACQUIS
  chmod 0644 /etc/crowdsec/acquis.d/caddy.yaml
else
  log "Caddy acquisition уже существует — второй не создаю"
fi

crowdsec -t
systemctl enable --now crowdsec
systemctl restart crowdsec
systemctl is-active --quiet crowdsec || die "CrowdSec не запустился"

{
  printf 'USE_YANDEX=%q\n' "$USE_YANDEX"
  printf 'USE_BEELINE=%q\n' "$USE_BEELINE"
  if [[ "$USE_BEELINE" -eq 1 ]]; then
    printf 'BEELINE_USER=%q\n' "$BEELINE_USER"
    printf 'BEELINE_PASSWORD=%q\n' "$BEELINE_PASSWORD"
  fi
} >/etc/cdn-trusted-proxies.conf
chown root:root /etc/cdn-trusted-proxies.conf
chmod 0600 /etc/cdn-trusted-proxies.conf
unset BEELINE_PASSWORD

cat >/usr/local/sbin/update-cdn-trusted-proxies <<'UPDATER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source /etc/cdn-trusted-proxies.conf

: "${USE_YANDEX:=0}"
: "${USE_BEELINE:=0}"
[[ "$USE_YANDEX" == 1 || "$USE_BEELINE" == 1 ]] || {
  echo "[cdn-proxies] ERROR: не выбран ни один CDN-провайдер" >&2
  exit 1
}

TRUST_DIR=/etc/caddy/trusted-proxies.d
COMBINED=/etc/caddy/trusted-proxies.caddy
STATE=/var/lib/cdn-trusted-proxies
CADDYFILE=/etc/caddy/Caddyfile
install -d -m 0755 "$TRUST_DIR"
install -d -m 0700 "$STATE" "$STATE/backups"
work="$(mktemp -d "$STATE/run.XXXXXX")"
trap 'rm -rf "$work"' EXIT
exec 9>"$STATE/update.lock"
flock -n 9 || exit 0

log(){ printf '[cdn-proxies] %s\n' "$*"; }
die(){ printf '[cdn-proxies] ERROR: %s\n' "$*" >&2; exit 1; }

canonicalize_plain_list() {
  local src="$1" dst="$2" provider="$3"
  python3 - "$src" "$dst" "$provider" <<'PY'
import ipaddress
import pathlib
import sys

src, dst, provider = sys.argv[1:]
nets = set()
for line in pathlib.Path(src).read_text(encoding='utf-8', errors='ignore').splitlines():
    value = line.strip().strip('[](),;\"\'')
    if not value or value.startswith('#'):
        continue
    try:
        net = ipaddress.ip_network(value, strict=False)
    except ValueError as exc:
        raise SystemExit(f'{provider}: некорректный CIDR {value!r}: {exc}')
    addr = net.network_address
    if (addr.is_private or addr.is_loopback or addr.is_link_local
            or addr.is_multicast or addr.is_unspecified):
        raise SystemExit(f'{provider}: запрещён непубличный диапазон {net}')
    if net.version == 4 and net.prefixlen < 8:
        raise SystemExit(f'{provider}: подозрительно широкий диапазон {net}')
    if net.version == 6 and net.prefixlen < 16:
        raise SystemExit(f'{provider}: подозрительно широкий диапазон {net}')
    nets.add(net)
if len(nets) < 20:
    raise SystemExit(f'{provider}: подозрительно короткий список: {len(nets)}')
key = lambda n: (n.version, int(n.network_address), n.prefixlen)
pathlib.Path(dst).write_text(
    ''.join(f'{net}\n' for net in sorted(nets, key=key)),
    encoding='utf-8',
)
PY
}

selected_files=()

if [[ "$USE_YANDEX" == 1 ]]; then
  log "Получаю официальный список Yandex CDN"
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 90 \
    https://tech.cdn.yandex.net/prefixes/yc.json \
    -o "$work/yandex.json"
  jq -er '.prefixes[]' "$work/yandex.json" >"$work/yandex.raw"
  canonicalize_plain_list \
    "$work/yandex.raw" "$work/yandex.cidr" "Yandex CDN"
  selected_files+=("$work/yandex.cidr")
fi

if [[ "$USE_BEELINE" == 1 ]]; then
  : "${BEELINE_USER:?Не задан BEELINE_USER}"
  : "${BEELINE_PASSWORD:?Не задан BEELINE_PASSWORD}"
  log "Получаю временный API-токен Beeline CDN"
  token_json="$work/token.json"
  code="$(curl -k -sS --retry 2 --connect-timeout 15 --max-time 60 \
    -o "$token_json" -w '%{http_code}' \
    --data-urlencode "username=$BEELINE_USER" \
    --data-urlencode "password=$BEELINE_PASSWORD" \
    https://api.cdn.beeline.ru/app/oauth/v1/token/)"
  [[ "$code" == 200 ]] || die "Beeline OAuth HTTP $code"
  token="$(jq -er '.token' "$token_json")"

  code="$(curl -k -sS --retry 2 --connect-timeout 15 --max-time 90 \
    -o "$work/beeline.json" -w '%{http_code}' \
    -H "CDN-AUTH-TOKEN: $token" \
    -H 'Accept: application/json' \
    https://api.cdn.beeline.ru/app/nodes/v2/ip2origin/)"
  unset token
  [[ "$code" == 200 ]] || die "Beeline nodes API HTTP $code"

  python3 - "$work/beeline.json" "$work/beeline.raw" <<'PY'
import json
import pathlib
import re
import sys

src, dst = sys.argv[1:]
obj = json.loads(pathlib.Path(src).read_text(encoding='utf-8'))
texts = []
def walk(value):
    if isinstance(value, str):
        texts.append(value)
    elif isinstance(value, dict):
        for key, item in value.items():
            texts.append(str(key))
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)
walk(obj)
pattern = re.compile(
    r'(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}'
    r'(?:/[0-9]{1,2})?(?![0-9.])'
)
values = []
for text in texts:
    values.extend(pattern.findall(text))
with pathlib.Path(dst).open('w', encoding='utf-8') as handle:
    for value in values:
        handle.write((value if '/' in value else value + '/32') + '\n')
PY
  canonicalize_plain_list \
    "$work/beeline.raw" "$work/beeline.cidr" "Beeline CDN"
  selected_files+=("$work/beeline.cidr")
fi

python3 - "$work/combined.caddy" "${selected_files[@]}" <<'PY'
import ipaddress
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
nets = set()
for name in sys.argv[2:]:
    for line in pathlib.Path(name).read_text(encoding='utf-8').splitlines():
        nets.add(ipaddress.ip_network(line.strip(), strict=False))
if not nets:
    raise SystemExit('Нет диапазонов для объединения')
key = lambda n: (n.version, int(n.network_address), n.prefixlen)
out.write_text(
    '# Generated automatically. Do not edit.\n'
    + 'trusted_proxies static '
    + ' '.join(str(net) for net in sorted(nets, key=key))
    + '\n',
    encoding='utf-8',
)
PY

stamp="$(date +%Y%m%d-%H%M%S)"
backup="$STATE/backups/$stamp"
install -d -m 0700 "$backup"
for file in yandex.cidr beeline.cidr; do
  if [[ -f "$TRUST_DIR/$file" ]]; then
    cp -a "$TRUST_DIR/$file" "$backup/$file"
  else
    : >"$backup/$file.missing"
  fi
done
if [[ -f "$COMBINED" ]]; then
  cp -a "$COMBINED" "$backup/trusted-proxies.caddy"
else
  : >"$backup/trusted-proxies.caddy.missing"
fi

restore_file() {
  local dst="$1" name="$2"
  if [[ -f "$backup/$name" ]]; then
    install -o root -g root -m 0644 "$backup/$name" "$dst"
  elif [[ -f "$backup/$name.missing" ]]; then
    rm -f "$dst"
  fi
}

rollback() {
  log "Откатываю файлы доверенных диапазонов"
  restore_file "$TRUST_DIR/yandex.cidr" yandex.cidr
  restore_file "$TRUST_DIR/beeline.cidr" beeline.cidr
  restore_file "$COMBINED" trusted-proxies.caddy
}

changed=0
if [[ "$USE_YANDEX" == 1 ]]; then
  if [[ ! -f "$TRUST_DIR/yandex.cidr" ]] || \
     ! cmp -s "$work/yandex.cidr" "$TRUST_DIR/yandex.cidr"; then
    install -o root -g root -m 0644 \
      "$work/yandex.cidr" "$TRUST_DIR/yandex.cidr"
    changed=1
  fi
elif [[ -f "$TRUST_DIR/yandex.cidr" ]]; then
  rm -f "$TRUST_DIR/yandex.cidr"
  changed=1
fi

if [[ "$USE_BEELINE" == 1 ]]; then
  if [[ ! -f "$TRUST_DIR/beeline.cidr" ]] || \
     ! cmp -s "$work/beeline.cidr" "$TRUST_DIR/beeline.cidr"; then
    install -o root -g root -m 0644 \
      "$work/beeline.cidr" "$TRUST_DIR/beeline.cidr"
    changed=1
  fi
elif [[ -f "$TRUST_DIR/beeline.cidr" ]]; then
  rm -f "$TRUST_DIR/beeline.cidr"
  changed=1
fi

if [[ ! -f "$COMBINED" ]] || \
   ! cmp -s "$work/combined.caddy" "$COMBINED"; then
  install -o root -g root -m 0644 "$work/combined.caddy" "$COMBINED"
  changed=1
fi

[[ "$changed" -eq 1 ]] || {
  rm -rf "$backup"
  log "Списки не изменились"
  exit 0
}

if grep -Fq "import $COMBINED" "$CADDYFILE"; then
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
    rollback
    die "Новая конфигурация Caddy не прошла проверку"
  fi
  if ! systemctl reload caddy; then
    rollback
    die "Graceful reload Caddy завершился ошибкой; restart не выполнялся"
  fi
  systemctl is-active --quiet caddy || {
    rollback
    die "Caddy не активен после reload; restart не выполнялся"
  }
  log "Списки обновлены, выполнен graceful reload"
else
  log "Списки созданы. Добавьте import $COMBINED в блок servers Caddy"
fi

find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d \
  -printf '%T@ %p\n' | sort -nr | awk 'NR>10 {print $2}' | xargs -r rm -rf
UPDATER
chmod 0700 /usr/local/sbin/update-cdn-trusted-proxies

cat >/etc/systemd/system/cdn-trusted-proxies.service <<'EOF_SERVICE'
[Unit]
Description=Update selected CDN trusted proxies for Caddy
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-cdn-trusted-proxies
User=root
Group=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
EOF_SERVICE

cat >/etc/systemd/system/cdn-trusted-proxies.timer <<'EOF_TIMER'
[Unit]
Description=Hourly selected CDN trusted proxy update

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

systemctl daemon-reload
systemctl enable --now cdn-trusted-proxies.timer
systemctl start cdn-trusted-proxies.service || {
  journalctl -u cdn-trusted-proxies.service -n 80 --no-pager -l >&2
  die "Первое обновление диапазонов завершилось ошибкой"
}

ADMIN_IP="${SSH_CONNECTION%% *}"
install -d -m 0755 /etc/crowdsec
touch /etc/crowdsec/cdn-origin-admins.txt
chown root:root /etc/crowdsec/cdn-origin-admins.txt
chmod 0600 /etc/crowdsec/cdn-origin-admins.txt
if [[ -n "$ADMIN_IP" ]] && \
   python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' \
     "$ADMIN_IP" 2>/dev/null; then
  printf '%s\n' "$ADMIN_IP" >>/etc/crowdsec/cdn-origin-admins.txt
  sort -u -o \
    /etc/crowdsec/cdn-origin-admins.txt \
    /etc/crowdsec/cdn-origin-admins.txt
fi

log "Создаю CrowdSec AllowList для выбранных CDN и администратора"
tmp_csv="$(mktemp)"
{
  echo 'value,expiration,comment'
  for file in \
    /etc/caddy/trusted-proxies.d/yandex.cidr \
    /etc/caddy/trusted-proxies.d/beeline.cidr \
    /etc/crowdsec/cdn-origin-admins.txt; do
    [[ -f "$file" ]] && \
      awk 'NF && $1 !~ /^#/ {print $1 ",,CDN edge or trusted administrator"}' \
        "$file"
  done
} >"$tmp_csv"
cscli allowlists delete vpn-cdn-infrastructure >/dev/null 2>&1 || true
cscli allowlists create vpn-cdn-infrastructure \
  -d "Selected CDN providers and trusted administrators" >/dev/null
cscli allowlists import vpn-cdn-infrastructure -i "$tmp_csv" >/dev/null
rm -f "$tmp_csv"

providers=()
[[ "$USE_YANDEX" -eq 1 ]] && providers+=("Яндекс CDN")
[[ "$USE_BEELINE" -eq 1 ]] && providers+=("Билайн CDN")

cat <<DONE

Установка завершена.
Выбранные CDN: ${providers[*]}

Добавьте в глобальный блок Caddy:

    admin 127.0.0.1:2019

    servers {
        import /etc/caddy/trusted-proxies.caddy
        trusted_proxies_strict
        client_ip_headers X-Forwarded-For
        ...
    }

В каждом VPN/XHTTP handle добавьте:

    log_skip

После правки:

    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    systemctl reload caddy

Firewall bouncer намеренно не устанавливался автоматически.
DONE
