obj = json.load(sys.stdin)[0]
for mount in obj.get("Mounts", []):
    if mount.get("Destination") == "/var/log/caddy":
        print(mount.get("Source", ""))
        break
' 2>/dev/null || true
  )"
fi

TX="$(mktemp -d "$TX_ROOT/$(date +%Y%m%d-%H%M%S)-remnawave-panel-caddy.XXXXXX")"
chmod 0700 "$TX"
cp -a "$CADDYFILE" "$TX/Caddyfile.before"
if [[ -n "$OVERRIDE_FILE" ]]; then
  if [[ -f "$OVERRIDE_FILE" ]]; then
    cp -a "$OVERRIDE_FILE" "$TX/docker-compose.override.yml.before"
  else
    touch "$TX/override.absent"
  fi
fi

OVERRIDE_CHANGED=0
if [[ "$CADDY_MODE" == docker && -z "$DOCKER_LOG_SOURCE" ]]; then
  if [[ -e "$OVERRIDE_FILE" ]]; then
    die "$OVERRIDE_FILE уже существует без /var/log/caddy; автоматическое объединение произвольного override отключено"
  fi
  cat >"$OVERRIDE_FILE" <<'EOF_OVERRIDE'
services:
  caddy:
    volumes:
      - /var/log/caddy:/var/log/caddy
EOF_OVERRIDE
  chmod 0644 "$OVERRIDE_FILE"
  DOCKER_LOG_SOURCE="$LOG_DIR"
  OVERRIDE_CHANGED=1
  status APPLIED "Создан $OVERRIDE_FILE с bind mount журналов"
fi

install -d -o root -g root -m 0755 "${DOCKER_LOG_SOURCE:-$LOG_DIR}"
touch "${DOCKER_LOG_SOURCE:-$LOG_DIR}/remnawave-panel-access.log"
if [[ "$CADDY_MODE" == host ]] && getent passwd caddy >/dev/null 2>&1; then
  chown caddy:caddy "$LOG_DIR" "$LOG_DIR/remnawave-panel-access.log"
  chmod 0750 "$LOG_DIR"
  chmod 0640 "$LOG_DIR/remnawave-panel-access.log"
else
  chmod 0644 "${DOCKER_LOG_SOURCE:-$LOG_DIR}/remnawave-panel-access.log"
fi

PATCH_RESULT="$(python3 - "$CADDYFILE" "$PANEL_DOMAIN" "$DEFAULT_LOG_PATH" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
domain = sys.argv[2]
desired_log = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

def structural(line: str) -> str:
    out = []
    quote = None
    escaped = False
    for ch in line:
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in {"\"", "'"}:
            quote = ch
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)

blocks = []
depth = 0
start = None
header = ""
for index, raw in enumerate(lines):
    clean = structural(raw)
    opens = clean.count("{")
    closes = clean.count("}")
    if depth == 0 and opens:
        start = index
        header = clean.split("{", 1)[0].strip()
    depth += opens - closes
    if start is not None and depth == 0:
        blocks.append((start, index, header))
        start = None
if depth != 0:
    raise SystemExit("Caddyfile: несбалансированные фигурные скобки")

candidates = []
for begin, end, hdr in blocks:
    body = "".join(lines[begin:end + 1])
    by_domain = domain in hdr.replace("https://", "").replace("http://", "")
    by_upstream = re.search(r"(?m)^\s*reverse_proxy\b[^\n]*(?:remnawave:3000|127\.0\.0\.1:3000|localhost:3000)", body)
    if by_domain or by_upstream:
        candidates.append((begin, end, hdr, body))

if len(candidates) != 1:
    raise SystemExit(f"не удалось однозначно найти site block панели: найдено {len(candidates)}")
begin, end, hdr, body = candidates[0]

