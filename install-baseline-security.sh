#!/usr/bin/env bash
set -euo pipefail
umask 077

STATE_DIR="/var/lib/server-security"
TX_ROOT="$STATE_DIR/transactions"
SSH_MANAGED="/etc/ssh/sshd_config.d/00-server-security.conf"
SYSCTL_MANAGED="/etc/sysctl.d/90-server-security.conf"
APT_MANAGED="/etc/apt/apt.conf.d/90-server-security"
NFT_DIR="/etc/server-security"
NFT_CONFIG="$NFT_DIR/nftables.conf"
NFT_HELPER="/usr/local/sbin/server-security-apply-nft"
NFT_SERVICE="server-security-nft.service"
SSH_CONNECTION="${SSH_CONNECTION:-${SSH_CLIENT:-}}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: запускайте через sudo" >&2
  exit 1
}
[[ -r /dev/tty ]] || {
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
}

mkdir -p "$TX_ROOT"
chmod 0700 "$STATE_DIR" "$TX_ROOT"

say() { printf '%s\n' "$*"; }
status() { printf '[%-10s] %s\n' "$1" "$2"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

ask_yes() {
  local prompt="$1" answer
  read -r -p "$prompt [Y/n]: " answer
  answer="${answer:-yes}"
  case "${answer,,}" in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

ask_no() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  case "${answer,,}" in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

pause() {
  read -r -p "Нажмите Enter для продолжения..." _ || true
}

safe_id() {
  printf '%s-%s-%s-%s' "$(date +%Y%m%d-%H%M%S)" "$1" "$$" "$RANDOM"
}

transaction_create() {
  local kind="$1" id tx
  id="$(safe_id "$kind")"
  tx="$TX_ROOT/$id"
  mkdir -p "$tx"
  chmod 0700 "$tx"
  printf '%s' "$tx"
}

transaction_start_timer() {
  local tx="$1" minutes="$2" id unit service_file timer_file
  id="$(basename "$tx")"
  unit="server-security-rollback-$id"
  service_file="/etc/systemd/system/$unit.service"
  timer_file="/etc/systemd/system/$unit.timer"

  if ! has_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    status ERROR "systemd недоступен — опасное изменение отменено"
    return 1
  fi

  cat >"$service_file" <<UNIT
[Unit]
Description=Automatic rollback for server security transaction $id

[Service]
Type=oneshot
ExecStart=/bin/bash $tx/rollback.sh
UNIT

  cat >"$timer_file" <<UNIT
[Unit]
Description=Rollback timer for server security transaction $id

[Timer]
OnActiveSec=${minutes}min
AccuracySec=1s
Persistent=true
Unit=$unit.service

[Install]
WantedBy=timers.target
UNIT

  chmod 0600 "$service_file" "$timer_file"
  printf '%s' "$unit" >"$tx/unit"
  printf 'PENDING\n' >"$tx/status"
  systemctl daemon-reload
  systemctl enable --now "$unit.timer" >/dev/null
  status ROLLBACK "Автовосстановление запланировано через $minutes мин. ($unit.timer)"
}

transaction_cleanup_units_snippet() {
  local unit="$1"
  cat <<EOF
systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
}

transaction_cancel() {
  local tx="$1" unit
  unit="$(cat "$tx/unit")"
  systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  printf 'CONFIRMED\n' >"$tx/status"
  status CONFIRMED "Автоматический откат отменён"
}

transaction_rollback_now() {
  local tx="$1" unit
  unit="$(cat "$tx/unit")"
  status RESTORE "Выполняю немедленный откат"
  systemctl start "$unit.service" || /bin/bash "$tx/rollback.sh"
}

confirm_or_leave_timer() {
  local tx="$1" message="$2"
  say ""
  say "$message"
  if ask_no "Работа сервера и новое SSH-подключение проверены. Отменить откат?"; then
    transaction_cancel "$tx"
    return 0
  fi
  status ROLLBACK "Подтверждение не получено. Таймер оставлен активным"
  say "Мастер остановлен до завершения или ручной отмены транзакции."
  return 2
}

find_sshd_bin() {
  if has_cmd sshd; then command -v sshd; elif [[ -x /usr/sbin/sshd ]]; then printf '/usr/sbin/sshd'; fi
}

find_ssh_service() {
  if service_active ssh.service; then printf 'ssh.service'; elif service_active sshd.service; then printf 'sshd.service'; fi
}

sshd_effective() {
  local bin
  bin="$(find_sshd_bin)"
  [[ -n "$bin" ]] || return 1
  "$bin" -T 2>/dev/null
}

sshd_value() {
  local key="$1"
  sshd_effective | awk -v key="${key,,}" '$1==key {print $2; exit}'
}

valid_key_count() {
  local file="$1" count=0 line tmp
  [[ -f "$file" ]] || { printf 0; return; }
  tmp="$(mktemp)"
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    printf '%s\n' "$line" >"$tmp"
    if ssh-keygen -lf "$tmp" >/dev/null 2>&1; then ((count+=1)); fi
  done <"$file"
  rm -f "$tmp"
  printf '%s' "$count"
}

setup_ssh_key() {
  local default_user target entry home group auth_file count choice pub tmp server_ip
  default_user="${SUDO_USER:-root}"
  [[ "$default_user" == "root" || -n "$default_user" ]] || default_user=root

  read -r -p "Пользователь для входа по SSH-ключу [$default_user]: " target
  target="${target:-$default_user}"
  entry="$(getent passwd "$target" || true)"
  if [[ -z "$entry" ]]; then
    status ERROR "Пользователь $target не существует"
    return 1
  fi
  home="$(awk -F: '{print $6}' <<<"$entry")"
  group="$(id -gn "$target")"
  auth_file="$home/.ssh/authorized_keys"
  count="$(valid_key_count "$auth_file")"

  if (( count > 0 )); then
    status OK "У пользователя $target найдено корректных SSH-ключей: $count"
    if ask_no "Подтвердить, что вход этим пользователем по ключу уже проверен в новой сессии?"; then
      KEY_LOGIN_CONFIRMED=1
      SSH_TARGET_USER="$target"
    else
      KEY_LOGIN_CONFIRMED=0
      SSH_TARGET_USER="$target"
      status INFO "Отключение парольной аутентификации предлагаться не будет"
    fi
    return 0
  fi

  status CHECK "Рабочие ключи для $target не найдены"
  ask_yes "Настроить вход по SSH-ключу для $target?" || {
    status SKIP "Настройка SSH-ключа пропущена"
    KEY_LOGIN_CONFIRMED=0
    SSH_TARGET_USER="$target"
    return 0
  }

  cat <<'INSTRUCTIONS'

На вашем компьютере откройте новый терминал и создайте ключ:

  macOS / Linux / Windows PowerShell:

  ssh-keygen -t ed25519 -a 100 -f ~/.ssh/vpn-admin-ed25519 -C "vpn-admin"

Рекомендуется задать парольную фразу. Приватный ключ остаётся только
на вашем компьютере. На сервер передаётся строка из файла .pub.

Просмотр публичного ключа:

  macOS / Linux:
  cat ~/.ssh/vpn-admin-ed25519.pub

  Windows PowerShell:
  Get-Content $HOME\.ssh\vpn-admin-ed25519.pub

Никогда не вставляйте блок, начинающийся с:
  -----BEGIN OPENSSH PRIVATE KEY-----
INSTRUCTIONS

  say ""
  say "1 — Вставить публичный ключ в этот мастер"
  say "2 — Использовать ssh-copy-id из другого терминала"
  say "0 — Пропустить"
  read -r -p "Выберите способ [1]: " choice
  choice="${choice:-1}"

  mkdir -p "$home/.ssh"
  chown "$target:$group" "$home/.ssh"
  chmod 0700 "$home/.ssh"

  case "$choice" in
    1)
      read -r -p "Вставьте одну строку публичного ключа: " pub
      if grep -q 'BEGIN .*PRIVATE KEY' <<<"$pub"; then
        status ERROR "Обнаружен приватный ключ. Он не был сохранён"
        return 1
      fi
      case "$pub" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *) ;;
        *) status ERROR "Формат публичного ключа не распознан"; return 1 ;;
      esac
      tmp="$(mktemp)"
      printf '%s\n' "$pub" >"$tmp"
      if ! ssh-keygen -lf "$tmp"; then
        rm -f "$tmp"
        status ERROR "ssh-keygen не смог проверить ключ"
        return 1
      fi
      rm -f "$tmp"
      mkdir -p "$STATE_DIR/key-backups"
      chmod 0700 "$STATE_DIR/key-backups"
      if [[ -f "$auth_file" ]]; then
        cp -a "$auth_file" "$STATE_DIR/key-backups/${target}-authorized_keys-$(date +%Y%m%d-%H%M%S)"
      fi
      touch "$auth_file"
      if grep -Fqx "$pub" "$auth_file"; then
        status OK "Такой ключ уже присутствует"
      else
        printf '%s\n' "$pub" >>"$auth_file"
        status APPLIED "Публичный ключ добавлен"
      fi
      chown "$target:$group" "$auth_file"
      chmod 0600 "$auth_file"
      ;;
    2)
      server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      say ""
      say "В другом терминале на вашем компьютере выполните:"
      say "  ssh-copy-id -i ~/.ssh/vpn-admin-ed25519.pub $target@${server_ip:-SERVER_IP}"
      pause
      count="$(valid_key_count "$auth_file")"
      if (( count == 0 )); then
        status ERROR "После ожидания корректный ключ не найден"
        return 1
      fi
      ;;
    0) status SKIP "Добавление ключа пропущено"; KEY_LOGIN_CONFIRMED=0; SSH_TARGET_USER="$target"; return 0 ;;
    *) status ERROR "Неизвестный вариант"; return 1 ;;
  esac

  server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  say ""
  say "Откройте НОВУЮ SSH-сессию и проверьте вход:"
  say "  ssh -i ~/.ssh/vpn-admin-ed25519 $target@${server_ip:-SERVER_IP}"
  if ask_no "Новое подключение по ключу успешно?"; then
    KEY_LOGIN_CONFIRMED=1
    status CONFIRMED "Вход по ключу подтверждён"
  else
    KEY_LOGIN_CONFIRMED=0
    status WARN "Вход по ключу не подтверждён. Парольный вход отключаться не будет"
  fi
  SSH_TARGET_USER="$target"
}

