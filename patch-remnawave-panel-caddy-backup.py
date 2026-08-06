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
        print("usage: patch-remnawave-panel-caddy-backup.py FILE", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    old_block = r'''TX="$(mktemp -d "$TX_ROOT/$(date +%Y%m%d-%H%M%S)-remnawave-panel-caddy.XXXXXX")"
chmod 0700 "$TX"
cp -a "$CADDYFILE" "$TX/Caddyfile.before"
if [[ -n "$OVERRIDE_FILE" ]]; then
  if [[ -f "$OVERRIDE_FILE" ]]; then
    cp -a "$OVERRIDE_FILE" "$TX/docker-compose.override.yml.before"
  else
    touch "$TX/override.absent"
  fi
fi

OVERRIDE_CHANGED=0'''

    new_block = r'''BACKUP_ROOT="/var/backups/server-security/caddy"
install -d -o root -g root -m 0700 "$BACKUP_ROOT" || \
  die "не удалось создать каталог резервных копий Caddy: $BACKUP_ROOT"

TX="$(mktemp -d "$TX_ROOT/$(date +%Y%m%d-%H%M%S)-remnawave-panel-caddy.XXXXXX")" || \
  die "не удалось создать транзакцию Caddy"
chmod 0700 "$TX"

BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ID="${BACKUP_STAMP}-$(basename "$CADDYFILE")-$$"
PERSISTENT_CADDY_BACKUP="$BACKUP_ROOT/$BACKUP_ID"
PERSISTENT_METADATA="$PERSISTENT_CADDY_BACKUP.metadata"

backup_exact_copy() {
  local source="$1" destination="$2" label="$3"
  [[ -f "$source" ]] || die "$label: исходный файл не найден: $source"
  cp -a -- "$source" "$destination" || \
    die "$label: не удалось создать резервную копию $destination"
  cmp -s -- "$source" "$destination" || \
    die "$label: резервная копия не совпадает с исходным файлом"
}

# Сначала создаём и проверяем две копии Caddyfile. Только после этого
# разрешены любые записи в Caddyfile или Compose override.
backup_exact_copy "$CADDYFILE" "$TX/Caddyfile.before" \
  "транзакционная копия Caddyfile"
install -o root -g root -m 0600 -- "$CADDYFILE" "$PERSISTENT_CADDY_BACKUP" || \
  die "не удалось создать постоянную резервную копию Caddyfile"
cmp -s -- "$CADDYFILE" "$PERSISTENT_CADDY_BACKUP" || \
  die "постоянная резервная копия Caddyfile не прошла проверку"

CADDY_BACKUP_SHA256="$(sha256sum "$PERSISTENT_CADDY_BACKUP" | awk '{print $1}')"
[[ "$CADDY_BACKUP_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || \
  die "не удалось вычислить SHA256 резервной копии Caddyfile"

{
  printf 'source=%s\n' "$CADDYFILE"
  printf 'backup=%s\n' "$PERSISTENT_CADDY_BACKUP"
  printf 'sha256=%s\n' "$CADDY_BACKUP_SHA256"
  stat -c 'source_mode=%a\nsource_uid=%u\nsource_gid=%g\nsource_size=%s\nsource_mtime=%Y' \
    "$CADDYFILE"
} >"$PERSISTENT_METADATA" || \
  die "не удалось записать метаданные резервной копии Caddyfile"
chmod 0600 "$PERSISTENT_METADATA"

status BACKUP "Caddyfile сохранён до любых изменений:"
printf '            %s\n' "$PERSISTENT_CADDY_BACKUP"
status BACKUP "SHA256: $CADDY_BACKUP_SHA256"

if [[ -n "$OVERRIDE_FILE" ]]; then
  if [[ -f "$OVERRIDE_FILE" ]]; then
    backup_exact_copy "$OVERRIDE_FILE" \
      "$TX/docker-compose.override.yml.before" \
      "транзакционная копия Compose override"
    install -o root -g root -m 0600 -- "$OVERRIDE_FILE" \
      "$PERSISTENT_CADDY_BACKUP.compose-override" || \
      die "не удалось сохранить постоянную копию Compose override"
    cmp -s -- "$OVERRIDE_FILE" "$PERSISTENT_CADDY_BACKUP.compose-override" || \
      die "резервная копия Compose override не прошла проверку"
  else
    touch "$TX/override.absent"
  fi
fi

# Защитный инвариант: без обеих проверенных копий код ниже не выполняется.
[[ -s "$TX/Caddyfile.before" && -s "$PERSISTENT_CADDY_BACKUP" ]] || \
  die "резервные копии Caddyfile отсутствуют или пусты"

OVERRIDE_CHANGED=0'''

    text = replace_once(
        text,
        old_block,
        new_block,
        "обязательный backup Caddyfile",
    )

    path.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
