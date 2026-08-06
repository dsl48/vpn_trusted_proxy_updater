#!/usr/bin/env bash
set -uo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: проверку нужно запускать через sudo" >&2
  exit 1
}

OK_COUNT=0
WARN_COUNT=0
CRITICAL_COUNT=0
INFO_COUNT=0
SKIP_COUNT=0

emit() {
  local level="$1"
  shift
  case "$level" in
    OK)       ((OK_COUNT+=1)) ;;
    WARN)     ((WARN_COUNT+=1)) ;;
    CRITICAL) ((CRITICAL_COUNT+=1)) ;;
    INFO)     ((INFO_COUNT+=1)) ;;
    SKIP)     ((SKIP_COUNT+=1)) ;;
  esac
  printf '[%-8s] %s\n' "$level" "$*"
}

section() {
  printf '\n%s\n' "────────────────────────────────────────────────────────────"
  printf '%s\n' "$1"
  printf '%s\n' "────────────────────────────────────────────────────────────"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

service_enabled() {
  systemctl is-enabled --quiet "$1" 2>/dev/null
}

sysctl_value() {
  sysctl -n "$1" 2>/dev/null || true
}

check_equals() {
  local key="$1" expected="$2" description="$3" value
  value="$(sysctl_value "$key")"
  if [[ -z "$value" ]]; then
    emit SKIP "$description: параметр $key недоступен"
  elif [[ "$value" == "$expected" ]]; then
    emit OK "$description ($key=$value)"
  else
    emit WARN "$description: $key=$value, рекомендуется $expected"
  fi
}

percent_used() {
  printf '%s' "$1" | tr -cd '0-9'
}

print_header() {
  cat <<'HEADER'

════════════════════════════════════════════════════════════
              ПРОВЕРКА БАЗОВОЙ БЕЗОПАСНОСТИ
════════════════════════════════════════════════════════════
Режим: только чтение. Конфигурация сервера не изменяется.
HEADER
  printf 'Дата: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
  printf 'Хост: %s\n' "$(hostname -f 2>/dev/null || hostname)"
}

check_os() {
  section "ОС, обновления и пакетная база"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    emit INFO "ОС: ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
  else
    emit WARN "Не найден /etc/os-release"
  fi
  emit INFO "Ядро: $(uname -srmo)"

  if has_cmd dpkg; then
    local audit
    audit="$(dpkg --audit 2>&1 || true)"
    if [[ -z "${audit//[[:space:]]/}" ]]; then
      emit OK "dpkg не сообщает о незавершённых пакетах"
    else
      emit CRITICAL "dpkg сообщает о незавершённой настройке пакетов"
      printf '%s\n' "$audit" | sed 's/^/             /'
    fi
  else
    emit SKIP "dpkg не найден"
  fi

  if has_cmd apt-get; then
    local simulation upgradable security
    simulation="$(timeout 45 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null || true)"
    upgradable="$(grep -c '^Inst ' <<<"$simulation" || true)"
    security="$(grep '^Inst ' <<<"$simulation" | grep -Eic 'security|Debian-Security' || true)"
    if (( upgradable == 0 )); then
      emit OK "Ожидающих обновлений в текущем APT-кэше нет"
    elif (( security > 0 )); then
      emit WARN "Доступно обновлений: $upgradable, из них похожих на security: $security"
    else
      emit INFO "Доступно обновлений: $upgradable; security-пакеты по текущему кэшу не выделены"
    fi
  else
    emit SKIP "APT не найден"
  fi

  if systemctl list-unit-files unattended-upgrades.service >/dev/null 2>&1; then
    if service_active unattended-upgrades.service || service_enabled unattended-upgrades.service; then
      emit OK "unattended-upgrades установлен и активирован"
    else
      emit WARN "unattended-upgrades установлен, но не активен"
    fi
  elif has_cmd dpkg-query && dpkg-query -W unattended-upgrades >/dev/null 2>&1; then
    emit WARN "Пакет unattended-upgrades установлен, но systemd unit не найден"
  else
    emit WARN "Автоматические обновления безопасности unattended-upgrades не установлены"
  fi

  if [[ -e /var/run/reboot-required ]]; then
    emit WARN "Для применения обновлений требуется перезагрузка"
  else
    emit OK "Флаг обязательной перезагрузки отсутствует"
  fi
}

check_users_and_ssh() {
  section "Пользователи и SSH"

  local uid0 shell_users empty_passwords sudo_members wheel_members
  uid0="$(awk -F: '$3 == 0 {print $1}' /etc/passwd | paste -sd, -)"
  if [[ "$uid0" == "root" ]]; then
    emit OK "Единственный пользователь с UID 0: root"
  else
    emit CRITICAL "Пользователи с UID 0: ${uid0:-не удалось определить}"
  fi

  shell_users="$(awk -F: '$7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | paste -sd, -)"
  emit INFO "Учётные записи с интерактивной оболочкой: ${shell_users:-нет}"

  if [[ -r /etc/shadow ]]; then
    empty_passwords="$(awk -F: '$2 == "" {print $1}' /etc/shadow | paste -sd, -)"
    if [[ -z "$empty_passwords" ]]; then
      emit OK "Учётных записей с пустым паролем не найдено"
    else
      emit CRITICAL "Учётные записи с пустым паролем: $empty_passwords"
    fi
  else
    emit SKIP "Нет доступа к /etc/shadow"
  fi

  sudo_members="$(getent group sudo 2>/dev/null | awk -F: '{print $4}' || true)"
  wheel_members="$(getent group wheel 2>/dev/null | awk -F: '{print $4}' || true)"
  emit INFO "Члены sudo/wheel: ${sudo_members:-${wheel_members:-не указаны}}"

  local ssh_service=""
  if service_active ssh.service; then
    ssh_service=ssh.service
  elif service_active sshd.service; then
    ssh_service=sshd.service
  fi

  if [[ -z "$ssh_service" ]]; then
    emit WARN "Активный SSH service не найден"
    return
  fi
  emit OK "SSH активен: $ssh_service"

  if ! has_cmd sshd; then
    emit WARN "Команда sshd не найдена; эффективная конфигурация не проверена"
    return
  fi

  local sshd_effective
  sshd_effective="$(sshd -T 2>/dev/null || true)"
  if [[ -z "$sshd_effective" ]]; then
    emit WARN "Не удалось получить эффективную конфигурацию sshd"
    return
  fi

  local permit_root password_auth kbd_auth pubkey_auth empty_auth max_auth grace x11 agent tcp_forward
  permit_root="$(awk '$1=="permitrootlogin" {print $2; exit}' <<<"$sshd_effective")"
  password_auth="$(awk '$1=="passwordauthentication" {print $2; exit}' <<<"$sshd_effective")"
  kbd_auth="$(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<<"$sshd_effective")"
  pubkey_auth="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<<"$sshd_effective")"
  empty_auth="$(awk '$1=="permitemptypasswords" {print $2; exit}' <<<"$sshd_effective")"
  max_auth="$(awk '$1=="maxauthtries" {print $2; exit}' <<<"$sshd_effective")"
  grace="$(awk '$1=="logingracetime" {print $2; exit}' <<<"$sshd_effective")"
  x11="$(awk '$1=="x11forwarding" {print $2; exit}' <<<"$sshd_effective")"
  agent="$(awk '$1=="allowagentforwarding" {print $2; exit}' <<<"$sshd_effective")"
  tcp_forward="$(awk '$1=="allowtcpforwarding" {print $2; exit}' <<<"$sshd_effective")"

  case "$permit_root" in
    no) emit OK "Прямой вход root по SSH запрещён" ;;
    prohibit-password|without-password) emit WARN "Root SSH разрешён только по ключу ($permit_root)" ;;
    yes) emit CRITICAL "Прямой вход root по SSH полностью разрешён" ;;
    *) emit WARN "PermitRootLogin=$permit_root" ;;
  esac

  if [[ "$password_auth" == "no" ]]; then
    emit OK "Парольная SSH-аутентификация отключена"
  else
    if [[ "$permit_root" == "yes" ]]; then
      emit CRITICAL "Парольная SSH-аутентификация включена при разрешённом root-login"
    else
      emit WARN "Парольная SSH-аутентификация включена"
    fi
  fi
  [[ "$kbd_auth" == "no" ]] && emit OK "Keyboard-interactive SSH отключён" || emit WARN "Keyboard-interactive SSH включён"
  [[ "$pubkey_auth" == "yes" ]] && emit OK "SSH-ключи разрешены" || emit CRITICAL "SSH-ключи отключены"
  [[ "$empty_auth" == "no" ]] && emit OK "SSH не принимает пустые пароли" || emit CRITICAL "SSH допускает пустые пароли"

  if [[ "$max_auth" =~ ^[0-9]+$ ]] && (( max_auth <= 4 )); then
    emit OK "MaxAuthTries=$max_auth"
  else
    emit WARN "MaxAuthTries=${max_auth:-не определён}; рекомендуется не более 4"
  fi

  if [[ "$grace" =~ ^[0-9]+$ ]] && (( grace <= 60 )); then
    emit OK "LoginGraceTime=${grace}s"
  else
    emit WARN "LoginGraceTime=${grace:-не определён}; рекомендуется не более 60 секунд"
  fi

  [[ "$x11" == "no" ]] && emit OK "X11Forwarding отключён" || emit WARN "X11Forwarding включён"
  [[ "$agent" == "no" ]] && emit OK "SSH agent forwarding отключён" || emit WARN "SSH agent forwarding включён"
  [[ "$tcp_forward" == "no" ]] && emit OK "SSH TCP forwarding отключён" || emit INFO "SSH TCP forwarding разрешён: $tcp_forward"

  local bad_permissions=0 home ssh_dir auth_file mode user shell
  while IFS=: read -r user _ _ _ _ home shell; do
    [[ "$shell" =~ (nologin|false)$ ]] && continue
    ssh_dir="$home/.ssh"
    auth_file="$ssh_dir/authorized_keys"
    if [[ -d "$ssh_dir" ]]; then
      mode="$(stat -c '%a' "$ssh_dir" 2>/dev/null || true)"
      if [[ -n "$mode" ]] && (( 10#$mode % 100 >= 20 )); then
        emit WARN "$ssh_dir имеет слишком широкие права: $mode"
        ((bad_permissions+=1))
      fi
    fi
    if [[ -f "$auth_file" ]]; then
      mode="$(stat -c '%a' "$auth_file" 2>/dev/null || true)"
      if [[ -n "$mode" ]] && (( 10#$mode % 100 >= 20 )); then
        emit WARN "$auth_file имеет слишком широкие права: $mode"
        ((bad_permissions+=1))
      fi
    fi
  done </etc/passwd
  (( bad_permissions == 0 )) && emit OK "Опасные права на .ssh/authorized_keys не обнаружены"
}

check_network() {
  section "Сетевая поверхность и публичные порты"

  if ! has_cmd ss; then
    emit SKIP "Команда ss не найдена"
    return
  fi

  local listeners public_listeners count line port
  listeners="$(ss -H -lntup 2>/dev/null || true)"
  public_listeners="$(grep -E '([[:space:]]|^)(0\.0\.0\.0:|\[::\]:|\*:)' <<<"$listeners" || true)"
  count="$(grep -c . <<<"$public_listeners" || true)"

  if (( count == 0 )); then
    emit OK "Публичные TCP/UDP listeners не найдены"
  else
    emit INFO "Публичных listeners: $count"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '             %s\n' "$line"
      port="$(sed -E 's/.*:([0-9]+)[[:space:]].*/\1/' <<<"$line")"
      case "$port" in
        2375|2376|5432|6379|6380|18888)
          emit CRITICAL "Чувствительный сервис доступен публично на порту $port"
          ;;
        3000|3001|3002|6767|8080|8081|8082|9090)
          emit WARN "Административный/служебный порт $port слушает публичный интерфейс"
          ;;
      esac
    done <<<"$public_listeners"
  fi

  if grep -Eq '127\.0\.0\.1:18888|\[::1\]:18888' <<<"$listeners"; then
    emit OK "CrowdSec LAPI 18888 привязан к loopback"
  elif grep -Eq ':18888[[:space:]]' <<<"$listeners"; then
    emit CRITICAL "CrowdSec LAPI 18888 не ограничен loopback"
  fi
}

check_firewall_and_ping() {
  section "Firewall, сканирование и ping"

  local nft_rules="" iptables_rules="" ip6tables_rules=""
  local firewall_found=0 input_drop=0 established=0 invalid_drop=0
  if has_cmd nft; then
    nft_rules="$(nft list ruleset 2>/dev/null || true)"
    if [[ -n "$nft_rules" ]]; then
      firewall_found=1
      grep -Eq 'hook input[^;]*;[[:space:]]*policy drop' <<<"$nft_rules" && input_drop=1
      grep -Eqi 'ct state[^\n]*(established|related)[^\n]*accept' <<<"$nft_rules" && established=1
      grep -Eqi 'ct state[^\n]*invalid[^\n]*drop' <<<"$nft_rules" && invalid_drop=1
      emit INFO "Обнаружен nftables ruleset"
    fi
  fi

  if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    firewall_found=1
    emit OK "UFW активен"
    ufw status verbose 2>/dev/null | grep -Eq 'Default: deny \(incoming\)|Default: reject \(incoming\)' && input_drop=1
  fi

  if has_cmd iptables; then
    if iptables -S INPUT >/dev/null 2>&1; then
      firewall_found=1
      iptables_rules="$(iptables-save 2>/dev/null || true)"
      iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP' && input_drop=1
      iptables -S INPUT 2>/dev/null | grep -Eq -- '--ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED).* -j ACCEPT' && established=1
      iptables -S INPUT 2>/dev/null | grep -Eq -- '--ctstate INVALID.* -j DROP' && invalid_drop=1
    fi
  fi
  if has_cmd ip6tables; then
    ip6tables_rules="$(ip6tables-save 2>/dev/null || true)"
  fi

  if (( firewall_found == 0 )); then
    emit CRITICAL "Активные правила host firewall не обнаружены"
  elif (( input_drop == 1 )); then
    emit OK "Входящий firewall использует политику DROP/DENY"
  else
    emit WARN "Не удалось подтвердить политику DROP/DENY для входящего трафика"
  fi

  (( established == 1 )) && emit OK "Established/related соединения явно разрешены" || emit INFO "Правило established/related не распознано автоматически"
  (( invalid_drop == 1 )) && emit OK "Invalid packets явно отбрасываются" || emit WARN "Не найдено явное отбрасывание ct state invalid"

  local ping4 ping6 ipv6_disabled
  ping4="$(sysctl_value net.ipv4.icmp_echo_ignore_all)"
  ipv6_disabled="$(sysctl_value net.ipv6.conf.all.disable_ipv6)"
  ping6="$(sysctl_value net.ipv6.icmp.echo_ignore_all)"

  if [[ "$ping4" == "1" ]]; then
    emit OK "IPv4 ping полностью отключён через sysctl"
  elif grep -Eqi 'icmp type echo-request[^\n]*(limit|drop)' <<<"$nft_rules" || \
       grep -Eqi -- '-p icmp[^\n]*(--icmp-type echo-request|--icmp-type 8)[^\n]*(-m limit|-j DROP)' <<<"$iptables_rules"; then
    emit OK "IPv4 echo-request ограничивается или отбрасывается firewall"
  else
    emit WARN "Ограничение IPv4 ping не обнаружено"
  fi

  if [[ "$ipv6_disabled" == "1" ]]; then
    emit SKIP "IPv6 отключён"
  elif [[ "$ping6" == "1" ]]; then
    emit OK "IPv6 echo-request отключён через sysctl"
  elif grep -Eqi '(icmpv6|meta l4proto ipv6-icmp)[^\n]*echo-request[^\n]*(limit|drop)' <<<"$nft_rules" || \
       grep -Eqi -- '-p ipv6-icmp[^\n]*(echo-request|--icmpv6-type 128)[^\n]*(-m limit|-j DROP)' <<<"$ip6tables_rules"; then
    emit OK "IPv6 echo-request ограничивается или отбрасывается firewall"
  else
    emit WARN "Ограничение IPv6 ping не обнаружено; служебный ICMPv6 блокировать полностью нельзя"
  fi

  if service_active crowdsec-firewall-bouncer.service; then
    emit OK "CrowdSec firewall bouncer активен и может динамически блокировать сканеры"
  else
    emit WARN "CrowdSec firewall bouncer не активен"
  fi
}

check_sysctl() {
  section "Kernel/sysctl hardening"

  check_equals net.ipv4.tcp_syncookies 1 "SYN cookies включены"
  check_equals net.ipv4.icmp_echo_ignore_broadcasts 1 "Broadcast ICMP echo игнорируется"
  check_equals net.ipv4.conf.all.accept_redirects 0 "IPv4 redirects не принимаются"
  check_equals net.ipv4.conf.default.accept_redirects 0 "IPv4 redirects по умолчанию не принимаются"
  check_equals net.ipv4.conf.all.send_redirects 0 "IPv4 redirects не отправляются"
  check_equals net.ipv4.conf.default.send_redirects 0 "IPv4 redirects по умолчанию не отправляются"
  check_equals net.ipv4.conf.all.accept_source_route 0 "IPv4 source routing отключён"
  check_equals net.ipv4.conf.default.accept_source_route 0 "IPv4 source routing по умолчанию отключён"

  local rp_all rp_default
  rp_all="$(sysctl_value net.ipv4.conf.all.rp_filter)"
  rp_default="$(sysctl_value net.ipv4.conf.default.rp_filter)"
  if [[ "$rp_all" =~ ^[12]$ && "$rp_default" =~ ^[12]$ ]]; then
    emit OK "Reverse path filtering включён (all=$rp_all, default=$rp_default)"
  else
    emit WARN "Reverse path filtering ослаблен (all=${rp_all:-?}, default=${rp_default:-?}); для VPN допустим loose mode=2"
  fi

  if [[ "$(sysctl_value net.ipv6.conf.all.disable_ipv6)" != "1" ]]; then
    check_equals net.ipv6.conf.all.accept_redirects 0 "IPv6 redirects не принимаются"
    check_equals net.ipv6.conf.default.accept_redirects 0 "IPv6 redirects по умолчанию не принимаются"
    check_equals net.ipv6.conf.all.accept_source_route 0 "IPv6 source routing отключён"
    check_equals net.ipv6.conf.default.accept_source_route 0 "IPv6 source routing по умолчанию отключён"
  fi

  local kptr dmesg ptrace
  kptr="$(sysctl_value kernel.kptr_restrict)"
  dmesg="$(sysctl_value kernel.dmesg_restrict)"
  ptrace="$(sysctl_value kernel.yama.ptrace_scope)"
  [[ "$kptr" =~ ^[12]$ ]] && emit OK "kernel.kptr_restrict=$kptr" || emit WARN "kernel.kptr_restrict=${kptr:-не определён}"
  [[ "$dmesg" == "1" ]] && emit OK "kernel.dmesg_restrict=1" || emit WARN "kernel.dmesg_restrict=${dmesg:-не определён}"
  [[ "$ptrace" =~ ^[1-3]$ ]] && emit OK "kernel.yama.ptrace_scope=$ptrace" || emit WARN "kernel.yama.ptrace_scope=${ptrace:-не определён}"
}

check_crowdsec() {
  section "CrowdSec"

  if ! has_cmd cscli; then
    emit WARN "CrowdSec не установлен"
    return
  fi

  if service_active crowdsec.service; then
    emit OK "CrowdSec Security Engine активен"
  else
    emit CRITICAL "CrowdSec установлен, но service не активен"
  fi

  if has_cmd crowdsec && crowdsec -t >/dev/null 2>&1; then
    emit OK "Конфигурация CrowdSec проходит проверку"
  else
    emit WARN "Проверка конфигурации CrowdSec завершилась ошибкой"
  fi

  if cscli capi status >/dev/null 2>&1; then
    emit OK "CrowdSec Central API доступен"
  else
    emit WARN "CrowdSec Central API недоступен"
  fi

  local bouncers bouncer_json valid_firewall acquisition
  bouncers="$(cscli bouncers list 2>/dev/null || true)"
  bouncer_json="$(cscli bouncers list -o json 2>/dev/null || true)"
  valid_firewall=0
  if [[ -n "$bouncer_json" ]] && has_cmd python3; then
    valid_firewall="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(0)
    raise SystemExit
if isinstance(data, dict):
    data = data.get("bouncers", data.get("items", []))
count = 0
for item in data if isinstance(data, list) else []:
    name = str(item.get("name", ""))
    valid = item.get("valid")
    if "firewall-bouncer" in name and valid is True:
        count += 1
print(count)
' <<<"$bouncer_json" 2>/dev/null || printf 0)"
  fi

  if [[ "$valid_firewall" =~ ^[0-9]+$ ]] && (( valid_firewall > 0 )); then
    emit OK "Зарегистрирован валидный firewall bouncer"
  elif grep -q 'firewall-bouncer' <<<"$bouncers"; then
    emit WARN "Firewall bouncer зарегистрирован, но валидность не подтверждена"
  else
    emit WARN "Firewall bouncer не найден в cscli bouncers list"
  fi

  acquisition="$(cscli metrics show acquisition 2>/dev/null || true)"
  if grep -q 'auth.log\|journalctl' <<<"$acquisition"; then
    emit OK "SSH/system acquisition получает данные"
  else
    emit WARN "SSH/system acquisition не распознана в метриках"
  fi
  if grep -Eqi 'caddy|docker:' <<<"$acquisition"; then
    emit OK "Caddy/Docker acquisition присутствует в метриках"
  else
    emit INFO "Caddy/Docker acquisition не видна; это нормально для ролей без Caddy или до первого запроса"
  fi
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
  if [[ -n "$docker_members" ]]; then
    emit WARN "Пользователи группы docker имеют привилегии уровня root: $docker_members"
  else
    emit OK "Дополнительные пользователи группы docker не указаны"
  fi

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
    issues = []
    infos = []

    if host.get("Privileged"):
        issues.append(("CRITICAL", "privileged=true"))
    if host.get("NetworkMode") == "host":
        issues.append(("WARN", "network_mode=host"))
    if not host.get("ReadonlyRootfs"):
        infos.append("rootfs writable")

    user = config.get("User", "")
    if user in ("", "0", "root", "0:0"):
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
        print("INFO|{}|{}".format(name, ", ".join(infos)))
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
  public_ports="$(docker ps --format '{{.Names}}|{{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:' || true)"
  if [[ -n "$public_ports" ]]; then
    emit INFO "Контейнеры публикуют порты на всех интерфейсах:"
    sed 's/^/             /' <<<"$public_ports"
  else
    emit OK "Публичные Docker port bindings не обнаружены"
  fi
}

check_storage_time_logs() {
  section "Диск, время и журналы"

  local disk inode disk_num inode_num
  disk="$(df -P / 2>/dev/null | awk 'NR==2 {print $5}')"
  inode="$(df -Pi / 2>/dev/null | awk 'NR==2 {print $5}')"
  disk_num="$(percent_used "$disk")"
  inode_num="$(percent_used "$inode")"

  if [[ "$disk_num" =~ ^[0-9]+$ ]] && (( disk_num >= 90 )); then
    emit CRITICAL "Корневой раздел заполнен на $disk"
  elif [[ "$disk_num" =~ ^[0-9]+$ ]] && (( disk_num >= 80 )); then
    emit WARN "Корневой раздел заполнен на $disk"
  else
    emit OK "Использование корневого раздела: ${disk:-не определено}"
  fi

  if [[ "$inode_num" =~ ^[0-9]+$ ]] && (( inode_num >= 90 )); then
    emit CRITICAL "Inode корневого раздела заняты на $inode"
  elif [[ "$inode_num" =~ ^[0-9]+$ ]] && (( inode_num >= 80 )); then
    emit WARN "Inode корневого раздела заняты на $inode"
  else
    emit OK "Использование inode: ${inode:-не определено}"
  fi

  if has_cmd timedatectl; then
    local synced
    synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [[ "$synced" == "yes" ]] && emit OK "Время синхронизировано по NTP" || emit WARN "NTP-синхронизация времени не подтверждена"
  else
    emit SKIP "timedatectl не найден"
  fi

  if service_active logrotate.timer || service_enabled logrotate.timer; then
    emit OK "logrotate timer активен"
  elif has_cmd logrotate; then
    emit INFO "logrotate установлен; используется cron или другой запуск"
  else
    emit WARN "logrotate не установлен"
  fi

  local failed_units
  failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
  if [[ -z "$failed_units" ]]; then
    emit OK "Неуспешных systemd units нет"
  else
    emit WARN "Есть неуспешные systemd units"
    sed 's/^/             /' <<<"$failed_units"
  fi

  local oom_count ssh_failures
  oom_count="$(journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -Eic 'out of memory|oom-killer|killed process' || true)"
  (( oom_count == 0 )) && emit OK "OOM-событий за 24 часа не обнаружено" || emit WARN "OOM-событий за 24 часа: $oom_count"

  ssh_failures="$(journalctl -u ssh.service -u sshd.service --since '24 hours ago' --no-pager 2>/dev/null | grep -Eic 'Failed password|Invalid user|authentication failure' || true)"
  if (( ssh_failures == 0 )); then
    emit OK "Неудачных SSH-входов в journal за 24 часа не обнаружено"
  elif (( ssh_failures >= 100 )); then
    emit WARN "Неудачных SSH-входов за 24 часа: $ssh_failures"
  else
    emit INFO "Неудачных SSH-входов за 24 часа: $ssh_failures"
  fi
}

check_sensitive_files() {
  section "Права на секреты и конфигурации"

  local files=()
  local file mode bad=0
  for file in \
    /etc/crowdsec/local_api_credentials.yaml \
    /etc/crowdsec/online_api_credentials.yaml \
    /root/.ssh/authorized_keys; do
    [[ -f "$file" ]] && files+=("$file")
  done

  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(find /etc/crowdsec/bouncers -maxdepth 1 -type f -name '*.yaml.local' 2>/dev/null || true)

  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(find /opt -xdev -maxdepth 5 -type f \( -name '.env' -o -name '*.env' \) 2>/dev/null | head -n 100 || true)

  if (( ${#files[@]} == 0 )); then
    emit INFO "Известные файлы секретов не найдены"
    return
  fi

  for file in "${files[@]}"; do
    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
    [[ -z "$mode" ]] && continue
    if (( 10#$mode % 10 >= 4 )); then
      emit CRITICAL "$file доступен для чтения всем (mode=$mode)"
      ((bad+=1))
    elif (( (10#$mode / 10) % 10 >= 4 )); then
      emit WARN "$file доступен группе (mode=$mode); проверьте необходимость"
      ((bad+=1))
    fi
  done
  (( bad == 0 )) && emit OK "У известных файлов секретов нет world/group-readable прав"
}

print_summary() {
  section "ИТОГ"
  printf 'Critical: %d\n' "$CRITICAL_COUNT"
  printf 'Warning:  %d\n' "$WARN_COUNT"
  printf 'OK:       %d\n' "$OK_COUNT"
  printf 'Info:     %d\n' "$INFO_COUNT"
  printf 'Skip:     %d\n' "$SKIP_COUNT"
  printf '\n'

  if (( CRITICAL_COUNT > 0 )); then
    printf 'Рекомендация: сначала устраните критические проблемы.\n'
  elif (( WARN_COUNT > 0 )); then
    printf 'Рекомендация: критических проблем не найдено, изучите предупреждения.\n'
  else
    printf 'Критические проблемы и предупреждения не обнаружены.\n'
  fi
  printf 'Проверка завершена. Изменений в систему не внесено.\n'
}

print_header
check_os
check_users_and_ssh
check_network
check_firewall_and_ping
check_sysctl
check_crowdsec
check_docker
check_storage_time_logs
check_sensitive_files
print_summary

exit 0
