#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
runtime_identity() {
  [[ $1 =~ ^[1-9][0-9]*$ ]] || return 1
  python3 - "$1" "$CURRENT/xray" "$CONFIG_FILE" "$(id -u xray-bootstrap)" <<'PY'
import os, pathlib, sys
pid, executable, config, uid = sys.argv[1:]
try:
    process = pathlib.Path('/proc') / pid
    arguments = (process / 'cmdline').read_bytes().split(b'\0')[:-1]
    uids = next(line.split()[1:] for line in (process / 'status').read_text().splitlines() if line.startswith('Uid:'))
    correct = (os.path.realpath(process / 'exe') == os.path.realpath(executable)
               and arguments[1:] == [b'run', b'-config', os.fsencode(config)]
               and uids == [uid] * 4)
except (OSError, StopIteration):
    correct = False
sys.exit(0 if correct else 1)
PY
}
service_health() {
  local tries=0 p main_pid
  while ((tries < 10)); do
    if systemctl is-active --quiet xray; then
      local listening=true
      main_pid=$(systemctl show -p MainPID --value xray)
      if [[ ! $main_pid =~ ^[1-9][0-9]*$ ]] || ! runtime_identity "$main_pid"; then
        tries=$((tries + 1))
        sleep 1
        continue
      fi
      for p in "$(jq -r '.options.LISTEN_PORT' "$STATE_FILE")" "$(jq -r '.options.FALLBACK_PORT' "$STATE_FILE")"; do
        [[ -n $p ]] || continue
        if ! ss -H -lntp "sport = :$p" | grep "pid=$main_pid," >/dev/null; then listening=false; fi
      done
      if [[ $listening == true ]]; then
        sleep 1
        systemctl is-active --quiet xray && return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}
