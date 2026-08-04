#!/usr/bin/env python3
import pathlib
import sys


OLD_BLOCK = '''reload_caddy() {
  if [[ "$CADDY_RUNTIME" == "host" ]]; then
    systemctl reload caddy
    systemctl is-active --quiet caddy
    return
  fi

  if docker exec "$CADDY_CONTAINER" \\
       caddy reload --config "$CADDY_CONTAINER_CONFIG" --adapter caddyfile; then
    return 0
  fi

  log "Admin API Caddy недоступен; выполняю reload контейнера сигналом SIGUSR1"
  docker kill --signal=USR1 "$CADDY_CONTAINER" >/dev/null
  sleep 2
  [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER")" == "true" ]]
}
'''

NEW_BLOCK = '''reload_caddy() {
  if [[ "$CADDY_RUNTIME" == "host" ]]; then
    systemctl reload caddy
    systemctl is-active --quiet caddy
    return
  fi

  if docker exec "$CADDY_CONTAINER" \\
       caddy reload --config "$CADDY_CONTAINER_CONFIG" --adapter caddyfile; then
    sleep 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER")" == "true" ]]
    return
  fi

  log "Admin API Caddy недоступен; перезапускаю контейнер для применения Caddyfile"
  docker restart "$CADDY_CONTAINER" >/dev/null || return 1

  for _ in {1..30}; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == "true" ]] && \\
       docker exec "$CADDY_CONTAINER" caddy version >/dev/null 2>&1; then
      log "Caddy-контейнер успешно перезапущен"
      return 0
    fi
    sleep 1
  done

  docker logs --tail 100 "$CADDY_CONTAINER" >&2 || true
  return 1
}
'''


def main():
    if len(sys.argv) != 2:
        print("usage: patch-vless-docker-reload.py INSTALLER", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    count = text.count(OLD_BLOCK)
    if count != 1:
        print(
            "expected exactly one Docker reload block, found {}".format(count),
            file=sys.stderr,
        )
        return 1

    path.write_text(text.replace(OLD_BLOCK, NEW_BLOCK, 1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
