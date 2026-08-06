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
        print("usage: patch-remnawave-panel-caddy-errexit.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    old_select_tail = '''  [[ "$CADDY_CONTAINER" == - ]] && CADDY_CONTAINER=""
  [[ "$CADDY_CONTAINER_CONFIG" == - ]] && CADDY_CONTAINER_CONFIG=""
  [[ "$COMPOSE_DIR" == - ]] && COMPOSE_DIR=""
  [[ "$COMPOSE_FILE" == - ]] && COMPOSE_FILE=""
  [[ "$CADDY_COMPOSE_SERVICE" == - ]] && CADDY_COMPOSE_SERVICE=""
}
'''
    new_select_tail = '''  if [[ "$CADDY_CONTAINER" == - ]]; then CADDY_CONTAINER=""; fi
  if [[ "$CADDY_CONTAINER_CONFIG" == - ]]; then CADDY_CONTAINER_CONFIG=""; fi
  if [[ "$COMPOSE_DIR" == - ]]; then COMPOSE_DIR=""; fi
  if [[ "$COMPOSE_FILE" == - ]]; then COMPOSE_FILE=""; fi
  if [[ "$CADDY_COMPOSE_SERVICE" == - ]]; then CADDY_COMPOSE_SERVICE=""; fi
  return 0
}
'''
    text = replace_once(
        text,
        old_select_tail,
        new_select_tail,
        "завершение select_caddy_candidate",
    )

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
