#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
installer_version() { printf '2.0.0'; }

welcome_screen() {
  cat >&2 <<EOF

============================================================
  Welcome to vless-xtls-vision-installer
  VLESS + REALITY + XTLS Vision
  Version: v$(installer_version)
  Made by: braydos-h
============================================================

EOF
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

startup_menu() {
  MODE=$(prompt_choice 'What would you like to do?' install \
    'install|Install / configure Xray' \
    'preflight|Check this server (preflight)' \
    'status|View deployment status' \
    'list-clients|List clients' \
    'list-backups|List backups' \
    'help|Show all commands' \
    'exit|Exit')
  case "$MODE" in
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
  local key value
  printf '\nInstallation settings\n' >&2
  for key in SERVER_NAME DEST_ENDPOINT LISTEN_PORT FALLBACK_PORT LISTEN_ADDRESS PUBLIC_IP PROFILE_NAME FIREWALL_STYLE XRAY_UPDATE_POLICY BLOCK_PRIVATE_OUTBOUND CAMOUFLAGE_ENABLED SSH_HARDENING FAIL2BAN_ENABLED UNATTENDED_UPGRADES_ENABLED OS_PRIVATE_OUTBOUND; do
    value=$(profile_opt "$key")
    if [[ -z $value ]]; then
      if [[ $key == PUBLIC_IP ]]; then value='auto-detect'; else value='disabled'; fi
    fi
    printf '  %-30s %s\n' "$key" "$value" >&2
  done
  printf '\nEnter keeps the displayed default. Ctrl+C cancels.\n' >&2
}

wizard_customize() {
  local key label value
  printf '\nCustomize settings\nUse - to clear an optional port or server address.\n' >&2
  for key in SERVER_NAME DEST_ENDPOINT LISTEN_PORT FALLBACK_PORT LISTEN_ADDRESS PUBLIC_IP PROFILE_NAME FIREWALL_STYLE XRAY_UPDATE_POLICY BLOCK_PRIVATE_OUTBOUND CAMOUFLAGE_ENABLED; do
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
          SERVER_NAME) label='REALITY server name (SNI)' ;;
          DEST_ENDPOINT) label='REALITY destination (host:port)' ;;
          LISTEN_PORT) label='Xray listen port' ;;
          FALLBACK_PORT) label='Optional alternate listen port (blank disables)' ;;
          LISTEN_ADDRESS) label='Listen address (:: for IPv4/IPv6, 0.0.0.0 for IPv4)' ;;
          PUBLIC_IP) label='Server IP or hostname for clients (blank auto-detects)' ;;
          PROFILE_NAME) label='First client name' ;;
        esac
        value=$(prompt_value "$label" "$value")
        case "$key" in FALLBACK_PORT | PUBLIC_IP) [[ $value != - ]] || value='' ;; esac
        ;;
    esac
    set_profile "$key" "$value"
  done
}
