#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
load_deployment() {
  workspace || return $?
  DESIRED=$WORK/state.json
  if [[ -f $STATE_FILE ]]; then
    data state "$STATE_FILE" >"$DESIRED" || return $?
  elif [[ -f $XRAY_DIR/bootstrap-state.env && -f $XRAY_DIR/config.json ]]; then
    data migrate "$XRAY_DIR/bootstrap-state.env" "$XRAY_DIR/config.json" >"$DESIRED" || return $?
    log 'Legacy deployment loaded without executing shell state. Host hardening defaults are now opt-in.'
    log 'Legacy firewall and primary SSH changes require manual review; they cannot safely be attributed or undone.'
  else
    die 'No saved deployment. Install first, or restore a backup.'
  fi
}
load_profile() {
  workspace || return $?
  PROFILE=$WORK/options.json
  local legacy=false
  if [[ ! -f $STATE_FILE && -f $XRAY_DIR/bootstrap-state.env && -f $XRAY_DIR/config.json ]]; then legacy=true; fi
  if [[ -n $PROFILE_PATH ]]; then
    if [[ $legacy == true ]]; then
      data profile-legacy "$PROFILE_PATH" "$XRAY_DIR/bootstrap-state.env" "$XRAY_DIR/config.json" >"$WORK/profile-loaded" || return $?
    elif [[ -f $STATE_FILE ]]; then
      data profile-deployed "$PROFILE_PATH" "$STATE_FILE" >"$WORK/profile-loaded" || return $?
    else data profile "$PROFILE_PATH" >"$WORK/profile-loaded" || return $?; fi
  elif [[ -f $STATE_FILE ]]; then
    jq '.options' "$STATE_FILE" >"$WORK/profile-loaded" || return $?
  elif [[ $legacy == true ]]; then
    data migrate "$XRAY_DIR/bootstrap-state.env" "$XRAY_DIR/config.json" >"$WORK/legacy-profile-state" || return $?
    jq '.options' "$WORK/legacy-profile-state" >"$WORK/profile-loaded" || return $?
  elif [[ -f $XRAY_DIR/bootstrap-options.json && ! -L $XRAY_DIR/bootstrap-options.json ]]; then
    data profile "$XRAY_DIR/bootstrap-options.json" >"$WORK/profile-loaded" || return $?
  else
    data defaults >"$WORK/profile-loaded" || return $?
  fi
  data profile "$WORK/profile-loaded" >"$WORK/profile-validated" || return $?
  mv "$WORK/profile-validated" "$WORK/profile-loaded" || return $?
  mv "$WORK/profile-loaded" "$PROFILE" || return $?
  if [[ -n $PIN ]]; then
    jq --arg pin "$PIN" '.XRAY_PIN=$pin' "$PROFILE" >"$WORK/profile-next" || return $?
    data profile "$WORK/profile-next" >"$PROFILE" || return $?
  fi
  if [[ ${ALLOW_PRERELEASE_CLI:-false} == true ]]; then
    set_profile ALLOW_PRERELEASE yes || return $?
  fi
  if [[ -n $SID_COUNT ]]; then
    jq --arg count "$SID_COUNT" '.SHORT_ID_COUNT=$count' "$PROFILE" >"$WORK/profile-next" || return $?
    data profile "$WORK/profile-next" >"$PROFILE" || return $?
  fi
  if [[ -n ${PUBLIC_IP_CLI:-} ]]; then
    set_profile PUBLIC_IP "$PUBLIC_IP_CLI" || return $?
    data profile "$PROFILE" >"$WORK/profile-validated" || return $?
    mv "$WORK/profile-validated" "$PROFILE" || return $?
  fi
}

detect_public_ip() {
  local listen=$1 response address family url ssh_client ssh_client_port ssh_server ssh_server_port
  local families=(4 6)
  # Prefer a specifically bound public address, then the ingress address of SSH.
  if address=$(data public-ip "$listen" 2>/dev/null); then
    printf '%s\n' "$address"
    return 0
  fi
  if [[ $listen != *:* ]]; then families=(4); elif [[ $listen != :: ]]; then families=(6); fi
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r ssh_client ssh_client_port ssh_server ssh_server_port <<<"$SSH_CONNECTION"
    if address=$(data public-ip "$ssh_server" 2>/dev/null); then
      if [[ $listen == :: || ($listen == *:* && $address == *:*) || ($listen != *:* && $address != *:*) ]]; then
        printf '%s\n' "$address"
        return 0
      fi
    fi
  fi
  command -v curl >/dev/null || return 1
  for family in "${families[@]}"; do
    for url in https://api.ipify.org https://icanhazip.com; do
      # Bypass proxies: their egress address would produce unusable client links.
      if response=$(curl "-$family" --proto '=https' --noproxy '*' -fsS --connect-timeout 3 --max-time 5 --max-filesize 128 "$url" 2>/dev/null) &&
        address=$(data public-ip "$response" 2>/dev/null); then
        printf '%s\n' "$address"
        return 0
      fi
    done
  done
  return 1
}
resolve_profile_public_ip() {
  local address
  [[ -z $(profile_opt PUBLIC_IP) ]] || return 0
  if address=$(detect_public_ip "$(profile_opt LISTEN_ADDRESS)"); then
    set_profile PUBLIC_IP "$address" || return $?
    log "Client server address detected: $address. Use --public-ip to override it (required for custom NAT/port-forwarding)."
  else
    log '[FAIL] Cannot determine the server public IP or hostname for client exports. Rerun install with --public-ip YOUR_SERVER_IP_OR_HOSTNAME; no deployment was activated.'
    return 2
  fi
}

