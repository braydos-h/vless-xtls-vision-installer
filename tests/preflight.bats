#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-only
# shellcheck disable=SC2154,SC2030,SC2031,SC2317,SC2329
load helpers.bash
bats_require_minimum_version 1.5.0
load preflight_helpers.bash
setup() { setup_preflight; }

@test "preflight accepts every supported OS including Ubuntu 26.04" {
  for OS_FIXTURE in ubuntu:26.04 ubuntu:22.04 ubuntu:24.04 debian:12 debian:13; do
    run preflight_mode
    [ "$status" -eq 0 ]
    [[ "$output" == *'[PASS] OS:'* && "$output" == *'Preflight PASSED.'* ]]
  done
}

@test "unsupported OS reports its identity and supported releases" {
  OS_FIXTURE=fedora:44
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Unsupported operating system: fedora 44'* ]]
  [[ "$output" == *'Ubuntu 22.04, 24.04, 26.04'* ]]
}

@test "architecture and root failures explain prerequisites" {
  uname() { printf 'riscv64\n'; }
  id() { printf '1000\n'; }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Unsupported architecture: riscv64'* ]]
  [[ "$output" == *'[FAIL] Root privileges required'* ]]
}

@test "occupied port identifies the listener and does not trust an xray process name" {
  ss() { printf 'LISTEN 0 511 *:443 *:* users:(("xray",pid=9999,fd=3))\n'; }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Port 443 occupied by'* && "$output" == *'pid=9999'* ]]
  [ ! -d "$JOURNAL/pending" ]
}

@test "preflight preserves selected interactive profile including matching SNI and target" {
  load_profile
  set_profile SERVER_NAME www.apple.com
  set_profile DEST_ENDPOINT www.apple.com:443
  set_profile LISTEN_PORT 9443
  PROFILE_PATH=$PROFILE
  run preflight_mode
  [ "$status" -eq 0 ]
  [[ "$output" == *'primary=9443'* && "$output" == *'target=www.apple.com:443 SNI=www.apple.com'* ]]
}

@test "invalid noninteractive profile reports validation failure without recovery" {
  PROFILE_PATH=$WORK/invalid.json
  printf '{"DEST_ENDPOINT":"https://www.apple.com:443"}\n' >"$PROFILE_PATH"
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Invalid profile:'* ]]
  [[ "$output" != *'Recovery will run'* && "$output" != *'ROLLED_BACK'* ]]
}

@test "missing dependencies all have diagnostics before profile parsing" {
  command() {
    if [[ $1 == -v && ($2 == curl || $2 == jq) ]]; then return 1; fi
    builtin command "$@"
  }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Missing dependency: curl'* && "$output" == *'[FAIL] Missing dependency: jq'* ]]
}

@test "systemd storage and IPv6 failures are explicit" {
  cat() {
    if [[ $1 == /proc/1/comm ]]; then printf 'init\n'; else command cat "$@"; fi
  }
  df() { printf 'Filesystem blocks used available\nmock 100 99 1\n'; }
  ipv6_available() { return 1; }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] systemd must be PID 1'* ]]
  [[ "$output" == *'[FAIL] Free storage:'* && "$output" == *'[FAIL] IPv6 unavailable'* ]]
}

@test "ss inspection failure cannot be mistaken for a free port" {
  ss() {
    printf 'permission denied\n' >&2
    return 13
  }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Cannot inspect TCP port 443 with ss: permission denied'* ]]
}

write_deployed_fixture() {
  python3 - "$STATE_FILE" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('fixture', sys.argv[2] + '/test_data.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
open(sys.argv[1], 'w').write(json.dumps(m.deployment()))
PY
}

@test "managed listener permits reruns only when every socket has the verified PID" {
  write_deployed_fixture
  systemctl() {
    if [[ $1 == show ]]; then printf '1234\n'; else return 1; fi
  }
  runtime_identity() { [[ $1 == 1234 ]]; }
  ss() { printf 'LISTEN users:(("xray",pid=1234,fd=3))\n'; }
  run preflight_mode
  [ "$status" -eq 0 ]
  [[ "$output" == *'[PASS] Port 443 owned by the managed Xray deployment'* ]]
  ss() { printf 'LISTEN users:(("xray",pid=1234,fd=3))\nLISTEN users:(("other",pid=9999,fd=4))\n'; }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Port 443 occupied by'* ]]
}

@test "existing unmanaged Xray files are never adopted" {
  printf 'administrator binary\n' >"$BIN"
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Existing unmanaged Xray service/binary found'* ]]
  [ "$(cat "$BIN")" = 'administrator binary' ]
}

@test "network probe accepts identical SNI and destination and checks TLS arguments" {
  load_profile
  set_profile SERVER_NAME www.apple.com
  set_profile DEST_ENDPOINT www.apple.com:443
  getent() { printf '17.253.144.10 STREAM www.apple.com\n'; }
  timeout() {
    [[ $* == *'-connect www.apple.com:443 -servername www.apple.com'* ]]
    [[ $* == *'-tls1_3 -groups X25519 -alpn h2 -verify_hostname www.apple.com -verify_return_error'* ]]
    printf 'TLSv1.3\nALPN protocol: h2\n'
  }
  run probe_reality
  [ "$status" -eq 0 ]
}

@test "DNS and TLS errors identify operation endpoint and underlying status" {
  load_profile
  set_profile DEST_ENDPOINT www.apple.com:443
  set_profile SERVER_NAME www.apple.com
  getent() { return 2; }
  run probe_reality
  [ "$status" -eq 2 ]
  [[ "$output" == *'DNS resolution failed: getent ahosts www.apple.com'* ]]
  getent() { :; }
  timeout() {
    printf 'certificate verify failed\n'
    return 35
  }
  run probe_reality
  [ "$status" -eq 35 ]
  [[ "$output" == *'endpoint=www.apple.com:443 SNI=www.apple.com'* && "$output" == *'certificate verify failed'* ]]
  timeout() { return 124; }
  run probe_reality
  [ "$status" -eq 124 ]
  [[ "$output" == *'timed out after 20 seconds'* ]]
}

@test "TLS success without required ALPN is a specific validation failure" {
  load_profile
  getent() { :; }
  timeout() { printf 'TLSv1.3\nALPN protocol: http/1.1\n'; }
  run probe_reality
  [ "$status" -eq 1 ]
  [[ "$output" == *'did not negotiate HTTP/2 (h2)'* ]]
}

@test "network-check failure participates in the preflight result" {
  NETWORK_CHECK=true
  getent() { return 2; }
  run preflight_mode
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] DNS resolution failed'* && "$output" == *'Preflight FAILED.'* ]]
}

