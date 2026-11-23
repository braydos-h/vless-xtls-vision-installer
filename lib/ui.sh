#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
installer_version() { printf '2.1.0'; }

welcome_screen() {
  cat >&2 <<EOF

============================================================
  Welcome to vless-xtls-vision-installer
  VLESS + REALITY + XTLS Vision
  Version: v$(installer_version)
  Made by: braydos-h
============================================================

  Quick install: choose 1, pick a camouflage site, press Enter.
  Camouflage presets are numbered 1-8 (1 = Cloudflare, the default).
  Every prompt shows a default; press Enter to accept it.
EOF
  if [[ ${EUID:-1} != 0 ]]; then
    printf '\n  Note: installing or changing the server requires sudo (root).\n' >&2
  fi
  printf '\n' >&2
}

# Menus go to stderr so command substitution captures only the selected value.
# Match strings rather than evaluating user input as shell arithmetic.
prompt_choice() {
  local label=$1 default=$2 answer option value description index default_index=''
  shift 2
  local options=("$@")
  while :; do
    printf '\n%s\n' "$label" >&2
    index=0
    for option in "${options[@]}"; do
      index=$((index + 1))
      value=${option%%|*}
      description=${option#*|}
      if [[ $value == "$default" ]]; then
        default_index=$index
        printf '  %s) %s (default)\n' "$index" "$description" >&2
      else
        printf '  %s) %s\n' "$index" "$description" >&2
      fi
    done
    printf 'Choose [%s]: ' "$default_index" >&2
    read -r answer || die 'Cancelled (EOF).'
    answer=${answer:-$default_index}
    index=0
    for option in "${options[@]}"; do
      index=$((index + 1))
      value=${option%%|*}
      if [[ $answer == "$index" || $answer == "$value" ]]; then
        printf '%s' "$value"
        return 0
      fi
    done
    printf 'Please enter one of the listed numbers or values.\n' >&2
  done
}

print_presets() {
  printf 'Built-in camouflage targets (used as the REALITY destination):\n'
  data presets | jq -r '.[] | "  \(.number)) \(.label) - \(.sni) (\(.note))"'
}

# Build "id|Label - hostname" entries for the numbered wizard prompt.
reality_preset_options() {
  data presets | jq -r '.[] | "\(.id)|\(.label) - \(.sni)"'
}

reality_preset_default() {
  local current_sni current_destination id sni destination
  current_sni=$(profile_opt SERVER_NAME) || current_sni=''
  current_destination=$(profile_opt DEST_ENDPOINT) || current_destination=''
  while IFS=$'\t' read -r id sni destination; do
    if [[ $sni == "$current_sni" && $destination == "$current_destination" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(data presets | jq -r '.[] | "\(.id)\t\(.sni)\t\(.destination)"')
  printf ''
}

reality_preset_label() {
  data presets | jq -r --arg sni "$1" '[.[] | select(.sni == $sni) | .label][0] // empty'
}

# Accept either a 1-based number (as shown by the wizard) or a short id.
apply_reality_preset() {
  local selector=$1 result name destination
  workspace || return $?
  if ! result=$(data preset "$selector" 2>"$WORK/reality-preset-error"); then
    log "[FAIL] Unknown camouflage preset '$selector'. Run 'presets' to list the built-in choices."
    return 1
  fi
  name=$(printf '%s\n' "$result" | jq -r '.sni') || return 1
  destination=$(printf '%s\n' "$result" | jq -r '.destination') || return 1
  set_profile SERVER_NAME "$name" || return 1
  set_profile DEST_ENDPOINT "$destination"
}

wizard_reality_target() {
  local default choice option options=() current
  workspace || return $?
  current=$(profile_opt SERVER_NAME) || current=''
  default=$(reality_preset_default)
  if [[ -z $default ]]; then
    options+=("keep|Keep current target - $current")
    default='keep'
  fi
  while IFS= read -r option; do
    options+=("$option")
  done < <(reality_preset_options)
  options+=('custom|Custom target - type your own hostname and port')
  choice=$(prompt_choice 'Choose a camouflage website for REALITY' "$default" "${options[@]}")
  if [[ $choice == keep ]]; then
    log "Keeping the current camouflage target: $current."
  elif [[ $choice == custom ]]; then
    set_profile SERVER_NAME "$(prompt_value 'Camouflage hostname (SNI)' "$(profile_opt SERVER_NAME)")" || return 1
    set_profile DEST_ENDPOINT "$(prompt_value 'Forwarding destination host:port' "$(profile_opt DEST_ENDPOINT)")"
  else
    apply_reality_preset "$choice" || return 1
    log "Camouflage target: $(profile_opt SERVER_NAME) (unauthenticated TLS is forwarded to $(profile_opt DEST_ENDPOINT))."
  fi
}

deployment_hint() {
  local name=''
  if [[ -f $STATE_FILE ]]; then
    name=$(jq -r '.clients[0].name // empty' "$STATE_FILE" 2>/dev/null) || name=''
  fi
  if [[ -n $name ]]; then
    printf 'Existing deployment found (first client: %s).\n' "$name" >&2
  else
    printf 'No deployment found yet. Choose 1 for a guided install.\n' >&2
  fi
}

startup_menu() {
  local default_name
  deployment_hint
  MODE=$(prompt_choice 'What would you like to do?' install \
    'install|Install or reconfigure Xray' \
    'preflight|Check this server before installing' \
    'status|Show deployment status' \
    'diagnose|Run full diagnostics' \
    'show-client|Show a client VLESS link' \
    'list-clients|List clients' \
    'list-backups|List backups' \
    'update|Update Xray' \
    'help|Show all commands' \
    'exit|Exit')
  case "$MODE" in
    show-client)
      default_name='reality-main'
      if [[ -f $STATE_FILE ]]; then
        default_name=$(jq -r '.clients[0].name // empty' "$STATE_FILE" 2>/dev/null) || default_name=''
        [[ -n $default_name ]] || default_name='reality-main'
      fi
      NAME=$(prompt_value 'Client name' "$default_name")
      ;;
    help)
      usage
      exit 0
      ;;
    exit)
      printf 'Goodbye.\n' >&2
      exit 0
      ;;
  esac
}

