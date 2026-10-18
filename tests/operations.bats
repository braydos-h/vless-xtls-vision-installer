#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-only
# Bats supplies fixture globals, runs each test in a subshell, and calls mocks indirectly.
# shellcheck disable=SC2154,SC2030,SC2031,SC2317,SC2329
load helpers.bash
bats_require_minimum_version 1.5.0
setup() { setup_sandbox; }

@test "failed activation restores pointer, binary, unit and service" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c 'source "$1"; setup_sandbox; touch "$SANDBOX/fail-restart"; setup_traps; activate_generation' _ "$BATS_TEST_DIRNAME/helpers.bash"
  [ "$status" -eq 1 ]
  [[ "$output" == *ROLLED_BACK* ]]
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
  [ "$(cat "$BIN")" = 'old binary' ]
  grep -qx 'old unit' "$UNIT"
  [ -f "$SANDBOX/active" ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "ERR reporting preserves original activation exit code and completes rollback" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1"; setup_sandbox
    eval "$(declare -f systemctl | sed "1s/systemctl/base_systemctl/")"
    touch "$SANDBOX/fail-once"
    systemctl() {
      if [[ $1 == restart && -f $SANDBOX/fail-once ]]; then
        rm "$SANDBOX/fail-once"; return 37
      fi
      base_systemctl "$@"
    }
    setup_traps
    activate_generation
  ' _ "$BATS_TEST_DIRNAME/helpers.bash"
  [ "$status" -eq 37 ]
  [[ "$output" == *'systemctl restart xray (exit 37)'* && "$output" == *ROLLED_BACK* ]]
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "successful activation commits binary config and state as one pointer" {
  activate_generation
  [ "$(readlink "$CURRENT")" = "deployments/$new" ]
  [ -d "$JOURNAL/pending" ]
  commit_transaction
  [ ! -d "$JOURNAL/pending" ]
  [ "$(readlink "$CURRENT")" = "deployments/$new" ]
}

@test "durable recovery restores interrupted activation and managed firewall only" {
  begin_transaction
  point_current "$new"
  printf modified >"$UNIT"
  touch "$JOURNAL/pending/firewall-changed"
  TX_ACTIVE=false
  recover_transaction
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
  grep -qx 'old unit' "$UNIT"
  [ "$(cat "$SANDBOX/firewall-restored")" = restored ]
}

@test "recovery fails closed and preserves journal if service recovery fails" {
  begin_transaction
  point_current "$new"
  touch "$SANDBOX/fail-restart"
  run recover_transaction
  [ "$status" -ne 0 ]
  [ -d "$JOURNAL/pending" ]
}

@test "symlink managed files rejected before activation" {
  rm "$UNIT"
  printf unchanged >"$SANDBOX/unrelated"
  ln -s "$SANDBOX/unrelated" "$UNIT"
  run begin_transaction
  [ "$status" -ne 0 ]
  [ "$(cat "$SANDBOX/unrelated")" = unchanged ]
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
}

@test "retry returns the final failure code" {
  sleep() { :; }
  always_fails() { return 37; }
  run retry always_fails
  [ "$status" -eq 37 ]
}

@test "profile load does not truncate its own input" {
  PROFILE_PATH=$WORK/options.json
  PIN=''
  SID_COUNT=''
  data defaults >"$PROFILE_PATH"
  load_profile
  [ "$(jq -r '.profile_format' "$PROFILE")" = 2 ]
}

@test "nft renderer owns one table without global input or forwarding drops" {
  DESIRED=$WORK/state.json
  jq -n '{options:{LISTEN_PORT:"443",FALLBACK_PORT:"8443",OS_PRIVATE_OUTBOUND:"no"}}' >"$DESIRED"
  run render_nft
  [ "$status" -eq 0 ]
  [[ "$output" == *'table inet xray_bootstrap'* ]]
  [[ "$output" == *'443, 8443'* ]]
  [[ "$output" != *'flush ruleset'* && "$output" != *'policy drop'* && "$output" != *'forward'* ]]
}

@test "nft application validates then atomically replaces only owned table" {
  nft() {
    printf '%s\n' "$*" >>"$SANDBOX/nft.calls"
    if [[ $1 == list ]]; then printf 'table inet xray_bootstrap { comment "xray-reality-bootstrap managed"; }\n'; fi
  }
  printf 'table inet xray_bootstrap { }\n' >"$WORK/proposed"
  nft_apply_file "$WORK/proposed"
  nft_apply_file "$WORK/proposed"
  [ "$(grep -c -- '-c -f' "$SANDBOX/nft.calls")" -eq 2 ]
  [ "$(head -n1 "$WORK/nft-batch")" = 'delete table inet xray_bootstrap' ]
  run ! grep -q 'flush ruleset' "$WORK/nft-batch"
}

@test "backup validation rejects corruption and links" {
  printf '2\n' >"$SANDBOX/backups/format"
  printf 'malformed\n' >"$SANDBOX/backups/SHA256SUMS"
  run validate_backup "$SANDBOX/backups"
  [ "$status" -ne 0 ]
}

@test "unknown version and unreasonable migration windows rejected" {
  run parse_args update --xray-version 'v1;id'
  [ "$status" -ne 0 ]
  run parse_args rotate-shortid --migration-window 99999999999
  [ "$status" -ne 0 ]
}

@test "nft validation failure never activates proposed rules" {
  nft() {
    printf '%s\n' "$*" >>"$SANDBOX/nft.failed.calls"
    if [[ $1 == list ]]; then printf 'table inet xray_bootstrap { comment "xray-reality-bootstrap managed"; }\n'; fi
    [[ $1 != -c ]]
  }
  printf 'table inet xray_bootstrap { }\n' >"$WORK/proposed"
  run nft_apply_file "$WORK/proposed"
  [ "$status" -ne 0 ]
  run ! grep -q '^-f ' "$SANDBOX/nft.failed.calls"
}

@test "UFW removal touches only tagged rules in descending order" {
  # shellcheck source=lib/firewall.sh
  source "$BATS_TEST_DIRNAME/../lib/firewall.sh"
  ufw() {
    if [[ $1 == status ]]; then
      printf '[ 1] 443/tcp ALLOW IN Anywhere # xray-bootstrap-443\n[ 2] 22/tcp ALLOW IN Anywhere # admin\n[ 3] 443/tcp (v6) ALLOW IN Anywhere (v6) # xray-bootstrap-443\n'
    else printf '%s\n' "$*" >>"$SANDBOX/ufw-deletes"; fi
  }
  ufw_remove_owned
  [ "$(cat "$SANDBOX/ufw-deletes")" = $'--force delete 3\n--force delete 1' ]
}

@test "watchdog carries matching token and timeout without secret arguments" {
  begin_transaction
  HELPER=$SANDBOX/helper
  persist_helper() { :; }
  systemd-run() { printf '%s\n' "$*" >"$SANDBOX/watchdog"; }
  SSH_CONNECTION='1.2.3.4 12345 5.6.7.8 22'
  arm_rollback
  [ -f "$JOURNAL/pending/armed" ]
  [[ "$(cat "$SANDBOX/watchdog")" == *'--on-active=180s'* ]]
  [[ "$(cat "$SANDBOX/watchdog")" == *"recover --transaction-id $(cat "$JOURNAL/pending/token")"* ]]
  [ "$(cat "$JOURNAL/pending/origin-ssh")" = "$SSH_CONNECTION" ]
}

@test "confirmation rejects originating session without canceling watchdog" {
  begin_transaction
  touch "$JOURNAL/pending/armed"
  SSH_CONNECTION='1.2.3.4 1000 5.6.7.8 22'
  printf '%s\n' "$SSH_CONNECTION" >"$JOURNAL/pending/origin-ssh"
  run confirm_host_mode
  [ "$status" -ne 0 ]
  [ -f "$JOURNAL/pending/armed" ]
  [ -d "$JOURNAL/pending" ]
}

@test "a second operation cannot acquire the held flock" {
  LOCK=$SANDBOX/operation.lock
  require_root() { :; } # Exercise flock itself on unprivileged CI runners.
  exec 7>"$LOCK"
  flock -n 7
  run lock_operation
  [ "$status" -ne 0 ]
  exec 7>&-
}

@test "candidate checksum mismatch preserves deployed binary" {
  MODE=update
  PIN=v26.3.27
  PROFILE=$WORK/profile.json
  data defaults >"$PROFILE"
  payload=$WORK/payload.zip
  printf corrupt >"$payload"
  jq -n --arg digest "sha256:$(printf '%064d' 0)" '{tag_name:"v26.3.27",draft:false,prerelease:false,assets:[{name:"Xray-linux-64.zip",size:7,digest:$digest,browser_download_url:"https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip"}]}' >"$WORK/metadata.fixture"
  download() {
    if [[ $1 == *api.github.com* ]]; then cp "$WORK/metadata.fixture" "$2"; else cp "$payload" "$2"; fi
  }
  run prepare_candidate
  [ "$status" -ne 0 ]
  [[ "$output" == *'checksum mismatch'* ]]
  [ "$(cat "$BIN")" = 'old binary' ]
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
}

@test "insufficient update staging space fails before downloading" {
  MODE=update
  PIN=v26.3.27
  df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nmock 100 99 1 99%% /\n'; }
  download() { touch "$SANDBOX/unexpected-download"; }
  run prepare_candidate
  [ "$status" -ne 0 ]
  [ ! -f "$SANDBOX/unexpected-download" ]
}

@test "client dry run validates changes without activating a deployment" {
  DESIRED=$WORK/input-state.json
  python3 - "$DESIRED" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util, json, sys
spec=importlib.util.spec_from_file_location('test_data', sys.argv[2]+'/test_data.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
open(sys.argv[1], 'w').write(json.dumps(m.deployment()))
PY
  cp "$DESIRED" "$STATE_FILE"
  MODE=remove-client
  NAME=alice
  WINDOW=0
  run dry_run_mode
  [ "$status" -ne 0 ]
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "fresh install space check handles a missing Xray directory" {
  XRAY_DIR=$SANDBOX/not-installed-yet
  PIN=v26.3.27
  download() {
    touch "$SANDBOX/download-requested"
    return 42
  }
  run prepare_candidate
  [ "$status" -ne 0 ]
  [ -f "$SANDBOX/download-requested" ]
  [ ! -d "$XRAY_DIR" ]
}

@test "client CLI accepts leading hyphens as literal data" {
  python3 - "$WORK/input.json" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util, json, sys
spec=importlib.util.spec_from_file_location('test_data', sys.argv[2]+'/test_data.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
open(sys.argv[1], 'w').write(json.dumps(m.deployment()))
PY
  run data mutate "$WORK/input.json" add-client '-leading-name' 0
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name": "-leading-name"'* ]]
}

@test "structured diagnostics redact credentials and fail when config is invalid" {
  python3 - "$STATE_FILE" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util, json, sys
spec=importlib.util.spec_from_file_location('test_data', sys.argv[2]+'/test_data.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
open(sys.argv[1], 'w').write(json.dumps(m.deployment()))
PY
  ss() { printf 'LISTEN users:(("xray",pid=1,fd=3))\n'; }
  run diagnose_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'"credentials": "redacted"'* ]]
  [[ "$output" != *'12345678-1234-4234-8234-123456789abc'* ]]
  [[ "$output" != *'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'* ]]
}

@test "offline update preserves disabled inactive service" {
  rm "$SANDBOX/active" "$SANDBOX/enabled"
  MODE=update
  activate_generation
  commit_transaction
  [ ! -f "$SANDBOX/active" ]
  [ ! -f "$SANDBOX/enabled" ]
  run ! grep -q '^restart xray$' "$SANDBOX/systemctl.log"
  [ "$(readlink "$CURRENT")" = "deployments/$new" ]
}

release_fixture() {
  MODE=update
  PIN=''
  PROFILE=$WORK/profile.json
  data defaults >"$PROFILE"
  jq -n --argjson prerelease "$1" --arg digest "sha256:$(printf '%064d' 0)" \
    '{tag_name:"v26.3.27",draft:false,prerelease:$prerelease,assets:[{name:"Xray-linux-64.zip",size:7,digest:$digest,browser_download_url:"https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip"}]}' >"$WORK/metadata.fixture"
  download() {
    if [[ $1 == *api.github.com* ]]; then cp "$WORK/metadata.fixture" "$2"; else
      touch "$SANDBOX/asset-requested"
      return 42
    fi
  }
}

@test "upstream prerelease requires explicit permission before asset download" {
  release_fixture true
  run prepare_candidate
  [ "$status" -ne 0 ]
  [[ "$output" == *'marked prerelease'* ]]
  [ ! -f "$SANDBOX/asset-requested" ]
}

@test "explicit prerelease permission reaches the verified asset staging path" {
  release_fixture true
  ALLOW_PRERELEASE_CLI=true
  run prepare_candidate
  [ "$status" -ne 0 ]
  [ -f "$SANDBOX/asset-requested" ]
  [ "$(cat "$BIN")" = 'old binary' ]
}

@test "unpinned update never silently downgrades to an older stable release" {
  release_fixture false
  printf '{"xray_version":"v26.10.10"}\n' >"$STATE_FILE"
  prepare_candidate
  [ "$UPDATE_SKIPPED" = true ]
  [ ! -f "$SANDBOX/asset-requested" ]
}

@test "repeated installation retains already installed host package versions" {
  data defaults >"$WORK/defaults.json"
  jq -n --slurpfile opts "$WORK/defaults.json" '{options:$opts[0]}' >"$DESIRED"
  dpkg-query() { printf 'install ok installed'; }
  retry() { touch "$SANDBOX/unexpected-package-operation"; }
  install_dependencies
  [ ! -f "$SANDBOX/unexpected-package-operation" ]
}

@test "SSH authentication-only hardening checks the existing login port" {
  opt() {
    case "$1" in
      CHANGE_SSH_PORT) printf no ;;
      SSH_PORT) printf 22 ;;
    esac
  }
  SSH_CONNECTION='1.2.3.4 1000 5.6.7.8 2200'
  [ "$(ssh_check_port $'2200\n2222')" = 2200 ]
  SSH_CONNECTION=''
  [ "$(ssh_check_port $'2200\n2222')" = 2200 ]
  unset SSH_CONNECTION
  [ "$(ssh_check_port $'2200\n2222')" = 2200 ]
}

@test "requested kernel egress policy is installed before starting reconfigured Xray" {
  MODE=install
  jq -n '{options:{FIREWALL_STYLE:"nftables",OS_PRIVATE_OUTBOUND:"yes"}}' >"$DESIRED"
  apply_firewall() { touch "$SANDBOX/egress-enforced"; }
  systemctl() {
    if [[ $1 == restart ]]; then test -f "$SANDBOX/egress-enforced"; else return 0; fi
  }
  activate_generation
  [ -f "$SANDBOX/egress-enforced" ]
  commit_transaction
}

@test "administrator unit ownership is checked before a runtime transaction" {
  printf 'administrator service\n' >"$UNIT"
  run activate_generation
  [ "$status" -ne 0 ]
  [ ! -d "$JOURNAL/pending" ]
  [ "$(readlink "$CURRENT")" = "deployments/$old" ]
  [ "$(cat "$UNIT")" = 'administrator service' ]
}

@test "unsafe lock symlink cannot truncate an unrelated file" {
  LOCK=$SANDBOX/operation.lock
  require_root() { :; }
  printf unchanged >"$SANDBOX/unrelated-lock-target"
  ln -s "$SANDBOX/unrelated-lock-target" "$LOCK"
  run lock_operation
  [ "$status" -ne 0 ]
  [ "$(cat "$SANDBOX/unrelated-lock-target")" = unchanged ]
}

@test "fail2ban readiness tolerates a delayed control socket and has a timeout" {
  FAKE_F2B_PINGS=0
  sleep() { :; }
  fail2ban-client() {
    FAKE_F2B_PINGS=$((FAKE_F2B_PINGS + 1))
    [ "$FAKE_F2B_PINGS" -ge 3 ]
  }
  wait_fail2ban
  [ "$FAKE_F2B_PINGS" -eq 3 ]
  fail2ban-client() { return 1; }
  run wait_fail2ban
  [ "$status" -ne 0 ]
}

@test "SSH confirmation publishes matching runtime metadata and restarts an active proxy" {
  begin_transaction
  touch "$JOURNAL/pending/armed" "$JOURNAL/pending/ssh-changed"
  printf '22\n' >"$JOURNAL/pending/ssh-port"
  printf 'requested SSH state\n' >"$JOURNAL/pending/ssh-state.json"
  SSH_CONNECTION='1.2.3.4 2000 5.6.7.8 22'
  KEY_CONFIRMED=false
  load_deployment() { DESIRED=$WORK/desired-ssh-state; }
  reuse_candidate() { :; }
  stage_generation() { GENERATION=$new; }
  confirm_host_mode
  grep -qx 'restart xray' "$SANDBOX/systemctl.log"
  [ -f "$SANDBOX/active" ]
  [ "$(readlink "$CURRENT")" = "deployments/$new" ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "rollback disables new firewall unit before removing its file" {
  begin_transaction
  printf '# Managed by xray-reality-bootstrap v2\n' >"$NFT_UNIT"
  printf '# Managed by xray-reality-bootstrap v2\n' >"$NFT_FILE"
  systemctl enable --now xray-bootstrap-firewall.service
  touch "$JOURNAL/pending/firewall-changed"
  recover_transaction
  [ ! -f "$NFT_UNIT" ]
  [ ! -f "$SANDBOX/xray-bootstrap-firewall.service.active" ]
  [ ! -f "$SANDBOX/xray-bootstrap-firewall.service.enabled" ]
  [ -f "$SANDBOX/active" ]
}

@test "SSH validation failure restores files without reloading an untouched daemon" {
  begin_transaction
  touch "$JOURNAL/pending/ssh-not-reloaded" "$JOURNAL/pending/ssh-changed"
  printf '# Managed by xray-reality-bootstrap v2\n' >"$SSH_DROPIN"
  sshd() { touch "$SANDBOX/unexpected-sshd-reload"; }
  recover_transaction
  [ ! -f "$SSH_DROPIN" ]
  [ ! -f "$SANDBOX/unexpected-sshd-reload" ]
  run ! grep -q '^reload ssh$' "$SANDBOX/systemctl.log"
}

@test "manual update policy never removes an administrator timer" {
  data defaults >"$WORK/defaults.json"
  jq -n --slurpfile opts "$WORK/defaults.json" '{options:$opts[0]}' >"$DESIRED"
  printf 'administrator job\n' >"$UPDATE_UNIT"
  run configure_timer
  [ "$status" -ne 0 ]
  [ "$(cat "$UPDATE_UNIT")" = 'administrator job' ]
}

@test "nft synchronization refuses an unowned reserved table" {
  nft() {
    if [[ $1 == list ]]; then printf 'table inet xray_bootstrap { comment "administrator"; }\n'; else touch "$SANDBOX/unexpected-nft-mutation"; fi
  }
  printf 'table inet xray_bootstrap {}\n' >"$WORK/proposed"
  run nft_apply_file "$WORK/proposed"
  [ "$status" -ne 0 ]
  [ ! -f "$SANDBOX/unexpected-nft-mutation" ]
}

@test "backup manifest links are rejected before reading their contents" {
  printf '2\n' >"$BACKUPS/format"
  printf 'malformed manifest\n' >"$SANDBOX/manifest-target"
  ln -s "$SANDBOX/manifest-target" "$BACKUPS/SHA256SUMS"
  run validate_backup "$BACKUPS"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unsafe backup file'* ]]
}

@test "firewall conflict detection consumes long UFW status without SIGPIPE" {
  jq -n '{options:{FIREWALL_STYLE:"nftables"}}' >"$DESIRED"
  ufw() {
    printf 'Status: active\n'
    local line
    for ((line = 0; line < 2000; line++)); do printf '%0100d\n' "$line"; done
  }
  run firewall_conflicts
  [ "$status" -ne 0 ]
  [[ "$output" == *'UFW is active'* ]]
}

@test "skipped updates do not accumulate full deployment backups" {
  load_deployment() { :; }
  prepare_candidate() { UPDATE_SKIPPED=true; }
  backup_mode() { touch "$SANDBOX/unexpected-backup"; }
  update_mode
  [ ! -f "$SANDBOX/unexpected-backup" ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "SSH readiness waits for daemon-owned listeners and times out on another owner" {
  systemctl() { printf '1234\n'; }
  sleep() { touch "$SANDBOX/ssh-ready"; }
  ss() {
    if [[ -f $SANDBOX/ssh-ready ]]; then
      printf 'LISTEN users:(("sshd",pid=1234,fd=3))\n'
    else printf 'LISTEN users:(("other",pid=9999,fd=3))\n'; fi
  }
  wait_ssh_listeners $'22\n2222'
  [ -f "$SANDBOX/ssh-ready" ]
  sleep() { :; }
  ss() { printf 'LISTEN users:(("other",pid=9999,fd=3))\n'; }
  run wait_ssh_listeners $'22\n2222'
  [ "$status" -ne 0 ]
}

@test "standalone recovery initializes a private temporary workspace" {
  begin_transaction
  export TMPDIR=$SANDBOX/recovery-tmp
  mkdir "$TMPDIR"
  WORK=''
  recover_transaction
  [[ $WORK == "$TMPDIR/"* ]]
  [ -d "$WORK" ]
  [ "$(stat -c %a "$WORK")" = 700 ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "legacy auto profiles preserve deployed binding and do not reapply old host defaults" {
  python3 - "$XRAY_DIR" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location('test_data',sys.argv[2]+'/test_data.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
s=m.deployment();cfg=m.d.config(s);cfg['inbounds'][0]['listen']='0.0.0.0'
root=pathlib.Path(sys.argv[1]);(root/'config.json').write_text(json.dumps(cfg))
(root/'bootstrap-state.env').write_text('PROFILE_NAME=alice\nXRAY_VERSION=v26.3.27\nUUID='+s['clients'][0]['id']+
    '\nREALITY_PRIVATE_KEY='+s['identity']['private_key']+'\nREALITY_PUBLIC_KEY='+s['identity']['public_key']+
    '\nFIREWALL_STYLE=nftables\nSSH_HARDENING=yes\nUNATTENDED_UPGRADES_ENABLED=yes\n')
(root/'bootstrap-options.json').write_text(json.dumps({'LISTEN_PORT':'8443','SSH_HARDENING':'yes'}))
PY
  PROFILE_PATH=''
  PIN=''
  SID_COUNT=''
  load_profile
  [ "$(jq -r '.LISTEN_ADDRESS' "$PROFILE")" = 0.0.0.0 ]
  [ "$(jq -r '.LISTEN_PORT' "$PROFILE")" = 443 ]
  [ "$(jq -r '.FIREWALL_STYLE' "$PROFILE")" = none ]
  [ "$(jq -r '.SSH_HARDENING' "$PROFILE")" = no ]
  [ "$(jq -r '.UNATTENDED_UPGRADES_ENABLED' "$PROFILE")" = no ]
  PROFILE_PATH=$WORK/request.json
  printf '{"profile_format":"1"}\n' >"$PROFILE_PATH"
  load_profile
  [ "$(jq -r '.LISTEN_ADDRESS' "$PROFILE")" = 0.0.0.0 ]
  data migrate "$XRAY_DIR/bootstrap-state.env" "$XRAY_DIR/config.json" >"$STATE_FILE"
  load_profile
  [ "$(jq -r '.LISTEN_ADDRESS' "$PROFILE")" = 0.0.0.0 ]
  printf '{"LISTEN_ADDRESS":"::"}\n' >"$PROFILE_PATH"
  load_profile
  [ "$(jq -r '.LISTEN_ADDRESS' "$PROFILE")" = :: ]
}

@test "Nginx opt-out removes its managed site while preserving an inactive service" {
  begin_transaction
  printf '# Managed by xray-reality-bootstrap v2\n' >"$NGINX_FILE"
  jq -n '{options:{CAMOUFLAGE_ENABLED:"no",FAIL2BAN_ENABLED:"no",UNATTENDED_UPGRADES_ENABLED:"no"}}' >"$DESIRED"
  nginx() { :; }
  configure_host_extras
  [ ! -f "$NGINX_FILE" ]
  run ! grep -q '^reload nginx$' "$SANDBOX/systemctl.log"
  [ ! -f "$SANDBOX/nginx.active" ]
  commit_transaction
}
