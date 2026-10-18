#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-only
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
load helpers
bats_require_minimum_version 1.5.0
setup() { setup_sandbox; }

@test "welcome identifies the repository, author and CLI version" {
  run welcome_screen
  [ "$status" -eq 0 ]
  [[ "$output" == *'vless-xtls-vision-installer'* ]]
  [[ "$output" == *'Made by: braydos-h'* ]]
  [[ "$output" == *"Version: v$(installer_version)"* ]]
  run bash "$BATS_TEST_DIRNAME/../xray_reality_bootstrap.sh" --version
  [ "$output" = "xray-reality-bootstrap v$(installer_version)" ]
}

@test "numbered choices retain a non-first default on Enter" {
  local selected
  selected=$(prompt_choice 'Updates' weekly 'manual|Manual' 'weekly|Weekly' 'daily|Daily' <<<'')
  [ "$selected" = weekly ]
}

@test "choices retry invalid input and accept numbers and literal values" {
  run prompt_choice 'Firewall' none 'none|Keep' 'nftables|Manage' <<<$'$(touch unexpected)\n2'
  [ "$status" -eq 0 ]
  [[ "$output" == *'Please enter one of the listed numbers or values.'* ]]
  [[ "$output" == *nftables ]]
  local selected
  selected=$(prompt_choice 'Firewall' none 'none|Keep' 'nftables|Manage' <<<nftables)
  [ "$selected" = nftables ]
}

@test "EOF cancels menu without selecting the default" {
  run prompt_choice 'Next' install 'install|Install' 'exit|Exit' </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *'Cancelled (EOF).'* ]]
}

@test "startup menu dispatches read-only choices and exits without mutations" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  local choice expected
  for choice in 2 3 4 5 6 7; do
    case "$choice" in
      2) expected='MENU PREFLIGHT' ;;
      3) expected='{"menu":"status"}' ;;
      4) expected='MENU CLIENTS' ;;
      5) expected='MENU BACKUPS' ;;
      6) expected='Usage:' ;;
      7) expected='Goodbye.' ;;
    esac
    run bash -c '
      printf "%s\n" "$1" | script -q -e -c '\''bash "$BATS_TEST_DIRNAME/ui-fixture.sh"'\'' /dev/null
    ' _ "$choice"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Welcome to vless-xtls-vision-installer'* ]]
    [[ "$output" == *"$expected"* ]]
  done
}

@test "explicit status keeps structured output even in a terminal" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  # shellcheck disable=SC2016
  run script -q -e -c 'bash "$BATS_TEST_DIRNAME/ui-fixture.sh" status' /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"menu":"status"}'* ]]
  [[ "$output" != *'Welcome'* && "$output" != *'Choose'* ]]
}

@test "Enter at startup and setup installs the displayed defaults" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  export WIZARD_DEFAULT_TEST=true WIZARD_STARTUP_MENU=true
  run bash -c '
    printf "\n\n" | script -q -e -c '\''bash "$BATS_TEST_DIRNAME/wizard-fixture.sh"'\'' /dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'WIZARD DEFAULTS RETAINED AT PACKAGE STAGE'* ]]
}

@test "wizard cancellation stops before package installation" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR
  run bash -c '
    printf "3\n" | script -q -e -c '\''bash "$BATS_TEST_DIRNAME/wizard-fixture.sh"'\'' /dev/null
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *'Installation cancelled.'* ]]
  [[ "$output" != *'PACKAGE STAGE'* ]]
}

@test "noninteractive install keeps existing automation behavior without menus" {
  run bash "$BATS_TEST_DIRNAME/../xray_reality_bootstrap.sh" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *'Noninteractive install requires --auto'* ]]
  [[ "$output" != *'Welcome'* && "$output" != *'Choose'* ]]
}

@test "customized numbered settings survive the review and validation" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR UI_WIZARD_ONLY=true
  run bash -c '
    printf "%s\n" 2 "" "" 9443 "" 0.0.0.0 proxy.example.com "Alice laptop" 2 2 2 2 "" |
      script -q -e -c '\''bash "$BATS_TEST_DIRNAME/ui-fixture.sh"'\'' /dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'WIZARD VALIDATED SETTINGS'* ]]
  [[ "$output" == *'"LISTEN_PORT": "9443"'* ]]
  [[ "$output" == *'"LISTEN_ADDRESS": "0.0.0.0"'* ]]
  [[ "$output" == *'"PUBLIC_IP": "proxy.example.com"'* ]]
  [[ "$output" == *'"PROFILE_NAME": "Alice laptop"'* ]]
  [[ "$output" == *'"FIREWALL_STYLE": "nftables"'* ]]
  [[ "$output" == *'"XRAY_UPDATE_POLICY": "weekly"'* ]]
  [[ "$output" == *'"BLOCK_PRIVATE_OUTBOUND": "no"'* ]]
  [[ "$output" == *'"CAMOUFLAGE_ENABLED": "yes"'* ]]
}

@test "invalid settings return to editing and can be corrected" {
  export BATS_TEST_DIRNAME BATS_TEST_TMPDIR UI_WIZARD_ONLY=true
  run bash -c '
    printf "%s\n" 2 "" "" bad "" "" "" "" "" "" "" "" "" \
      "" "" "" 9443 "" "" "" "" "" "" "" "" "" |
      script -q -e -c '\''bash "$BATS_TEST_DIRNAME/ui-fixture.sh"'\'' /dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'Please correct these settings before installing:'* ]]
  [[ "$output" == *'WIZARD VALIDATED SETTINGS'* ]]
  [[ "$output" == *'"LISTEN_PORT": "9443"'* ]]
}