managed_set_option() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  awk -v key="${key,,}" -v value="$value" '
    BEGIN {done=0}
    /^[[:space:]]*#/ {print; next}
    NF > 0 && tolower($1)==key {
      if (!done) {print key " " value; done=1}
      next
    }
    {print}
    END {if (!done) print key " " value}
  ' "$file" >"$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

offer_ssh_settings() {
  local effective current selected=0 bin service tx unit key value
  declare -A desired=()
  effective="$(sshd_effective || true)"
  if [[ -z "$effective" ]]; then
    status ERROR "Не удалось прочитать эффективную конфигурацию sshd"
    return 1
  fi
  bin="$(find_sshd_bin)"
  service="$(find_ssh_service)"
  [[ -n "$service" ]] || { status ERROR "Активный SSH service не найден"; return 1; }

  current="$(sshd_value pubkeyauthentication)"
  if [[ "$current" == "yes" ]]; then status OK "PubkeyAuthentication уже включена";
  elif ask_yes "Включить PubkeyAuthentication?"; then desired[PubkeyAuthentication]=yes; ((selected+=1)); fi

  current="$(sshd_value permitrootlogin)"
  case "$current" in
    no|prohibit-password|without-password|forced-commands-only) status OK "PermitRootLogin=$current уже ограничивает root-вход" ;;
    *) if ask_yes "Ограничить вход root только SSH-ключом (prohibit-password)?"; then desired[PermitRootLogin]=prohibit-password; ((selected+=1)); fi ;;
  esac

  current="$(sshd_value passwordauthentication)"
  if [[ "$current" == "no" ]]; then
    status OK "PasswordAuthentication уже отключена"
  elif (( KEY_LOGIN_CONFIRMED == 1 )); then
    if ask_yes "Отключить PasswordAuthentication?"; then desired[PasswordAuthentication]=no; ((selected+=1)); fi
  else
    status SKIP "PasswordAuthentication оставлена: вход по ключу не подтверждён"
  fi

  current="$(sshd_value kbdinteractiveauthentication)"
  if [[ "$current" == "no" ]]; then
    status OK "KbdInteractiveAuthentication уже отключена"
  elif (( KEY_LOGIN_CONFIRMED == 1 )); then
    if ask_yes "Отключить KbdInteractiveAuthentication?"; then desired[KbdInteractiveAuthentication]=no; ((selected+=1)); fi
  else
    status SKIP "Keyboard-interactive оставлен: вход по ключу не подтверждён"
  fi

  current="$(sshd_value permitemptypasswords)"
  if [[ "$current" == "no" ]]; then status OK "Пустые SSH-пароли уже запрещены";
  elif ask_yes "Запретить пустые SSH-пароли?"; then desired[PermitEmptyPasswords]=no; ((selected+=1)); fi

  current="$(sshd_value maxauthtries)"
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current <= 3 )); then status OK "MaxAuthTries=$current уже ограничен";
  elif ask_yes "Ограничить число попыток входа MaxAuthTries=3?"; then desired[MaxAuthTries]=3; ((selected+=1)); fi

  current="$(sshd_value logingracetime)"
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current <= 30 )); then status OK "LoginGraceTime=${current}s уже ограничен";
  elif ask_yes "Установить LoginGraceTime=30 секунд?"; then desired[LoginGraceTime]=30; ((selected+=1)); fi

  current="$(sshd_value maxstartups)"
  if [[ "$current" == "10:30:60" ]]; then status OK "MaxStartups уже равен 10:30:60";
  elif ask_yes "Ограничить неавторизованные соединения MaxStartups=10:30:60?"; then desired[MaxStartups]=10:30:60; ((selected+=1)); fi

  current="$(sshd_value x11forwarding)"
  if [[ "$current" == "no" ]]; then status OK "X11Forwarding уже отключён";
  elif ask_yes "Отключить X11Forwarding?"; then desired[X11Forwarding]=no; ((selected+=1)); fi

  current="$(sshd_value allowagentforwarding)"
  if [[ "$current" == "no" ]]; then status OK "SSH agent forwarding уже отключён";
  elif ask_yes "Отключить SSH agent forwarding?"; then desired[AllowAgentForwarding]=no; ((selected+=1)); fi

  (( selected > 0 )) || { status OK "Дополнительные изменения SSH не выбраны"; return 0; }

  tx="$(transaction_create ssh)"
  if [[ -f "$SSH_MANAGED" ]]; then
    cp -a "$SSH_MANAGED" "$tx/managed.before"
  else
    touch "$tx/managed.absent"
  fi
  unit="server-security-rollback-$(basename "$tx")"
  cat >"$tx/rollback.sh" <<EOF
