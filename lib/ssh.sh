#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
wait_ssh_listeners() {
  local attempt p main_pid ready
  [[ -n $1 ]] || return 1
  for ((attempt = 0; attempt < 30; attempt++)); do
    main_pid=$(systemctl show -p MainPID --value ssh) || return 1
    if [[ $main_pid =~ ^[1-9][0-9]*$ ]]; then
      ready=true
      while read -r p; do
        [[ -n $p ]] || continue
        [[ $p =~ ^[0-9]{1,5}$ ]] || return 1
        if ! ss -H -lntp "sport = :$p" | grep "pid=$main_pid," >/dev/null; then ready=false; fi
      done <<<"$1"
      [[ $ready != true ]] || return 0
    fi
    sleep 1
  done
  return 1
}
ssh_check_port() {
  local ports=$1 current_port=${SSH_CONNECTION:-}
  current_port=${current_port##* }
  if [[ $(opt CHANGE_SSH_PORT) == yes ]]; then
    opt SSH_PORT
  elif [[ -n ${SSH_CONNECTION:-} ]] && grep -qx "$current_port" <<<"$ports"; then
    printf '%s\n' "$current_port"
  else
    head -n1 <<<"$ports"
  fi
}
harden_ssh_mode() {
  load_deployment
  if [[ -n $PROFILE_PATH ]]; then
    load_profile
    jq --slurpfile options "$PROFILE" '.options += ($options[0] | {SSH_HARDENING,SSH_PORT,CHANGE_SSH_PORT,DISABLE_PASSWORD_AUTH,HAS_SSH_KEYS})' "$DESIRED" >"$WORK/next"
    mv "$WORK/next" "$DESIRED"
  fi
  [[ $(opt SSH_HARDENING) == yes ]] || die 'Set SSH_HARDENING=yes in your profile for this separate operation.'
  require_tools sshd ss
  [[ -d /etc/ssh/sshd_config.d ]] || die 'sshd drop-ins are unavailable. Configure SSH manually.'
  grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config || die 'Primary sshd_config does not include drop-ins; configure it manually.'
  if systemctl is-active --quiet ssh.socket; then die 'SSH socket activation is active. Migrate ports manually or disable socket activation through the VPS console.'; fi
  if [[ $(opt DISABLE_PASSWORD_AUTH) == yes && $KEY_CONFIRMED != true ]]; then
    die 'Password disabling requires --key-login-confirmed after testing a fresh key login. HAS_SSH_KEYS alone is insufficient.'
  fi
  sshd -t
  sshd -T >"$WORK/ssh-before"
  local ports new_port p
  ports=$(awk '$1=="port" {print $2}' "$WORK/ssh-before")
  [[ -n $ports ]] || die 'Cannot determine effective SSH ports.'
  new_port=$(ssh_check_port "$ports")
  if [[ $(opt CHANGE_SSH_PORT) != yes ]]; then
    jq --arg port "$new_port" '.options.SSH_PORT=$port' "$DESIRED" >"$WORK/next"
    mv "$WORK/next" "$DESIRED"
  fi
  begin_transaction
  arm_rollback
  touch "$JOURNAL/pending/ssh-not-reloaded" "$JOURNAL/pending/ssh-changed"
  {
    printf '# Managed by xray-reality-bootstrap v2; original ports retained\n'
    while read -r p; do printf 'Port %s\n' "$p"; done <<<"$ports"
    if [[ $(opt CHANGE_SSH_PORT) == yes ]] && ! grep -qx "$new_port" <<<"$ports"; then printf 'Port %s\n' "$new_port"; fi
    printf 'PubkeyAuthentication yes\n'
    if [[ $(opt DISABLE_PASSWORD_AUTH) == yes ]]; then
      printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
    fi
  } >"$WORK/ssh-dropin"
  atomic_managed_file "$WORK/ssh-dropin" "$SSH_DROPIN" 600
  sshd -t
  local remote local_address local_port
  read -r remote _ local_address local_port <<<"${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
  sshd -T -C "user=${SUDO_USER:-root},addr=$remote,host=$remote,laddr=$local_address,lport=$new_port" >"$WORK/ssh-after"
  grep -qx 'pubkeyauthentication yes' "$WORK/ssh-after" || die 'Administrator precedence prevents requested PubkeyAuthentication; rolling back.'
  if [[ $(opt DISABLE_PASSWORD_AUTH) == yes ]]; then
    grep -qx 'passwordauthentication no' "$WORK/ssh-after" || die 'PasswordAuthentication did not take effect; rolling back.'
    grep -qx 'kbdinteractiveauthentication no' "$WORK/ssh-after" || die 'KbdInteractiveAuthentication did not take effect; rolling back.'
  fi
  if [[ $(opt CHANGE_SSH_PORT) == yes ]]; then
    grep -qx "port $new_port" "$WORK/ssh-after" || die 'New SSH port did not take effect.'
    log 'Open the new SSH port in your existing host/cloud firewall before proceeding. Original SSH ports remain enabled.'
  fi
  rm -f -- "$JOURNAL/pending/ssh-not-reloaded"
  systemctl reload ssh
  configure_fail2ban
  local expected_ports=$ports
  if [[ $(opt CHANGE_SSH_PORT) == yes ]]; then
    expected_ports+=$'\n'"$new_port"
  fi
  wait_ssh_listeners "$expected_ports" || die 'Required SSH listeners did not become ready; rolling back.'
  # SSH settings are not proxy settings: persist requested posture only after SSH confirmation.
  install -m 600 "$DESIRED" "$JOURNAL/pending/ssh-state.json"
  if [[ $(opt CHANGE_SSH_PORT) == yes ]]; then
    printf '%s\n' "$new_port" >"$JOURNAL/pending/ssh-port"
  else
    printf '%s\n' "$ports" >"$JOURNAL/pending/ssh-port"
  fi
  [[ $(opt DISABLE_PASSWORD_AUTH) != yes ]] || touch "$JOURNAL/pending/key-confirmation-required"
  log 'SSH change is pending for 180 seconds. Test a fresh login, then run confirm-host --key-login-confirmed if using keys.'
  TX_ACTIVE=false
}
confirm_host_mode() {
  [[ -d $JOURNAL/pending && -f $JOURNAL/pending/armed ]] || die 'No pending host transition.'
  [[ -n ${SSH_CONNECTION:-} ]] || die 'Confirm from a fresh SSH session after external connectivity testing.'
  [[ ! -f $JOURNAL/pending/origin-ssh || ${SSH_CONNECTION:-} != "$(cat "$JOURNAL/pending/origin-ssh")" ]] || die 'Use a fresh SSH session, not the session that applied the change.'
  if [[ -f $JOURNAL/pending/ssh-changed ]]; then
    grep -qx "${SSH_CONNECTION##* }" "$JOURNAL/pending/ssh-port" || die 'Confirmation must come from the requested SSH port.'
    if [[ -f $JOURNAL/pending/key-confirmation-required && $KEY_CONFIRMED != true ]]; then die 'Confirm the fresh login used a key with --key-login-confirmed.'; fi
  fi
  TX_ACTIVE=true
  if [[ -f $JOURNAL/pending/ssh-changed ]]; then
    if [[ -f $JOURNAL/pending/ssh-state.json ]]; then
      load_deployment
      cp "$JOURNAL/pending/ssh-state.json" "$DESIRED"
      reuse_candidate
      stage_generation
      point_current "$GENERATION"
      if [[ -f $JOURNAL/pending/was-active ]]; then
        systemctl reset-failed xray
        systemctl restart xray
      fi
    fi
  fi
  if [[ -f $JOURNAL/pending/was-active ]]; then service_health || die 'Xray health failed; restoring the previous deployment.'; fi
  commit_transaction
}
restore_ssh_mode() {
  load_deployment
  [[ -f $SSH_DROPIN ]] || die 'No installer SSH drop-in to remove.'
  grep -q 'Managed by xray-reality-bootstrap v2' "$SSH_DROPIN" || die 'Drop-in is not installer-owned.'
  begin_transaction
  arm_rollback
  touch "$JOURNAL/pending/ssh-not-reloaded" "$JOURNAL/pending/ssh-changed"
  rm -f -- "$SSH_DROPIN"
  sshd -t
  sshd -T >"$WORK/ssh-restored"
  awk '$1=="port" {print $2}' "$WORK/ssh-restored" >"$JOURNAL/pending/ssh-port"
  rm -f -- "$JOURNAL/pending/ssh-not-reloaded"
  systemctl reload ssh
  configure_fail2ban
  jq --arg port "$(head -n1 "$JOURNAL/pending/ssh-port")" '.options.SSH_HARDENING="no" | .options.CHANGE_SSH_PORT="no" | .options.DISABLE_PASSWORD_AUTH="no" | .options.SSH_PORT=$port' "$DESIRED" >"$JOURNAL/pending/ssh-state.json"
  wait_ssh_listeners "$(cat "$JOURNAL/pending/ssh-port")" || die 'Restored SSH listeners did not become ready.'
  log 'Administrator SSH settings restored provisionally. Confirm from a fresh session on a restored port within 180 seconds.'
  TX_ACTIVE=false
}
