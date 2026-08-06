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

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
