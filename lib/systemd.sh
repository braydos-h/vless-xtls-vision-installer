#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
validate_runtime_ownership() {
  if [[ -f $UNIT ]] && ! grep -q 'Managed by xray-reality-bootstrap v2' "$UNIT"; then
    if [[ -f $STATE_FILE || ! -f $XRAY_DIR/bootstrap-state.env ]]; then
      die 'Xray unit is not installer-owned. Review administrator changes before managing this runtime.'
    fi
    # A validated legacy deployment is explicitly migrated by repair/install.
  fi
}
ensure_account() {
  if ! getent passwd xray-bootstrap >/dev/null; then
    useradd --system --user-group --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin xray-bootstrap
  fi
  local record
  record=$(getent passwd xray-bootstrap)
  [[ $(cut -d: -f3 <<<"$record") != 0 && $(cut -d: -f6 <<<"$record") == /nonexistent && $(cut -d: -f7 <<<"$record") == /usr/sbin/nologin ]] || die 'Service account conflicts with existing account.'
  [[ $(id -G xray-bootstrap) == "$(id -g xray-bootstrap)" && $(id -gn xray-bootstrap) == xray-bootstrap ]] || die 'Service account has unexpected group privileges.'
  [[ -z $(getent group xray-bootstrap | cut -d: -f4) ]] || die 'Service group has additional members; refusing to expose configuration secrets.'
  # Root owns the directory so a compromised service cannot swap log paths
  # between the symlink check and root's ownership/permission updates.
  install -d -m 750 -o root -g xray-bootstrap /var/log/xray
  local f
  for f in error.log access.log; do
    [[ ! -L /var/log/xray/$f ]] || die 'Unsafe log symlink.'
    touch /var/log/xray/"$f"
    chown xray-bootstrap:xray-bootstrap /var/log/xray/"$f"
    chmod 600 /var/log/xray/"$f"
  done
}
write_service() {
  local firewall_dependency=''
  if [[ $(opt FIREWALL_STYLE) == nftables && -f $NFT_UNIT ]]; then
    firewall_dependency='Requires=xray-bootstrap-firewall.service'
  fi
  cat >"$WORK/xray.service" <<EOF
# Managed by xray-reality-bootstrap v2
[Unit]
Description=Xray VLESS REALITY XTLS Vision
After=network-online.target nss-lookup.target xray-bootstrap-firewall.service
Wants=network-online.target
$firewall_dependency

[Service]
Type=simple
User=xray-bootstrap
Group=xray-bootstrap
ExecStart=$CURRENT/xray run -config $CONFIG_FILE
Environment=XRAY_LOCATION_ASSET=$CURRENT
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/var/log/xray
InaccessiblePaths=-$JOURNAL -$BACKUPS
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  atomic_file "$WORK/xray.service" "$UNIT" 644
  cat >"$WORK/xray-wrapper" <<EOF
#!/usr/bin/env bash
# Managed by xray-reality-bootstrap v2
exec $CURRENT/xray "\$@"
EOF
  atomic_file "$WORK/xray-wrapper" "$BIN" 755
}
persist_helper() {
  local source_file
  source_file=$(readlink -f "$ENTRY_PATH")
  if [[ $source_file == "$HELPER" ]]; then return 0; fi
  # Source installs use the reproducible standalone artifact at repository root.
  if [[ $STANDALONE == false ]]; then source_file=$PROJECT_DIR/xray_reality_bootstrap.sh; fi
  [[ -r $source_file ]] || die 'Standalone helper is missing. Run scripts/build.sh.'
  atomic_file "$source_file" "$HELPER" 700
}
configure_timer() {
  local policy file legacy=false
  policy=$(opt XRAY_UPDATE_POLICY)
  if [[ -f $XRAY_DIR/bootstrap-state.env && -f $UPDATE_UNIT ]] && grep -Fxq "ExecStart=$HELPER update --non-interactive" "$UPDATE_UNIT"; then legacy=true; fi
  for file in "$UPDATE_UNIT" "$UPDATE_TIMER"; do
    if [[ -f $file && $legacy == false ]] && ! grep -q 'Managed by xray-reality-bootstrap v2' "$file"; then
      die "Unrecognized update policy file requires administrator review: $file"
    fi
  done
  touch "$JOURNAL/pending/timer-changed"
  if [[ $policy == manual ]]; then
    if systemctl is-enabled --quiet xray-update.timer 2>/dev/null; then systemctl disable --now xray-update.timer; fi
    rm -f -- "$UPDATE_UNIT" "$UPDATE_TIMER"
    return 0
  fi
  persist_helper
  cat >"$WORK/update.service" <<EOF
# Managed by xray-reality-bootstrap v2
[Unit]
Description=Transactional Xray update
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$HELPER update --non-interactive
UMask=0077
EOF
  cat >"$WORK/update.timer" <<EOF
# Managed by xray-reality-bootstrap v2
[Unit]
Description=Scheduled Xray update
[Timer]
OnCalendar=$policy
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
  atomic_file "$WORK/update.service" "$UPDATE_UNIT" 644
  atomic_file "$WORK/update.timer" "$UPDATE_TIMER" 644
  systemctl daemon-reload
  systemctl enable --now xray-update.timer
}
