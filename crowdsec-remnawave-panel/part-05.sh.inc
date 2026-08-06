  if [[ -f "$ACQUIS_FILE" ]]; then
    cp -a "$ACQUIS_FILE" "$ACQUIS_FILE.backup-$(date +%Y%m%d-%H%M%S)"
  fi
  cat >"$ACQUIS_FILE" <<EOF_ACQUIS
source: file
filenames:
  - $HOST_LOG_PATH
labels:
  type: caddy
EOF_ACQUIS
  chmod 0644 "$ACQUIS_FILE"
  status APPLIED "Создан acquisition: $ACQUIS_FILE"
fi

crowdsec -t
systemctl enable --now crowdsec
systemctl restart crowdsec
systemctl is-active --quiet crowdsec || {
  journalctl -u crowdsec -n 120 --no-pager -l >&2 || true
  die "CrowdSec не запустился"
}
status OK "CrowdSec Security Engine запущен"

# Генерируем запись в access log и даём CrowdSec время прочитать её.
curl -sS -o /dev/null --connect-timeout 10 --max-time 20 "https://$PANEL_DOMAIN/" || true
sleep 2
if grep -Fq "$HOST_LOG_PATH" /var/log/crowdsec.log 2>/dev/null; then
  status OK "CrowdSec открыл Caddy access log"
else
  status WARN "Путь Caddy log пока не найден в /var/log/crowdsec.log; показываю acquisition metrics"
fi
cscli metrics show acquisition 2>/dev/null || true

ensure_allowlist() {
  if cscli allowlists inspect "$ALLOWLIST_NAME" >/dev/null 2>&1; then
    status OK "AllowList уже существует: $ALLOWLIST_NAME"
  else
    cscli allowlists create "$ALLOWLIST_NAME" -d "Trusted administrators and infrastructure for Remnawave panel" >/dev/null
    status APPLIED "Создан AllowList: $ALLOWLIST_NAME"
  fi
}

allow_value() {
  local value="$1" comment="$2" output
  if output="$(cscli allowlists add "$ALLOWLIST_NAME" "$value" -d "$comment" 2>&1)"; then
    status APPLIED "Добавлено в AllowList: $value"
  elif grep -qiE 'already|exist|duplicate' <<<"$output"; then
    status OK "$value уже присутствует в AllowList"
  else
    printf '%s\n' "$output" >&2
    die "не удалось добавить $value в AllowList"
  fi
}

ADMIN_IP="${SSH_CONNECTION%% *}"
if [[ -n "$ADMIN_IP" && "$ADMIN_IP" != "$SSH_CONNECTION" ]]; then
  if python3 - "$ADMIN_IP" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
  then
    if ask_yes "Добавить IP текущей SSH-сессии $ADMIN_IP в CrowdSec AllowList?"; then
      ensure_allowlist
      allow_value "$ADMIN_IP" "Current SSH administrator"
    else
      status WARN "IP текущей SSH-сессии не добавлен в AllowList"
    fi
  fi
fi

if ask_no "Добавить дополнительные доверенные IP или CIDR?"; then
  read -r -p "Введите IP/CIDR через пробел: " EXTRA_VALUES
  ensure_allowlist
  for value in $EXTRA_VALUES; do
    python3 - "$value" <<'PY' >/dev/null 2>&1 || die "некорректный IP/CIDR: $value"
import ipaddress, sys
ipaddress.ip_network(sys.argv[1], strict=False)
PY
    allow_value "$value" "Trusted Remnawave infrastructure"
  done
fi

install -d -o root -g root -m 0755 /etc/crowdsec
{
  printf 'CROWDSEC_PANEL_TRAFFIC_MODE=%q\n' "$PANEL_TRAFFIC_MODE"
  printf 'CROWDSEC_PANEL_DOMAIN=%q\n' "$PANEL_DOMAIN"
  printf 'CROWDSEC_PANEL_CADDY_MODE=%q\n' "$CADDY_MODE"
  printf 'CROWDSEC_PANEL_LOG=%q\n' "$HOST_LOG_PATH"
} >"$PROFILE_STATE"
chown root:root "$PROFILE_STATE"
chmod 0600 "$PROFILE_STATE"

cat <<DONE

Профиль Remnawave Panel подготовлен.
  Панель:            $REMNAWAVE_CONTAINER
  Домен:             $PANEL_DOMAIN
  Caddy:             $CADDY_MODE
  Access log:        $HOST_LOG_PATH
  CrowdSec:          active
  HTTP traffic mode: $PANEL_TRAFFIC_MODE

Следующий этап установит firewall bouncer и проверит Local API.
DONE
