log_directive = re.search(r"(?m)^\s*log(?:\s|\{|$)", body)
if log_directive:
    output = re.search(r"(?m)^\s*output\s+file\s+([^\s{]+)", body)
    if not output:
        raise SystemExit("в site block уже есть log без output file; автоматическая замена отключена")
    print(output.group(1) + "\t0")
    raise SystemExit(0)

indent_match = re.match(r"^(\s*)", lines[begin])
base = (indent_match.group(1) if indent_match else "") + "    "
block = [
    f"{base}log {{\n",
    f"{base}    output file {desired_log} {{\n",
    f"{base}        roll_size 100MiB\n",
    f"{base}        roll_keep 10\n",
    f"{base}        roll_keep_for 720h\n",
    f"{base}    }}\n",
    f"{base}    format json\n",
    f"{base}}}\n",
]
lines[begin + 1:begin + 1] = block
tmp = path.with_name(path.name + ".crowdsec-new")
tmp.write_text("".join(lines), encoding="utf-8")
tmp.chmod(path.stat().st_mode & 0o777)
tmp.replace(path)
print(desired_log + "\t1")
PY
)" || {
  cp -a "$TX/Caddyfile.before" "$CADDYFILE"
  [[ -f "$TX/override.absent" ]] && rm -f "$OVERRIDE_FILE"
  die "не удалось подготовить access log Caddy"
}
IFS=$'\t' read -r CADDY_LOG_PATH CADDYFILE_CHANGED <<<"$PATCH_RESULT"
[[ -n "$CADDY_LOG_PATH" ]] || die "не определён путь access log Caddy"
[[ "$CADDY_LOG_PATH" == /* ]] || die "Caddy access log должен использовать абсолютный путь"
if [[ "$CADDY_MODE" == docker && "$CADDY_LOG_PATH" != /var/log/caddy/* ]]; then
  die "для Docker Caddy access log должен находиться внутри /var/log/caddy"
fi

CHANGED=0
[[ "$CADDYFILE_CHANGED" == 1 ]] && CHANGED=1
(( OVERRIDE_CHANGED == 1 )) && CHANGED=1

ROLLBACK_UNIT="server-security-rollback-$(basename "$TX")"
write_rollback() {
  cat >"$TX/rollback.sh" <<EOF_ROLLBACK
#!/bin/bash
set -u
cp -a "$TX/Caddyfile.before" "$CADDYFILE"
if [[ -n "$OVERRIDE_FILE" ]]; then
  if [[ -f "$TX/override.absent" ]]; then
    rm -f "$OVERRIDE_FILE"
  elif [[ -f "$TX/docker-compose.override.yml.before" ]]; then
    cp -a "$TX/docker-compose.override.yml.before" "$OVERRIDE_FILE"
  fi
fi
if [[ "$CADDY_MODE" == host ]]; then
  caddy validate --config "$CADDYFILE" >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
else
  cd "$COMPOSE_DIR"
  if [[ -f "$OVERRIDE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d >/dev/null 2>&1 || true
  else
    docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
  fi
fi
printf 'RESTORED\n' >"$TX/status"
systemctl disable --now "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$ROLLBACK_UNIT.timer" "/etc/systemd/system/$ROLLBACK_UNIT.service"
systemctl daemon-reload >/dev/null 2>&1 || true
EOF_ROLLBACK
  chmod 0700 "$TX/rollback.sh"
}

start_rollback_timer() {
  write_rollback
  cat >"/etc/systemd/system/$ROLLBACK_UNIT.service" <<EOF_SERVICE
[Unit]
Description=Rollback Remnawave panel Caddy logging

[Service]
Type=oneshot
ExecStart=/bin/bash $TX/rollback.sh
EOF_SERVICE
  cat >"/etc/systemd/system/$ROLLBACK_UNIT.timer" <<EOF_TIMER
[Unit]
Description=Rollback timer for Remnawave panel Caddy logging

[Timer]
OnActiveSec=5min
AccuracySec=1s
Persistent=true
Unit=$ROLLBACK_UNIT.service

[Install]
WantedBy=timers.target
EOF_TIMER
  chmod 0600 "/etc/systemd/system/$ROLLBACK_UNIT.service" "/etc/systemd/system/$ROLLBACK_UNIT.timer"
  systemctl daemon-reload
  systemctl enable --now "$ROLLBACK_UNIT.timer" >/dev/null
  printf 'PENDING\n' >"$TX/status"
  status ROLLBACK "Автовосстановление Caddy запланировано через 5 минут"
}

rollback_now() {
  status RESTORE "Выполняю немедленный откат Caddy"
  systemctl start "$ROLLBACK_UNIT.service" || /bin/bash "$TX/rollback.sh"
}

cancel_rollback() {