#!/bin/bash
set -u
if [[ -f "$tx/managed.absent" ]]; then
  rm -f "$SSH_MANAGED"
else
  mkdir -p "$(dirname "$SSH_MANAGED")"
  cp -a "$tx/managed.before" "$SSH_MANAGED"
fi
"$bin" -t >/dev/null 2>&1 && systemctl reload "$service" >/dev/null 2>&1 || true
printf 'RESTORED\n' >"$tx/status"
$(transaction_cleanup_units_snippet "$unit")
EOF
  chmod 0700 "$tx/rollback.sh"
  transaction_start_timer "$tx" 5

  for key in "${!desired[@]}"; do
    managed_set_option "$SSH_MANAGED" "$key" "${desired[$key]}"
  done

  if ! "$bin" -t; then
    status ERROR "sshd -t завершился ошибкой"
    transaction_rollback_now "$tx"
    return 1
  fi
  systemctl reload "$service"
  service_active "$service" || {
    status ERROR "SSH service не активен после reload"
    transaction_rollback_now "$tx"
    return 1
  }

  for key in "${!desired[@]}"; do
    value="$(sshd_value "$key")"
    if [[ "$value" != "${desired[$key]}" ]]; then
      status ERROR "$key не применился: ожидалось ${desired[$key]}, получено ${value:-пусто}"
      transaction_rollback_now "$tx"
      return 1
    fi
  done
  status APPLIED "Настройки SSH применены и прошли sshd -t"
  confirm_or_leave_timer "$tx" "Откройте новую SSH-сессию и проверьте вход до отмены отката."
}

