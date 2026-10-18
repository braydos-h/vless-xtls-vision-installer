#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
ufw_owned_ports() {
  if ! command -v ufw >/dev/null; then return 0; fi
  LC_ALL=C ufw status numbered 2>/dev/null | sed -nE 's/.*# xray-bootstrap-([0-9]+)[[:space:]]*$/\1/p' | sort -nu
}
ufw_remove_owned() {
  local numbers n
  numbers=$(LC_ALL=C ufw status numbered | sed -nE 's/^\[[[:space:]]*([0-9]+)\].*# xray-bootstrap-[0-9]+[[:space:]]*$/\1/p' | sort -rn)
  while read -r n; do
    [[ -z $n ]] || ufw --force delete "$n" || return 1
  done <<<"$numbers"
}
firewall_conflicts() {
  local style
  style=$(opt FIREWALL_STYLE)
  [[ $style == none ]] && return 0
  if systemctl is-active --quiet firewalld; then die 'firewalld is active; use FIREWALL_STYLE=none and manage ports there.'; fi
  if [[ $style == nftables ]] && command -v ufw >/dev/null && LC_ALL=C ufw status | grep '^Status: active' >/dev/null; then
    die 'UFW is active. Select ufw or none; the installer will not disable it.'
  fi
  if [[ $style == ufw ]]; then
    LC_ALL=C ufw status | grep '^Status: active' >/dev/null || die 'UFW must already be active. Enable/configure it separately while preserving SSH.'
    if [[ $(opt LISTEN_ADDRESS) == *:* ]] && ! grep -Eq '^IPV6=yes$' /etc/default/ufw; then
      die 'UFW IPv6 is disabled; enable it separately or select IPv4 LISTEN_ADDRESS.'
    fi
  fi
}
render_nft() {
  local ports uid v4 v6
  ports=$(opt LISTEN_PORT)
  [[ -z $(opt FALLBACK_PORT) ]] || ports+=", $(opt FALLBACK_PORT)"
  printf 'table inet xray_bootstrap {\n  comment "xray-reality-bootstrap managed"\n'
  printf '  chain input { type filter hook input priority -10; policy accept;\n'
  printf '    tcp dport { %s } counter accept comment "xray-bootstrap ports"\n  }\n' "$ports"
  if [[ $(opt OS_PRIVATE_OUTBOUND) == yes ]]; then
    uid=$(id -u xray-bootstrap)
    v4=$(data cidrs 4 | jq -r 'join(", ")')
    v6=$(data cidrs 6 | jq -r 'join(", ")')
    printf '  chain output { type filter hook output priority 10; policy accept;\n'
    printf '    ct direction reply meta skuid %s accept\n' "$uid"
    printf '    meta skuid %s ip daddr { %s } counter reject\n' "$uid" "$v4"
    printf '    meta skuid %s ip6 daddr { %s } counter reject\n  }\n' "$uid" "$v6"
  fi
  printf '}\n'
}
nft_apply_file() {
  local file=$1
  if nft list table inet xray_bootstrap >"$WORK/nft-current" 2>/dev/null; then
    if ! grep -q 'comment "xray-reality-bootstrap managed"' "$WORK/nft-current"; then
      log 'ERROR: reserved nftables table is not installer-owned; refusing replacement.'
      return 1
    fi
    printf 'delete table inet xray_bootstrap\n' >"$WORK/nft-batch"
  else : >"$WORK/nft-batch"; fi
  cat "$file" >>"$WORK/nft-batch" || return 1
  nft -c -f "$WORK/nft-batch" || return 1
  nft -f "$WORK/nft-batch" || return 1
}
apply_firewall() {
  [[ $FIREWALL_APPLIED == false ]] || return 0
  local style port file
  style=$(opt FIREWALL_STYLE)
  [[ $style == none ]] && return 0
  if [[ $style == nftables ]]; then
    for file in "$NFT_FILE" "$NFT_UNIT"; do
      if [[ -f $file ]] && ! grep -q 'Managed by xray-reality-bootstrap v2' "$file"; then die "Unrecognized firewall file requires administrator review: $file"; fi
    done
  fi
  firewall_conflicts
  jq '.options' "$DESIRED" >"$WORK/egress-options"
  data egress-check "$WORK/egress-options" /etc/resolv.conf
  # Arm a watchdog before changing any live networking state.
  arm_rollback
  touch "$JOURNAL/pending/firewall-changed"
  if [[ $style == nftables ]]; then
    render_nft >"$WORK/firewall.nft"
    nft_apply_file "$WORK/firewall.nft"
    {
      printf '# Managed by xray-reality-bootstrap v2\n'
      printf 'add table inet xray_bootstrap\ndelete table inet xray_bootstrap\n'
      cat "$WORK/firewall.nft"
    } >"$WORK/firewall-persistent.nft"
    nft -c -f "$WORK/firewall-persistent.nft"
    atomic_managed_file "$WORK/firewall-persistent.nft" "$NFT_FILE" 600
    cat >"$WORK/firewall.service" <<EOF
# Managed by xray-reality-bootstrap v2
[Unit]
Description=Installer-owned Xray firewall table
After=network-pre.target ufw.service nftables.service
Before=xray.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $NFT_FILE
[Install]
WantedBy=multi-user.target
EOF
    atomic_managed_file "$WORK/firewall.service" "$NFT_UNIT" 644
    systemctl daemon-reload
    systemctl enable --now xray-bootstrap-firewall.service >/dev/null
    write_service
    systemctl daemon-reload
  else
    for port in "$(opt LISTEN_PORT)" "$(opt FALLBACK_PORT)"; do
      [[ -n $port ]] || continue
      # Adding a duplicate rule can update its comment in UFW. Preserve
      # existing administrator rules instead of claiming their ownership.
      if LC_ALL=C ufw status numbered | grep -E "^[[] *[0-9]+[]] +${port}/tcp( +| +\(v6\))" | grep -v '# xray-bootstrap-' | grep . >/dev/null; then
        log "Port $port already has an administrator UFW rule; leaving it unchanged."
        continue
      fi
      ufw --dry-run allow "$port/tcp" comment "xray-bootstrap-$port" >/dev/null
      ufw allow "$port/tcp" comment "xray-bootstrap-$port"
    done
  fi
  log 'Firewall additions are pending. Existing host drop rules may still block Xray.'
  log 'Within 180 seconds, verify connectivity and run confirm-host in a new SSH session; otherwise changes roll back.'
  HOST_PENDING=true
  FIREWALL_APPLIED=true
}
restore_firewall() {
  local port
  if command -v nft >/dev/null; then
    if [[ -f $JOURNAL/pending/had-nft ]]; then
      nft_apply_file "$JOURNAL/pending/nft.previous" || return 1
    elif nft list table inet xray_bootstrap >/dev/null 2>&1; then nft delete table inet xray_bootstrap || return 1; fi
  fi
  if command -v ufw >/dev/null; then
    ufw_remove_owned || return 1
    while read -r port; do
      [[ -z $port ]] || ufw allow "$port/tcp" comment "xray-bootstrap-$port" || return 1
    done <"$JOURNAL/pending/ufw.previous"
  fi
}
remove_firewall() {
  if [[ -f $NFT_FILE ]]; then
    grep -q 'Managed by xray-reality-bootstrap v2' "$NFT_FILE" || die 'Persisted firewall file is not installer-owned; refusing removal.'
    if [[ -f $NFT_UNIT ]]; then
      grep -q 'Managed by xray-reality-bootstrap v2' "$NFT_UNIT" || die 'Firewall unit is not installer-owned; refusing removal.'
    fi
    if nft list table inet xray_bootstrap >/dev/null 2>&1; then nft delete table inet xray_bootstrap; fi
    if systemctl is-enabled --quiet xray-bootstrap-firewall.service 2>/dev/null; then systemctl disable --now xray-bootstrap-firewall.service; fi
    rm -f -- "$NFT_FILE" "$NFT_UNIT"
  fi
  if command -v ufw >/dev/null; then ufw_remove_owned; fi
}

clear_firewall_mode() {
  load_deployment
  reuse_candidate
  jq '.options.FIREWALL_STYLE="none" | .options.OS_PRIVATE_OUTBOUND="no"' "$DESIRED" >"$WORK/next"
  mv "$WORK/next" "$DESIRED"
  stage_generation
  activate_generation
  arm_rollback
  touch "$JOURNAL/pending/firewall-changed"
  remove_firewall
  TX_ACTIVE=false
  log 'Installer firewall rules removed provisionally. Confirm-host from a fresh SSH session within 180 seconds.'
}
