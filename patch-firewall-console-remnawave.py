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
        print("usage: patch-firewall-console-remnawave.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    old = '''  vless-selfsteal)
    BOUNCER_NAME="vless-selfsteal-firewall-bouncer"
    SCENARIO_FILTER_LABEL="SSH- и HTTP-сценарии"
    SCENARIO_FILTER_YAML=$'  - ssh\\n  - http'
    ;;
  *)
    die "Неизвестный профиль установки: $PROFILE"
    ;;
esac
'''
    new = '''  vless-selfsteal)
    BOUNCER_NAME="vless-selfsteal-firewall-bouncer"
    SCENARIO_FILTER_LABEL="SSH- и HTTP-сценарии"
    SCENARIO_FILTER_YAML=$'  - ssh\\n  - http'
    ;;
  remnawave-panel)
    BOUNCER_NAME="remnawave-panel-firewall-bouncer"
    PANEL_TRAFFIC_MODE="${CROWDSEC_PANEL_TRAFFIC_MODE:-direct}"
    case "$PANEL_TRAFFIC_MODE" in
      direct)
        SCENARIO_FILTER_LABEL="SSH- и HTTP-сценарии (панель доступна напрямую)"
        SCENARIO_FILTER_YAML=$'  - ssh\\n  - http'
        ;;
      proxy)
        SCENARIO_FILTER_LABEL="только SSH-сценарии (панель находится за CDN/reverse proxy)"
        SCENARIO_FILTER_YAML=$'  - ssh'
        ;;
      *)
        die "Неизвестный CROWDSEC_PANEL_TRAFFIC_MODE: $PANEL_TRAFFIC_MODE"
        ;;
    esac
    ;;
  *)
    die "Неизвестный профиль установки: $PROFILE"
    ;;
esac
'''
    text = replace_once(text, old, new, "профили firewall bouncer")

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