apt_config_value() {
  local key="$1"
  apt-config dump 2>/dev/null | awk -v key="$key" '$1==key {gsub(/[\";]/,"",$2); print $2; exit}'
}

configure_updates() {
  local need_install=0 changed=0 auto_reboot=false reboot_time="04:30" backup
  local remove_unused=false periodic_enabled=false
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    status OK "unattended-upgrades уже установлен"
  elif ask_yes "Установить unattended-upgrades?"; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
    need_install=1
  else
    status SKIP "unattended-upgrades не установлен"
  fi

  if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    return 0
  fi

  local periodic
  periodic="$(apt_config_value 'APT::Periodic::Unattended-Upgrade')"
  if [[ "$periodic" == "1" ]]; then
    status OK "Автоматические security updates уже включены"
    periodic_enabled=true
  elif ask_yes "Включить автоматические security updates?"; then
    periodic_enabled=true
    changed=1
  else
    status SKIP "Автоматическая установка security updates не включена"
    return 0
  fi

  local remove_current
  remove_current="$(apt_config_value 'Unattended-Upgrade::Remove-Unused-Dependencies')"
  if [[ "$remove_current" == "true" ]]; then
    status OK "Удаление неиспользуемых зависимостей уже включено"
    remove_unused=true
  elif ask_yes "Автоматически удалять неиспользуемые зависимости?"; then
    changed=1
    remove_unused=true
  fi

  local reboot
  reboot="$(apt_config_value 'Unattended-Upgrade::Automatic-Reboot')"
  if [[ "$reboot" == "true" ]]; then
    status INFO "Автоматическая перезагрузка уже включена"
    auto_reboot=true
    reboot_time="$(apt_config_value 'Unattended-Upgrade::Automatic-Reboot-Time')"
    reboot_time="${reboot_time:-04:30}"
  elif ask_no "Разрешить автоматическую перезагрузку после обновлений?"; then
    auto_reboot=true
    read -r -p "Время автоматической перезагрузки [04:30]: " reboot_time
    reboot_time="${reboot_time:-04:30}"
    changed=1
  fi

  [[ "$periodic_enabled" == true ]] || return 0
  (( changed == 1 || need_install == 1 )) || return 0
  mkdir -p "$STATE_DIR/config-backups"
  if [[ -f "$APT_MANAGED" ]]; then
    backup="$STATE_DIR/config-backups/apt-$(date +%Y%m%d-%H%M%S)"
    cp -a "$APT_MANAGED" "$backup"
    status BACKUP "Сохранён $backup"
  fi
  cat >"$APT_MANAGED" <<EOF
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Remove-Unused-Dependencies "$remove_unused";
Unattended-Upgrade::Automatic-Reboot "$auto_reboot";
Unattended-Upgrade::Automatic-Reboot-Time "$reboot_time";
EOF
  chmod 0644 "$APT_MANAGED"
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  status APPLIED "Настройки автоматических обновлений сохранены"
}

