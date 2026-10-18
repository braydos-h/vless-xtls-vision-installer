#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
begin_transaction() {
  validate_runtime_ownership
  [[ ! -d $JOURNAL/pending ]] || die 'An interrupted/pending operation exists. Run recover or confirm-host first.'
  install -d -m 700 "$JOURNAL" "$JOURNAL/pending" "$JOURNAL/pending/files"
  TX_ACTIVE=true
  local old='' f auxiliary index=0
  if [[ -L $CURRENT ]]; then
    old=$(readlink "$CURRENT")
    [[ $old =~ ^deployments/[0-9]{8}T[0-9]{6}-[a-f0-9]{12}$ ]] || die 'Unsafe current deployment symlink.'
  fi
  printf '%s\n' "$old" >"$JOURNAL/pending/previous"
  printf '%s\n' "$(new_id)" >"$JOURNAL/pending/token"
  if systemctl is-active --quiet xray; then touch "$JOURNAL/pending/was-active"; fi
  if systemctl is-enabled --quiet xray 2>/dev/null; then touch "$JOURNAL/pending/was-enabled"; fi
  for auxiliary in xray-update.timer xray-bootstrap-firewall.service; do
    if systemctl is-active --quiet "$auxiliary"; then touch "$JOURNAL/pending/$auxiliary.active"; fi
    if systemctl is-enabled --quiet "$auxiliary" 2>/dev/null; then touch "$JOURNAL/pending/$auxiliary.enabled"; fi
  done
  touch "$JOURNAL/pending/aux-state-recorded"
  for f in "${MANAGED_FILES[@]}"; do
    [[ ! -L $f ]] || die "Managed path is a symlink: $f"
    printf '%s\n' "$f" >"$JOURNAL/pending/files/$index.path"
    if [[ -f $f ]]; then cp -a -- "$f" "$JOURNAL/pending/files/$index.data"; fi
    index=$((index + 1))
  done
  if command -v nft >/dev/null && nft list table inet xray_bootstrap >"$JOURNAL/pending/nft.previous" 2>/dev/null; then
    grep -q 'comment "xray-reality-bootstrap managed"' "$JOURNAL/pending/nft.previous" || die 'Reserved nftables table exists without installer ownership; refusing takeover.'
    touch "$JOURNAL/pending/had-nft"
  fi
  ufw_owned_ports >"$JOURNAL/pending/ufw.previous"
  touch "$JOURNAL/pending/ready"
  sync -f "$JOURNAL"
}
arm_rollback() {
  local token
  token=$(cat "$JOURNAL/pending/token")
  persist_helper
  printf '%s\n' "${SSH_CONNECTION:-}" >"$JOURNAL/pending/origin-ssh"
  systemd-run --quiet --collect --unit="xray-bootstrap-rollback-$token" --on-active=180s \
    "$HELPER" recover --transaction-id "$token"
  touch "$JOURNAL/pending/armed"
}
cancel_rollback() {
  if [[ -f $JOURNAL/pending/armed ]]; then
    local timer
    timer="xray-bootstrap-rollback-$(cat "$JOURNAL/pending/token").timer"
    # An elapsed transient timer may already have been collected by systemd.
    if [[ $(systemctl show -p LoadState --value "$timer") != not-found ]]; then systemctl stop "$timer"; fi
  fi
}
stop_managed_unit() {
  local unit=$1 file=$2
  if [[ -f $file ]] && grep -q 'Managed by xray-reality-bootstrap v2' "$file"; then
    systemctl stop "$unit" || return 1
    systemctl disable "$unit" >/dev/null || return 1
  fi
  return 0
}
restore_auxiliary() {
  local unit=$1 file=$2
  [[ -f $file ]] || return 0
  if [[ ! -f $JOURNAL/pending/aux-state-recorded || -f $JOURNAL/pending/$unit.enabled ]]; then
    systemctl enable "$unit" >/dev/null || return 1
  elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then systemctl disable "$unit" || return 1; fi
  if [[ ! -f $JOURNAL/pending/aux-state-recorded || -f $JOURNAL/pending/$unit.active ]]; then
    systemctl start "$unit" || return 1
  elif systemctl is-active --quiet "$unit"; then systemctl stop "$unit" || return 1; fi
  return 0
}
recover_transaction() {
  [[ -d $JOURNAL/pending ]] || return 0
  workspace || return 1
  local old f index=0
  TX_ACTIVE=false
  if [[ ! -f $JOURNAL/pending/ready ]]; then
    mv "$JOURNAL/pending" "$JOURNAL/incomplete-$(new_id)" || return 1
    log 'Incomplete journal archived; no activation occurred.'
    return 0
  fi
  old=$(cat "$JOURNAL/pending/previous") || return 1
  if [[ -n $old ]]; then
    [[ $old =~ ^deployments/[0-9]{8}T[0-9]{6}-[a-f0-9]{12}$ && -d $XRAY_DIR/$old ]] || return 1
    point_current "${old#deployments/}" || return 1
  else
    [[ ! -L $CURRENT ]] || rm -f -- "$CURRENT" || return 1
  fi
  # Disable while unit files still exist: doing so after deleting them can
  # leave enabled dangling symlinks and active transient policy behind.
  # UNIT is a shared global initialized by common.sh.
  # shellcheck disable=SC2153
  stop_managed_unit xray "$UNIT" || return 1
  if [[ -f $JOURNAL/pending/firewall-changed ]]; then stop_managed_unit xray-bootstrap-firewall.service "$NFT_UNIT" || return 1; fi
  if [[ -f $JOURNAL/pending/timer-changed ]]; then stop_managed_unit xray-update.timer "$UPDATE_TIMER" || return 1; fi
  for f in "${MANAGED_FILES[@]}"; do
    [[ $(cat "$JOURNAL/pending/files/$index.path") == "$f" ]] || return 1
    [[ ! -L $f ]] || return 1
    if [[ -f $JOURNAL/pending/files/$index.data ]]; then
      atomic_file "$JOURNAL/pending/files/$index.data" "$f" "$(stat -c %a "$JOURNAL/pending/files/$index.data")" || return 1
    elif [[ -f $f ]]; then rm -f -- "$f" || return 1; fi
    index=$((index + 1))
  done
  if [[ -f $JOURNAL/pending/firewall-changed ]]; then restore_firewall || return 1; fi
  systemctl daemon-reload || return 1
  if [[ -f $JOURNAL/pending/firewall-changed ]]; then restore_auxiliary xray-bootstrap-firewall.service "$NFT_UNIT" || return 1; fi
  if [[ -f $JOURNAL/pending/timer-changed ]]; then restore_auxiliary xray-update.timer "$UPDATE_TIMER" || return 1; fi
  if [[ -f $JOURNAL/pending/was-enabled ]]; then
    systemctl enable xray >/dev/null || return 1
  elif systemctl is-enabled --quiet xray 2>/dev/null; then
    systemctl disable xray >/dev/null || return 1
  fi
  if [[ -f $JOURNAL/pending/was-active ]]; then
    systemctl reset-failed xray || return 1
    systemctl restart xray || return 1
    if [[ -L $CURRENT ]]; then service_health || return 1; else systemctl is-active --quiet xray || return 1; fi
  else
    if systemctl is-active --quiet xray; then systemctl stop xray || return 1; fi
  fi
  if [[ -f $JOURNAL/pending/ssh-changed && ! -f $JOURNAL/pending/ssh-not-reloaded ]]; then
    sshd -t || return 1
    systemctl reload ssh || return 1
    local restored_ports
    restored_ports=$(sshd -T | awk '$1=="port" {print $2}') || return 1
    wait_ssh_listeners "$restored_ports" || return 1
  fi
  if [[ -f $JOURNAL/pending/nginx-changed ]] && command -v nginx >/dev/null; then
    nginx -t || return 1
    if systemctl is-active --quiet nginx; then systemctl reload nginx || return 1; fi
  fi
  if [[ -f $JOURNAL/pending/f2b-changed ]] && systemctl is-active --quiet fail2ban; then
    wait_fail2ban || return 1
    fail2ban-client reload || return 1
  fi
  cancel_rollback || return 1
  mv "$JOURNAL/pending" "$JOURNAL/recovered-$(new_id)" || return 1
  log 'ROLLED_BACK: previous deployment and managed files restored.'
}
commit_transaction() {
  cancel_rollback
  TX_ACTIVE=false
  mv "$JOURNAL/pending" "$JOURNAL/committed-$(new_id)"
  log 'SUCCEEDED: deployment committed.'
}
activate_generation() {
  validate_runtime_ownership
  begin_transaction
  write_service
  point_current "$GENERATION"
  systemctl daemon-reload
  # Enforce the requested kernel boundary before a reconfigured process runs.
  # Client edits/updates retain the already deployed firewall policy.
  case "$MODE" in
    install | repair | restore)
      if [[ $(opt OS_PRIVATE_OUTBOUND) == yes ]]; then apply_firewall; fi
      ;;
  esac
  case "$MODE" in
    install | repair | restore | test) systemctl enable xray >/dev/null ;;
  esac
  if [[ -f $JOURNAL/pending/was-active || $MODE == install || $MODE == repair || $MODE == restore || $MODE == test ]]; then
    systemctl reset-failed xray
    systemctl restart xray
    service_health || die 'Xray startup/listener health check failed.'
  else
    log 'Service was inactive and remains inactive. Configuration/version validated; runtime health requires a manual start.'
  fi
}
