#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запустите через sudo" >&2; exit 1; }

log(){ printf '[installer] %s\n' "$*"; }
die(){ printf '[installer] ERROR: %s\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null || die "Поддерживаются Debian/Ubuntu"
command -v caddy >/dev/null || die "Caddy должен быть установлен заранее"
[[ -f /etc/caddy/Caddyfile ]] || die "Не найден /etc/caddy/Caddyfile"
getent passwd caddy >/dev/null || die "Не найден пользователь caddy"

export DEBIAN_FRONTEND=noninteractive
log "Устанавливаю зависимости"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl jq python3 util-linux gnupg apt-transport-https

if ! command -v cscli >/dev/null 2>&1; then
  log "Добавляю официальный репозиторий CrowdSec"
  tmp_repo="$(mktemp)"
  curl -fsSL https://install.crowdsec.net -o "$tmp_repo"
  sh "$tmp_repo"
  rm -f "$tmp_repo"
fi

cat >/etc/apt/preferences.d/crowdsec <<'EOF'
Package: *
Pin: release o=packagecloud.io/crowdsec/crowdsec,a=any,n=any,c=main
Pin-Priority: 1001
EOF

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
usermod -aG caddy crowdsec

install -d -m 0755 /etc/crowdsec/acquis.d
if ! grep -RqsF '/var/log/caddy/access.log' /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d 2>/dev/null; then
  cat >/etc/crowdsec/acquis.d/caddy.yaml <<'EOF'
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
EOF
  chmod 0644 /etc/crowdsec/acquis.d/caddy.yaml
else
  log "Caddy acquisition уже существует — второй не создаю"
fi

crowdsec -t
systemctl enable --now crowdsec
systemctl restart crowdsec
systemctl is-active --quiet crowdsec || die "CrowdSec не запустился"

read -r -p "Email Beeline CDN: " BEELINE_USER
read -r -s -p "Пароль Beeline CDN: " BEELINE_PASSWORD
printf '\n'
[[ -n "$BEELINE_USER" && -n "$BEELINE_PASSWORD" ]] || die "Email или пароль пуст"

{
  printf 'BEELINE_USER=%q\n' "$BEELINE_USER"
  printf 'BEELINE_PASSWORD=%q\n' "$BEELINE_PASSWORD"
} >/etc/cdn-trusted-proxies.conf
chmod 0600 /etc/cdn-trusted-proxies.conf
unset BEELINE_PASSWORD

cat >/usr/local/sbin/update-cdn-trusted-proxies <<'UPDATER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source /etc/cdn-trusted-proxies.conf

TRUST_DIR=/etc/caddy/trusted-proxies.d
COMBINED=/etc/caddy/trusted-proxies.caddy
STATE=/var/lib/cdn-trusted-proxies
CADDYFILE=/etc/caddy/Caddyfile
install -d -m 0755 "$TRUST_DIR"
install -d -m 0700 "$STATE"
work="$(mktemp -d "$STATE/run.XXXXXX")"
trap 'rm -rf "$work"' EXIT
exec 9>"$STATE/update.lock"
flock -n 9 || exit 0

log(){ printf '[cdn-proxies] %s\n' "$*"; }

curl -fsSL --retry 3 https://tech.cdn.yandex.net/prefixes/yc.json -o "$work/yandex.json"
jq -er '.prefixes[]' "$work/yandex.json" >"$work/yandex.raw"

TOKEN_JSON="$work/token.json"
code="$(curl -k -sS --retry 2 --connect-timeout 15 --max-time 60 \
  -o "$TOKEN_JSON" -w '%{http_code}' \
  --data-urlencode "username=$BEELINE_USER" \
  --data-urlencode "password=$BEELINE_PASSWORD" \
  https://api.cdn.beeline.ru/app/oauth/v1/token/)"
[[ "$code" == 200 ]] || { echo "Beeline OAuth HTTP $code" >&2; exit 1; }
token="$(jq -er '.token' "$TOKEN_JSON")"

code="$(curl -k -sS --retry 2 --connect-timeout 15 --max-time 90 \
  -o "$work/beeline.json" -w '%{http_code}' \
  -H "CDN-AUTH-TOKEN: $token" -H 'Accept: application/json' \
  https://api.cdn.beeline.ru/app/nodes/v2/ip2origin/)"
unset token
[[ "$code" == 200 ]] || { echo "Beeline nodes API HTTP $code" >&2; exit 1; }

python3 - "$work/yandex.raw" "$work/beeline.json" "$work/yandex.cidr" "$work/beeline.cidr" "$work/combined.caddy" <<'PY'
import ipaddress,json,pathlib,re,sys
yraw,bjson,yout,bout,combined=sys.argv[1:]

def valid(net):
    a=net.network_address
    return not (a.is_private or a.is_loopback or a.is_link_local or a.is_multicast or a.is_unspecified)

y=set()
for line in pathlib.Path(yraw).read_text().splitlines():
    try:
        n=ipaddress.ip_network(line.strip(),strict=False)
        if valid(n): y.add(n)
    except ValueError: pass

obj=json.loads(pathlib.Path(bjson).read_text())
texts=[]
def walk(v):
    if isinstance(v,str): texts.append(v)
    elif isinstance(v,dict):
        for k,x in v.items(): texts.append(str(k)); walk(x)
    elif isinstance(v,list):
        for x in v: walk(x)
walk(obj)
pat=re.compile(r'(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?:/[0-9]{1,2})?(?![0-9.])')
b=set()
for text in texts:
    for token in pat.findall(text):
        try:
            if '/' in token: n=ipaddress.ip_network(token,strict=False)
            else: n=ipaddress.ip_network(token+'/32',strict=False)
            if valid(n): b.add(n)
        except ValueError: pass
if len(y)<20 or len(b)<20:
    raise SystemExit(f'Подозрительно короткие списки: Yandex={len(y)}, Beeline={len(b)}')
key=lambda n:(n.version,int(n.network_address),n.prefixlen)
pathlib.Path(yout).write_text(''.join(f'{n}\n' for n in sorted(y,key=key)))
pathlib.Path(bout).write_text(''.join(f'{n}\n' for n in sorted(b,key=key)))
allnets=sorted(y|b,key=key)
pathlib.Path(combined).write_text('# Generated automatically. Do not edit.\ntrusted_proxies static '+' '.join(map(str,allnets))+'\n')
PY

changed=0
for name in yandex.cidr beeline.cidr; do
  if [[ ! -f "$TRUST_DIR/$name" ]] || ! cmp -s "$work/$name" "$TRUST_DIR/$name"; then
    install -o root -g root -m 0644 "$work/$name" "$TRUST_DIR/$name"
    changed=1
  fi
 done

if [[ ! -f "$COMBINED" ]] || ! cmp -s "$work/combined.caddy" "$COMBINED"; then
  cp -a "$COMBINED" "$COMBINED.bak" 2>/dev/null || true
  install -o root -g root -m 0644 "$work/combined.caddy" "$COMBINED"
  changed=1
fi

[[ "$changed" -eq 1 ]] || { log "Списки не изменились"; exit 0; }

if grep -Fq "import $COMBINED" "$CADDYFILE"; then
  if caddy validate --config "$CADDYFILE" --adapter caddyfile; then
    systemctl reload caddy || { cp -a "$COMBINED.bak" "$COMBINED" 2>/dev/null || true; exit 1; }
    log "Списки обновлены, выполнен graceful reload"
  else
    cp -a "$COMBINED.bak" "$COMBINED" 2>/dev/null || true
    exit 1
  fi
else
  log "Списки созданы. Добавьте import $COMBINED в блок servers Caddy"
fi
UPDATER
chmod 0700 /usr/local/sbin/update-cdn-trusted-proxies

cat >/etc/systemd/system/cdn-trusted-proxies.service <<'EOF'
[Unit]
Description=Update Yandex and Beeline CDN trusted proxies
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
EOF

cat >/etc/systemd/system/cdn-trusted-proxies.timer <<'EOF'
[Unit]
Description=Hourly CDN trusted proxy update
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cdn-trusted-proxies.timer
systemctl start cdn-trusted-proxies.service || {
  journalctl -u cdn-trusted-proxies.service -n 80 --no-pager -l >&2
  die "Первое обновление диапазонов завершилось ошибкой"
}

ADMIN_IP="${SSH_CONNECTION%% *}"
install -d -m 0755 /etc/crowdsec
install -m 0600 /dev/null /etc/crowdsec/cdn-origin-admins.txt 2>/dev/null || true
if [[ -n "$ADMIN_IP" ]] && python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$ADMIN_IP" 2>/dev/null; then
  printf '%s\n' "$ADMIN_IP" >>/etc/crowdsec/cdn-origin-admins.txt
  sort -u -o /etc/crowdsec/cdn-origin-admins.txt /etc/crowdsec/cdn-origin-admins.txt
fi

log "Создаю CrowdSec AllowList для CDN и администратора"
tmp_csv="$(mktemp)"
{
  echo 'value,expiration,comment'
  for file in /etc/caddy/trusted-proxies.d/yandex.cidr /etc/caddy/trusted-proxies.d/beeline.cidr /etc/crowdsec/cdn-origin-admins.txt; do
    [[ -f "$file" ]] && awk 'NF && $1 !~ /^#/ {print $1 ",,CDN edge or trusted administrator"}' "$file"
  done
} >"$tmp_csv"
cscli allowlists delete vpn-cdn-infrastructure >/dev/null 2>&1 || true
cscli allowlists create vpn-cdn-infrastructure -d "Yandex/Beeline CDN and trusted administrators" >/dev/null
cscli allowlists import vpn-cdn-infrastructure -i "$tmp_csv" >/dev/null
rm -f "$tmp_csv"

cat <<'DONE'

Установка завершена.

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
