#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-only
# shellcheck disable=SC2154,SC2030,SC2031,SC2317,SC2329
load helpers.bash
bats_require_minimum_version 1.5.0
setup() {
  setup_sandbox
  parse_args export-client reality-main
  python3 - "$STATE_FILE" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('fixture', sys.argv[2] + '/test_data.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
s = m.deployment(); s['options']['PUBLIC_IP'] = ''; s['clients'][0]['name'] = 'reality-main'
open(sys.argv[1], 'w').write(json.dumps(s))
PY
  cp "$STATE_FILE" "$SANDBOX/original-state"
  detect_public_ip() { printf '8.8.8.8\n'; }
}

@test "export works after installation with a blank public address without modifying deployment" {
  run export_client_mode
  [ "$status" -eq 0 ]
  grep -F '@8.8.8.8:443?' "$CLIENT_DIR/"*.uri.txt
  cmp "$STATE_FILE" "$SANDBOX/original-state"
  [ ! -d "$JOURNAL/pending" ]
  [ ! -f "$SANDBOX/systemctl.log" ]
}

@test "export accepts an explicit server address without network discovery or restart" {
  parse_args export-client reality-main --public-ip proxy.example.com
  detect_public_ip() { return 99; }
  run export_client_mode
  [ "$status" -eq 0 ]
  grep -F '@proxy.example.com:443?' "$CLIENT_DIR/"*.uri.txt
  cmp "$STATE_FILE" "$SANDBOX/original-state"
}

@test "failed address discovery gives a usable command and preserves credentials" {
  detect_public_ip() { return 1; }
  run export_client_mode
  [ "$status" -eq 2 ]
  [[ "$output" == *'--public-ip'* && "$output" == *'server public IP or hostname'* ]]
  [[ "$output" != *'failed at line'* ]]
  cmp "$STATE_FILE" "$SANDBOX/original-state"
  [ ! -d "$CLIENT_DIR" ]
}

@test "invalid explicit export address cannot create credential files" {
  parse_args export-client reality-main --public-ip 'https://example.com'
  run export_client_mode
  [ "$status" -ne 0 ]
  [ -z "$(find "$CLIENT_DIR" -type f 2>/dev/null)" ]
  cmp "$STATE_FILE" "$SANDBOX/original-state"
}

@test "saved explicit address is retained without discovery" {
  jq '.options.PUBLIC_IP="2001:db8::5"' "$STATE_FILE" >"$WORK/with-address"
  cp "$WORK/with-address" "$STATE_FILE"
  detect_public_ip() { return 99; }
  run export_client_mode
  [ "$status" -eq 0 ]
  grep -F '@[2001:db8::5]:443?' "$CLIENT_DIR/"*.uri.txt
}

@test "unknown client never reports successful export or writes credential files" {
  NAME=nonexistent
  run export_client_mode
  [ "$status" -eq 2 ]
  [[ "$output" == *'Client export failed'* && "$output" != *'Exports saved'* ]]
  [ -z "$(find "$CLIENT_DIR" -type f)" ]
}

@test "discovery prefers SSH ingress and never queries the network for a public bound address" {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../lib/config.sh"
  curl() { return 99; }
  SSH_CONNECTION='1.1.1.1 1234 8.8.8.8 22'
  run detect_public_ip ::
  [ "$status" -eq 0 ]
  [ "$output" = 8.8.8.8 ]
  run detect_public_ip 2606:4700:4700::1111
  [ "$status" -eq 0 ]
  [ "$output" = 2606:4700:4700::1111 ]
}

@test "discovery falls back to HTTPS IPv6 and rejects private addresses and HTML" {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../lib/config.sh"
  SSH_CONNECTION=''
  curl() {
    [[ $* == *'--connect-timeout 3 --max-time 5 --max-filesize 128'* ]] || return 98
    case "$1:$*" in
      -4:*) printf '10.0.0.1\n' ;;
      -6:*api.ipify*) printf '<html>error</html>\n' ;;
      *) printf '2606:4700:4700::1111\n' ;;
    esac
  }
  run detect_public_ip ::
  [ "$status" -eq 0 ]
  [ "$output" = 2606:4700:4700::1111 ]
  run detect_public_ip 0.0.0.0
  [ "$status" -eq 1 ]
}

@test "install resolves and saves an empty profile address before identity generation" {
  parse_args install --auto --non-interactive
  load_profile
  resolve_profile_public_ip
  [ "$(profile_opt PUBLIC_IP)" = 8.8.8.8 ]
  detect_public_ip() { return 99; }
  resolve_profile_public_ip
  [ "$(profile_opt PUBLIC_IP)" = 8.8.8.8 ]
}

@test "CLI public address takes precedence over profile defaults" {
  parse_args install --auto --public-ip=proxy.example.com
  load_profile
  [ "$(profile_opt PUBLIC_IP)" = proxy.example.com ]
}

@test "nested ERR traps report once while retaining the original exit code" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    source "$1/helpers.bash"; setup_sandbox; setup_traps
    MODE=export-client
    inner() { return 2; }
    middle() { local prefix; prefix=$(inner); }
    outer() { middle; }
    outer
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 2 ]
  [ "$(grep -c '^ERROR:' <<<"$output")" -eq 1 ]
}

@test "blank wizard public address produces a usable export after a mocked full install" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  export WIZARD_EXPORT_TEST=true
  run bash -c '
    printf "2\nwww.apple.com\nwww.apple.com:443\n9443\n\n\n\n\n\n\n\n\n\n" |
      script -q -e -c '\''bash "$BATS_TEST_DIRNAME/wizard-fixture.sh"'\'' /dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'VLESS link for reality-main:'* ]]
  [[ "$output" == *'vless://'*'@8.8.8.8:9443?'* ]]
  [[ "$output" == *'wizard blank public address to installed state to usable client export'* ]]
}