sysctl_current() { sysctl -n "$1" 2>/dev/null || true; }

offer_sysctl() {
  local key="$1" expected="$2" description="$3" mode="${4:-exact}" current
  current="$(sysctl_current "$key")"
  [[ -n "$current" ]] || { status SKIP "$description: параметр недоступен"; return; }
  case "$mode" in
    one-or-two)
      if [[ "$current" == "1" || "$current" == "2" ]]; then status OK "$description ($key=$current)"; return; fi ;;
    at-least)
      if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= expected )); then status OK "$description ($key=$current)"; return; fi ;;
    *)
      if [[ "$current" == "$expected" ]]; then status OK "$description ($key=$current)"; return; fi ;;
  esac
  if ask_yes "$description: установить $key=$expected?"; then
    SYSCTL_SELECTED["$key"]="$expected"
  else
    status SKIP "$description"
  fi
}

configure_sysctl() {
  declare -gA SYSCTL_SELECTED=()
  offer_sysctl net.ipv4.tcp_syncookies 1 "Включить SYN cookies"
  offer_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1 "Игнорировать broadcast ICMP echo"
  offer_sysctl net.ipv4.conf.all.accept_redirects 0 "Отключить приём IPv4 redirects"
  offer_sysctl net.ipv4.conf.default.accept_redirects 0 "Отключить IPv4 redirects по умолчанию"
  offer_sysctl net.ipv4.conf.all.send_redirects 0 "Отключить отправку IPv4 redirects"
  offer_sysctl net.ipv4.conf.default.send_redirects 0 "Отключить отправку IPv4 redirects по умолчанию"
  offer_sysctl net.ipv4.conf.all.accept_source_route 0 "Отключить IPv4 source routing"
  offer_sysctl net.ipv4.conf.default.accept_source_route 0 "Отключить IPv4 source routing по умолчанию"
  offer_sysctl net.ipv4.conf.all.rp_filter 2 "Включить reverse path filtering для VPN (loose mode)" one-or-two
  offer_sysctl net.ipv4.conf.default.rp_filter 2 "Включить reverse path filtering по умолчанию" one-or-two

  if [[ "$(sysctl_current net.ipv6.conf.all.disable_ipv6)" != "1" ]]; then
    offer_sysctl net.ipv6.conf.all.accept_redirects 0 "Отключить приём IPv6 redirects"
    offer_sysctl net.ipv6.conf.default.accept_redirects 0 "Отключить IPv6 redirects по умолчанию"
    offer_sysctl net.ipv6.conf.all.accept_source_route 0 "Отключить IPv6 source routing"
    offer_sysctl net.ipv6.conf.default.accept_source_route 0 "Отключить IPv6 source routing по умолчанию"
  fi

  offer_sysctl kernel.kptr_restrict 2 "Ограничить отображение адресов ядра" at-least
  offer_sysctl kernel.dmesg_restrict 1 "Ограничить чтение dmesg"
  offer_sysctl kernel.yama.ptrace_scope 1 "Ограничить ptrace между процессами" at-least

  (( ${#SYSCTL_SELECTED[@]} > 0 )) || { status OK "Изменения sysctl не выбраны"; return 0; }

  local tx unit key value
  tx="$(transaction_create sysctl)"
  if [[ -f "$SYSCTL_MANAGED" ]]; then cp -a "$SYSCTL_MANAGED" "$tx/managed.before"; else touch "$tx/managed.absent"; fi
  : >"$tx/runtime.before"
  for key in "${!SYSCTL_SELECTED[@]}"; do
    printf '%s\t%s\n' "$key" "$(sysctl_current "$key")" >>"$tx/runtime.before"
  done
  unit="server-security-rollback-$(basename "$tx")"
  cat >"$tx/rollback.sh" <<EOF
#!/bin/bash
set -u
if [[ -f "$tx/managed.absent" ]]; then rm -f "$SYSCTL_MANAGED"; else cp -a "$tx/managed.before" "$SYSCTL_MANAGED"; fi
while IFS=	 read -r key value; do sysctl -w "\$key=\$value" >/dev/null 2>&1 || true; done <"$tx/runtime.before"
printf 'RESTORED\n' >"$tx/status"
$(transaction_cleanup_units_snippet "$unit")
EOF
  chmod 0700 "$tx/rollback.sh"
  transaction_start_timer "$tx" 5

  for key in "${!SYSCTL_SELECTED[@]}"; do
    managed_set_option "$SYSCTL_MANAGED" "$key" "${SYSCTL_SELECTED[$key]}"
  done
  chmod 0644 "$SYSCTL_MANAGED"
  if ! sysctl -p "$SYSCTL_MANAGED"; then
    status ERROR "Не все sysctl применились"
    transaction_rollback_now "$tx"
    return 1
  fi
  for key in "${!SYSCTL_SELECTED[@]}"; do
    value="$(sysctl_current "$key")"
    [[ "$value" == "${SYSCTL_SELECTED[$key]}" ]] || {
      status ERROR "$key не применился"
      transaction_rollback_now "$tx"
      return 1
    }
  done
  status APPLIED "Выбранные sysctl применены"
  confirm_or_leave_timer "$tx" "Проверьте SSH, VPN-маршрутизацию и доступность сервисов."
}

nft_has_ping_rule() {
  local family="$1" rules
  rules="$(nft list ruleset 2>/dev/null || true)"
  if [[ "$family" == "4" ]]; then
    grep -Eqi 'icmp type echo-request.*(limit|drop)' <<<"$rules"
  else
    grep -Eqi '(icmpv6 type echo-request|icmp type echo-request).*(limit|drop)' <<<"$rules"
  fi
}

configure_ping_firewall() {
  local v4=0 v6=0 keep_v4=0 keep_v6=0 tx unit old_enabled=0 old_active=0 candidate path nft_bin
  if ! has_cmd nft; then
    status SKIP "nftables не установлен; ограничение ping не применяется автоматически"
    return 0
  fi
  nft_bin="$(command -v nft)"
  [[ -f "$NFT_CONFIG" ]] && grep -q 'ip protocol icmp icmp type echo-request' "$NFT_CONFIG" && keep_v4=1 || true
  [[ -f "$NFT_CONFIG" ]] && grep -q 'icmpv6 type echo-request' "$NFT_CONFIG" && keep_v6=1 || true

  if nft_has_ping_rule 4; then status OK "IPv4 echo-request уже ограничивается или блокируется";
  elif ask_yes "Ограничить IPv4 ping до 2 запросов/сек с burst 5?"; then v4=1; fi

  if [[ "$(sysctl_current net.ipv6.conf.all.disable_ipv6)" == "1" ]]; then
    status SKIP "IPv6 отключён"
  elif nft_has_ping_rule 6; then status OK "IPv6 echo-request уже ограничивается или блокируется";
  elif ask_yes "Ограничить IPv6 ping до 2 запросов/сек с burst 5?"; then v6=1; fi

  (( v4 == 1 || v6 == 1 )) || return 0
  tx="$(transaction_create nft-ping)"
  mkdir -p "$tx/files"
  nft list table inet server_security >"$tx/old-table.nft" 2>/dev/null || touch "$tx/no-old-table"
  for path in "$NFT_CONFIG" "$NFT_HELPER" "/etc/systemd/system/$NFT_SERVICE"; do
    if [[ -e "$path" ]]; then cp -a "$path" "$tx/files/$(basename "$path")"; else touch "$tx/absent-$(basename "$path")"; fi
  done
  service_enabled "$NFT_SERVICE" && old_enabled=1 || true
  service_active "$NFT_SERVICE" && old_active=1 || true
  printf '%s %s\n' "$old_enabled" "$old_active" >"$tx/service.before"
  unit="server-security-rollback-$(basename "$tx")"
  cat >"$tx/rollback.sh" <<EOF
#!/bin/bash
set -u
systemctl disable --now "$NFT_SERVICE" >/dev/null 2>&1 || true
"$nft_bin" delete table inet server_security >/dev/null 2>&1 || true
for name in nftables.conf server-security-apply-nft $NFT_SERVICE; do
  case "\$name" in
    nftables.conf) dst="$NFT_CONFIG" ;;
    server-security-apply-nft) dst="$NFT_HELPER" ;;
    *) dst="/etc/systemd/system/$NFT_SERVICE" ;;
  esac
  if [[ -f "$tx/absent-\$name" ]]; then rm -f "\$dst"; elif [[ -e "$tx/files/\$name" ]]; then mkdir -p "\$(dirname "\$dst")"; cp -a "$tx/files/\$name" "\$dst"; fi
done
if [[ -s "$tx/old-table.nft" ]]; then "$nft_bin" -f "$tx/old-table.nft" >/dev/null 2>&1 || true; fi
read -r was_enabled was_active <"$tx/service.before"
systemctl daemon-reload >/dev/null 2>&1 || true
[[ "\$was_enabled" == 1 ]] && systemctl enable "$NFT_SERVICE" >/dev/null 2>&1 || true
[[ "\$was_active" == 1 ]] && systemctl start "$NFT_SERVICE" >/dev/null 2>&1 || true
printf 'RESTORED\n' >"$tx/status"
$(transaction_cleanup_units_snippet "$unit")
EOF
  chmod 0700 "$tx/rollback.sh"

  cat >"$tx/new-nftables.conf" <<EOF
table inet server_security {
  chain input {
    type filter hook input priority -5; policy accept;
EOF
  (( v4 == 1 || keep_v4 == 1 )) && printf '    ip protocol icmp icmp type echo-request limit rate over 2/second burst 5 packets drop\n' >>"$tx/new-nftables.conf"
  (( v6 == 1 || keep_v6 == 1 )) && printf '    ip6 nexthdr ipv6-icmp icmpv6 type echo-request limit rate over 2/second burst 5 packets drop\n' >>"$tx/new-nftables.conf"
  cat >>"$tx/new-nftables.conf" <<'EOF'
  }
}
EOF
  candidate="$tx/candidate.nft"
  sed 's/server_security/server_security_candidate/g' "$tx/new-nftables.conf" >"$candidate"
  "$nft_bin" delete table inet server_security_candidate >/dev/null 2>&1 || true
  if ! "$nft_bin" -c -f "$candidate"; then
    status ERROR "Кандидат nftables не прошёл проверку"
    return 1
  fi

  cat >"$tx/new-helper" <<EOF
#!/bin/sh
set -eu
"$nft_bin" delete table inet server_security >/dev/null 2>&1 || true
exec "$nft_bin" -f "$NFT_CONFIG"
EOF
  chmod 0750 "$tx/new-helper"
  cat >"$tx/new-service" <<EOF
[Unit]
Description=Server Security managed nftables rules
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT_HELPER
ExecReload=$NFT_HELPER

[Install]
WantedBy=multi-user.target
EOF

  transaction_start_timer "$tx" 3
  mkdir -p "$NFT_DIR"
  install -m 0600 "$tx/new-nftables.conf" "$NFT_CONFIG"
  install -m 0750 "$tx/new-helper" "$NFT_HELPER"
  install -m 0644 "$tx/new-service" "/etc/systemd/system/$NFT_SERVICE"
  systemctl daemon-reload
  systemctl enable --now "$NFT_SERVICE"
  "$nft_bin" list table inet server_security >/dev/null
  status APPLIED "Ограничение ping применено отдельной таблицей inet server_security"
  confirm_or_leave_timer "$tx" "Проверьте SSH, VPN и доступность публичных сервисов."
}

