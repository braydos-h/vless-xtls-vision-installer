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
  ERROR_REPORTED=false
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
# A single policy for standalone preflight and install (including parser bootstrap).
supported_os() {
  case "$1:$2" in
    debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04 | ubuntu:26.04) return 0 ;;
    *) return 1 ;;
  esac
}
check_platform() {
  local id version arch failure=false
  id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  if supported_os "$id" "$version"; then
    printf '[PASS] OS: %s %s\n' "$id" "$version"
  else
    log "[FAIL] Unsupported operating system: ${id:-unknown} ${version:-unknown}. Supported: Debian 12, 13; Ubuntu 22.04, 24.04, 26.04 (apt + systemd)."
    failure=true
  fi
  arch=$(uname -m)
  if arch_asset >/dev/null; then printf '[PASS] Architecture: %s\n' "$arch"; else failure=true; fi
  if [[ $(cat /proc/1/comm) == systemd ]] && command -v systemctl >/dev/null; then
    printf '[PASS] systemd available\n'
  else
    log '[FAIL] systemd must be PID 1 and systemctl must be installed; use a systemd VPS/VM.'
    failure=true
  fi
  if [[ $(id -u) == 0 ]]; then printf '[PASS] Root privileges\n'; else
    log '[FAIL] Root privileges required to validate listener ownership; run with sudo.'
    failure=true
  fi
  [[ $failure == false ]]
}
ipv6_available() { [[ -e /proc/net/if_inet6 ]]; }
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
  WORK=$(mktemp -d) || return $?
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
  trap 'report_error "$?" "$LINENO" "${FUNCNAME[0]:-main}"' ERR
  trap 'exit 130' INT TERM HUP
}
report_error() {
  local rc=$1 line=$2 operation=$3
  # Command substitutions inherit ERR. Report once in the parent shell, where
  # the failure status propagates, instead of once per unwinding function.
  if ((BASH_SUBSHELL > 0)) || [[ ${ERROR_REPORTED:-false} == true ]]; then return 0; fi
  ERROR_REPORTED=true
  log "ERROR: $MODE: $operation failed at line $line (exit $rc)."
  if [[ $TX_ACTIVE == true ]]; then log 'Deployment transaction is active; cleanup will restore the previous deployment.'; fi
  # ERR retains the original command status. Returning nonzero from the trap
  # itself can interrupt Bash's stack unwinding before EXIT recovery runs.
  return 0
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
