  systemctl disable --now "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$ROLLBACK_UNIT.timer" "/etc/systemd/system/$ROLLBACK_UNIT.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  printf 'CONFIRMED\n' >"$TX/status"
  status CONFIRMED "Автоматический откат Caddy отменён"
}

if (( CHANGED == 1 )); then
  if ! start_rollback_timer; then
    cp -a "$TX/Caddyfile.before" "$CADDYFILE"
    if [[ -n "$OVERRIDE_FILE" && -f "$TX/override.absent" ]]; then
      rm -f "$OVERRIDE_FILE"
    fi
    die "не удалось запустить таймер автоматического отката Caddy"
  fi
  if [[ "$CADDY_MODE" == host ]]; then
    caddy validate --config "$CADDYFILE" || { rollback_now; die "Caddyfile не прошёл проверку"; }
    systemctl reload caddy || { rollback_now; die "не удалось перезагрузить Caddy"; }
    systemctl is-active --quiet caddy || { rollback_now; die "caddy.service остановлен"; }
  else
    docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile || {
      rollback_now; die "Caddyfile в контейнере не прошёл проверку"
    }
    (
      cd "$COMPOSE_DIR"
      if [[ -f "$OVERRIDE_FILE" ]]; then
        docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d
      else
        docker compose -f "$COMPOSE_FILE" up -d
      fi
    ) || { rollback_now; die "не удалось применить Docker override Caddy"; }
    docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile || {
      rollback_now; die "Caddy после пересоздания не прошёл проверку"
    }
    docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile || {
      rollback_now; die "не удалось выполнить caddy reload в контейнере"
    }
  fi
  status APPLIED "JSON access log добавлен в site block панели"
else
  status OK "Файловый access log Caddy уже настроен: $CADDY_LOG_PATH"
fi

HTTP_CODE="$(curl -sS -o /dev/null --connect-timeout 10 --max-time 20 -w '%{http_code}' "https://$PANEL_DOMAIN/" || true)"
if [[ "$HTTP_CODE" =~ ^[1-4][0-9][0-9]$ ]]; then
  status OK "Панель отвечает по HTTPS: HTTP $HTTP_CODE"
else
  (( CHANGED == 1 )) && rollback_now
  die "панель не прошла HTTPS-проверку после настройки Caddy (HTTP ${HTTP_CODE:-000})"
fi

if (( CHANGED == 1 )); then
  printf '\nОткройте панель в браузере и проверьте вход и страницу подписки.\n'
  if ask_no "Панель и новое SSH-подключение работают. Отменить откат Caddy?"; then
    cancel_rollback
  else
    status ROLLBACK "Подтверждение не получено; таймер оставлен активным"
    exit 2
  fi
fi

export DEBIAN_FRONTEND=noninteractive
log "Устанавливаю зависимости CrowdSec"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl python3 gnupg apt-transport-https

if ! has_cmd cscli; then
  log "Добавляю официальный репозиторий CrowdSec"
  REPO_INSTALLER="$(mktemp)"
  curl -fsSL https://install.crowdsec.net -o "$REPO_INSTALLER"
  /bin/sh "$REPO_INSTALLER"
  rm -f "$REPO_INSTALLER"
fi

cat >/etc/apt/preferences.d/crowdsec <<'EOF_PIN'
Package: *
Pin: release o=packagecloud.io/crowdsec/crowdsec,a=any,n=any,c=main
Pin-Priority: 1001
EOF_PIN

apt-get update
apt-get install -y crowdsec

log "Устанавливаю базовые коллекции Linux и Caddy"
cscli hub update
for collection in \
  crowdsecurity/linux \
  crowdsecurity/caddy \
  crowdsecurity/base-http-scenarios \
  crowdsecurity/http-cve \
  crowdsecurity/whitelist-good-actors; do
  if cscli collections list -o raw 2>/dev/null | awk -F, -v name="$collection" '$1==name && tolower($3) ~ /enabled|installed/ {found=1} END {exit !found}'; then
    status OK "Коллекция уже установлена: $collection"
  else
    cscli collections install "$collection" >/dev/null
    status APPLIED "Установлена коллекция: $collection"
  fi
done

install -d -o root -g root -m 0755 /etc/crowdsec/acquis.d
HOST_LOG_PATH="$CADDY_LOG_PATH"
if [[ "$CADDY_MODE" == docker && "$CADDY_LOG_PATH" == /var/log/caddy/* ]]; then
  HOST_LOG_PATH="${DOCKER_LOG_SOURCE:-$LOG_DIR}/${CADDY_LOG_PATH#/var/log/caddy/}"
fi
[[ -f "$HOST_LOG_PATH" ]] || touch "$HOST_LOG_PATH"
chmod 0644 "$HOST_LOG_PATH"

if grep -RqsF "$HOST_LOG_PATH" /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.d 2>/dev/null; then
  status OK "Acquisition для Caddy log уже существует"
else