configure_fail2ban() {
  local installed=0 active=0 jails admin_ip config
  if service_active crowdsec.service && service_active crowdsec-firewall-bouncer.service; then
    status OK "CrowdSec и firewall bouncer уже защищают SSH; Fail2Ban не предлагается"
    return 0
  fi
  has_cmd fail2ban-client && installed=1
  if (( installed == 1 )) && fail2ban-client ping >/dev/null 2>&1; then
    active=1
    status OK "Fail2Ban установлен и отвечает"
  elif (( installed == 1 )); then
    if ask_yes "Fail2Ban установлен, но не работает. Запустить и включить?"; then
      systemctl enable --now fail2ban
      fail2ban-client ping >/dev/null
      active=1
    fi
  elif ask_yes "Установить Fail2Ban для защиты SSH?"; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
    systemctl enable --now fail2ban
    active=1
  else
    status SKIP "Fail2Ban не установлен"
    return 0
  fi

  (( active == 1 )) || return 0
  jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
  if grep -Eq '(^|,|[[:space:]])sshd($|,|[[:space:]])' <<<"$jails"; then
    status OK "Fail2Ban jail sshd уже активен"
    return 0
  fi
  if ask_yes "Включить Fail2Ban jail sshd?"; then
    admin_ip="${SSH_CONNECTION%% *}"
    config="/etc/fail2ban/jail.d/90-server-security.conf"
    mkdir -p "$STATE_DIR/config-backups"
    [[ -f "$config" ]] && cp -a "$config" "$STATE_DIR/config-backups/fail2ban-$(date +%Y%m%d-%H%M%S)"
    cat >"$config" <<EOF
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1${admin_ip:+ $admin_ip}
EOF
    chmod 0644 "$config"
    fail2ban-client -t
    systemctl restart fail2ban
    fail2ban-client status sshd >/dev/null
    status APPLIED "Fail2Ban jail sshd включён; IP текущей SSH-сессии добавлен в ignoreip"
  fi
}

