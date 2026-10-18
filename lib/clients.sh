#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
client_change_mode() {
  [[ -f $UNIT ]] || die 'Xray runtime is not installed. Run install, repair or restore first.'
  load_deployment
  data mutate "$DESIRED" "$MODE" "$NAME" "$WINDOW" >"$WORK/next"
  mv "$WORK/next" "$DESIRED"
  reuse_candidate
  stage_generation
  activate_generation
  commit_transaction
  if [[ $MODE == remove-client || $MODE == rotate-client ]]; then
    # Delete only that client's exports, never glob based on a user-controlled name.
    local prefix
    prefix=$(printf '%s' "$NAME" | sha256sum | cut -c1-24)
    if [[ -d $CLIENT_DIR ]]; then find "$CLIENT_DIR" -maxdepth 1 -type f -name "$prefix-*" -delete; fi
  fi
  if [[ $MODE == rotate-shortid ]]; then
    log "Old and new shortIds are accepted. Export updated clients; finalize-shortid after $WINDOW seconds revokes old shortIds."
  fi
  log 'Client change deployed. Existing sessions may disconnect because Xray was restarted.'
}
export_client_mode() {
  load_deployment
  [[ ! -L $CLIENT_DIR ]] || die 'Unsafe export directory symlink.'
  install -d -m 700 "$CLIENT_DIR"
  local prefix uri
  prefix=$(data export "$DESIRED" "$NAME" "$CLIENT_DIR")
  if command -v qrencode >/dev/null; then
    local label
    for label in primary fallback; do
      uri=$CLIENT_DIR/$prefix-$label.uri.txt
      if [[ -f $uri ]]; then
        qrencode -t PNG -o "$CLIENT_DIR/$prefix-$label.uri.qr.png" <"$uri"
        qrencode -t UTF8 <"$uri" >"$CLIENT_DIR/$prefix-$label.uri.qr.txt"
        chmod 600 "$CLIENT_DIR/$prefix-$label.uri.qr.png" "$CLIENT_DIR/$prefix-$label.uri.qr.txt"
      fi
    done
  fi
  log "Exports saved to $CLIENT_DIR/$prefix-* (mode 600)."
  if [[ $MODE == show-client ]]; then cat "$CLIENT_DIR/$prefix-primary.uri.txt"; fi
}
reprint_mode() {
  load_deployment
  local client
  while IFS= read -r client; do
    NAME=$client
    export_client_mode
  done < <(jq -r '.clients[].name' "$DESIRED")
}
list_clients_mode() {
  load_deployment
  jq '[.clients[] | {name,credential:"redacted"}]' "$DESIRED"
}
test_client_mode() {
  load_deployment
  [[ $TEST_URL == https://* ]] || die 'test-client requires --test-url https://HOST/PATH.'
  local prefix port config
  prefix=$(data export "$DESIRED" "$NAME" "$WORK/test-export")
  port=$(
    python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PY
  )
  CLIENT_TEST_DIR=$(mktemp -d /run/xray-bootstrap-client.XXXXXX)
  chown root:xray-bootstrap "$CLIENT_TEST_DIR"
  chmod 750 "$CLIENT_TEST_DIR"
  config=$CLIENT_TEST_DIR/client.json
  jq --argjson port "$port" '.inbounds=[{listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth"}}] | .log={loglevel:"none"}' \
    "$WORK/test-export/$prefix-v2rayn-primary.json" >"$WORK/client-test.json"
  install -m 640 -g xray-bootstrap "$WORK/client-test.json" "$config"
  runuser -u xray-bootstrap -- "$CURRENT/xray" run -config "$config" >"$WORK/client-test.log" 2>&1 &
  CHILD_PID=$!
  local n=0
  while ! ss -H -lnt "sport = :$port" | grep . >/dev/null; do
    kill -0 "$CHILD_PID" 2>/dev/null || die 'Temporary test client failed to start.'
    n=$((n + 1))
    ((n < 20)) || die 'Temporary client listener did not appear.'
    sleep 0.2
  done
  curl --proto '=https' --noproxy '' -fsS --max-time 20 --socks5-hostname "127.0.0.1:$port" "$TEST_URL" >/dev/null || die 'End-to-end request failed. Check PUBLIC_IP, REALITY target, server time and host/cloud firewall.'
  log 'End-to-end VLESS + REALITY + Vision request succeeded.'
}