set_profile() {
  jq --arg key "$1" --arg value "$2" '.[$key]=$value' "$PROFILE" >"$WORK/profile-next" || return $?
  mv "$WORK/profile-next" "$PROFILE"
}
prompt_value() {
  local answer
  read -r -p "$1 [$2]: " answer || die 'Installation cancelled (EOF).'
  printf '%s' "${answer:-$2}"
}
wizard() {
  [[ -t 0 && $NON_INTERACTIVE == false ]] || die 'Use install --auto --non-interactive with a profile on noninteractive hosts.'
  local action default=continue
  while :; do
    wizard_summary
    action=$(prompt_choice 'Next step' "$default" \
      'continue|Install with the settings above' 'edit|Customize settings' 'cancel|Cancel')
    case "$action" in
      continue)
        if data profile "$PROFILE" >"$WORK/validated" 2>"$WORK/wizard-errors"; then
          mv "$WORK/validated" "$PROFILE"
          return 0
        fi
        log 'Please correct these settings before installing:'
        cat "$WORK/wizard-errors" >&2
        default=edit
        ;;
      edit)
        wizard_customize
        default='continue'
        ;;
      cancel) die 'Installation cancelled.' ;;
    esac
  done
}
make_identity() {
  local key_output private public count
  key_output=$("$CANDIDATE/xray" x25519)
  private=$(printf '%s\n' "$key_output" | sed -nE 's/^Private[Kk]ey: *([A-Za-z0-9_-]{43})$/\1/p')
  public=$(printf '%s\n' "$key_output" | sed -nE 's/^(Public[Kk]ey|Password( \(PublicKey\))?): *([A-Za-z0-9_-]{43})$/\3/p')
  [[ -n $private && -n $public ]] || die 'Unrecognized x25519 output; candidate release unsupported.'
  count=$(profile_opt SHORT_ID_COUNT)
  python3 - "$count" >"$WORK/shortids" <<'PY'
import json, secrets, sys
print(json.dumps([secrets.token_hex(8) for _ in range(int(sys.argv[1]))]))
PY
  # Secrets travel through protected files, not command-line jq arguments.
  printf '%s' "$private" >"$WORK/private"
  printf '%s' "$public" >"$WORK/public"
  cat /proc/sys/kernel/random/uuid >"$WORK/uuid"
  jq -n --slurpfile options "$PROFILE" --slurpfile ids "$WORK/shortids" \
    --rawfile private "$WORK/private" --rawfile public "$WORK/public" --rawfile id "$WORK/uuid" \
    --arg version "$CANDIDATE_VERSION" '{format:2, options:$options[0], identity:{private_key:$private,public_key:$public},
      clients:[{name:$options[0].PROFILE_NAME,id:($id|rtrimstr("\n")),short_id:$ids[0][0]}],short_ids:$ids[0],rotation:null,xray_version:$version}' >"$DESIRED"
}
validate_keypair() {
  local public expected
  # Read the private key through a root-only PKCS#8 file, never through argv.
  data key-der "$DESIRED" "$WORK/private.der"
  openssl pkey -inform DER -in "$WORK/private.der" -pubout -outform DER -out "$WORK/public.der"
  public=$(data public-key "$WORK/public.der")
  expected=$(jq -r '.identity.public_key' "$DESIRED")
  [[ -n $public && $public == "$expected" ]] || die 'REALITY public/private key mismatch.'
}

stage_generation() {
  data state "$DESIRED" >"$WORK/validated-state"
  mv "$WORK/validated-state" "$DESIRED"
  validate_keypair
  GENERATION=$(new_id)
  STAGE=$DEPLOYMENTS/$GENERATION
  install -d -m 750 -g xray-bootstrap "$XRAY_DIR" "$DEPLOYMENTS" "$STAGE"
  install -m 755 "$CANDIDATE/xray" "$STAGE/xray"
  local asset
  for asset in geoip.dat geosite.dat; do
    if [[ -f $CANDIDATE/$asset ]]; then install -m 644 "$CANDIDATE/$asset" "$STAGE/$asset"; fi
  done
  install -m 600 "$DESIRED" "$STAGE/state.json"
  data config "$DESIRED" >"$WORK/config.json"
  install -m 640 -g xray-bootstrap "$WORK/config.json" "$STAGE/config.json"
  jq '.options' "$DESIRED" >"$STAGE/options.json"
  chmod 600 "$STAGE/options.json"
  validate_xray "$STAGE/xray" "$STAGE/config.json" "$STAGE"
  # Last check runs as the service identity, catching permissions and asset failures.
  if ! runuser -u xray-bootstrap -- env XRAY_LOCATION_ASSET="$STAGE" "$STAGE/xray" run -test -config "$STAGE/config.json" >"$WORK/config-test.log" 2>&1; then
    die 'Xray service account cannot validate staged config. Check generation directory permissions privately.'
  fi
  sync -f "$STAGE"
}