configure_time_logs_permissions() {
  local synced journal_file file mode
  if has_cmd timedatectl; then
    synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [[ "$synced" == "yes" ]]; then status OK "Время уже синхронизировано";
    elif ask_yes "Включить системную синхронизацию времени?"; then timedatectl set-ntp true; status APPLIED "NTP включён"; fi
  fi

  if has_cmd logrotate; then status OK "logrotate уже установлен";
  elif ask_yes "Установить logrotate?"; then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate; fi

  journal_file="/etc/systemd/journald.conf.d/90-server-security.conf"
  if grep -Rqs '^[[:space:]]*SystemMaxUse=512M' /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null; then
    status OK "Лимит journald SystemMaxUse=512M уже настроен"
  elif ask_yes "Ограничить persistent journal до 512M?"; then
    mkdir -p /etc/systemd/journald.conf.d
    cat >"$journal_file" <<'EOF'
[Journal]
SystemMaxUse=512M
RuntimeMaxUse=256M
EOF
    chmod 0644 "$journal_file"
    systemctl restart systemd-journald
    status APPLIED "Лимиты journald настроены"
  fi

  local files=()
  for file in /etc/crowdsec/local_api_credentials.yaml /etc/crowdsec/online_api_credentials.yaml; do [[ -f "$file" ]] && files+=("$file"); done
  while IFS= read -r file; do [[ -n "$file" ]] && files+=("$file"); done < <(find /etc/crowdsec/bouncers -maxdepth 1 -type f -name '*.yaml.local' 2>/dev/null || true)
  while IFS= read -r file; do [[ -n "$file" ]] && files+=("$file"); done < <(find /opt -xdev -maxdepth 5 -type f \( -name '.env' -o -name '*.env' \) 2>/dev/null | head -n 100 || true)

  for file in "${files[@]}"; do
    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
    [[ -n "$mode" ]] || continue
    if (( 10#$mode % 10 > 0 )); then
      if ask_yes "Убрать доступ 'other' у $file (сейчас mode=$mode)?"; then
        chmod o-rwx "$file"
        status APPLIED "Права $file ограничены до $(stat -c '%a' "$file")"
      fi
    else
      status OK "$file не доступен посторонним (mode=$mode)"
    fi
  done
}

main() {
  cat <<'HEADER'

════════════════════════════════════════════════════════════
       УСТАНОВКА БАЗОВЫХ НАСТРОЕК БЕЗОПАСНОСТИ
════════════════════════════════════════════════════════════

Каждый пункт сначала проверяется. Уже применённые настройки пропускаются.
Каждое изменение запрашивается отдельно. Для SSH, sysctl и nftables
создаётся backup и автоматический откат, который отменяется только после
подтверждения пользователя.

Создание отдельного администратора этим мастером не выполняется.
HEADER

  KEY_LOGIN_CONFIRMED=0
  SSH_TARGET_USER=""
  setup_ssh_key || status WARN "Настройка SSH-ключа завершена с ошибкой"

  say ""
  say "--- SSH hardening ---"
  if offer_ssh_settings; then :; else
    local rc=$?
    (( rc == 2 )) && return 0
    status WARN "Раздел SSH завершён с ошибкой после безопасного отката"
  fi

  say ""
  say "--- Автоматические обновления ---"
  configure_updates

  say ""
  say "--- Kernel и сетевые sysctl ---"
  if configure_sysctl; then :; else
    local rc=$?
    (( rc == 2 )) && return 0
    status WARN "Раздел sysctl завершён с ошибкой после безопасного отката"
  fi

  say ""
  say "--- Ограничение ping ---"
  if configure_ping_firewall; then :; else
    local rc=$?
    (( rc == 2 )) && return 0
    status WARN "Раздел nftables завершён с ошибкой после безопасного отката"
  fi

  say ""
  say "--- Fail2Ban ---"
  configure_fail2ban

  say ""
  say "--- Время, журналы и права ---"
  configure_time_logs_permissions

  say ""
  status DONE "Мастер базовых настроек завершён"
}

main "$@"