diagnose_mode() {
  load_deployment
  local active=false config_ok=false listeners=false identity_ok=false nginx_ok=true firewall_ok=true timer_ok=true
  if systemctl is-active --quiet xray; then active=true; fi
  if XRAY_LOCATION_ASSET="$CURRENT" "$CURRENT/xray" run -test -config "$CONFIG_FILE" >"$WORK/config-test.log" 2>&1; then config_ok=true; fi
  local p listening_count=0 port_count=0 main_pid
  main_pid=0
  if [[ $active == true ]]; then
    if ! main_pid=$(systemctl show -p MainPID --value xray); then main_pid=0; fi
    if runtime_identity "$main_pid"; then identity_ok=true; fi
  fi
  for p in "$(opt LISTEN_PORT)" "$(opt FALLBACK_PORT)"; do
    [[ -n $p ]] || continue
    port_count=$((port_count + 1))
    if [[ $main_pid =~ ^[1-9][0-9]*$ ]] && ss -H -lntp "sport = :$p" | grep "pid=$main_pid," >/dev/null; then listening_count=$((listening_count + 1)); fi
  done
  if ((listening_count == port_count)); then listeners=true; fi
  if [[ $(opt CAMOUFLAGE_ENABLED) == yes ]]; then
    if [[ $(curl -fsS --max-time 4 "http://127.0.0.1:$(opt CAMOUFLAGE_WEB_PORT)/healthz") != ok ]]; then nginx_ok=false; fi
  fi
  case "$(opt FIREWALL_STYLE)" in
    nftables)
      if ! nft list table inet xray_bootstrap >"$WORK/firewall-check" 2>/dev/null; then firewall_ok=false; else
        if ! grep -q 'comment "xray-reality-bootstrap managed"' "$WORK/firewall-check"; then firewall_ok=false; fi
        if [[ $(opt OS_PRIVATE_OUTBOUND) == yes ]] && ! grep -q 'skuid' "$WORK/firewall-check"; then firewall_ok=false; fi
      fi
      ;;
    ufw)
      if ! LC_ALL=C ufw status | grep '^Status: active' >/dev/null; then firewall_ok=false; fi
      ;;
  esac
  if [[ $(opt XRAY_UPDATE_POLICY) != manual ]] && ! systemctl is-active --quiet xray-update.timer; then timer_ok=false; fi
  jq -n --argjson service "$active" --argjson config "$config_ok" --argjson listeners "$listeners" --argjson identity "$identity_ok" \
    --argjson nginx "$nginx_ok" --argjson firewall "$firewall_ok" --argjson timer "$timer_ok" \
    --argjson pending "$([[ -d $JOURNAL/pending ]] && printf true || printf false)" \
    '{service:$service,configuration:$config,listeners:$listeners,runtime_identity:$identity,loopback_site:$nginx,managed_firewall:$firewall,update_timer:$timer,pending_transition:$pending,
      external_connectivity:"not tested",credentials:"redacted"}'
  [[ $active == true && $config_ok == true && $listeners == true && $identity_ok == true && $nginx_ok == true && $firewall_ok == true && $timer_ok == true ]]
}
preflight_mode() {
  local failure=false p service storage='' ipv6=true dependencies_missing=false listeners main_pid previous_style
  if ! check_platform; then failure=true; fi
  for p in bash jq python3 curl openssl flock ss timeout getent systemctl apt-get dpkg-query runuser useradd; do
    if ! command -v "$p" >/dev/null; then
      log "[FAIL] Missing dependency: $p. Install the prerequisites listed in README, then rerun preflight."
      dependencies_missing=true
    fi
  done
  if [[ $dependencies_missing == true ]]; then
    log 'Preflight FAILED. No deployment or host policy changes applied.'
    return 1
  fi
  printf '[PASS] Required dependencies\n'
  if ! storage=$(df -Pk / | awk 'NR==2{print $4}'); then storage=''; fi
  if [[ ! $storage =~ ^[0-9]+$ || $storage -lt 524288 ]]; then
    log "[FAIL] Free storage: ${storage:-unknown} KiB; at least 524288 KiB (512 MiB) required on /."
    failure=true
  else printf '[PASS] Free storage: %s KiB\n' "$storage"; fi
  ipv6_available || ipv6=false
  if ! workspace; then
    log '[FAIL] Cannot create a private temporary workspace; check TMPDIR permissions and free space.'
    return 1
  fi
  if ! load_profile >"$WORK/profile-check.log" 2>&1; then
    log "[FAIL] Invalid profile: $(cat "$WORK/profile-check.log")"
    log 'Preflight FAILED. No deployment or host policy changes applied.'
    return 1
  fi
  printf '[PASS] Valid profile\n'
  if [[ -z $(profile_opt PUBLIC_IP) ]]; then
    printf 'Client server address: automatic discovery during install/export; override with --public-ip YOUR_SERVER_IP_OR_HOSTNAME.\n'
  else printf '[PASS] Client server address: %s\n' "$(profile_opt PUBLIC_IP)"; fi
  if [[ $(profile_opt LISTEN_ADDRESS) == *:* && $ipv6 == false ]]; then
    log '[FAIL] IPv6 unavailable for the selected listener; enable IPv6 or set LISTEN_ADDRESS to 0.0.0.0.'
    failure=true
  elif [[ $ipv6 == true ]]; then printf '[PASS] IPv6 available\n'; else printf '[PASS] IPv4 listener selected; IPv6 unavailable\n'; fi
  printf 'Plan: install/update Xray deployment, dedicated service account, helper and selected managed files.\n'
  printf 'Selected policies: firewall=%s SSH=%s OS-upgrades=%s Xray-updates=%s OS-egress=%s\n' \
    "$(profile_opt FIREWALL_STYLE)" "$(profile_opt SSH_HARDENING)" "$(profile_opt UNATTENDED_UPGRADES_ENABLED)" "$(profile_opt XRAY_UPDATE_POLICY)" "$(profile_opt OS_PRIVATE_OUTBOUND)"
  printf 'Xray listeners: address=%s primary=%s alternate=%s; REALITY target=%s SNI=%s\n' \
    "$(profile_opt LISTEN_ADDRESS)" "$(profile_opt LISTEN_PORT)" "$(profile_opt FALLBACK_PORT)" "$(profile_opt DEST_ENDPOINT)" "$(profile_opt SERVER_NAME)"
  printf 'Managed runtime paths: %s/*, %s, %s, %s\n' "$DEPLOYMENTS" "$UNIT" "$BIN" "$HELPER"
  case "$(profile_opt FIREWALL_STYLE)" in
    nftables) printf 'Firewall plan: replace only inet xray_bootstrap; persist %s and %s; timed confirmation required.\n' "$NFT_FILE" "$NFT_UNIT" ;;
    ufw) printf 'Firewall plan: add tagged TCP rules for selected proxy ports; preserve administrator rules; timed confirmation required.\n' ;;
    none) printf 'Firewall plan: leave host policies unchanged; arrange provider/host port access separately.\n' ;;
  esac
  if [[ $(profile_opt SSH_HARDENING) == yes ]]; then printf 'SSH is a separate harden-ssh operation; install does not apply this request.\n'; fi
  if [[ $(profile_opt CAMOUFLAGE_ENABLED) == yes ]]; then
    printf 'Nginx plan: managed loopback site in %s. Installing nginx may also activate distribution default sites; review first.\n' "$NGINX_FILE"
  fi
  for p in "$(profile_opt LISTEN_PORT)" "$(profile_opt FALLBACK_PORT)"; do
    [[ -n $p ]] || continue
    if ! listeners=$(ss -H -lntp "sport = :$p" 2>&1); then
      log "[FAIL] Cannot inspect TCP port $p with ss: $listeners"
      failure=true
    elif [[ -n $listeners ]]; then
      main_pid=$(systemctl show -p MainPID --value xray 2>/dev/null) || main_pid=0
      if [[ -f $STATE_FILE && $main_pid =~ ^[1-9][0-9]*$ ]] && runtime_identity "$main_pid" &&
        [[ $listeners == *"pid=$main_pid,"* ]] && ! grep -v "pid=$main_pid," <<<"$listeners" | grep . >/dev/null; then
        printf '[PASS] Port %s owned by the managed Xray deployment (PID %s)\n' "$p" "$main_pid"
      else
        failure=true
        log "[FAIL] Port $p occupied by: $listeners. Stop/reconfigure the conflicting service or choose another LISTEN_PORT."
      fi
    else printf '[PASS] Port %s available\n' "$p"; fi
  done
  if [[ $(profile_opt CAMOUFLAGE_ENABLED) == yes ]] && command -v ss >/dev/null; then
    p=$(profile_opt CAMOUFLAGE_WEB_PORT)
    if ! listeners=$(ss -H -lntp "sport = :$p" 2>&1); then
      failure=true
      log "[FAIL] Cannot inspect Nginx port $p with ss: $listeners"
    elif [[ -n $listeners ]]; then
      if [[ ! -f $NGINX_FILE ]] || ! grep -q 'Managed by xray-reality-bootstrap v2' "$NGINX_FILE" || ! grep -Fq "listen 127.0.0.1:$p;" "$NGINX_FILE"; then
        failure=true
        log "[FAIL] Local Nginx diagnostics port $p occupied by: $listeners"
      fi
    fi
  fi
  for service in xray ssh ssh.socket nginx ufw nftables firewalld fail2ban; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then printf 'Existing service: %s\n' "$service"; fi
  done
  for p in "$XRAY_DIR/config.json" "$STATE_FILE" /etc/ssh/sshd_config /etc/nginx/nginx.conf /etc/nftables.conf /etc/apt/apt.conf.d/20auto-upgrades; do
    [[ ! -f $p ]] || printf 'Existing configuration: %s\n' "$p"
  done
  if [[ -f $STATE_FILE ]]; then
    previous_style=$(jq -er '.options.FIREWALL_STYLE' "$STATE_FILE") || previous_style=invalid
    if [[ $previous_style != none && $previous_style != "$(profile_opt FIREWALL_STYLE)" ]]; then
      failure=true
      log '[FAIL] Changing firewall managers requires clear-firewall and confirmation first; inspect saved state if invalid.'
    fi
  fi
  if [[ ! -f $STATE_FILE && ! -f $XRAY_DIR/bootstrap-state.env ]]; then
    if [[ -f $UNIT || -e $BIN || -L $BIN ]] || systemctl cat xray.service >/dev/null 2>&1; then
      log '[FAIL] Existing unmanaged Xray service/binary found: refusing takeover; migrate or back up the existing installation first.'
      failure=true
    fi
  fi
  if [[ $(profile_opt FIREWALL_STYLE) == nftables ]] && command -v ufw >/dev/null && LC_ALL=C ufw status | grep '^Status: active' >/dev/null; then
    failure=true
    log '[FAIL] Firewall conflict: UFW is active; select none or manage the existing firewall separately.'
  fi
  if [[ $(profile_opt FIREWALL_STYLE) != none ]] && systemctl is-active --quiet firewalld; then
    failure=true
    log '[FAIL] Firewall conflict: firewalld is active; select none and manage ports there.'
  fi
  if [[ $(profile_opt FIREWALL_STYLE) == ufw ]] && ! LC_ALL=C ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    failure=true
    log '[FAIL] UFW must already be active; activate it separately or select none.'
  fi
  if [[ $(profile_opt UNATTENDED_UPGRADES_ENABLED) == yes && -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    failure=true
    log '[FAIL] Existing apt periodic policy prevents installer opt-in; manage it separately.'
  fi
  if ! data egress-check "$PROFILE" /etc/resolv.conf >"$WORK/egress-check.log" 2>&1; then
    log "[FAIL] Outbound policy validation: $(cat "$WORK/egress-check.log")"
    failure=true
  fi
  if [[ $NETWORK_CHECK == true ]]; then
    if ! probe_reality; then failure=true; fi
  else printf 'Network/TLS reachability not tested; use --network-check.\n'; fi
  if [[ $failure == true ]]; then
    log 'Preflight FAILED. No deployment or host policy changes applied.'
    return 1
  fi
  printf 'Preflight PASSED. No deployment or host policy changes applied.\n'
  return 0
}
dry_run_mode() {
  log "Read-only plan for $MODE. No deployment, packages, SSH or firewall will be changed."
  case "$MODE" in
    install | preflight) preflight_mode ;;
    add-client | remove-client | rotate-client | rotate-shortid | finalize-shortid)
      load_deployment || return $?
      data mutate "$DESIRED" "$MODE" "$NAME" "$WINDOW" >"$WORK/proposed-state" || return $?
      data config "$WORK/proposed-state" >"$WORK/proposed-config" || return $?
      printf 'Plan: validate and activate the requested client change, restart Xray, retain recovery generation.\n'
      jq '[.clients[]|{name,credentials:"redacted"}]' "$WORK/proposed-state"
      ;;
    *)
      load_deployment || return $?
      if [[ $MODE == harden-ssh && -n $PROFILE_PATH ]]; then
        load_profile || return $?
        jq --slurpfile options "$PROFILE" '.options += ($options[0] | {SSH_HARDENING,SSH_PORT,CHANGE_SSH_PORT,DISABLE_PASSWORD_AUTH,HAS_SSH_KEYS})' "$DESIRED" >"$WORK/proposed-state"
        mv "$WORK/proposed-state" "$DESIRED"
      fi
      if [[ $MODE == restore ]]; then
        [[ $NAME =~ ^[0-9]{8}T[0-9]{6}-[a-f0-9]{12}$ && -d $BACKUPS/$NAME ]] || die 'Select an existing backup ID from list-backups.'
        printf 'Restore plan: read backup %s, validate checksums/config/binary, preserve live SSH policy, activate saved deployment and regenerate managed host options.\n' "$NAME"
      fi
      printf 'Plan for %s: operate on installer-owned deployment/files only. Credentials are retained unless explicitly rotated or revoked.\n' "$MODE"
      printf 'Selected firewall=%s, updates=%s, SSH request=%s. Backups and rollback journal protect deployment transitions.\n' \
        "$(opt FIREWALL_STYLE)" "$(opt XRAY_UPDATE_POLICY)" "$(opt SSH_HARDENING)"
      if [[ $MODE == harden-ssh ]]; then
        printf 'SSH plan: managed drop-in %s; requested port=%s change-port=%s password-disable=%s; keep original ports, validate effective settings, confirm from a fresh session.\n' \
          "$SSH_DROPIN" "$(opt SSH_PORT)" "$(opt CHANGE_SSH_PORT)" "$(opt DISABLE_PASSWORD_AUTH)"
      elif [[ $MODE == uninstall ]]; then
        printf 'Uninstall plan: stop installed Xray, remove owned runtime/unit/rules, retain deployment secrets, exports, backups and helper. SSH restoration must be confirmed first.\n'
      fi
      printf 'Service activation, downloaded binary compatibility, external connectivity and kernel policy activation are not tested in dry-run.\n'
      ;;
  esac
}