wizard_summary() {
  local camouflage destination listen alternate address client firewall updates block nginx ssh upgrades egress port label ports
  camouflage=$(profile_opt SERVER_NAME)
  label=$(reality_preset_label "$camouflage" 2>/dev/null) || label=''
  [[ -z $label ]] || camouflage="$label ($camouflage)"
  destination=$(profile_opt DEST_ENDPOINT)
  listen=$(profile_opt LISTEN_ADDRESS)
  port=$(profile_opt LISTEN_PORT)
  alternate=$(profile_opt FALLBACK_PORT)
  ports=$port
  [[ -z $alternate ]] || ports="$port and $alternate"
  address=$(profile_opt PUBLIC_IP)
  client=$(profile_opt PROFILE_NAME)
  firewall=$(profile_opt FIREWALL_STYLE)
  updates=$(profile_opt XRAY_UPDATE_POLICY)
  block=$(profile_opt BLOCK_PRIVATE_OUTBOUND)
  nginx=$(profile_opt CAMOUFLAGE_ENABLED)
  ssh=$(profile_opt SSH_HARDENING)
  upgrades=$(profile_opt UNATTENDED_UPGRADES_ENABLED)
  egress=$(profile_opt OS_PRIVATE_OUTBOUND)
  [[ -n $address ]] || address='auto-detect'
  [[ -n $alternate ]] || alternate='disabled'
  if [[ $listen == *:* ]]; then listen="[$listen]"; fi
  case "$firewall" in
    none) firewall='none - host firewall unchanged' ;;
    nftables) firewall='nftables - installer-managed rules' ;;
    ufw) firewall='ufw - tagged rules in the active firewall' ;;
  esac
  case "$updates" in
    manual) updates='manual (recommended)' ;;
    weekly) updates='automatic weekly' ;;
    daily) updates='automatic daily' ;;
  esac
  if [[ $block == yes ]]; then block='yes - proxy traffic only'; else block='no'; fi
  if [[ $nginx == yes ]]; then nginx='yes - loopback diagnostics site'; else nginx='no'; fi
  if [[ $ssh == yes ]]; then ssh='requested (applied later by harden-ssh)'; else ssh='no'; fi
  if [[ $egress == yes ]]; then egress='yes - enforce with nftables'; else egress='no'; fi
  printf '\nInstallation settings\n' >&2
  printf '  %-24s %s\n' 'Camouflage website' "$camouflage" >&2
  printf '  %-24s %s\n' 'REALITY forward target' "$destination" >&2
  printf '  %-24s %s:%s (alternate: %s)\n' 'Xray listener' "$listen" "$port" "$alternate" >&2
  printf '  %-24s %s\n' 'Client-facing address' "$address" >&2
  printf '  %-24s %s\n' 'First client name' "$client" >&2
  printf '  %-24s %s\n' 'Host firewall' "$firewall" >&2
  printf '  %-24s %s\n' 'Xray updates' "$updates" >&2
  printf '  %-24s %s\n' 'Block private networks' "$block" >&2
  printf '  %-24s %s\n' 'Local web diagnostics' "$nginx" >&2
  printf '  %-24s %s\n' 'SSH hardening' "$ssh" >&2
  printf '  %-24s %s\n' 'Unattended OS upgrades' "$upgrades" >&2
  printf '  %-24s %s\n' 'OS-level egress filter' "$egress" >&2
  printf '\nTip: if your provider has its own firewall, allow TCP %s.\n' "$ports" >&2
  printf 'Enter keeps the displayed default. Ctrl+C cancels.\n' >&2
}

