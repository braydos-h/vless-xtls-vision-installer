#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Exercise main's interactive dispatch without touching system paths.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "${BATS_TEST_DIRNAME:?}/helpers.bash"
setup_sandbox
init_paths() { :; }
lock_operation() { [[ ${MODE:-} == show-client ]] || die 'Unexpected mutation from menu.'; }
check_platform() { die 'Unexpected platform check from menu.'; }
diagnose_mode() { printf '{"menu":"%s"}\n' "$MODE"; }
list_clients_mode() { printf 'MENU CLIENTS\n'; }
list_backups_mode() { printf 'MENU BACKUPS\n'; }
export_client_mode() { printf 'MENU SHOW %s\n' "$NAME"; }
dry_run_mode() { printf 'MENU PREFLIGHT\n'; }
if [[ ${UI_WIZARD_ONLY:-false} == true ]]; then
  parse_args install
  load_profile
  wizard
  printf 'WIZARD VALIDATED SETTINGS\n'
  cat "$PROFILE"
else
  main "$@"
fi
