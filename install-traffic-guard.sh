#!/usr/bin/env bash
set -euo pipefail
umask 077

TG_REPO="dotX12/traffic-guard"
TG_INSTALLER_REF="${TRAFFIC_GUARD_INSTALLER_REF:-0594f8241a37d20876ebafada6e80ca2fa597900}"
TG_INSTALLER_URL="https://raw.githubusercontent.com/${TG_REPO}/${TG_INSTALLER_REF}/install.sh"
ANTISCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
GOVERNMENT_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl не установлен" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/traffic-guard-install.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

cat <<'INTRO'

TrafficGuard блокирует известные сети массовых сканеров на уровне
iptables/ipset до того, как соединение попадёт в SSH, Caddy, Xray
или другие публичные сервисы.

Будут применены списки:
  • antiscanner.list
  • government_networks.list
INTRO

read -r -p "Продолжить установку и применение списков? [Y/n]: " answer
answer="${answer:-yes}"
case "${answer,,}" in
  y|yes|д|да) ;;
  *) echo "Установка отменена."; exit 0 ;;
esac

curl -fsSL --retry 3 --connect-timeout 15 \
  "$ANTISCANNER_URL" -o "$TMP_DIR/antiscanner.list"
curl -fsSL --retry 3 --connect-timeout 15 \
  "$GOVERNMENT_URL" -o "$TMP_DIR/government_networks.list"

ADMIN_IP="${SSH_CONNECTION%% *}"
if [[ -n "$ADMIN_IP" && "$ADMIN_IP" != "$SSH_CONNECTION" ]] && command -v python3 >/dev/null 2>&1; then
  if python3 - "$ADMIN_IP" "$TMP_DIR/antiscanner.list" "$TMP_DIR/government_networks.list" <<'PY'
import ipaddress
import pathlib
import sys

address = ipaddress.ip_address(sys.argv[1])
for filename in sys.argv[2:]:
    for raw in pathlib.Path(filename).read_text(encoding="utf-8", errors="ignore").splitlines():
        value = raw.split("#", 1)[0].strip()
        if not value:
            continue
        try:
            network = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if address in network:
            print("{} входит в {} ({})".format(address, network, filename))
            raise SystemExit(0)
raise SystemExit(1)
PY
  then
    echo "ERROR: IP текущего SSH-подключения найден в одном из списков." >&2
    echo "Применение остановлено, чтобы не потерять доступ к серверу." >&2
    exit 1
  fi
fi

if command -v traffic-guard >/dev/null 2>&1; then
  echo "TrafficGuard уже установлен: $(command -v traffic-guard)"
else
  echo "Устанавливаю TrafficGuard из официального репозитория ${TG_REPO}."
  curl -fsSL --retry 3 --connect-timeout 15 \
    "$TG_INSTALLER_URL" -o "$TMP_DIR/upstream-install.sh"
  bash -n "$TMP_DIR/upstream-install.sh"
  /bin/bash "$TMP_DIR/upstream-install.sh"
fi

TG_BIN="$(command -v traffic-guard || true)"
[[ -n "$TG_BIN" && -x "$TG_BIN" ]] || {
  echo "ERROR: бинарник traffic-guard после установки не найден" >&2
  exit 1
}

read -r -p "Включить журналирование и агрегированную статистику блокировок? [y/N]: " log_answer
TG_ARGS=(
  full
  -u "$ANTISCANNER_URL"
  -u "$GOVERNMENT_URL"
)
case "${log_answer,,}" in
  y|yes|д|да) TG_ARGS+=(--enable-logging) ;;
esac

"$TG_BIN" "${TG_ARGS[@]}"

command -v ipset >/dev/null 2>&1 || {
  echo "ERROR: ipset не найден после применения TrafficGuard" >&2
  exit 1
}

V4_ENTRIES="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | awk '/^Number of entries:/ {print $4; exit}')"
V6_ENTRIES="$(ipset list SCANNERS-BLOCK-V6 2>/dev/null | awk '/^Number of entries:/ {print $4; exit}')"
V4_ENTRIES="${V4_ENTRIES:-0}"
V6_ENTRIES="${V6_ENTRIES:-0}"

if (( V4_ENTRIES == 0 && V6_ENTRIES == 0 )); then
  echo "ERROR: списки TrafficGuard созданы, но не содержат сетей" >&2
  exit 1
fi

if ! iptables -S SCANNERS-BLOCK 2>/dev/null | \
     grep -q -- '--match-set SCANNERS-BLOCK-V4 src -j DROP'; then
  echo "ERROR: не найдено IPv4 DROP-правило TrafficGuard" >&2
  exit 1
fi

if ! iptables -S INPUT 2>/dev/null | grep -q -- '-j SCANNERS-BLOCK' && \
   ! iptables -S ufw-before-input 2>/dev/null | grep -q -- '-j SCANNERS-BLOCK'; then
  echo "ERROR: цепочка SCANNERS-BLOCK не подключена к входящему трафику" >&2
  exit 1
fi

cat <<RESULT

TrafficGuard успешно применён.
  IPv4-сетей: $V4_ENTRIES
  IPv6-сетей: $V6_ENTRIES
  Списки: antiscanner.list, government_networks.list
RESULT