@test "download package and systemd failures retain their exit codes" {
  sleep() { :; }
  curl() {
    printf 'Could not resolve host\n' >&2
    return 6
  }
  run download https://example.com/release "$WORK/download"
  [ "$status" -eq 6 ]
  [[ "$output" == *'Download failed: HTTPS GET https://example.com/release (curl exit 6'* ]]
  retry() { return 100; }
  run apt_action update
  [ "$status" -eq 100 ]
  [[ "$output" == *'Package operation failed: apt-get update (exit 100)'* ]]
  systemctl() { return 5; }
  run systemd_action restart xray
  [ "$status" -eq 5 ]
  [[ "$output" == *'systemd activation failed: systemctl restart xray (exit 5)'* ]]
}

@test "standalone preflight failure exits cleanly with traps enabled" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1/helpers.bash"; source "$1/preflight_helpers.bash"; setup_preflight
    init_paths() { :; }
    OS_FIXTURE=ubuntu:20.04
    main preflight
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Unsupported operating system: ubuntu 20.04'* ]]
  [[ "$output" != *'failed at line'* && "$output" != *'Recovery'* && "$output" != *'restoring'* ]]
  [ ! -d "$JOURNAL/pending" ]
}

@test "standalone preflight succeeds without obtaining a mutation lock" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1/helpers.bash"; source "$1/preflight_helpers.bash"; setup_preflight
    init_paths() { :; }
    lock_operation() { die "read-only command acquired a mutation lock"; }
    main preflight
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Preflight PASSED.'* ]]
  [ ! -d "$JOURNAL/pending" ]
}

@test "unsupported install is rejected before parser bootstrap and locking" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1/helpers.bash"; source "$1/preflight_helpers.bash"; setup_preflight
    init_paths() { :; }; OS_FIXTURE=fedora:44
    lock_operation() { touch "$SANDBOX/unexpected-lock"; }
    apt_action() { touch "$SANDBOX/unexpected-packages"; }
    main install --auto --non-interactive
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Unsupported operating system: fedora 44'* ]]
  [ ! -f "$SANDBOX/unexpected-lock" ]
  [ ! -f "$SANDBOX/unexpected-packages" ]
}

@test "install fails validation before package or transaction mutations without ERR trap noise" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1/helpers.bash"; source "$1/preflight_helpers.bash"; setup_preflight
    init_paths() { :; }; lock_operation() { :; }
    ss() { echo "LISTEN nginx pid=99"; }
    install_dependencies() { touch "$SANDBOX/unexpected-packages"; }
    main install --auto --non-interactive
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *'[FAIL] Port 443 occupied by'* ]]
  [[ "$output" != *'failed at line'* && "$output" != *'Recovery'* ]]
  [ ! -f "$SANDBOX/unexpected-packages" ]
  [ ! -d "$JOURNAL/pending" ]
}

@test "automatic install proceeds beyond preflight on Ubuntu 26.04" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1/helpers.bash"; source "$1/preflight_helpers.bash"; setup_preflight
    init_paths() { :; }; lock_operation() { :; }
    install_dependencies() { echo "REACHED PACKAGE STAGE"; exit 0; }
    main install --auto --non-interactive
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Preflight PASSED.'* && "$output" == *'REACHED PACKAGE STAGE'* ]]
}

@test "real interactive wizard retains selected values through install preflight" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    printf "www.apple.com\nwww.apple.com:443\n9443\n\n\n\n\n\n\n\n" |
      script -q -e -c '\''bash "$BATS_TEST_DIRNAME/wizard-fixture.sh"'\'' /dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'WIZARD PROFILE RETAINED AT PACKAGE STAGE'* ]]
}
