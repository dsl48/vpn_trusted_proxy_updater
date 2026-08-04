#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите через sudo" >&2
  exit 1
}

log() {
  printf '[update-interval] %s\n' "$*"
}

die() {
  printf '[update-interval] ERROR: %s\n' "$*" >&2
  exit 1
}

TIMER_FILE=/etc/systemd/system/cdn-trusted-proxies.timer
SERVICE_NAME=cdn-trusted-proxies.service
TIMER_NAME=cdn-trusted-proxies.timer

[[ -f /etc/systemd/system/cdn-trusted-proxies.service ]] || \
  die "Не найден cdn-trusted-proxies.service"

printf '\nНастройка частоты обновления доверенных CDN-диапазонов.\n'
printf 'Допустимый формат: минуты, часы или дни — например 30m, 1h, 6h, 1d.\n'

while true; do
  read -r -p "Как часто обновлять списки CDN? [1h]: " UPDATE_INTERVAL
  UPDATE_INTERVAL="${UPDATE_INTERVAL:-1h}"
  UPDATE_INTERVAL="${UPDATE_INTERVAL//[[:space:]]/}"

  if [[ "$UPDATE_INTERVAL" =~ ^([1-9][0-9]*)(m|h|d)$ ]]; then
    VALUE="${BASH_REMATCH[1]}"
    UNIT="${BASH_REMATCH[2]}"
    case "$UNIT" in
      m) INTERVAL_SECONDS=$((VALUE * 60)) ;;
      h) INTERVAL_SECONDS=$((VALUE * 3600)) ;;
      d) INTERVAL_SECONDS=$((VALUE * 86400)) ;;
    esac

    if (( INTERVAL_SECONDS < 300 )); then
      printf 'Минимальный период — 5m, чтобы не перегружать API CDN.\n'
      continue
    fi
    break
  fi

  printf 'Введите значение вида 30m, 1h, 6h или 1d.\n'
done

TMP_TIMER="$(mktemp /tmp/cdn-trusted-proxies.timer.XXXXXX)"
cleanup() {
  rm -f "$TMP_TIMER"
}
trap cleanup EXIT HUP INT TERM

cat >"$TMP_TIMER" <<EOF_TIMER
[Unit]
Description=Periodic selected CDN trusted proxy update

[Timer]
OnBootSec=5min
OnUnitActiveSec=$UPDATE_INTERVAL
RandomizedDelaySec=5min
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF_TIMER

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$TMP_TIMER" >/dev/null || \
    die "systemd не принял период $UPDATE_INTERVAL"
fi

if [[ -f "$TIMER_FILE" ]]; then
  cp -a "$TIMER_FILE" "${TIMER_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
fi

install -o root -g root -m 0644 "$TMP_TIMER" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable "$TIMER_NAME" >/dev/null
systemctl restart "$TIMER_NAME"
systemctl is-active --quiet "$TIMER_NAME" || \
  die "$TIMER_NAME не запущен"

log "Период обновления установлен: $UPDATE_INTERVAL"
printf '\nСледующий запуск таймера:\n'
systemctl list-timers "$TIMER_NAME" --no-pager --all | sed -n '1,3p' || true
