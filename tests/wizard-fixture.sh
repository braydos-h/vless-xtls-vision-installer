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
  if [[ ${WIZARD_DEFAULT_TEST:-false} == true ]]; then
    [[ $(profile_opt SERVER_NAME) == www.cloudflare.com ]]
    [[ $(profile_opt DEST_ENDPOINT) == www.cloudflare.com:443 ]]
    [[ $(profile_opt LISTEN_PORT) == 443 ]]
    [[ $(profile_opt FIREWALL_STYLE) == none ]]
    [[ $(profile_opt XRAY_UPDATE_POLICY) == manual ]]
    [[ $(profile_opt BLOCK_PRIVATE_OUTBOUND) == yes ]]
    printf 'WIZARD DEFAULTS RETAINED AT PACKAGE STAGE\n'
  else
    [[ $(profile_opt SERVER_NAME) == www.apple.com ]]
    [[ $(profile_opt DEST_ENDPOINT) == www.apple.com:443 ]]
    [[ $(profile_opt LISTEN_PORT) == 9443 ]]
  fi
  [[ $(profile_opt PUBLIC_IP) == 8.8.8.8 ]]
  printf 'WIZARD PROFILE RETAINED AT PACKAGE STAGE\n'
  if [[ ${WIZARD_EXPORT_TEST:-false} != true ]]; then exit 0; fi
}
if [[ ${WIZARD_EXPORT_TEST:-false} == true ]]; then
  rm -f -- "$STATE_FILE"
  probe_reality() { :; }
  prepare_candidate() { CANDIDATE_VERSION=v26.3.27; }
  make_identity() {
    python3 - "$DESIRED" "$PROFILE" "$BATS_TEST_DIRNAME" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('fixture', sys.argv[3] + '/test_data.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
s = m.deployment(); s['options'] = json.load(open(sys.argv[2]))
s['clients'][0]['name'] = s['options']['PROFILE_NAME']
open(sys.argv[1], 'w').write(json.dumps(s))
PY
  }
  ensure_account() { :; }
  stage_generation() {
    data config "$DESIRED" >"$SANDBOX/installed-config.json"
    cp "$DESIRED" "$STATE_FILE"
  }
  persist_helper() { :; }
  activate_generation() { :; }
  configure_host_extras() { :; }
  configure_timer() { :; }
  apply_firewall() { :; }
  commit_transaction() { :; }
fi
if [[ ${WIZARD_STARTUP_MENU:-false} == true ]]; then main; else main install; fi
if [[ ${WIZARD_EXPORT_TEST:-false} == true ]]; then
  main export-client reality-main
  grep -F '@8.8.8.8:9443?' "$CLIENT_DIR/"*.uri.txt >/dev/null
  printf 'PASS: wizard blank public address to installed state to usable client export\n'
fi
