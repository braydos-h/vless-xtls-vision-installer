#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Runs only against sandbox paths, with installation replaced by an assertion.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "${BATS_TEST_DIRNAME:?}/helpers.bash"
# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/preflight_helpers.bash"
setup_preflight
init_paths() { :; }
lock_operation() { :; }
install_dependencies() {
  [[ $(profile_opt SERVER_NAME) == www.apple.com ]]
  [[ $(profile_opt DEST_ENDPOINT) == www.apple.com:443 ]]
  [[ $(profile_opt LISTEN_PORT) == 9443 ]]
  printf 'WIZARD PROFILE RETAINED AT PACKAGE STAGE\n'
  exit 0
}
main install
