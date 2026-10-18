#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Modified from braydos-h's original installer: security and operational overhaul.
set -Eeuo pipefail
ENTRY_PATH=${BASH_SOURCE[0]}
PROJECT_DIR=$(cd -- "$(dirname -- "$ENTRY_PATH")/.." && pwd)
STANDALONE=false
# shellcheck source-path=SCRIPTDIR/../lib
for module in common config transaction xray systemd reality firewall ssh host backup clients diagnostics main; do
  # shellcheck disable=SC1090
  source "$PROJECT_DIR/lib/$module.sh"
done
data() { python3 "$PROJECT_DIR/lib/data.py" "$@" || exit $?; }
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