wizard_customize() {
  local key label value
  wizard_reality_target || return $?
  printf '\nCustomize settings\nPress Enter to keep a value; use - to clear an optional field.\n' >&2
  for key in LISTEN_PORT FALLBACK_PORT LISTEN_ADDRESS PUBLIC_IP PROFILE_NAME FIREWALL_STYLE XRAY_UPDATE_POLICY BLOCK_PRIVATE_OUTBOUND CAMOUFLAGE_ENABLED; do
    value=$(profile_opt "$key")
    case "$key" in
      FIREWALL_STYLE)
        value=$(prompt_choice 'Host firewall' "$value" \
          'none|Keep existing firewall settings' \
          'nftables|Add managed nftables rules (connectivity confirmation required)' \
          'ufw|Add rules to an already active UFW firewall')
        ;;
      XRAY_UPDATE_POLICY)
        value=$(prompt_choice 'Xray updates' "$value" \
          'manual|Manual updates' 'weekly|Automatic weekly updates' 'daily|Automatic daily updates')
        ;;
      BLOCK_PRIVATE_OUTBOUND)
        value=$(prompt_choice 'Block client access to private networks' "$value" \
          'yes|Yes (Xray routing rules)' 'no|No')
        ;;
      CAMOUFLAGE_ENABLED)
        value=$(prompt_choice 'Install optional loopback Nginx diagnostics' "$value" \
          'no|No' 'yes|Yes')
        ;;
      *)
        case "$key" in
          LISTEN_PORT) label='Xray listen port' ;;
          FALLBACK_PORT) label='Optional alternate listen port (blank disables)' ;;
          LISTEN_ADDRESS) label='Listen address (:: for IPv4/IPv6, 0.0.0.0 for IPv4)' ;;
          PUBLIC_IP) label='Client-facing server IP or hostname (blank auto-detects)' ;;
          PROFILE_NAME) label='First client name' ;;
        esac
        value=$(prompt_value "$label" "$value")
        case "$key" in FALLBACK_PORT | PUBLIC_IP) [[ $value != - ]] || value='' ;; esac
        ;;
    esac
    set_profile "$key" "$value"
  done
}
