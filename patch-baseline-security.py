#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: ожидалось одно совпадение, найдено {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-baseline-security.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    old_answers = '''ask_yes() {
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
'''
    new_answers = '''normalize_answer() {
  local answer="$1"
  answer="${answer#"${answer%%[![:space:]]*}"}"
  answer="${answer%"${answer##*[![:space:]]}"}"
  printf '%s' "${answer,,}"
}

ask_yes() {
  local prompt="$1" answer
  while :; do
    read -r -p "$prompt [Y/n]: " answer
    answer="$(normalize_answer "$answer")"
    case "$answer" in
      ''|y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) status INFO "Введите yes или no" ;;
    esac
  done
}

ask_no() {
  local prompt="$1" answer
  while :; do
    read -r -p "$prompt [y/N]: " answer
    answer="$(normalize_answer "$answer")"
    case "$answer" in
      y|yes|д|да) return 0 ;;
      ''|n|no|н|нет) return 1 ;;
      *) status INFO "Введите yes или no" ;;
    esac
  done
}
'''
    text = replace_once(text, old_answers, new_answers, "обработчики yes/no")

    old_apt = '''apt_config_value() {
  local key="$1"
  apt-config dump 2>/dev/null | awk -v key="$key" '$1==key {gsub(/[\\\";]/,"",$2); print $2; exit}'
}
'''
    new_apt = '''apt_config_value() {
  local key="$1" value
  value="$(apt-config dump 2>/dev/null | awk -v key="$key" '$1==key {print $2; exit}' || true)"
  printf '%s' "$value" | tr -d '\";'
}
'''
    text = replace_once(text, old_apt, new_apt, "парсер apt-config")

    old_writer = '''managed_set_option() {
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
'''
    new_writer = old_writer + '''
managed_set_sysctl_option() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN {done=0}
    /^[[:space:]]*#/ {print; next}
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      split(line, fields, /[[:space:]=]+/)
      if (fields[1] == key) {
        if (!done) {print key " = " value; done=1}
        next
      }
    }
    {print}
    END {if (!done) print key " = " value}
  ' "$file" >"$tmp"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}
'''
    text = replace_once(text, old_writer, new_writer, "редактор управляемых настроек")

    old_offer = '''  case "$mode" in
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
'''
    new_offer = '''  case "$mode" in
    one-or-two)
      if [[ "$current" == "1" || "$current" == "2" ]]; then
        status OK "$key=$current — допустимое значение уже установлено"
        return
      fi
      ;;
    at-least)
      if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= expected )); then
        status OK "$key=$current — требуемое или более строгое значение уже установлено"
        return
      fi
      ;;
    *)
      if [[ "$current" == "$expected" ]]; then
        status OK "$key=$current — настройка уже установлена"
        return
      fi
      ;;
  esac
  status CHECK "$key: текущее значение=${current:-не определено}, целевое=$expected"
  if ask_yes "$description: установить $key=$expected?"; then
    SYSCTL_SELECTED["$key"]="$expected"
    status SELECTED "$key=$expected"
  else
    status SKIP "$description"
  fi
'''
    text = replace_once(text, old_offer, new_offer, "проверка sysctl перед вопросом")

    old_local = '''  local tx unit key value
'''
    new_local = '''  local tx unit key value verify_failed=0
'''
    text = replace_once(text, old_local, new_local, "локальные переменные sysctl")

    old_apply = '''  for key in "${!SYSCTL_SELECTED[@]}"; do
    managed_set_option "$SYSCTL_MANAGED" "$key" "${SYSCTL_SELECTED[$key]}"
  done
  chmod 0644 "$SYSCTL_MANAGED"
'''
    new_apply = '''  status INFO "Выбранные параметры sysctl:"
  while IFS= read -r key; do
    status SELECTED "$key=${SYSCTL_SELECTED[$key]}"
  done < <(printf '%s\\n' "${!SYSCTL_SELECTED[@]}" | sort)

  for key in "${!SYSCTL_SELECTED[@]}"; do
    managed_set_sysctl_option "$SYSCTL_MANAGED" "$key" "${SYSCTL_SELECTED[$key]}"
  done
  chmod 0644 "$SYSCTL_MANAGED"
'''
    text = replace_once(text, old_apply, new_apply, "запись sysctl в формате key = value")

    old_verify = '''  for key in "${!SYSCTL_SELECTED[@]}"; do
    value="$(sysctl_current "$key")"
    [[ "$value" == "${SYSCTL_SELECTED[$key]}" ]] || {
      status ERROR "$key не применился"
      transaction_rollback_now "$tx"
      return 1
    }
  done
  status APPLIED "Выбранные sysctl применены"
'''
    new_verify = '''  status CHECK "Проверяю каждый выбранный параметр sysctl после применения"
  while IFS= read -r key; do
    value="$(sysctl_current "$key")"
    if [[ "$value" == "${SYSCTL_SELECTED[$key]}" ]]; then
      status OK "$key=$value"
    else
      status ERROR "$key: ожидалось ${SYSCTL_SELECTED[$key]}, фактически ${value:-не определено}"
      verify_failed=1
    fi
  done < <(printf '%s\\n' "${!SYSCTL_SELECTED[@]}" | sort)
  if (( verify_failed != 0 )); then
    transaction_rollback_now "$tx"
    return 1
  fi
  status APPLIED "Все выбранные параметры sysctl применены и проверены"
'''
    text = replace_once(text, old_verify, new_verify, "итоговая проверка sysctl")

    old_rollback_ifs = r'''while IFS=\t read -r key value; do sysctl -w "\$key=\$value" >/dev/null 2>&1 || true; done <"$tx/runtime.before"'''
    new_rollback_ifs = r'''while IFS=\$'\\t' read -r key value; do sysctl -w "\$key=\$value" >/dev/null 2>&1 || true; done <"$tx/runtime.before"'''
    text = replace_once(text, old_rollback_ifs, new_rollback_ifs, "разделитель rollback sysctl")

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
