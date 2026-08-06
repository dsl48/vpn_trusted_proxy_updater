#!/usr/bin/env bash
set -uo pipefail
umask 077

BASE_AUDIT="${1:-}"
[[ -n "$BASE_AUDIT" && -r "$BASE_AUDIT" ]] || {
  echo "ERROR: не указан базовый check-basic-security.sh" >&2
  exit 1
}

AUDIT_LIBRARY="$(mktemp)"
cleanup_extension() {
  rm -f "$AUDIT_LIBRARY"
}
trap cleanup_extension EXIT HUP INT TERM

# Загружаем функции базового аудита, но не запускаем его старый main-блок.
awk '/^print_header$/ {exit} {print}' "$BASE_AUDIT" >"$AUDIT_LIBRARY"
# shellcheck disable=SC1090
source "$AUDIT_LIBRARY"

TG_ANTISCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
TG_GOVERNMENT_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"

endpoint_host() {
  local endpoint="$1"
  if [[ "$endpoint" == \[*\]:* ]]; then
    endpoint="${endpoint#\[}"
    printf '%s' "${endpoint%]:*}"
  else
    printf '%s' "${endpoint%:*}"
  fi
}

endpoint_port() {
  printf '%s' "${1##*:}"
}

is_public_bind_host() {
  case "$1" in
    '*'|'0.0.0.0'|'::') return 0 ;;
    *) return 1 ;;
  esac
}

is_loopback_host() {
  case "$1" in
    127.*|'::1') return 0 ;;
    *) return 1 ;;
  esac
}

check_network() {
  section "Сетевая поверхность и публичные порты"

  if ! has_cmd ss; then
    emit SKIP "Команда ss не найдена"
    return
  fi

  local listeners public_lines="" public_count=0
  local proto state recvq sendq local_ep peer_ep rest host port line
  local lapi_loopback=0 lapi_exposed=0
  listeners="$(ss -H -lntup 2>/dev/null || true)"

  while read -r proto state recvq sendq local_ep peer_ep rest; do
    [[ -n "${local_ep:-}" ]] || continue
    host="$(endpoint_host "$local_ep")"
    port="$(endpoint_port "$local_ep")"
    line="$proto $state $recvq $sendq $local_ep $peer_ep${rest:+ $rest}"

    if is_public_bind_host "$host"; then
      public_lines+="$line"$'\n'
      ((public_count+=1))
    fi

    if [[ "$port" == "18888" ]]; then
      if is_loopback_host "$host"; then
        lapi_loopback=1
      else
        lapi_exposed=1
      fi
    fi
  done <<<"$listeners"

  if (( public_count == 0 )); then
    emit OK "Публичные TCP/UDP listeners не найдены"
  else
    emit INFO "Публичных listeners: $public_count"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '             %s\n' "$line"
      local_ep="$(awk '{print $5}' <<<"$line")"
      port="$(endpoint_port "$local_ep")"
      case "$port" in
        2375|2376|5432|6379|6380|18888)
          emit CRITICAL "Чувствительный сервис доступен публично на порту $port"
          ;;
        3000|3001|3002|6767|8080|8081|8082|9090)
          emit WARN "Административный/служебный порт $port слушает публичный интерфейс"
          ;;
      esac
    done <<<"$public_lines"
  fi

  if (( lapi_exposed == 1 )); then
    emit CRITICAL "CrowdSec LAPI 18888 доступен не только через loopback"
  elif (( lapi_loopback == 1 )); then
    emit OK "CrowdSec LAPI 18888 привязан к loopback"
  fi
}

