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
        print("usage: patch-remnawave-panel-caddy-apply.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    old_block = r'''  else
    docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "Caddyfile в контейнере не прошёл проверку"
    }
    if (( OVERRIDE_CHANGED == 1 )); then
      (
        cd "$COMPOSE_DIR"
        docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d
      ) || { rollback_now; die "не удалось применить Docker mount журналов Caddy"; }
      for _ in {1..30}; do
        [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == true ]] && break
        sleep 1
      done
    fi
    docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "Caddy после применения настроек не прошёл проверку"
    }
    docker exec "$CADDY_CONTAINER" caddy reload --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "не удалось выполнить caddy reload в контейнере"
    }
  fi'''

    new_block = r'''  else
    docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
      rollback_now; die "Caddyfile в контейнере не прошёл проверку"
    }

    wait_for_caddy_container() {
      local attempt
      for attempt in {1..30}; do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == true ]] &&
           docker exec "$CADDY_CONTAINER" caddy version >/dev/null 2>&1; then
          return 0
        fi
        sleep 1
      done
      return 1
    }

    if (( OVERRIDE_CHANGED == 1 )); then
      (
        cd "$COMPOSE_DIR"
        docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d
      ) || { rollback_now; die "не удалось применить Docker mount журналов Caddy"; }

      wait_for_caddy_container || {
        rollback_now; die "контейнер Caddy не восстановился после применения mount журналов"
      }
      docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
        rollback_now; die "Caddy после пересоздания не прошёл проверку"
      }
      status APPLIED "Контейнер Caddy запущен с новой конфигурацией; дополнительный reload не требуется"
    else
      CADDY_ADMIN_STATE="$(
        docker exec "$CADDY_CONTAINER" caddy adapt --config "$CADDY_CONTAINER_CONFIG" 2>/dev/null |
          python3 -c '
import json
import sys
try:
    obj = json.load(sys.stdin)
except Exception:
    print("unknown")
    raise SystemExit(0)
admin = obj.get("admin") or {}
if admin.get("disabled") is True:
    print("disabled")
elif admin.get("listen"):
    print("listen=" + str(admin.get("listen")))
else:
    print("default")
'
      )"

      RELOAD_OK=0
      case "$CADDY_ADMIN_STATE" in
        disabled)
          status INFO "Admin API Caddy отключён; graceful reload недоступен"
          ;;
        listen=*)
          CADDY_ADMIN_ADDRESS="${CADDY_ADMIN_STATE#listen=}"
          if docker exec "$CADDY_CONTAINER" caddy reload \
               --address "$CADDY_ADMIN_ADDRESS" \
               --config "$CADDY_CONTAINER_CONFIG"; then
            RELOAD_OK=1
          fi
          ;;
        *)
          if docker exec "$CADDY_CONTAINER" caddy reload \
               --config "$CADDY_CONTAINER_CONFIG"; then
            RELOAD_OK=1
          fi
          ;;
      esac

      if (( RELOAD_OK == 1 )); then
        status APPLIED "Caddy перечитал конфигурацию через Admin API"
      else
        status WARN "Graceful reload Caddy недоступен"
        if ! ask_yes "Пересоздать контейнер Caddy для применения access log?"; then
          rollback_now
          die "настройка отменена: Caddyfile восстановлен"
        fi

        if [[ -n "$COMPOSE_DIR" && -n "$COMPOSE_FILE" && -n "$CADDY_COMPOSE_SERVICE" ]]; then
          (
            cd "$COMPOSE_DIR"
            COMPOSE_ARGS=(-f "$COMPOSE_FILE")
            if [[ -n "$OVERRIDE_FILE" && -f "$OVERRIDE_FILE" ]]; then
              COMPOSE_ARGS+=(-f "$OVERRIDE_FILE")
            fi
            docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate "$CADDY_COMPOSE_SERVICE"
          ) || { rollback_now; die "не удалось пересоздать Compose service Caddy"; }
        else
          docker restart "$CADDY_CONTAINER" >/dev/null || {
            rollback_now; die "не удалось перезапустить контейнер Caddy"
          }
        fi

        wait_for_caddy_container || {
          rollback_now; die "контейнер Caddy не восстановился после пересоздания"
        }
        docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONTAINER_CONFIG" || {
          rollback_now; die "Caddy после пересоздания не прошёл проверку"
        }
        status APPLIED "Caddy запущен с обновлённым Caddyfile"
      fi
    fi
  fi'''

    text = replace_once(
        text,
        old_block,
        new_block,
        "применение Docker Caddy без обязательного Admin API",
    )

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
