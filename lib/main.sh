#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
usage() {
  cat <<'EOF'
Usage: xray_reality_bootstrap.sh COMMAND [CLIENT_NAME | BACKUP_ID] [OPTIONS]
Commands:
  install update repair preflight status diagnose reprint uninstall
  add-client remove-client list-clients show-client rotate-client export-client
  rotate-shortid finalize-shortid backup restore list-backups recover
  harden-ssh restore-ssh confirm-host firewall-sync clear-firewall test-client
Options:
  --auto --non-interactive --profile-json PATH --dry-run --network-check --allow-prerelease
  --xray-version vN.N.N --shortid-count 1..16 --migration-window SECONDS
  --key-login-confirmed --yes --json --transaction-id TOKEN --test-url HTTPS_URL
Install defaults: no firewall/SSH/OS changes, manual Xray updates, private routing block.
Use preflight first. Firewall and SSH transitions require confirm-host in a new
SSH session within 180 seconds. Credentials are printed only by show-client.
EOF
}
parse_args() {
  ALLOW_PRERELEASE_CLI=false
  MODE=install AUTO=false NON_INTERACTIVE=false DRY_RUN=false PROFILE_PATH='' PIN='' SID_COUNT=''
  NAME='' WINDOW=604800 KEY_CONFIRMED=false YES=false NETWORK_CHECK=false TRANSACTION_ID='' TEST_URL=''
  local positional=false
  if (($#)) && [[ $1 != -* ]]; then
    MODE=$1
    shift
  fi
  case "$MODE" in
    install | update | repair | preflight | status | diagnose | reprint | uninstall | add-client | remove-client | list-clients | show-client | rotate-client | export-client | rotate-shortid | finalize-shortid | backup | restore | list-backups | recover | harden-ssh | restore-ssh | confirm-host | firewall-sync | clear-firewall | test-client) ;;
    *) die 'Unknown command. Use --help.' ;;
  esac
  while (($#)); do
    case "$1" in
      --profile-json=* | --xray-version=* | --shortid-count=* | --migration-window=* | --transaction-id=* | --test-url=*)
        set -- "${1%%=*}" "${1#*=}" "${@:2}"
        ;;
    esac
    case "$1" in
      --auto) AUTO=true ;;
      --allow-prerelease) ALLOW_PRERELEASE_CLI=true ;;
      --non-interactive) NON_INTERACTIVE=true ;;
      --dry-run) DRY_RUN=true ;;
      --network-check) NETWORK_CHECK=true ;;
      --key-login-confirmed) KEY_CONFIRMED=true ;;
      --yes) YES=true ;;
      --json) : ;; # Status/diagnose are always structured and redacted.
      --profile-json | --xray-version | --shortid-count | --migration-window | --transaction-id | --test-url)
        (($# >= 2)) || die "Missing value for $1"
        case "$1" in
          --profile-json) PROFILE_PATH=$2 ;;
          --xray-version) PIN=$2 ;;
          --shortid-count) SID_COUNT=$2 ;;
          --migration-window) WINDOW=$2 ;;
          --transaction-id) TRANSACTION_ID=$2 ;;
          --test-url) TEST_URL=$2 ;;
        esac
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -V | --version)
        printf 'xray-reality-bootstrap v2.0.0\n'
        exit 0
        ;;
      --)
        shift
        (($# == 1)) || die 'Expected one name after --'
        NAME=$1
        positional=true
        ;;
      -*) die "Unknown option: $1" ;;
      *)
        [[ $positional == false ]] || die 'Too many positional arguments'
        NAME=$1
        positional=true
        ;;
    esac
    shift
  done
  [[ $WINDOW =~ ^[0-9]{1,8}$ ]] || die 'Migration window must be 0-31536000 seconds.'
  WINDOW=$((10#$WINDOW))
  ((WINDOW <= 31536000)) || die 'Migration window cannot exceed one year.'
  if [[ -n $SID_COUNT ]]; then [[ $SID_COUNT =~ ^([1-9]|1[0-6])$ ]] || die 'shortid-count must be 1-16.'; fi
  if [[ -n $PIN ]]; then [[ $PIN =~ ^v[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || die 'Invalid version tag.'; fi
  case "$MODE" in add-client | remove-client | show-client | rotate-client | export-client | restore | test-client) [[ -n $NAME ]] || die "$MODE requires a name or backup ID" ;; esac
}
install_mode() {
  load_profile
  [[ $AUTO == true ]] || wizard
  # Preflight checks run before packages or service changes. Requested profile
  # is passed through to prevent checks from using different wizard defaults.
  PROFILE_PATH=$PROFILE
  preflight_mode || die 'Preflight failed; resolve the reported prerequisites.'
  DESIRED=$WORK/state.json
  if [[ -f $STATE_FILE || -f $XRAY_DIR/bootstrap-state.env ]]; then
    load_deployment
    backup_mode >/dev/null
    jq --slurpfile options "$PROFILE" '.options=$options[0]' "$DESIRED" >"$WORK/next"
    mv "$WORK/next" "$DESIRED"
  else
    jq -n --slurpfile options "$PROFILE" '{options:$options[0]}' >"$DESIRED"
  fi
  install_dependencies
  probe_reality
  prepare_candidate
  if ! jq -e '.identity' "$DESIRED" >/dev/null; then make_identity; else
    jq --arg version "$CANDIDATE_VERSION" '.xray_version=$version' "$DESIRED" >"$WORK/next"
    mv "$WORK/next" "$DESIRED"
  fi
  ensure_account
  stage_generation
  persist_helper
  activate_generation
  configure_host_extras
  configure_timer
  apply_firewall
  finish_install
}
finish_install() {
  if [[ $HOST_PENDING == true ]]; then
    # Leave durable journal for the separate confirmer/watchdog.
    TX_ACTIVE=false
  else commit_transaction; fi
  log 'Xray deployed. Run diagnose, then export-client NAME. No credentials were printed.'
  [[ $(opt SSH_HARDENING) != yes ]] || log 'SSH option requested: run harden-ssh separately after confirming proxy installation.'
}
repair_mode() {
  load_deployment
  backup_mode >/dev/null
  reuse_candidate
  ensure_account
  stage_generation
  persist_helper
  activate_generation
  configure_host_extras
  configure_timer
  apply_firewall
  finish_install
}
uninstall_mode() {
  [[ -f $STATE_FILE ]] || die 'Migrate legacy deployment with repair before uninstall; legacy host policies need manual review.'
  [[ ! -f $SSH_DROPIN ]] || die 'Run restore-ssh and confirm-host first to restore administrator SSH settings safely.'
  validate_runtime_ownership
  if [[ $YES != true ]]; then
    [[ -t 0 && $NON_INTERACTIVE == false ]] || die 'Uninstall requires --yes or interactive confirmation.'
    [[ $(prompt_value 'Remove managed runtime files? Type REMOVE; backups/credentials are retained' '') == REMOVE ]] || die 'Cancelled.'
  fi
  load_deployment
  backup_mode >/dev/null
  begin_transaction
  touch "$JOURNAL/pending/timer-changed" "$JOURNAL/pending/firewall-changed"
  if systemctl is-active --quiet xray; then systemctl stop xray; fi
  if systemctl is-enabled --quiet xray 2>/dev/null; then systemctl disable xray; fi
  if systemctl is-enabled --quiet xray-update.timer 2>/dev/null; then systemctl disable --now xray-update.timer; fi
  remove_firewall
  local f
  for f in "$UNIT" "$BIN" "$UPDATE_UNIT" "$UPDATE_TIMER" "$NGINX_FILE" "$F2B_FILE" "$APT_FILE"; do
    if [[ -f $f ]]; then
      if grep -q 'Managed by xray-reality-bootstrap v2' "$f"; then
        rm -f -- "$f"
      else
        log "Retained unrecognized administrator/legacy file: $f"
      fi
    fi
  done
  if command -v nginx >/dev/null && systemctl is-active --quiet nginx; then
    nginx -t
    systemctl reload nginx
  fi
  if command -v fail2ban-client >/dev/null && systemctl is-active --quiet fail2ban; then
    touch "$JOURNAL/pending/f2b-changed"
    fail2ban-client reload
  fi
  systemctl daemon-reload
  commit_transaction
  log 'Managed runtime removed. Backups, deployment credentials, exports, helper and service account retained for recovery; delete them explicitly when no longer needed.'
}
main() {
  init_paths
  parse_args "$@"
  umask 077
  setup_traps
  if [[ $MODE == install && $DRY_RUN == false && $AUTO == false ]] && [[ ! -t 0 || $NON_INTERACTIVE == true ]]; then
    die 'Noninteractive install requires --auto; no packages or host policies were changed.'
  fi
  # Fresh VPS convenience: only real install can bootstrap parsers. Read-only
  # modes never install packages, write host policies or acquire a write lock.
  local bootstrap_packages=()
  command -v jq >/dev/null || bootstrap_packages+=(jq)
  command -v python3 >/dev/null || bootstrap_packages+=(python3)
  if [[ $MODE == install && $DRY_RUN == false ]] && ((${#bootstrap_packages[@]} > 0)); then
    [[ $EUID == 0 ]] || die 'Run install with sudo.'
    lock_operation
    retry env DEBIAN_FRONTEND=noninteractive apt-get update
    retry env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove --no-install-recommends "${bootstrap_packages[@]}"
  fi
  require_tools jq python3 openssl
  if [[ $MODE == preflight || $DRY_RUN == true ]]; then
    dry_run_mode
    return
  fi
  case "$MODE" in
    status | diagnose)
      diagnose_mode
      return
      ;;
    list-clients)
      list_clients_mode
      return
      ;;
    list-backups)
      list_backups_mode
      return
      ;;
  esac
  lock_operation
  if [[ -d $JOURNAL/pending && $MODE != recover && $MODE != confirm-host ]]; then
    die 'Pending/interrupted transition found. Run recover, or confirm-host after connectivity verification.'
  fi
  case "$MODE" in
    install) install_mode ;;
    update) update_mode ;;
    repair) repair_mode ;;
    reprint) reprint_mode ;;
    add-client | remove-client | rotate-client | rotate-shortid | finalize-shortid) client_change_mode ;;
    show-client | export-client) export_client_mode ;;
    backup) backup_mode ;;
    restore) restore_mode ;;
    harden-ssh) harden_ssh_mode ;;
    restore-ssh) restore_ssh_mode ;;
    confirm-host) confirm_host_mode ;;
    recover)
      if [[ -n $TRANSACTION_ID ]]; then
        [[ -f $JOURNAL/pending/token ]] || return 0
        [[ $(cat "$JOURNAL/pending/token") == "$TRANSACTION_ID" ]] || return 0
      fi
      recover_transaction
      ;;
    firewall-sync)
      workspace
      load_deployment
      firewall_conflicts
      [[ $(opt FIREWALL_STYLE) == nftables ]] || die 'firewall-sync requires the deployed nftables policy.'
      [[ -f $NFT_FILE ]] || die 'No persisted managed firewall table.'
      grep -q 'Managed by xray-reality-bootstrap v2' "$NFT_FILE" || die 'Persisted firewall file is not installer-owned.'
      nft_apply_file "$NFT_FILE"
      ;;
    clear-firewall) clear_firewall_mode ;;
    test-client) test_client_mode ;;
    uninstall) uninstall_mode ;;
  esac
}