check_fail2ban() {
  section "Fail2Ban"

  local installed=0
  has_cmd fail2ban-client && installed=1
  if (( installed == 0 )) && has_cmd dpkg-query && dpkg-query -W fail2ban >/dev/null 2>&1; then
    installed=1
  fi

  if (( installed == 0 )); then
    if service_active crowdsec.service && service_active crowdsec-firewall-bouncer.service; then
      emit INFO "Fail2Ban не установлен; динамическую защиту обеспечивает CrowdSec"
    else
      emit WARN "Fail2Ban не установлен, а полная защита CrowdSec не подтверждена"
    fi
    return
  fi

  if ! service_active fail2ban.service; then
    emit WARN "Fail2Ban установлен, но service не активен"
    return
  fi

  if ! has_cmd fail2ban-client || ! timeout 10 fail2ban-client ping >/dev/null 2>&1; then
    emit WARN "Fail2Ban запущен, но fail2ban-client не отвечает"
    return
  fi

  local status jails
  status="$(timeout 10 fail2ban-client status 2>/dev/null || true)"
  jails="$(sed -n 's/.*Jail list:[[:space:]]*//p' <<<"$status" | head -n1)"
  emit OK "Fail2Ban установлен, запущен и отвечает"
  emit INFO "Fail2Ban jails: ${jails:-не настроены}"
  service_enabled fail2ban.service \
    && emit OK "Fail2Ban включён в автозагрузку" \
    || emit WARN "Fail2Ban не включён в автозагрузку"

  service_active crowdsec.service \
    && emit INFO "Одновременно работают Fail2Ban и CrowdSec"
}

