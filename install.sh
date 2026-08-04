#!/bin/sh
set -eu

REPO="dsl48/vpn_trusted_proxy_updater"
REF="${VPN_INSTALL_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl не установлен" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: запускайте через sudo sh" >&2
  exit 1
fi

if [ ! -r /dev/tty ]; then
  echo "ERROR: нужен интерактивный терминал /dev/tty" >&2
  exit 1
fi

if [ -z "${SSH_CONNECTION:-}" ] && [ -n "${SSH_CLIENT:-}" ]; then
  SSH_CONNECTION="$SSH_CLIENT"
fi
export SSH_CONNECTION="${SSH_CONNECTION:-}"

printf '\nКуда устанавливается CrowdSec?\n' >/dev/tty
printf '  1 — Панель управления (пока не реализовано)\n' >/dev/tty
printf '  2 — Нода CDN Origin\n' >/dev/tty
printf '  3 — Нода VLESS + selfsteal на Caddy\n' >/dev/tty

while :; do
  printf 'Выберите тип установки [2]: ' >/dev/tty
  IFS= read -r INSTALL_TARGET </dev/tty
  INSTALL_TARGET="${INSTALL_TARGET:-2}"
  case "$INSTALL_TARGET" in
    1|panel)
      printf '\nУстановка на панель управления пока не реализована.\n' >/dev/tty
      exit 0
      ;;
    2|cdn|cdn-origin)
      PROFILE="cdn-origin"
      break
      ;;
    3|vless|selfsteal|vless-selfsteal)
      PROFILE="vless-selfsteal"
      break
      ;;
    *)
      printf 'Введите 1, 2 или 3.\n' >/dev/tty
      ;;
  esac
done

TMP_DIR="$(mktemp -d /tmp/crowdsec-installer.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

download() {
  name="$1"
  printf '%s\n' "[bootstrap] Загружаю $name из ${REPO}@${REF}"
  curl -fsSL --retry 3 --connect-timeout 15 \
    "$BASE_URL/$name" -o "$TMP_DIR/$name"
  chmod 0700 "$TMP_DIR/$name"
}

run_tty() {
  /bin/bash "$1" </dev/tty >/dev/tty 2>&1
}

download install-firewall-console.sh
download cleanup-default-bouncer-registrations.sh
download verify-remediation-component.sh

case "$PROFILE" in
  cdn-origin)
    download install-crowdsec-cdn-origin.sh
    download configure-update-interval.sh

    sed -i \
      -e 's/\$prompt \[да\/нет\]: /\$prompt [Y\/n]: /' \
      -e '/read -r -p "\$prompt \[Y\/n\]: " answer/a\
    [ -n "$answer" ] || answer=yes' \
      -e 's/да|д|yes|y)/yes|y)/' \
      -e 's/нет|н|no|n)/no|n)/' \
      -e 's/Введите «да» или «нет»\./Введите yes или no./' \
      -e 's/Firewall bouncer намеренно не устанавливался автоматически\./Firewall bouncer устанавливается следующим этапом./' \
      "$TMP_DIR/install-crowdsec-cdn-origin.sh"

    run_tty "$TMP_DIR/install-crowdsec-cdn-origin.sh"
    run_tty "$TMP_DIR/configure-update-interval.sh"
    CROWDSEC_INSTALL_PROFILE=cdn-origin \
      run_tty "$TMP_DIR/install-firewall-console.sh"
    CROWDSEC_BOUNCER_NAME=cdn-origin-firewall-bouncer \
      run_tty "$TMP_DIR/cleanup-default-bouncer-registrations.sh"
    CROWDSEC_BOUNCER_NAME=cdn-origin-firewall-bouncer \
      run_tty "$TMP_DIR/verify-remediation-component.sh"
    ;;

  vless-selfsteal)
    download install-vless-selfsteal.sh
    download detect-selfsteal-site.py

    python3 - "$TMP_DIR/install-vless-selfsteal.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

