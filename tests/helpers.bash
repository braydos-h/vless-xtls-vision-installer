#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# shellcheck disable=SC2317
setup_sandbox() {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../xray_reality_bootstrap.sh"
  init_paths
  SANDBOX=$BATS_TEST_TMPDIR/host
  mkdir -p "$SANDBOX/etc/systemd" "$SANDBOX/bin" "$SANDBOX/journal" "$SANDBOX/backups"
  XRAY_DIR=$SANDBOX/etc/xray
  CURRENT=$XRAY_DIR/current
  DEPLOYMENTS=$XRAY_DIR/deployments
  STATE_FILE=$CURRENT/state.json
  CONFIG_FILE=$CURRENT/config.json
  BIN=$SANDBOX/bin/xray
  UNIT=$SANDBOX/etc/systemd/xray.service
  JOURNAL=$SANDBOX/journal
  BACKUPS=$SANDBOX/backups
  NFT_FILE=$SANDBOX/firewall.nft
  NFT_UNIT=$SANDBOX/etc/systemd/firewall.service
  SSH_DROPIN=$SANDBOX/ssh.conf
  UPDATE_TIMER=$SANDBOX/etc/systemd/update.timer
  UPDATE_UNIT=$SANDBOX/etc/systemd/update.service
  NGINX_FILE=$SANDBOX/nginx.conf
  F2B_FILE=$SANDBOX/fail2ban.conf
  APT_FILE=$SANDBOX/apt.conf
  CLIENT_DIR=$SANDBOX/clients
  MANAGED_FILES=("$BIN" "$UNIT" "$NFT_FILE" "$NFT_UNIT" "$SSH_DROPIN" "$UPDATE_TIMER" "$UPDATE_UNIT" "$NGINX_FILE" "$F2B_FILE" "$APT_FILE")
  WORK=$SANDBOX/work
  mkdir -p "$DEPLOYMENTS" "$WORK"
  MODE="test"
  DESIRED=$WORK/state.json
  mkdir -p "$WORK"
  OPLOG=''
  old=20261013T120000-aaaaaaaaaaaa
  new=20261013T120001-bbbbbbbbbbbb
  mkdir -p "$DEPLOYMENTS/$old" "$DEPLOYMENTS/$new"
  printf 'old config\n' >"$DEPLOYMENTS/$old/config.json"
  printf 'old binary\n' >"$BIN"
  printf '# Managed by xray-reality-bootstrap v2\nold unit\n' >"$UNIT"
  point_current "$old"
  GENERATION=$new
  printf '{"options":{"FIREWALL_STYLE":"none"}}\n' >"$DESIRED"
  touch "$SANDBOX/active" "$SANDBOX/enabled"
  systemctl() {
    printf '%s\n' "$*" >>"$SANDBOX/systemctl.log"
    local unit=${*: -1} active_marker=$SANDBOX/active enabled_marker=$SANDBOX/enabled
    if [[ $unit != xray ]]; then
      active_marker=$SANDBOX/$unit.active
      enabled_marker=$SANDBOX/$unit.enabled
    fi
    case "$1" in
      is-active) [[ -f $active_marker ]] ;;
      is-enabled) [[ -f $enabled_marker ]] ;;
      restart)
        if [[ -f $SANDBOX/start-limit-hit ]]; then return 1; fi
        if [[ -f $SANDBOX/fail-restart ]]; then
          rm "$SANDBOX/fail-restart"
          touch "$SANDBOX/start-limit-hit"
          return 1
        fi
        touch "$active_marker"
        ;;
      start) touch "$active_marker" ;;
      stop) rm -f "$active_marker" ;;
      reset-failed) rm -f "$SANDBOX/start-limit-hit" ;;
      enable)
        touch "$enabled_marker"
        if [[ $* == *--now* ]]; then touch "$active_marker"; fi
        ;;
      disable)
        # Model systemd's inability to disable a unit after its file is deleted.
        if [[ $unit == xray-bootstrap-firewall.service && ! -f $NFT_UNIT ]]; then return 1; fi
        rm -f "$enabled_marker"
        if [[ $* == *--now* ]]; then rm -f "$active_marker"; fi
        ;;
      *) return 0 ;;
    esac
  }
  service_health() { [[ ! -f $SANDBOX/unhealthy && -f $SANDBOX/active ]]; }
  ufw_owned_ports() { :; }
  restore_firewall() { printf restored >"$SANDBOX/firewall-restored"; }
}