check_traffic_guard_online_lists() {
  local local_save="$1" tmp_dir result label total found missing coverage

  if ! has_cmd curl; then
    emit SKIP "Онлайн-сравнение TrafficGuard пропущено: curl не найден"
    return
  fi
  if ! has_cmd python3; then
    emit SKIP "Онлайн-сравнение TrafficGuard пропущено: Python 3 не найден"
    return
  fi

  tmp_dir="$(mktemp -d)"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
       "$TG_ANTISCANNER_URL" -o "$tmp_dir/antiscanner.list" || \
     ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
       "$TG_GOVERNMENT_URL" -o "$tmp_dir/government_networks.list"; then
    rm -rf "$tmp_dir"
    emit SKIP "Онлайн-сравнение списков TrafficGuard недоступно"
    return
  fi

  result="$(python3 - "$local_save" \
    "$tmp_dir/antiscanner.list" \
    "$tmp_dir/government_networks.list" <<'PY'
import ipaddress
import sys


def parse_networks(path):
    result = set()
    with open(path, encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            value = raw.split("#", 1)[0].strip()
            if not value:
                continue
            try:
                result.add(str(ipaddress.ip_network(value, strict=False)))
            except ValueError:
                continue
    return result


def parse_ipset(path):
    result = set()
    with open(path, encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            parts = raw.split()
            if len(parts) < 3 or parts[0] != "add" or parts[1] not in {
                "SCANNERS-BLOCK-V4", "SCANNERS-BLOCK-V6"
            }:
                continue
            try:
                result.add(str(ipaddress.ip_network(parts[2], strict=False)))
            except ValueError:
                continue
    return result


local = parse_ipset(sys.argv[1])
for label, path in (
    ("antiscanner.list", sys.argv[2]),
    ("government_networks.list", sys.argv[3]),
):
    expected = parse_networks(path)
    found = len(expected & local)
    print("{}|{}|{}|{}".format(label, len(expected), found, len(expected) - found))
PY
)"
  rm -rf "$tmp_dir"

  while IFS='|' read -r label total found missing; do
    [[ "$total" =~ ^[0-9]+$ ]] || continue
    if (( total == 0 )); then
      emit WARN "TrafficGuard: список $label не содержит распознанных сетей"
      continue
    fi
    coverage=$(( found * 100 / total ))
    if (( missing == 0 )); then
      emit OK "TrafficGuard: $label загружен полностью — $found/$total"
    elif (( coverage >= 90 )); then
      emit WARN "TrafficGuard: $label загружен частично — $found/$total ($coverage%), отсутствует $missing"
    else
      emit CRITICAL "TrafficGuard: $label покрыт недостаточно — $found/$total ($coverage%), отсутствует $missing"
    fi
  done <<<"$result"
}

check_traffic_guard() {
  section "TrafficGuard"

  local binary="" version=""
  binary="$(command -v traffic-guard 2>/dev/null || true)"
  [[ -z "$binary" && -x /usr/local/bin/traffic-guard ]] \
    && binary=/usr/local/bin/traffic-guard
  if [[ -z "$binary" ]]; then
    emit CRITICAL "TrafficGuard не установлен"
    return
  fi

  version="$(timeout 10 "$binary" --version 2>&1 | head -n1 || true)"
  [[ -n "$version" ]] \
    && emit OK "TrafficGuard установлен: $binary ($version)" \
    || emit WARN "TrafficGuard найден: $binary, но версия/запуск не подтверждены"

  if ! has_cmd ipset; then
    emit CRITICAL "TrafficGuard установлен, но команда ipset отсутствует"
    return
  fi

  local v4_exists=0 v6_exists=0 v4_count=0 v6_count=0 local_save
  ipset list SCANNERS-BLOCK-V4 >/dev/null 2>&1 && v4_exists=1
  ipset list SCANNERS-BLOCK-V6 >/dev/null 2>&1 && v6_exists=1

  if (( v4_exists == 1 )); then
    v4_count="$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | \
      awk -F: '/^Number of entries:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    [[ "$v4_count" =~ ^[0-9]+$ ]] || v4_count=0
    (( v4_count > 0 )) \
      && emit OK "SCANNERS-BLOCK-V4 загружен: $v4_count сетей" \
      || emit CRITICAL "SCANNERS-BLOCK-V4 существует, но пуст"
  else
    emit CRITICAL "Набор SCANNERS-BLOCK-V4 не найден"
  fi

  if (( v6_exists == 1 )); then
    v6_count="$(ipset list SCANNERS-BLOCK-V6 2>/dev/null | \
      awk -F: '/^Number of entries:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    [[ "$v6_count" =~ ^[0-9]+$ ]] || v6_count=0
    (( v6_count > 0 )) \
      && emit OK "SCANNERS-BLOCK-V6 загружен: $v6_count сетей" \
      || emit INFO "SCANNERS-BLOCK-V6 пуст; публичные списки могут не содержать IPv6"
  else
    emit WARN "Набор SCANNERS-BLOCK-V6 не найден"
  fi

  local_save="$(mktemp)"
  ipset save >"$local_save" 2>/dev/null || true

  local chain4="" rules4="" chain6="" rules6=""
  has_cmd iptables && chain4="$(iptables -S SCANNERS-BLOCK 2>/dev/null || true)"
  has_cmd iptables && rules4="$(iptables-save 2>/dev/null || true)"
  has_cmd ip6tables && chain6="$(ip6tables -S SCANNERS-BLOCK 2>/dev/null || true)"
  has_cmd ip6tables && rules6="$(ip6tables-save 2>/dev/null || true)"

  grep -Eq -- '--match-set SCANNERS-BLOCK-V4 src.*-j DROP' <<<"$chain4" \
    && emit OK "TrafficGuard IPv4-цепочка использует ipset и DROP" \
    || emit CRITICAL "TrafficGuard IPv4: правило DROP по SCANNERS-BLOCK-V4 не найдено"
  grep -Eq -- '-A (INPUT|ufw-before-input) -j SCANNERS-BLOCK' <<<"$rules4" \
    && emit OK "SCANNERS-BLOCK подключена к входящему IPv4-трафику" \
    || emit CRITICAL "SCANNERS-BLOCK не подключена к входящему IPv4-трафику"

  if (( v6_count > 0 )); then
    grep -Eq -- '--match-set SCANNERS-BLOCK-V6 src.*-j DROP' <<<"$chain6" \
      && emit OK "TrafficGuard IPv6-цепочка использует ipset и DROP" \
      || emit CRITICAL "TrafficGuard IPv6: правило DROP по SCANNERS-BLOCK-V6 не найдено"
    grep -Eq -- '-A (INPUT|ufw6-before-input) -j SCANNERS-BLOCK' <<<"$rules6" \
      && emit OK "SCANNERS-BLOCK подключена к входящему IPv6-трафику" \
      || emit CRITICAL "SCANNERS-BLOCK не подключена к входящему IPv6-трафику"
  fi

  [[ -s /etc/ipset.conf ]] \
    && emit OK "Сохранённая конфигурация TrafficGuard найдена: /etc/ipset.conf" \
    || emit CRITICAL "/etc/ipset.conf отсутствует или пуст"

  service_enabled antiscan-ipset-restore.service \
    && emit OK "Автовосстановление TrafficGuard включено" \
    || emit WARN "antiscan-ipset-restore.service не включён в автозагрузку"

  if systemctl list-unit-files antiscan-aggregate.timer >/dev/null 2>&1; then
    service_active antiscan-aggregate.timer \
      && emit OK "TrafficGuard logging включён, antiscan-aggregate.timer активен" \
      || emit WARN "TrafficGuard logging настроен, но antiscan-aggregate.timer не активен"
  else
    emit INFO "TrafficGuard работает без журналирования блокировок"
  fi

  check_traffic_guard_online_lists "$local_save"
  rm -f "$local_save"
}

check_docker() {
  section "Docker"

  if ! has_cmd docker || ! docker info >/dev/null 2>&1; then
    emit SKIP "Docker не установлен или daemon недоступен"
    return
  fi
  emit OK "Docker daemon доступен"

  local docker_members
  docker_members="$(getent group docker 2>/dev/null | awk -F: '{print $4}' || true)"
  [[ -n "$docker_members" ]] \
    && emit WARN "Пользователи группы docker имеют привилегии уровня root: $docker_members" \
    || emit OK "Дополнительные пользователи группы docker не указаны"

  local ids inspect_file findings
  ids="$(docker ps -q)"
  if [[ -z "$ids" ]]; then
    emit INFO "Работающих контейнеров нет"
    return
  fi
  if ! has_cmd python3; then
    emit WARN "Python 3 не найден; детальная проверка docker inspect пропущена"
    return
  fi

  inspect_file="$(mktemp)"
  docker inspect $ids >"$inspect_file" 2>/dev/null || {
    rm -f "$inspect_file"
    emit WARN "Не удалось выполнить docker inspect"
    return
  }

  findings="$(python3 - "$inspect_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    containers = json.load(stream)

for item in containers:
    name = item.get("Name", "").lstrip("/") or item.get("Id", "")[:12]
    host = item.get("HostConfig", {})
    config = item.get("Config", {})
    is_remnanode_agent = name == "remnawave-node-agent"
    issues = []
    infos = []

    if host.get("Privileged"):
        if is_remnanode_agent:
            infos.append("расширенные привилегии соответствуют профилю RemnaNode")
        else:
            issues.append(("CRITICAL", "privileged=true"))
    if host.get("NetworkMode") == "host":
        issues.append(("WARN", "network_mode=host"))

    user = config.get("User", "")
    root_or_default = user in ("", "0", "root", "0:0")
    writable = not host.get("ReadonlyRootfs")
    if is_remnanode_agent and (root_or_default or writable):
        infos.append("root/default user и writable rootfs штатны для RemnaNode")
    else:
        if writable:
            infos.append("rootfs writable")
        if root_or_default:
            infos.append("process runs as root/default")

    restart = host.get("RestartPolicy", {}).get("Name", "")
    if restart in ("", "no"):
        issues.append(("WARN", "restart policy disabled"))

    log_config = host.get("LogConfig", {})
    log_type = log_config.get("Type", "") or "default"
    log_opts = log_config.get("Config", {}) or {}
    if log_type == "none":
        issues.append(("WARN", "logging driver=none"))
    elif log_type in ("json-file", "local", "default") and not any(
        key in log_opts for key in ("max-size", "max-file")
    ):
        issues.append(("WARN", "log rotation limits not set per container"))

    for mount in item.get("Mounts", []):
        source = mount.get("Source", "")
        destination = mount.get("Destination", "")
        if source == "/" or destination == "/":
            issues.append(("CRITICAL", "host root filesystem mounted"))
        if source.endswith("/docker.sock") or destination.endswith("/docker.sock"):
            issues.append(("CRITICAL", "Docker socket mounted"))

    for level, issue in issues:
        print("{}|{}|{}".format(level, name, issue))
    if infos:
        print("INFO|{}|{}".format(name, "; ".join(dict.fromkeys(infos))))
PY
)"
  rm -f "$inspect_file"

  if [[ -z "$findings" ]]; then
    emit OK "Опасные параметры работающих контейнеров не обнаружены"
  else
    while IFS='|' read -r level name message; do
      emit "$level" "Docker $name: $message"
    done <<<"$findings"
  fi

  local public_ports
  public_ports="$(docker ps --format '{{.Names}}|{{.Ports}}' | \
    grep -E '0\.0\.0\.0:|\[::\]:' || true)"
  if [[ -n "$public_ports" ]]; then
    emit INFO "Контейнеры публикуют порты на всех интерфейсах:"
    sed 's/^/             /' <<<"$public_ports"
  else
    emit OK "Публичные Docker port bindings не обнаружены"
  fi
}

print_header
check_os
check_users_and_ssh
check_network
check_firewall_and_ping
check_sysctl
check_crowdsec
check_fail2ban
check_traffic_guard
check_docker
check_storage_time_logs
check_sensitive_files
print_summary

exit 0