old_prompt = '''printf '\\nУстановка CrowdSec для прямой ноды VLESS + selfsteal на Caddy.\\n'
printf 'Укажите адрес сайта из заголовка site block в выбранном Caddyfile.\\n'
read -r -p "Домен/адрес selfsteal-сайта: " SELFSTEAL_SITE
SELFSTEAL_SITE="$(printf '%s' "$SELFSTEAL_SITE" | tr -d '[:space:]')"
[[ -n "$SELFSTEAL_SITE" ]] || die "Домен/адрес selfsteal-сайта не задан"
'''
new_prompt = '''printf '\\nУстановка CrowdSec для прямой ноды VLESS + selfsteal на Caddy.\\n'
[[ -x "$CADDY_SELFSTEAL_DETECTOR" ]] || die "Не найден модуль определения selfsteal-блока"
AUTO_SELFSTEAL_SITE="$("$CADDY_SELFSTEAL_DETECTOR" "$CADDYFILE" 2>/dev/null || true)"
if [[ -n "$AUTO_SELFSTEAL_SITE" ]]; then
  SELFSTEAL_SITE="$AUTO_SELFSTEAL_SITE"
  log "Обнаружен стандартный selfsteal HTTPS-блок: $SELFSTEAL_SITE"
else
  printf 'Стандартный selfsteal-блок с переменной не найден однозначно.\\n'
  printf 'Укажите адрес точно так, как он написан в заголовке site block.\\n'
  read -r -p "Домен/адрес selfsteal-сайта: " SELFSTEAL_SITE
  SELFSTEAL_SITE="$(printf '%s' "$SELFSTEAL_SITE" | tr -d '[:space:]')"
  [[ -n "$SELFSTEAL_SITE" ]] || die "Домен/адрес selfsteal-сайта не задан"
fi
'''
if text.count(old_prompt) != 1:
    raise SystemExit('Не найден ожидаемый блок запроса selfsteal-сайта')
text = text.replace(old_prompt, new_prompt, 1)

old_header = "header = line.split('{', 1)[0].strip()"
new_header = "header = line.rsplit('{', 1)[0].strip()"
if text.count(old_header) != 1:
    raise SystemExit('Не найден ожидаемый парсер заголовка Caddy site block')
text = text.replace(old_header, new_header, 1)

needle = '''if len(blocks) != 1:
    raise SystemExit(
'''
replacement = '''if len(blocks) > 1:
    structured = []
    for block_start, block_end in blocks:
        body = ''.join(lines[block_start + 1:block_end])
        if (re.search(r'(?m)^\\s*bind\\s+unix/', body)
                and re.search(r'(?m)^\\s*file_server(?:\\s|$)', body)):
            structured.append((block_start, block_end))
    if len(structured) == 1:
        blocks = structured

if len(blocks) != 1:
    raise SystemExit(
'''
if text.count(needle) != 1:
    raise SystemExit('Не найдена ожидаемая проверка количества Caddy site blocks')
text = text.replace(needle, replacement, 1)

path.write_text(text, encoding='utf-8')
PY

    export CADDY_SELFSTEAL_DETECTOR="$TMP_DIR/detect-selfsteal-site.py"
    run_tty "$TMP_DIR/install-vless-selfsteal.sh"
    unset CADDY_SELFSTEAL_DETECTOR

    CROWDSEC_INSTALL_PROFILE=vless-selfsteal \
      run_tty "$TMP_DIR/install-firewall-console.sh"
    CROWDSEC_BOUNCER_NAME=vless-selfsteal-firewall-bouncer \
      run_tty "$TMP_DIR/cleanup-default-bouncer-registrations.sh"
    CROWDSEC_BOUNCER_NAME=vless-selfsteal-firewall-bouncer \
      run_tty "$TMP_DIR/verify-remediation-component.sh"
    ;;
esac
