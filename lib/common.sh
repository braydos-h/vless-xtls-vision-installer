#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
init_paths() {
  MODE=install
  OPLOG=''
  XRAY_DIR=/etc/xray
  CURRENT=$XRAY_DIR/current
  DEPLOYMENTS=$XRAY_DIR/deployments
  STATE_FILE=$CURRENT/state.json
  CONFIG_FILE=$CURRENT/config.json
  BIN=/usr/local/bin/xray
  UNIT=/etc/systemd/system/xray.service
  HELPER=/usr/local/sbin/xray-reality-bootstrap
  BACKUPS=/var/backups/xray-bootstrap
  JOURNAL=/var/lib/xray-bootstrap
  CLIENT_DIR=/root/xray-client-configs
  SSH_DROPIN=/etc/ssh/sshd_config.d/00-xray-bootstrap.conf
  NFT_FILE=/etc/xray/bootstrap-firewall.nft
  NFT_UNIT=/etc/systemd/system/xray-bootstrap-firewall.service
  NGINX_FILE=/etc/nginx/conf.d/xray-camouflage.conf
  F2B_FILE=/etc/fail2ban/jail.d/xray-bootstrap.local
  APT_FILE=/etc/apt/apt.conf.d/52xray-bootstrap-upgrades
  UPDATE_UNIT=/etc/systemd/system/xray-update.service
  UPDATE_TIMER=/etc/systemd/system/xray-update.timer
  LOCK=/run/lock/xray-bootstrap.lock
  TX_ACTIVE=false
  WORK=''
  CHILD_PID=''
  CLIENT_TEST_DIR=''
  HOST_PENDING=false
  FIREWALL_APPLIED=false
  MANAGED_FILES=("$BIN" "$UNIT" "$NFT_FILE" "$NFT_UNIT" "$NGINX_FILE" "$F2B_FILE" "$APT_FILE" "$UPDATE_UNIT" "$UPDATE_TIMER" "$SSH_DROPIN")
}
log() {
  printf '%s\n' "$*" >&2
  if [[ -n ${OPLOG:-} ]]; then printf '%s %s: %s\n' "$(date -u +%FT%TZ)" "$MODE" "$*" >>"$OPLOG"; fi
}
die() {
  log "ERROR: $*"
  exit 1
}
require_tools() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "Missing dependency: $c. Install prerequisites listed in README."
  done
}
require_root() {
  [[ $EUID == 0 ]] || die 'Run mutations with sudo.'
}
lock_operation() {
  require_root
  if [[ ! -e $LOCK && ! -L $LOCK ]]; then
    (
      set -o noclobber
      : >"$LOCK"
    ) || die 'Cannot safely create the operation lock.'
  fi
  [[ -f $LOCK && ! -L $LOCK && $(stat -c %u "$LOCK") == "$EUID" && $(stat -c %h "$LOCK") == 1 ]] || die 'Unsafe operation lock ownership/type.'
  chmod 600 "$LOCK"
  exec 9>>"$LOCK"
  if [[ $MODE == recover && -n ${TRANSACTION_ID:-} ]]; then
    flock -w 300 9 || die 'Timed recovery could not obtain the operation lock; use the VPS console.'
  else
    flock -n 9 || die 'Another operation is running. Retry after it finishes.'
  fi
  install -d -m 700 "$JOURNAL"
  OPLOG=$JOURNAL/operations.log
  [[ ! -L $OPLOG ]] || die 'Unsafe operation log symlink.'
  touch "$OPLOG"
  chmod 600 "$OPLOG"
}
workspace() {
  [[ -n $WORK ]] && return 0
  WORK=$(mktemp -d)
  chmod 700 "$WORK"
}
cleanup() {
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  if [[ $TX_ACTIVE == true ]]; then
    log 'Operation failed; restoring the previous deployment.'
    if ! recover_transaction; then
      log 'ERROR: recovery failed; use the VPS console and run recover.'
      rc=1
    fi
  fi
  if [[ -n $CHILD_PID ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID"
    wait "$CHILD_PID" 2>/dev/null || : # SIGTERM exit is expected for the temporary client.
  fi
  if [[ -n $CLIENT_TEST_DIR && -d $CLIENT_TEST_DIR ]]; then rm -rf -- "$CLIENT_TEST_DIR"; fi
  if [[ -n $WORK && -d $WORK ]]; then rm -rf -- "$WORK"; fi
  exit "$rc"
}
setup_traps() {
  trap cleanup EXIT
  # Never print BASH_COMMAND: it may contain keys or UUIDs.
  trap 'log "ERROR: operation failed at line $LINENO (exit $?). Recovery will run if needed."' ERR
  trap 'exit 130' INT TERM HUP
}
atomic_file() {
  local src=$1 dest=$2 mode=${3:-600} tmp
  [[ ! -L $dest ]] || die "Refusing symlink at managed file: $dest"
  tmp=$(mktemp "${dest}.tmp.XXXXXX") || return 1
  install -m "$mode" "$src" "$tmp" || return 1
  sync -f "$tmp" || return 1
  mv -fT -- "$tmp" "$dest" || return 1
}
atomic_managed_file() {
  if [[ -f $2 ]] && ! grep -q 'Managed by xray-reality-bootstrap v2' "$2"; then
    die "Existing administrator/legacy file requires review before replacement: $2"
  fi
  atomic_file "$@"
}

point_current() {
  local generation=$1 temp=$XRAY_DIR/.current-next
  [[ $generation =~ ^[0-9]{8}T[0-9]{6}-[a-f0-9]{12}$ ]] || die 'Invalid generation identifier.'
  if [[ -e $temp || -L $temp ]]; then rm -f -- "$temp" || return 1; fi
  ln -s "deployments/$generation" "$temp" || return 1
  mv -fT -- "$temp" "$CURRENT" || return 1
  sync -f "$XRAY_DIR" || return 1
}

new_id() { printf '%s-%s' "$(date -u +%Y%m%dT%H%M%S)" "$(openssl rand -hex 6)"; }
opt() { jq -er --arg k "$1" '.options[$k]' "$DESIRED"; }
# jq -e treats empty strings as success, but false/null as failures.
profile_opt() { jq -r --arg k "$1" '.[$k]' "$PROFILE"; }
retry() {
  local n=0 rc=0
  while ((n < 3)); do
    if "$@"; then return 0; else rc=$?; fi
    n=$((n + 1))
    ((n == 3)) || sleep 2
  done
  return "$rc"
}
