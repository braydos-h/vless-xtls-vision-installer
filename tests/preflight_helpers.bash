#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# shellcheck disable=SC2154,SC2030,SC2031,SC2317,SC2329
setup_preflight() {
  setup_sandbox
  rm -f "$BIN" "$UNIT"
  parse_args preflight
  OS_FIXTURE=ubuntu:26.04
  sed() {
    if [[ ${*: -1} == /etc/os-release ]]; then
      case "$2" in
        *VERSION_ID*) printf '%s\n' "${OS_FIXTURE#*:}" ;;
        *PRETTY_NAME*) printf '%s\n' "$OS_FIXTURE" ;;
        *) printf '%s\n' "${OS_FIXTURE%:*}" ;;
      esac
    else command sed "$@"; fi
  }
  uname() { printf 'x86_64\n'; }
  cat() {
    if [[ $1 == /proc/1/comm ]]; then printf 'systemd\n'; else command cat "$@"; fi
  }
  df() { printf 'Filesystem blocks used available\nmock 20000000 1000000 19000000\n'; }
  systemctl() { return 1; }
  ss() { :; }
  id() {
    if [[ $1 == -u ]]; then printf '0\n'; else command id "$@"; fi
  }
  # These commands are checked, never executed by read-only preflight.
  apt-get() { return 99; }
  dpkg-query() { return 99; }
  runuser() { return 99; }
  useradd() { return 99; }
}
