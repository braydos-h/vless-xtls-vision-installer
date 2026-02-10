#!/usr/bin/env bash
# xray_reality_bootstrap.sh
# Production-oriented bootstrap/install/update tool for Xray VLESS+REALITY+XTLS Vision.

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
STATE_FILE="/etc/xray/bootstrap-state.env"
XRAY_DIR="/etc/xray"
XRAY_CONFIG_FILE="/etc/xray/config.json"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SHARE_DIR="/usr/local/share/xray"
LOG_DIR="/var/log/xray"
CLIENT_DIR="/root/xray-client-configs"
SELF_INSTALLED_PATH="/usr/local/sbin/xray-reality-bootstrap"
CAMOUFLAGE_SITE_DIR="/var/www/xray-camouflage"
CAMOUFLAGE_NGINX_CONF="/etc/nginx/conf.d/xray-camouflage.conf"

# Colors
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_RED='\033[31m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_BLUE='\033[34m'
else
  C_RESET=''
  C_BOLD=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
fi

MODE="install"
NON_INTERACTIVE=false
SHORT_ID_COUNT_CLI=""

# Runtime settings/state (loaded from file or wizard)
OS_ID=""
OS_VERSION_ID=""
XRAY_ASSET=""
XRAY_VERSION=""
SERVER_NAME=""
DEST_ENDPOINT=""
LISTEN_PORT="443"
FALLBACK_PORT=""
FIREWALL_STYLE="nftables"
SSH_PORT="22"
CHANGE_SSH_PORT="no"
HAS_SSH_KEYS="yes"
DISABLE_PASSWORD_AUTH="yes"
FAIL2BAN_ENABLED="yes"
UNATTENDED_UPGRADES_ENABLED="yes"
XRAY_UPDATE_POLICY="weekly"
LOG_PROFILE="minimal"
PROFILE_NAME="reality-main"
SHORT_ID_LABEL="main"
SHORT_ID_COUNT="3"
BLOCK_PRIVATE_OUTBOUND="yes"
HTTP_CONNECT_TIMEOUT="30"
HTTP_MAX_TIME="180"
HTTP_RETRIES="5"
HTTP_RETRY_DELAY="3"
XRAY_HANDSHAKE_TIMEOUT_SEC="12"
XRAY_CONN_IDLE_TIMEOUT_SEC="600"
XRAY_UPLINK_ONLY_TIMEOUT_SEC="4"
XRAY_DOWNLINK_ONLY_TIMEOUT_SEC="10"
UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_SHORT_IDS=""
PUBLIC_IP=""
CAMOUFLAGE_WEB_PORT="18080"
REPRINT_CMD="sudo ${SELF_INSTALLED_PATH} reprint"

log_info() { printf "%b[INFO]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; }
log_warn() { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
log_error() { printf "%b[ERROR]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
log_ok() { printf "%b[OK]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
section() { printf "\n%b==>%b %s\n" "$C_BOLD$C_BLUE" "$C_RESET" "$*"; }

die() {
  log_error "$*"
  exit 1
}

on_error() {
  local code=$?
  local line=${1:-unknown}
  log_error "Command failed at line ${line}: ${BASH_COMMAND} (exit ${code})"
  log_error "Actionable checks: journalctl -u xray -xe, ${XRAY_BIN} -test -config ${XRAY_CONFIG_FILE}, systemctl status xray"
  exit "$code"
}

trap 'on_error $LINENO' ERR
trap 'log_warn "Interrupted"; exit 130' INT TERM

usage() {
  cat <<EOF
Usage: $0 [install|update|repair|status|diagnose|reprint|rotate-shortid|uninstall] [--non-interactive] [--shortid-count N]

Modes:
  install    Interactive wizard install/reconfigure (default)
  update     Update Xray binary safely (preserves keys/config)
  repair     Re-apply current state and hardening
  status     Show service, listening ports, and firewall summary
  diagnose   Unified diagnostics: config test, status, ports, firewall, recent errors
  reprint    Reprint saved client configs without regenerating secrets
  rotate-shortid  Rotate REALITY shortIds only (preserve UUID/keypair)
  uninstall  Remove Xray service/config with confirmation
EOF
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0 ..."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

safe_mkdir() {
  local dir="$1"
  local mode="$2"
  install -d -m "$mode" "$dir"
  chown root:root "$dir"
}

urlencode() {
  local s="$1"
  local out=""
  local c
  local i
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'${c}" ;;
    esac
  done
  printf '%s' "$out"
}

trim() {
  local x="$*"
  x="${x#"${x%%[![:space:]]*}"}"
  x="${x%"${x##*[![:space:]]}"}"
  printf '%s' "$x"
}

extract_uuid_from_text() {
  local text="$1"
  printf '%s\n' "$text" | awk '
    match($0, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) {
      print tolower(substr($0, RSTART, RLENGTH))
      exit
    }
  '
}

extract_reality_key_from_text() {
  local label="$1"
  local text="$2"
  printf '%s\n' "$text" | awk -v key_label="$label" '
    BEGIN {
      wanted = tolower(key_label)
    }
    {
      line = $0
      lowered = tolower(line)
      if (index(lowered, wanted) > 0 && match(line, /[A-Za-z0-9+\/=_-]{32,}/)) {
        print substr(line, RSTART, RLENGTH)
        exit
      }
    }
  '
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

validate_short_id_count() {
  local count="$1"
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  (( count >= 1 && count <= 16 ))
}

validate_short_id_value() {
  local sid="$1"
  [[ "$sid" =~ ^[0-9a-fA-F]{1,16}$ ]]
}

short_ids_count_from_csv() {
  local csv="$1"
  local count=0
  local token
  local -a _tokens=()
  IFS=',' read -r -a _tokens <<<"$csv"
  for token in "${_tokens[@]}"; do
    token="$(trim "$token")"
    [[ -z "$token" ]] && continue
    ((count++))
  done
  printf '%s' "$count"
}

normalize_short_ids_csv() {
  local csv="$1"
  local -a out=()
  local -a _tokens=()
  local token normalized
  local -A seen=()
  IFS=',' read -r -a _tokens <<<"$csv"
  for token in "${_tokens[@]}"; do
    token="$(trim "$token")"
    [[ -z "$token" ]] && continue
    normalized="${token,,}"
    validate_short_id_value "$normalized" || die "Invalid REALITY shortId in state/config: ${token}"
    if [[ -z "${seen[$normalized]+x}" ]]; then
      out+=("$normalized")
      seen["$normalized"]=1
    fi
  done
  if (( ${#out[@]} == 0 )); then
    printf '%s' ""
    return 1
  fi

  local joined
  local IFS=,
  joined="${out[*]}"
  printf '%s' "$joined"
}

primary_short_id_from_csv() {
  local csv="$1"
  local first="${csv%%,*}"
  first="$(trim "$first")"
  printf '%s' "${first,,}"
}

short_ids_csv_to_json_array() {
  local csv="$1"
  local -a _tokens=()
  local token normalized
  local first_item=true
  local out="["

  IFS=',' read -r -a _tokens <<<"$csv"
  for token in "${_tokens[@]}"; do
    token="$(trim "$token")"
    [[ -z "$token" ]] && continue
    normalized="${token,,}"
    if [[ "$first_item" == true ]]; then
      first_item=false
    else
      out+=", "
    fi
    out+="\"${normalized}\""
  done

  out+="]"
  printf '%s' "$out"
}

generate_short_ids_csv() {
  local count="$1"
  local -a generated=()
  local sid
  local -A seen=()
  while (( ${#generated[@]} < count )); do
    sid="$(openssl rand -hex 8 | awk 'NR==1{print tolower($1)}')"
    [[ -n "$sid" ]] || continue
    if [[ -z "${seen[$sid]+x}" ]]; then
      generated+=("$sid")
      seen["$sid"]=1
    fi
  done

  local joined
  local IFS=,
  joined="${generated[*]}"
  printf '%s' "$joined"
}

normalize_short_id_state() {
  if [[ -z "${REALITY_SHORT_IDS:-}" && -n "${REALITY_SHORT_ID:-}" ]]; then
    REALITY_SHORT_IDS="$REALITY_SHORT_ID"
  fi

  if [[ -n "${REALITY_SHORT_IDS:-}" ]]; then
    REALITY_SHORT_IDS="$(normalize_short_ids_csv "$REALITY_SHORT_IDS")"
    REALITY_SHORT_ID="$(primary_short_id_from_csv "$REALITY_SHORT_IDS")"
    if ! validate_short_id_count "${SHORT_ID_COUNT:-}"; then
      SHORT_ID_COUNT="$(short_ids_count_from_csv "$REALITY_SHORT_IDS")"
    fi
  else
    REALITY_SHORT_ID=""
  fi

  if ! validate_short_id_count "${SHORT_ID_COUNT:-}"; then
    SHORT_ID_COUNT="3"
  fi
}

validate_hostport() {
  local hp="$1"
  [[ "$hp" == *:* ]] || return 1
  local host="${hp%:*}"
  local port="${hp##*:}"
  [[ -n "$host" ]] || return 1
  validate_port "$port"
}

is_ipv4_literal() {
  local host="$1"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local octet
  IFS='.' read -r -a octets <<<"$host"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command_exists timeout; then
    timeout "${seconds}s" "$@"
  else
    "$@"
  fi
}

validate_reality_dest_connectivity() {
  section "REALITY destination probe"

  local host="${DEST_ENDPOINT%:*}"
  local port="${DEST_ENDPOINT##*:}"

  if is_ipv4_literal "$host"; then
    log_warn "DEST endpoint is pinned to IP (${host}). CDN IPs rotate; prefer ${SERVER_NAME}:${port} to avoid timeout regressions."
  fi

  if ! run_with_timeout 8 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$host" "$port" 2>/dev/null; then
    die "Cannot reach DEST endpoint ${DEST_ENDPOINT} from this server. This causes client timeouts."
  fi

  if command_exists openssl; then
    if ! run_with_timeout 12 openssl s_client -connect "$DEST_ENDPOINT" -servername "$SERVER_NAME" -brief </dev/null >/dev/null 2>&1; then
      die "TLS probe failed for DEST ${DEST_ENDPOINT} with SNI ${SERVER_NAME}. Choose a different serverName/DEST pair."
    fi
  fi

  log_ok "REALITY destination is reachable and TLS-capable (${DEST_ENDPOINT} with SNI ${SERVER_NAME})"
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local answer=""
  local default_hint="[y/N]"
  [[ "$default" == "yes" ]] && default_hint="[Y/n]"

  while true; do
    if ! is_tty; then
      [[ "$default" == "yes" ]] && return 0 || return 1
    fi
    read -r -p "${prompt} ${default_hint}: " answer
    answer="$(trim "$answer")"
    if [[ -z "$answer" ]]; then
      [[ "$default" == "yes" ]] && return 0 || return 1
    fi
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) log_warn "Please answer yes or no." ;;
    esac
  done
}

prompt_input() {
  local prompt="$1"
  local default="$2"
  local result=""

  if ! is_tty; then
    printf '%s' "$default"
    return 0
  fi

  read -r -p "${prompt} [default: ${default}]: " result
  result="$(trim "$result")"
  if [[ -z "$result" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$result"
  fi
}

save_state() {
  safe_mkdir "$XRAY_DIR" 700
  umask 077
  {
    printf "# xray bootstrap state\n"
    printf "SCRIPT_VERSION=%q\n" "$SCRIPT_VERSION"
    printf "OS_ID=%q\n" "$OS_ID"
    printf "OS_VERSION_ID=%q\n" "$OS_VERSION_ID"
    printf "XRAY_ASSET=%q\n" "$XRAY_ASSET"
    printf "XRAY_VERSION=%q\n" "$XRAY_VERSION"
    printf "SERVER_NAME=%q\n" "$SERVER_NAME"
    printf "DEST_ENDPOINT=%q\n" "$DEST_ENDPOINT"
    printf "LISTEN_PORT=%q\n" "$LISTEN_PORT"
    printf "FALLBACK_PORT=%q\n" "$FALLBACK_PORT"
    printf "FIREWALL_STYLE=%q\n" "$FIREWALL_STYLE"
    printf "SSH_PORT=%q\n" "$SSH_PORT"
    printf "CHANGE_SSH_PORT=%q\n" "$CHANGE_SSH_PORT"
    printf "HAS_SSH_KEYS=%q\n" "$HAS_SSH_KEYS"
    printf "DISABLE_PASSWORD_AUTH=%q\n" "$DISABLE_PASSWORD_AUTH"
    printf "FAIL2BAN_ENABLED=%q\n" "$FAIL2BAN_ENABLED"
    printf "UNATTENDED_UPGRADES_ENABLED=%q\n" "$UNATTENDED_UPGRADES_ENABLED"
    printf "XRAY_UPDATE_POLICY=%q\n" "$XRAY_UPDATE_POLICY"
    printf "LOG_PROFILE=%q\n" "$LOG_PROFILE"
    printf "PROFILE_NAME=%q\n" "$PROFILE_NAME"
    printf "SHORT_ID_LABEL=%q\n" "$SHORT_ID_LABEL"
    printf "SHORT_ID_COUNT=%q\n" "$SHORT_ID_COUNT"
    printf "BLOCK_PRIVATE_OUTBOUND=%q\n" "$BLOCK_PRIVATE_OUTBOUND"
    printf "HTTP_CONNECT_TIMEOUT=%q\n" "$HTTP_CONNECT_TIMEOUT"
    printf "HTTP_MAX_TIME=%q\n" "$HTTP_MAX_TIME"
    printf "HTTP_RETRIES=%q\n" "$HTTP_RETRIES"
    printf "HTTP_RETRY_DELAY=%q\n" "$HTTP_RETRY_DELAY"
    printf "XRAY_HANDSHAKE_TIMEOUT_SEC=%q\n" "$XRAY_HANDSHAKE_TIMEOUT_SEC"
    printf "XRAY_CONN_IDLE_TIMEOUT_SEC=%q\n" "$XRAY_CONN_IDLE_TIMEOUT_SEC"
    printf "XRAY_UPLINK_ONLY_TIMEOUT_SEC=%q\n" "$XRAY_UPLINK_ONLY_TIMEOUT_SEC"
    printf "XRAY_DOWNLINK_ONLY_TIMEOUT_SEC=%q\n" "$XRAY_DOWNLINK_ONLY_TIMEOUT_SEC"
    printf "UUID=%q\n" "$UUID"
    printf "REALITY_PRIVATE_KEY=%q\n" "$REALITY_PRIVATE_KEY"
    printf "REALITY_PUBLIC_KEY=%q\n" "$REALITY_PUBLIC_KEY"
    printf "REALITY_SHORT_ID=%q\n" "$REALITY_SHORT_ID"
    printf "REALITY_SHORT_IDS=%q\n" "$REALITY_SHORT_IDS"
    printf "CAMOUFLAGE_WEB_PORT=%q\n" "$CAMOUFLAGE_WEB_PORT"
    printf "PUBLIC_IP=%q\n" "$PUBLIC_IP"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    if [[ -n "$SHORT_ID_COUNT_CLI" ]]; then
      SHORT_ID_COUNT="$SHORT_ID_COUNT_CLI"
    fi
    normalize_short_id_state
    return 0
  fi
  return 1
}

detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"

  case "$OS_ID" in
    debian)
      [[ "$OS_VERSION_ID" == "12" ]] || die "Unsupported Debian version: ${OS_VERSION_ID}. Require Debian 12."
      ;;
    ubuntu)
      [[ "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ]] || die "Unsupported Ubuntu version: ${OS_VERSION_ID}. Require 22.04 or 24.04."
      ;;
    *)
      die "Unsupported OS: ${OS_ID}. Supported: Debian 12, Ubuntu 22.04/24.04."
      ;;
  esac
}

apt_install() {
  local pkgs=("$@")
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

ensure_qrencode() {
  if command_exists qrencode; then
    return 0
  fi

  if ! command_exists apt-get; then
    return 1
  fi

  log_info "Installing qrencode for QR output"
  if DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 &&
     DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1; then
    return 0
  fi

  log_warn "Could not install qrencode automatically; continuing without QR output"
  return 1
}

install_dependencies() {
  section "Installing dependencies"
  local pkgs=(ca-certificates curl wget openssl unzip iproute2 nginx qrencode)

  case "$FIREWALL_STYLE" in
    nftables) pkgs+=(nftables) ;;
    ufw) pkgs+=(ufw) ;;
    *) die "Invalid firewall style: $FIREWALL_STYLE" ;;
  esac

  [[ "$FAIL2BAN_ENABLED" == "yes" ]] && pkgs+=(fail2ban)
  [[ "$UNATTENDED_UPGRADES_ENABLED" == "yes" ]] && pkgs+=(unattended-upgrades)

  apt_install "${pkgs[@]}"
}

write_camouflage_site_content() {
  safe_mkdir "$CAMOUFLAGE_SITE_DIR" 755
  cat >"${CAMOUFLAGE_SITE_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Service Gateway</title>
  <style>
    :root { color-scheme: light; }
    body {
      margin: 0;
      font-family: "Segoe UI", Arial, sans-serif;
      background: #f4f6f9;
      color: #16202a;
    }
    .wrap {
      max-width: 760px;
      margin: 8vh auto;
      background: #ffffff;
      border: 1px solid #d7dee6;
      border-radius: 10px;
      padding: 28px;
      box-shadow: 0 8px 20px rgba(0, 0, 0, 0.06);
    }
    h1 { margin-top: 0; font-size: 1.6rem; letter-spacing: 0.01em; }
    p { line-height: 1.55; }
    .muted { color: #566474; font-size: 0.95rem; }
  </style>
</head>
<body>
  <main class="wrap">
    <h1>Gateway Edge</h1>
    <p>Service edge is online and accepting secure traffic.</p>
    <p class="muted">If you reached this page directly, no additional action is required.</p>
  </main>
</body>
</html>
EOF
  chmod 644 "${CAMOUFLAGE_SITE_DIR}/index.html"
}

configure_camouflage_web_server() {
  section "Configuring fallback camouflage web server"

  validate_port "$CAMOUFLAGE_WEB_PORT" || die "Invalid camouflage web port: ${CAMOUFLAGE_WEB_PORT}"
  if [[ "$CAMOUFLAGE_WEB_PORT" == "$LISTEN_PORT" || ( -n "$FALLBACK_PORT" && "$CAMOUFLAGE_WEB_PORT" == "$FALLBACK_PORT" ) ]]; then
    die "Camouflage web port must differ from Xray primary/fallback listen ports"
  fi

  write_camouflage_site_content
  safe_mkdir "/etc/nginx/conf.d" 755

  cat >"$CAMOUFLAGE_NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:${CAMOUFLAGE_WEB_PORT};
    listen [::1]:${CAMOUFLAGE_WEB_PORT};
    server_name ${SERVER_NAME} _;

    root ${CAMOUFLAGE_SITE_DIR};
    index index.html;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location = /healthz {
        default_type text/plain;
        return 200 "ok\n";
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
  chmod 644 "$CAMOUFLAGE_NGINX_CONF"

  nginx -t
  systemctl enable --now nginx
  systemctl restart nginx

  if ! curl -fsS --connect-timeout 3 --max-time 5 "http://127.0.0.1:${CAMOUFLAGE_WEB_PORT}/healthz" >/dev/null; then
    die "Camouflage web server health check failed on 127.0.0.1:${CAMOUFLAGE_WEB_PORT}"
  fi

  log_ok "Camouflage web server ready on 127.0.0.1:${CAMOUFLAGE_WEB_PORT}"
}

get_arch_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
    armv7l) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
    *) die "Unsupported architecture: ${arch}" ;;
  esac
}

download_to_file() {
  local url="$1"
  local output="$2"
  if command_exists curl; then
    curl -fsSL \
      --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
      --max-time "$HTTP_MAX_TIME" \
      --retry "$HTTP_RETRIES" \
      --retry-delay "$HTTP_RETRY_DELAY" \
      --retry-all-errors \
      "$url" -o "$output"
  else
    wget --quiet --tries="$HTTP_RETRIES" --timeout="$HTTP_CONNECT_TIMEOUT" -O "$output" "$url"
  fi
}

extract_asset_digest_from_release_json() {
  local json_file="$1"
  local asset_name="$2"

  awk -v asset="$asset_name" '
    {
      line = $0
      gsub("\r", "", line)
      count = split(line, parts, ",")
      for (i = 1; i <= count; i++) {
        token = parts[i]
        sub(/^[[:space:]]+/, "", token)

        if (token ~ /"name"[[:space:]]*:[[:space:]]*"/) {
          name = token
          sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", name)
          sub(/".*/, "", name)
          matched_asset = (name == asset)
          continue
        }

        if (matched_asset && token ~ /"digest"[[:space:]]*:[[:space:]]*"sha256:[A-Fa-f0-9]{64}"/) {
          digest = token
          sub(/.*"sha256:/, "", digest)
          sub(/".*/, "", digest)
          print tolower(digest)
          exit
        }
      }
    }
  ' "$json_file"
}

install_or_update_xray_binary() {
  section "Installing/Updating Xray-core"
  get_arch_asset

  local tmpdir
  tmpdir="$(mktemp -d)"
  local release_json="$tmpdir/release.json"
  local zip_file="$tmpdir/xray.zip"
  local dgst_file="$tmpdir/xray.dgst"
  local sha_file="$tmpdir/sha256sum.txt"

  download_to_file "https://api.github.com/repos/XTLS/Xray-core/releases/latest" "$release_json"

  local tag
  tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_json" | head -n1)"
  [[ -n "$tag" ]] || die "Could not parse latest Xray release tag"

  local urls
  urls="$(grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' "$release_json" | cut -d'"' -f4)"

  local zip_url dgst_url checksum_url
  zip_url="$(printf '%s\n' "$urls" | grep "/${XRAY_ASSET}$" | head -n1 || true)"
  dgst_url="$(printf '%s\n' "$urls" | grep "/${XRAY_ASSET}\.dgst$" | head -n1 || true)"
  checksum_url="$(printf '%s\n' "$urls" | grep -E '/(sha256sum|sha256sums|checksums?|checksum)(\.(txt|sha256))?$' | head -n1 || true)"

  [[ -n "$zip_url" ]] || die "Could not find release asset URL for ${XRAY_ASSET}"

  download_to_file "$zip_url" "$zip_file"

  local expected_sha=""
  expected_sha="$(extract_asset_digest_from_release_json "$release_json" "$XRAY_ASSET" || true)"

  if [[ -z "$expected_sha" && -n "$dgst_url" ]]; then
    download_to_file "$dgst_url" "$dgst_file"
    expected_sha="$(awk -v a="$XRAY_ASSET" '
      {
        gsub("\r", "", $0)
        if (index($0, a) && match($0, /[A-Fa-f0-9]{64}/)) {
          print tolower(substr($0, RSTART, RLENGTH));
          exit
        }
      }
    ' "$dgst_file")"
  fi

  if [[ -z "$expected_sha" && -n "$checksum_url" ]]; then
    download_to_file "$checksum_url" "$sha_file"
    expected_sha="$(awk -v a="$XRAY_ASSET" '
      {
        gsub("\r", "", $0)
        if (index($0, a) && match($0, /[A-Fa-f0-9]{64}/)) {
          print tolower(substr($0, RSTART, RLENGTH));
          exit
        }
      }
    ' "$sha_file")"
  fi

  [[ -n "$expected_sha" ]] || die "Checksum verification data not found for ${XRAY_ASSET}; refusing install"

  local calculated_sha
  calculated_sha="$(sha256sum "$zip_file" | awk '{print tolower($1)}')"
  [[ "$calculated_sha" == "$expected_sha" ]] || die "Checksum mismatch for ${XRAY_ASSET}"

  unzip -oq "$zip_file" -d "$tmpdir/unpack"
  [[ -f "$tmpdir/unpack/xray" ]] || die "xray binary missing in release archive"

  install -m 755 "$tmpdir/unpack/xray" "$XRAY_BIN"
  safe_mkdir "$XRAY_SHARE_DIR" 755
  [[ -f "$tmpdir/unpack/geoip.dat" ]] && install -m 644 "$tmpdir/unpack/geoip.dat" "$XRAY_SHARE_DIR/geoip.dat"
  [[ -f "$tmpdir/unpack/geosite.dat" ]] && install -m 644 "$tmpdir/unpack/geosite.dat" "$XRAY_SHARE_DIR/geosite.dat"

  XRAY_VERSION="$tag"
  rm -rf "$tmpdir"
  log_ok "Xray ${XRAY_VERSION} installed/updated"
}

persist_self_for_reuse() {
  local src=""
  src="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ -f "$src" && -r "$src" ]]; then
    install -m 700 "$src" "$SELF_INSTALLED_PATH" || true
  fi

  if [[ -x "$SELF_INSTALLED_PATH" ]]; then
    REPRINT_CMD="sudo ${SELF_INSTALLED_PATH} reprint"
  else
    REPRINT_CMD="sudo bash $0 reprint"
  fi
}

ensure_identity_materials() {
  section "Generating or reusing REALITY identity materials"

  normalize_short_id_state

  if [[ -z "$UUID" ]]; then
    local uuid_output
    uuid_output="$($XRAY_BIN uuid 2>&1)"
    UUID="$(extract_uuid_from_text "$uuid_output")"
  fi

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    local keypair
    keypair="$($XRAY_BIN x25519 2>&1)"
    REALITY_PRIVATE_KEY="$(extract_reality_key_from_text "private" "$keypair")"
    REALITY_PUBLIC_KEY="$(extract_reality_key_from_text "public" "$keypair")"

    local key_candidates=()
    mapfile -t key_candidates < <(
      printf '%s\n' "$keypair" | awk '
        match($0, /[A-Za-z0-9+\/=_-]{32,}/) {
          print substr($0, RSTART, RLENGTH)
        }
      '
    )
    if [[ -z "$REALITY_PRIVATE_KEY" && ${#key_candidates[@]} -ge 1 ]]; then
      REALITY_PRIVATE_KEY="${key_candidates[0]}"
    fi
    if [[ -z "$REALITY_PUBLIC_KEY" && ${#key_candidates[@]} -ge 2 ]]; then
      REALITY_PUBLIC_KEY="${key_candidates[1]}"
    fi
  fi

  [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9+/_=-]{32,}$ ]] || REALITY_PRIVATE_KEY=""
  [[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9+/_=-]{32,}$ ]] || REALITY_PUBLIC_KEY=""

  if [[ -z "$REALITY_SHORT_IDS" ]]; then
    REALITY_SHORT_IDS="$(generate_short_ids_csv "$SHORT_ID_COUNT")"
  fi
  REALITY_SHORT_ID="$(primary_short_id_from_csv "$REALITY_SHORT_IDS")"

  [[ -n "$UUID" && -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" && -n "$REALITY_SHORT_IDS" ]] || die "Failed generating identity materials"
  local short_id_count_actual
  short_id_count_actual="$(short_ids_count_from_csv "$REALITY_SHORT_IDS")"
  log_ok "Identity materials ready (UUID + REALITY keypair + ${short_id_count_actual} shortId(s))"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local conf="/etc/ssh/sshd_config"

  if grep -qiE "^[#[:space:]]*${key}[[:space:]]+" "$conf"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$conf"
  else
    printf '%s %s\n' "$key" "$value" >>"$conf"
  fi
}

harden_ssh() {
  section "Applying SSH hardening"
  local ssh_service=""
  local candidate
  for candidate in ssh sshd; do
    if systemctl list-unit-files --type=service --no-legend "${candidate}.service" 2>/dev/null | awk '{print $1}' | grep -qx "${candidate}.service"; then
      ssh_service="$candidate"
      break
    fi
  done
  if [[ -z "$ssh_service" ]]; then
    for candidate in ssh sshd; do
      if systemctl cat "${candidate}.service" >/dev/null 2>&1; then
        ssh_service="$candidate"
        break
      fi
    done
  fi
  [[ -n "$ssh_service" ]] || die "Neither ssh.service nor sshd.service found. Install/enable OpenSSH server first."

  local conf="/etc/ssh/sshd_config"
  [[ -f "$conf" ]] || die "sshd_config not found"

  if [[ ! -f /etc/ssh/sshd_config.pre-xray-bootstrap.bak ]]; then
    cp -a "$conf" /etc/ssh/sshd_config.pre-xray-bootstrap.bak
  fi

  set_sshd_option "Port" "$SSH_PORT"
  set_sshd_option "PubkeyAuthentication" "yes"

  if [[ "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "KbdInteractiveAuthentication" "no"
    set_sshd_option "ChallengeResponseAuthentication" "no"
    set_sshd_option "PermitRootLogin" "prohibit-password"
  else
    set_sshd_option "PasswordAuthentication" "yes"
    set_sshd_option "KbdInteractiveAuthentication" "yes"
  fi

  sshd -t -f "$conf"
  systemctl restart "$ssh_service"
  log_ok "SSH hardening applied via ${ssh_service}.service (port ${SSH_PORT}, password auth ${DISABLE_PASSWORD_AUTH})"
}

configure_fail2ban() {
  if [[ "$FAIL2BAN_ENABLED" != "yes" ]]; then
    systemctl disable --now fail2ban >/dev/null 2>&1 || true
    return
  fi

  section "Configuring fail2ban"
  safe_mkdir "/etc/fail2ban/jail.d" 755
  cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  chmod 644 /etc/fail2ban/jail.d/sshd.local
  systemctl enable --now fail2ban
  log_ok "fail2ban enabled"
}

configure_unattended_upgrades() {
  section "Configuring unattended-upgrades"

  if [[ "$UNATTENDED_UPGRADES_ENABLED" == "yes" ]]; then
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    chmod 644 /etc/apt/apt.conf.d/20auto-upgrades
    log_ok "Unattended OS security upgrades enabled"
  else
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    chmod 644 /etc/apt/apt.conf.d/20auto-upgrades
    log_warn "Unattended upgrades disabled"
  fi
}

render_nft_rules() {
  local fallback_rule=""
  if [[ -n "$FALLBACK_PORT" ]]; then
    fallback_rule="    tcp dport ${FALLBACK_PORT} accept"
  fi

  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept
    ct state established,related accept

    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept

    tcp dport ${SSH_PORT} accept
    tcp dport ${LISTEN_PORT} accept
${fallback_rule}
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF
  chmod 600 /etc/nftables.conf
}

apply_firewall_nftables() {
  section "Configuring nftables firewall"
  systemctl disable --now ufw >/dev/null 2>&1 || true
  render_nft_rules
  systemctl enable --now nftables
  nft -f /etc/nftables.conf
  log_ok "nftables active: SSH ${SSH_PORT}, Xray ${LISTEN_PORT}${FALLBACK_PORT:+,${FALLBACK_PORT}}"
}

apply_firewall_ufw() {
  section "Configuring UFW firewall"
  systemctl disable --now nftables >/dev/null 2>&1 || true

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw allow "${LISTEN_PORT}/tcp" comment 'Xray primary'
  [[ -n "$FALLBACK_PORT" ]] && ufw allow "${FALLBACK_PORT}/tcp" comment 'Xray fallback'
  ufw --force enable

  log_ok "UFW active: SSH ${SSH_PORT}, Xray ${LISTEN_PORT}${FALLBACK_PORT:+,${FALLBACK_PORT}}"
}

apply_firewall() {
  case "$FIREWALL_STYLE" in
    nftables) apply_firewall_nftables ;;
    ufw) apply_firewall_ufw ;;
    *) die "Unknown firewall style: $FIREWALL_STYLE" ;;
  esac
}

write_xray_config() {
  section "Writing Xray config"

  safe_mkdir "$XRAY_DIR" 700
  safe_mkdir "$LOG_DIR" 700

  local access_log="none"
  local error_log="$LOG_DIR/error.log"
  local log_level="warning"
  if [[ "$LOG_PROFILE" == "verbose" ]]; then
    access_log="$LOG_DIR/access.log"
    log_level="info"
    touch "$LOG_DIR/access.log"
    chmod 600 "$LOG_DIR/access.log"
  fi
  touch "$error_log"
  chmod 600 "$error_log"

  local outbounds_json routing_json
  if [[ "$BLOCK_PRIVATE_OUTBOUND" == "yes" ]]; then
    outbounds_json='[
    {"tag":"direct","protocol":"freedom"},
    {"tag":"blocked","protocol":"blackhole"}
  ]'
    routing_json='{
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private", "geoip:reserved"],
        "outboundTag": "blocked"
      }
    ]
  }'
  else
    outbounds_json='[
    {"tag":"direct","protocol":"freedom"}
  ]'
    routing_json='{
    "domainStrategy": "AsIs",
    "rules": []
  }'
  fi

  local client_email
  client_email="$(echo "$PROFILE_NAME" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//;s/-$//')@xray"
  normalize_short_id_state
  [[ -n "$REALITY_SHORT_IDS" ]] || die "REALITY shortIds are missing; run install/repair or rotate-shortid"
  validate_port "$CAMOUFLAGE_WEB_PORT" || die "Invalid camouflage web port: ${CAMOUFLAGE_WEB_PORT}"
  local reality_short_ids_json
  reality_short_ids_json="$(short_ids_csv_to_json_array "$REALITY_SHORT_IDS")"

  local primary_fallbacks_json
  primary_fallbacks_json=$(cat <<EOF
        "fallbacks": [
          {
            "name": "${SERVER_NAME}",
            "dest": ${CAMOUFLAGE_WEB_PORT},
            "xver": 0
          },
          {
            "dest": ${CAMOUFLAGE_WEB_PORT},
            "xver": 0
          }
        ]
EOF
)

  local fallback_inbound=""
  if [[ -n "$FALLBACK_PORT" ]]; then
    fallback_inbound=$(cat <<EOF
,
    {
      "tag": "vless-reality-fallback",
      "listen": "0.0.0.0",
      "port": ${FALLBACK_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "${client_email}-fb"
          }
        ],
${primary_fallbacks_json}
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_ENDPOINT}",
          "xver": 0,
          "serverNames": ["${SERVER_NAME}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ${reality_short_ids_json}
        }
      },
      "sniffing": {
        "enabled": false
      }
    }
EOF
)
  fi

  cat >"$XRAY_CONFIG_FILE" <<EOF
{
  "log": {
    "access": "${access_log}",
    "error": "${error_log}",
    "loglevel": "${log_level}"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": ${XRAY_HANDSHAKE_TIMEOUT_SEC},
        "connIdle": ${XRAY_CONN_IDLE_TIMEOUT_SEC},
        "uplinkOnly": ${XRAY_UPLINK_ONLY_TIMEOUT_SEC},
        "downlinkOnly": ${XRAY_DOWNLINK_ONLY_TIMEOUT_SEC}
      }
    }
  },
  "inbounds": [
    {
      "tag": "vless-reality-primary",
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "${client_email}"
          }
        ],
${primary_fallbacks_json}
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_ENDPOINT}",
          "xver": 0,
          "serverNames": ["${SERVER_NAME}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ${reality_short_ids_json}
        }
      },
      "sniffing": {
        "enabled": false
      }
    }${fallback_inbound}
  ],
  "outbounds": ${outbounds_json},
  "routing": ${routing_json}
}
EOF

  chmod 600 "$XRAY_CONFIG_FILE"
  chown root:root "$XRAY_CONFIG_FILE"

  "$XRAY_BIN" -test -config "$XRAY_CONFIG_FILE" >/dev/null
  log_ok "Xray config validated"
}

write_systemd_unit() {
  section "Writing systemd service"

  cat >"$XRAY_SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service (VLESS REALITY XTLS Vision)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576

# Hardening
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=${LOG_DIR} /run
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$XRAY_SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1
  if systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray
  else
    systemctl start xray
  fi
  sleep 1
  systemctl --no-pager --full status xray >/dev/null
  log_ok "xray.service enabled and reloaded (restart/start applied)"
}

configure_xray_update_timer() {
  section "Configuring Xray update policy"

  if [[ "$XRAY_UPDATE_POLICY" == "manual" ]]; then
    systemctl disable --now xray-update.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray-update.timer /etc/systemd/system/xray-update.service
    systemctl daemon-reload
    log_info "Xray updates set to manual"
    return
  fi

  persist_self_for_reuse
  if [[ ! -x "$SELF_INSTALLED_PATH" ]]; then
    log_warn "Could not install helper command at ${SELF_INSTALLED_PATH}; falling back to manual updates"
    XRAY_UPDATE_POLICY="manual"
    return
  fi

  local calendar_expr
  if [[ "$XRAY_UPDATE_POLICY" == "daily" ]]; then
    calendar_expr="daily"
  else
    calendar_expr="weekly"
  fi

  cat >/etc/systemd/system/xray-update.service <<EOF
[Unit]
Description=Update Xray-core binary (preserve config)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SELF_INSTALLED_PATH} update --non-interactive
User=root
Group=root
EOF

  cat >/etc/systemd/system/xray-update.timer <<EOF
[Unit]
Description=Scheduled Xray-core update

[Timer]
OnCalendar=${calendar_expr}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 644 /etc/systemd/system/xray-update.service /etc/systemd/system/xray-update.timer
  systemctl daemon-reload
  systemctl enable --now xray-update.timer
  log_ok "Xray update timer enabled (${XRAY_UPDATE_POLICY})"
}

detect_public_ip() {
  local ip=""
  if command_exists curl; then
    ip="$(curl -4fsSL --max-time 8 https://api.ipify.org || true)"
    [[ -z "$ip" ]] && ip="$(curl -4fsSL --max-time 8 https://ifconfig.me || true)"
  elif command_exists wget; then
    ip="$(wget -qO- https://api.ipify.org || true)"
  fi

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"
  else
    printf '%s' ""
  fi
}

build_vless_uri() {
  local host="$1"
  local port="$2"
  local profile_fragment
  profile_fragment="$(urlencode "$PROFILE_NAME")"

  normalize_short_id_state

  local sni fp pbk sid
  sni="$(urlencode "$SERVER_NAME")"
  fp="chrome"
  pbk="$(urlencode "$REALITY_PUBLIC_KEY")"
  sid="$(urlencode "$REALITY_SHORT_ID")"

  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&spx=%%2F&type=tcp#%s' \
    "$UUID" "$host" "$port" "$sni" "$fp" "$pbk" "$sid" "$profile_fragment"
}

generate_client_artifacts() {
  section "Generating client artifacts"

  safe_mkdir "$CLIENT_DIR" 700
  chmod 700 "$CLIENT_DIR"
  normalize_short_id_state

  local primary_short_id short_ids_display
  primary_short_id="$REALITY_SHORT_ID"
  short_ids_display="${REALITY_SHORT_IDS//,/, }"

  local server_host
  PUBLIC_IP="$(detect_public_ip)"
  server_host="${PUBLIC_IP:-<SERVER_PUBLIC_IP>}"

  local profile_safe
  profile_safe="$(echo "$PROFILE_NAME" | tr -cs 'A-Za-z0-9._-' '_')"
  profile_safe="${profile_safe#_}"
  profile_safe="${profile_safe%_}"
  [[ -z "$profile_safe" ]] && profile_safe="reality"

  local uri_primary uri_fallback
  uri_primary="$(build_vless_uri "$server_host" "$LISTEN_PORT")"
  [[ -n "$FALLBACK_PORT" ]] && uri_fallback="$(build_vless_uri "$server_host" "$FALLBACK_PORT")"

  local v2rayn_json="$CLIENT_DIR/${profile_safe}-v2rayn-primary.json"
  local v2rayng_json="$CLIENT_DIR/${profile_safe}-v2rayng-primary.json"
  local sing_primary_json="$CLIENT_DIR/${profile_safe}-sing-box-primary.json"
  local apple_style_json="$CLIENT_DIR/${profile_safe}-shadowrocket-streisand-singbox-primary.json"
  local uri_primary_file="$CLIENT_DIR/${profile_safe}-primary.uri.txt"
  local uri_fallback_file="$CLIENT_DIR/${profile_safe}-fallback.uri.txt"
  local shortids_file="$CLIENT_DIR/${profile_safe}-shortids.txt"
  local summary_file="$CLIENT_DIR/${profile_safe}-summary.txt"
  local qr_primary_utf8_file="$CLIENT_DIR/${profile_safe}-primary.uri.qr.txt"
  local qr_primary_png_file="$CLIENT_DIR/${profile_safe}-primary.uri.qr.png"
  local qr_fallback_utf8_file="$CLIENT_DIR/${profile_safe}-fallback.uri.qr.txt"
  local qr_fallback_png_file="$CLIENT_DIR/${profile_safe}-fallback.uri.qr.png"

  cat >"$uri_primary_file" <<EOF
${uri_primary}
EOF
  chmod 600 "$uri_primary_file"

  if [[ -n "$uri_fallback" ]]; then
    cat >"$uri_fallback_file" <<EOF
${uri_fallback}
EOF
    chmod 600 "$uri_fallback_file"
  else
    rm -f "$uri_fallback_file"
  fi

  printf '%s\n' "$REALITY_SHORT_IDS" | tr ',' '\n' >"$shortids_file"
  chmod 600 "$shortids_file"

  cat >"$v2rayn_json" <<EOF
{
  "remarks": "${PROFILE_NAME}-primary",
  "log": {
    "loglevel": "warning"
  },
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${server_host}",
            "port": ${LISTEN_PORT},
            "users": [
              {
                "id": "${UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SERVER_NAME}",
          "fingerprint": "chrome",
          "publicKey": "${REALITY_PUBLIC_KEY}",
          "shortId": "${primary_short_id}",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF
  cp "$v2rayn_json" "$v2rayng_json"
  chmod 600 "$v2rayn_json" "$v2rayng_json"

  cat >"$sing_primary_json" <<EOF
{
  "type": "vless",
  "tag": "${PROFILE_NAME}-primary",
  "server": "${server_host}",
  "server_port": ${LISTEN_PORT},
  "uuid": "${UUID}",
  "flow": "xtls-rprx-vision",
  "packet_encoding": "xudp",
  "tls": {
    "enabled": true,
    "server_name": "${SERVER_NAME}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${REALITY_PUBLIC_KEY}",
      "short_id": "${primary_short_id}"
    }
  }
}
EOF
  cp "$sing_primary_json" "$apple_style_json"
  chmod 600 "$sing_primary_json" "$apple_style_json"

  local qr_primary_block=""
  local qr_fallback_block=""
  local qr_status_msg="install 'qrencode' to render QR output."
  if ensure_qrencode; then
    qr_primary_block="$(printf '%s' "$uri_primary" | qrencode -t ANSIUTF8 2>/dev/null || true)"
    if printf '%s' "$uri_primary" | qrencode -t UTF8 >"$qr_primary_utf8_file" 2>/dev/null; then
      chmod 600 "$qr_primary_utf8_file"
    else
      rm -f "$qr_primary_utf8_file"
    fi
    if printf '%s' "$uri_primary" | qrencode -t PNG -o "$qr_primary_png_file" 2>/dev/null; then
      chmod 600 "$qr_primary_png_file"
    else
      rm -f "$qr_primary_png_file"
    fi

    if [[ -n "$uri_fallback" ]]; then
      qr_fallback_block="$(printf '%s' "$uri_fallback" | qrencode -t ANSIUTF8 2>/dev/null || true)"
      if printf '%s' "$uri_fallback" | qrencode -t UTF8 >"$qr_fallback_utf8_file" 2>/dev/null; then
        chmod 600 "$qr_fallback_utf8_file"
      else
        rm -f "$qr_fallback_utf8_file"
      fi
      if printf '%s' "$uri_fallback" | qrencode -t PNG -o "$qr_fallback_png_file" 2>/dev/null; then
        chmod 600 "$qr_fallback_png_file"
      else
        rm -f "$qr_fallback_png_file"
      fi
    else
      rm -f "$qr_fallback_utf8_file" "$qr_fallback_png_file"
    fi
  else
    rm -f "$qr_primary_utf8_file" "$qr_primary_png_file" "$qr_fallback_utf8_file" "$qr_fallback_png_file"
  fi

  local qr_primary_utf8_display="<not generated>"
  local qr_primary_png_display="<not generated>"
  local qr_fallback_utf8_display="<not configured>"
  local qr_fallback_png_display="<not configured>"

  [[ -f "$qr_primary_utf8_file" ]] && qr_primary_utf8_display="$qr_primary_utf8_file"
  [[ -f "$qr_primary_png_file" ]] && qr_primary_png_display="$qr_primary_png_file"

  if [[ -n "$uri_fallback" ]]; then
    qr_fallback_utf8_display="<not generated>"
    qr_fallback_png_display="<not generated>"
    [[ -f "$qr_fallback_utf8_file" ]] && qr_fallback_utf8_display="$qr_fallback_utf8_file"
    [[ -f "$qr_fallback_png_file" ]] && qr_fallback_png_display="$qr_fallback_png_file"
  fi

  cat >"$summary_file" <<EOF
Server public IP: ${server_host}
REALITY shortIds (server accepts all): ${short_ids_display}
Primary shortId used in exported client JSON/URI: ${primary_short_id}
Primary URI:
${uri_primary}

Fallback URI:
${uri_fallback:-<not configured>}

Primary QR (UTF8 text):
${qr_primary_utf8_display}

Primary QR (PNG):
${qr_primary_png_display}

Fallback QR (UTF8 text):
${qr_fallback_utf8_display}

Fallback QR (PNG):
${qr_fallback_png_display}

v2rayN/v2rayNG JSON:
${v2rayn_json}
${v2rayng_json}

All accepted shortIds:
${shortids_file}

sing-box JSON:
${sing_primary_json}

Shadowrocket/Streisand/sing-box style JSON:
${apple_style_json}

Reprint command:
${REPRINT_CMD}
EOF
  chmod 600 "$summary_file"

  printf '%s\n' "$uri_primary" >"$CLIENT_DIR/.last_primary_uri"
  chmod 600 "$CLIENT_DIR/.last_primary_uri"

  section "Client Handoff (Final Output)"
  printf "============================================================\n"
  printf "Profile: %s\n" "$PROFILE_NAME"
  printf "Server public IP: %s\n" "${server_host}"
  printf "Primary port: %s\n" "$LISTEN_PORT"
  printf "Fallback port: %s\n" "${FALLBACK_PORT:-none}"
  printf "REALITY serverName: %s\n" "$SERVER_NAME"
  printf "REALITY dest: %s\n" "$DEST_ENDPOINT"
  printf "Primary-port fallback camouflage: %s -> 127.0.0.1:%s\n" "$LISTEN_PORT" "$CAMOUFLAGE_WEB_PORT"

  printf "\nPrimary VLESS URI:\n%s\n" "$uri_primary"
  if [[ -n "$uri_fallback" ]]; then
    printf "\nFallback VLESS URI:\n%s\n" "$uri_fallback"
  fi

  printf "\nREALITY shortIds accepted by server: %s\n" "$short_ids_display"
  printf "Primary shortId exported in client configs: %s\n" "$primary_short_id"

  printf "\n[JSON] v2rayN / v2rayNG (same payload)\n"
  cat "$v2rayn_json"

  printf "\n[JSON] sing-box (also reused for Shadowrocket/Streisand style)\n"
  cat "$sing_primary_json"

  if [[ -n "$qr_primary_block" ]]; then
    printf "\nASCII QR (primary URI):\n%s\n" "$qr_primary_block"
    if [[ -n "$uri_fallback" && -n "$qr_fallback_block" ]]; then
      printf "\nASCII QR (fallback URI):\n%s\n" "$qr_fallback_block"
    fi
  else
    printf "\nQR note: %s\n" "${qr_status_msg}"
  fi

  printf "\nClient artifact files:\n"
  printf "  - Summary: %s\n" "$summary_file"
  printf "  - Primary URI: %s\n" "$uri_primary_file"
  if [[ -n "$uri_fallback" ]]; then
    printf "  - Fallback URI: %s\n" "$uri_fallback_file"
  else
    printf "  - Fallback URI: <not configured>\n"
  fi
  printf "  - v2rayN JSON: %s\n" "$v2rayn_json"
  printf "  - v2rayNG JSON: %s\n" "$v2rayng_json"
  printf "  - sing-box JSON: %s\n" "$sing_primary_json"
  printf "  - Shadowrocket/Streisand JSON: %s\n" "$apple_style_json"
  printf "  - Accepted shortIds: %s\n" "$shortids_file"
  printf "  - Primary QR (UTF8 text): %s\n" "$qr_primary_utf8_display"
  printf "  - Primary QR (PNG): %s\n" "$qr_primary_png_display"
  printf "  - Fallback QR (UTF8 text): %s\n" "$qr_fallback_utf8_display"
  printf "  - Fallback QR (PNG): %s\n" "$qr_fallback_png_display"

  printf "\nVLESS links (copy/paste):\n"
  printf "  - Primary VLESS URI: %s\n" "$uri_primary"
  if [[ -n "$uri_fallback" ]]; then
    printf "  - Fallback VLESS URI: %s\n" "$uri_fallback"
  else
    printf "  - Fallback VLESS URI: <not configured>\n"
  fi

  printf "\nSingle-command reprint: %s\n" "$REPRINT_CMD"
  printf "============================================================\n"
}

status_mode() {
  section "Xray status"
  systemctl --no-pager --full status xray || true

  section "Listening TCP ports"
  ss -lntp | grep -E "(:${LISTEN_PORT}|:${FALLBACK_PORT:-0}|:${CAMOUFLAGE_WEB_PORT}|:443|:8443|sshd|ssh|nginx)" || ss -lntp || true

  section "Camouflage web status"
  systemctl --no-pager --full status nginx || true
  curl -fsS --max-time 4 "http://127.0.0.1:${CAMOUFLAGE_WEB_PORT}/healthz" || true
  printf '\n'

  section "Firewall summary"
  if [[ "$FIREWALL_STYLE" == "nftables" ]]; then
    nft list ruleset || true
  elif [[ "$FIREWALL_STYLE" == "ufw" ]]; then
    ufw status verbose || true
  else
    if systemctl is-active --quiet nftables; then
      nft list ruleset || true
    elif systemctl is-active --quiet ufw; then
      ufw status verbose || true
    else
      log_warn "Firewall manager not identified"
    fi
  fi
}

diagnose_mode() {
  section "Diagnose: Xray config test"
  if [[ -x "$XRAY_BIN" && -f "$XRAY_CONFIG_FILE" ]]; then
    "$XRAY_BIN" -test -config "$XRAY_CONFIG_FILE" 2>&1 || true
  else
    log_warn "Xray binary or config not found (${XRAY_BIN}, ${XRAY_CONFIG_FILE})"
  fi

  section "Diagnose: systemd status"
  systemctl --no-pager --full status xray || true

  section "Diagnose: listening TCP ports"
  ss -lntp || true

  section "Diagnose: firewall rules"
  if systemctl is-active --quiet nftables 2>/dev/null; then
    nft list ruleset || true
  fi
  if systemctl is-active --quiet ufw 2>/dev/null; then
    ufw status verbose || true
  fi
  if ! systemctl is-active --quiet nftables 2>/dev/null && ! systemctl is-active --quiet ufw 2>/dev/null; then
    log_warn "Neither nftables nor ufw appears active"
  fi

  section "Diagnose: recent xray errors (journalctl)"
  journalctl -u xray -p err -n 120 --no-pager || true

  section "Diagnose: recent xray log tail"
  if [[ -f "$LOG_DIR/error.log" ]]; then
    tail -n 120 "$LOG_DIR/error.log" || true
  else
    log_warn "Error log not found: $LOG_DIR/error.log"
  fi
}

reprint_mode() {
  load_state || die "State file not found. Run install first."
  persist_self_for_reuse
  generate_client_artifacts
}

rotate_shortid_mode() {
  section "Rotate REALITY shortIds"
  load_state || die "State file missing, cannot rotate shortIds. Run install first."

  validate_short_id_count "$SHORT_ID_COUNT" || die "Invalid --shortid-count value: ${SHORT_ID_COUNT} (allowed: 1-16)"
  [[ -n "$UUID" && -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "State missing UUID/REALITY keypair; run repair/install first."

  REALITY_SHORT_IDS="$(generate_short_ids_csv "$SHORT_ID_COUNT")"
  REALITY_SHORT_ID="$(primary_short_id_from_csv "$REALITY_SHORT_IDS")"

  if ! command_exists nginx; then
    apt_install nginx curl
  fi
  configure_camouflage_web_server
  write_xray_config
  write_systemd_unit
  save_state
  persist_self_for_reuse

  log_ok "Rotated REALITY shortIds (${SHORT_ID_COUNT} values). UUID/keypair preserved."
  generate_client_artifacts
}

repair_mode() {
  section "Repair mode"
  load_state || die "State file missing, cannot repair. Run install first."

  install_dependencies
  [[ -x "$XRAY_BIN" ]] || install_or_update_xray_binary

  configure_camouflage_web_server
  write_xray_config
  write_systemd_unit
  harden_ssh
  apply_firewall
  configure_fail2ban
  configure_unattended_upgrades
  configure_xray_update_timer
  save_state
  status_mode
  generate_client_artifacts
}

update_mode() {
  section "Update mode"
  local had_state="no"
  if load_state; then
    had_state="yes"
  else
    log_warn "State file not found; update will only refresh binary"
  fi

  # Ensure base tools exist
  apt_install ca-certificates curl wget openssl unzip iproute2 qrencode

  install_or_update_xray_binary

  if [[ -f "$XRAY_CONFIG_FILE" ]]; then
    "$XRAY_BIN" -test -config "$XRAY_CONFIG_FILE" >/dev/null
  fi

  systemctl daemon-reload
  if systemctl is-enabled --quiet xray 2>/dev/null || systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray
  fi

  if [[ "$had_state" == "yes" ]]; then
    save_state
  fi

  log_ok "Update completed. Config and keys preserved."
}

uninstall_mode() {
  section "Uninstall mode"
  load_state || true

  if ! is_tty; then
    die "Uninstall requires interactive confirmation"
  fi

  printf "This will stop and remove Xray service, configs, and update timer.\n"
  printf "Type UNINSTALL to continue: "
  local confirm
  read -r confirm
  [[ "$confirm" == "UNINSTALL" ]] || die "Aborted"

  systemctl disable --now xray >/dev/null 2>&1 || true
  systemctl disable --now xray-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray-update.timer /etc/systemd/system/xray-update.service
  rm -f "$XRAY_SERVICE_FILE"
  systemctl daemon-reload

  rm -f "$XRAY_BIN"
  rm -f "$XRAY_SHARE_DIR/geoip.dat" "$XRAY_SHARE_DIR/geosite.dat"
  rmdir "$XRAY_SHARE_DIR" >/dev/null 2>&1 || true

  rm -f "$CAMOUFLAGE_NGINX_CONF"
  rm -rf "$CAMOUFLAGE_SITE_DIR"
  if command_exists nginx; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi

  if prompt_yes_no "Remove ${XRAY_DIR} (contains secrets/state)?" "yes"; then
    rm -rf "$XRAY_DIR"
  fi

  if prompt_yes_no "Remove ${CLIENT_DIR} artifacts?" "no"; then
    rm -rf "$CLIENT_DIR"
  fi

  rm -f "$SELF_INSTALLED_PATH"

  log_ok "Xray components removed"
  log_info "Security packages (firewall/fail2ban/unattended-upgrades) were left in place intentionally"
}

print_existing_install_menu() {
  if ! is_tty; then
    return 1
  fi

  section "Existing installation detected"
  cat <<EOF
Choose action:
  1) update    - update Xray binary only (preserve config/keys)
  2) repair    - re-apply firewall/ssh/service/config from saved state
  3) install   - run full wizard again (can keep or rotate secrets)
  4) status    - show status and firewall summary
  5) diagnose  - unified diagnostics dump
  6) reprint   - print client configs from saved state
  7) rotate-shortid - rotate shortIds only (preserve UUID/keypair)
  8) uninstall - remove deployment
EOF

  local choice
  read -r -p "Selection [default: 1]: " choice
  choice="$(trim "$choice")"
  [[ -z "$choice" ]] && choice="1"

  case "$choice" in
    1) MODE="update" ;;
    2) MODE="repair" ;;
    3) MODE="install" ;;
    4) MODE="status" ;;
    5) MODE="diagnose" ;;
    6) MODE="reprint" ;;
    7) MODE="rotate-shortid" ;;
    8) MODE="uninstall" ;;
    *) die "Invalid selection" ;;
  esac

  return 0
}

opsec_briefing() {
  section "OPSEC/DPI briefing"
  cat <<'EOF'
- JA3/JA4 are TLS fingerprinting methods: censors hash handshake traits (cipher suites, extensions, timing) to identify non-standard clients.
- REALITY helps by making your server present handshake characteristics of a real high-traffic TLS target, reducing obvious protocol signatures.
- It does NOT make you invisible: IP reputation, ASN patterns, traffic correlation, and long-lived uniform sessions can still flag you.
- Use single-user profiles and avoid public sharing; shared links create noisy, correlated traffic.
- Keep ports minimal (443 only by default), keep logs minimal, and patch frequently.
EOF
}

wizard_question_1_domain_dest() {
  section "1) REALITY impersonation target"
  cat <<'EOF'
Selection criteria: choose a TLS 1.3-capable, high-traffic, stable endpoint with normal global usage.
Curated options are common front-door domains with broad baseline traffic.
EOF

  local options=(
    "www.cloudflare.com|Cloudflare edge; globally common TLS profile"
    "www.microsoft.com|Large enterprise footprint; stable TLS endpoints"
    "www.apple.com|High legitimate mobile/desktop traffic"
    "www.amazon.com|High-volume commerce traffic"
    "custom|Enter your own domain"
  )

  local i=1
  for item in "${options[@]}"; do
    printf "  %d) %s\n" "$i" "$item"
    ((i++))
  done

  local pick="1"
  if is_tty; then
    read -r -p "Choose serverName option [default: 1]: " pick
    pick="$(trim "$pick")"
    [[ -z "$pick" ]] && pick="1"
  fi

  case "$pick" in
    1) SERVER_NAME="www.cloudflare.com" ;;
    2) SERVER_NAME="www.microsoft.com" ;;
    3) SERVER_NAME="www.apple.com" ;;
    4) SERVER_NAME="www.amazon.com" ;;
    5)
      SERVER_NAME="$(prompt_input "Enter custom serverName domain" "www.cloudflare.com")"
      ;;
    *) die "Invalid choice for serverName" ;;
  esac

  DEST_ENDPOINT="$(prompt_input "Enter REALITY dest endpoint (domain:port recommended)" "${SERVER_NAME}:443")"
  validate_hostport "$DEST_ENDPOINT" || die "Invalid dest endpoint: ${DEST_ENDPOINT}"

  local dport
  dport="${DEST_ENDPOINT##*:}"
  validate_port "$dport" || die "Invalid dest port: ${dport}"

  validate_reality_dest_connectivity
}

wizard_question_2_ports() {
  section "2) Listen ports"
  cat <<'EOF'
Default is TCP/443 only (best blend-in, smallest attack surface).
Fallback port improves availability if 443 is targeted, but adds another visible open port.
EOF

  LISTEN_PORT="443"
  local custom_primary
  custom_primary="$(prompt_input "Primary listen port" "443")"
  validate_port "$custom_primary" || die "Invalid primary listen port"
  LISTEN_PORT="$custom_primary"

  if prompt_yes_no "Add fallback listen port (e.g., 8443)?" "no"; then
    local fb
    fb="$(prompt_input "Fallback port" "8443")"
    validate_port "$fb" || die "Invalid fallback port"
    [[ "$fb" == "$LISTEN_PORT" ]] && die "Fallback port cannot equal primary port"
    FALLBACK_PORT="$fb"
  else
    FALLBACK_PORT=""
  fi
}

wizard_question_3_firewall() {
  section "3) Firewall style"
  cat <<'EOF'
nftables: lower-level, explicit policy, minimal footprint (recommended).
ufw: simpler wrapper around netfilter, easier for admins used to ufw.
EOF

  local pick="1"
  if is_tty; then
    read -r -p "Choose firewall: 1) nftables 2) ufw [default: 1]: " pick
    pick="$(trim "$pick")"
    [[ -z "$pick" ]] && pick="1"
  fi

  case "$pick" in
    1) FIREWALL_STYLE="nftables" ;;
    2) FIREWALL_STYLE="ufw" ;;
    *) die "Invalid firewall choice" ;;
  esac
}

wizard_question_4_ssh_hardening() {
  section "4) SSH hardening"

  if prompt_yes_no "Change SSH port from 22?" "no"; then
    CHANGE_SSH_PORT="yes"
    local new_ssh
    new_ssh="$(prompt_input "New SSH port" "2222")"
    validate_port "$new_ssh" || die "Invalid SSH port"
    SSH_PORT="$new_ssh"
  else
    CHANGE_SSH_PORT="no"
    SSH_PORT="22"
  fi

  if [[ "$SSH_PORT" == "$LISTEN_PORT" || ( -n "$FALLBACK_PORT" && "$SSH_PORT" == "$FALLBACK_PORT" ) ]]; then
    die "SSH port must differ from Xray listen/fallback port"
  fi

  if prompt_yes_no "Have you verified SSH key login in another session?" "yes"; then
    HAS_SSH_KEYS="yes"
  else
    HAS_SSH_KEYS="no"
  fi

  if [[ "$HAS_SSH_KEYS" == "yes" ]]; then
    if prompt_yes_no "Disable SSH password authentication (recommended)?" "yes"; then
      DISABLE_PASSWORD_AUTH="yes"
    else
      DISABLE_PASSWORD_AUTH="no"
    fi
  else
    DISABLE_PASSWORD_AUTH="no"
    log_warn "Keeping password auth enabled because SSH key readiness not confirmed"
  fi

  if prompt_yes_no "Enable fail2ban for SSH brute-force mitigation?" "yes"; then
    FAIL2BAN_ENABLED="yes"
  else
    FAIL2BAN_ENABLED="no"
  fi
}

wizard_question_5_updates() {
  section "5) Auto updates"

  if prompt_yes_no "Enable unattended OS security upgrades?" "yes"; then
    UNATTENDED_UPGRADES_ENABLED="yes"
  else
    UNATTENDED_UPGRADES_ENABLED="no"
  fi

  cat <<'EOF'
Xray update policy options:
  1) manual  - no scheduler, operator triggers updates
  2) weekly  - systemd timer weekly (recommended)
  3) daily   - systemd timer daily (fastest patch cadence)
EOF

  local pick="2"
  if is_tty; then
    read -r -p "Choose Xray update policy [default: 2]: " pick
    pick="$(trim "$pick")"
    [[ -z "$pick" ]] && pick="2"
  fi

  case "$pick" in
    1) XRAY_UPDATE_POLICY="manual" ;;
    2) XRAY_UPDATE_POLICY="weekly" ;;
    3) XRAY_UPDATE_POLICY="daily" ;;
    *) die "Invalid update policy choice" ;;
  esac
}

wizard_question_6_logging() {
  section "6) Logging profile"
  cat <<'EOF'
minimal (default): access log disabled, warning-level errors only. Better OPSEC and less data at rest.
verbose: includes access logs and info-level details for troubleshooting; higher forensic footprint.
EOF

  local pick="1"
  if is_tty; then
    read -r -p "Choose logging profile: 1) minimal 2) verbose [default: 1]: " pick
    pick="$(trim "$pick")"
    [[ -z "$pick" ]] && pick="1"
  fi

  case "$pick" in
    1) LOG_PROFILE="minimal" ;;
    2) LOG_PROFILE="verbose" ;;
    *) die "Invalid logging choice" ;;
  esac
}

wizard_question_7_profile() {
  section "7) Client profile naming"
  PROFILE_NAME="$(prompt_input "Client profile name" "reality-$(hostname -s)")"
  SHORT_ID_LABEL="$(prompt_input "Optional short-ID label (metadata only)" "main")"
  local sid_count
  sid_count="$(prompt_input "REALITY shortId count (1-16, default 3)" "$SHORT_ID_COUNT")"
  validate_short_id_count "$sid_count" || die "Invalid shortId count: ${sid_count}"
  SHORT_ID_COUNT="$sid_count"

  if prompt_yes_no "Block client egress to private/reserved IP ranges?" "yes"; then
    BLOCK_PRIVATE_OUTBOUND="yes"
  else
    BLOCK_PRIVATE_OUTBOUND="no"
  fi
}

run_wizard() {
  opsec_briefing
  wizard_question_1_domain_dest
  wizard_question_2_ports
  wizard_question_3_firewall
  wizard_question_4_ssh_hardening
  wizard_question_5_updates
  wizard_question_6_logging
  wizard_question_7_profile
}

install_mode() {
  if [[ -f "$STATE_FILE" ]]; then
    load_state || true
    print_existing_install_menu || true
    case "$MODE" in
      update) update_mode; return ;;
      repair) repair_mode; return ;;
      status) status_mode; return ;;
      diagnose) diagnose_mode; return ;;
      reprint) reprint_mode; return ;;
      rotate-shortid) rotate_shortid_mode; return ;;
      uninstall) uninstall_mode; return ;;
      install) ;;
      *) die "Unexpected mode transition: ${MODE}" ;;
    esac

    if prompt_yes_no "Reuse existing UUID/REALITY keys/shortIds?" "yes"; then
      :
    else
      UUID=""
      REALITY_PRIVATE_KEY=""
      REALITY_PUBLIC_KEY=""
      REALITY_SHORT_ID=""
      REALITY_SHORT_IDS=""
    fi
  fi

  run_wizard
  install_dependencies
  install_or_update_xray_binary
  ensure_identity_materials
  configure_camouflage_web_server
  write_xray_config
  write_systemd_unit
  harden_ssh
  apply_firewall
  configure_fail2ban
  configure_unattended_upgrades
  persist_self_for_reuse
  configure_xray_update_timer
  PUBLIC_IP="$(detect_public_ip || true)"
  save_state

  if is_tty && prompt_yes_no "Display REALITY private key now? (sensitive)" "no"; then
    printf "REALITY private key: %s\n" "$REALITY_PRIVATE_KEY"
  fi

  status_mode
  generate_client_artifacts
}

parse_args() {
  local args=()
  while (( $# > 0 )); do
    case "$1" in
      install|update|repair|status|diagnose|reprint|rotate-shortid|uninstall)
        MODE="$1"
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=true
        shift
        ;;
      --shortid-count)
        shift
        (( $# > 0 )) || die "--shortid-count requires a value"
        SHORT_ID_COUNT="$1"
        SHORT_ID_COUNT_CLI="$SHORT_ID_COUNT"
        shift
        ;;
      --shortid-count=*)
        SHORT_ID_COUNT="${1#*=}"
        SHORT_ID_COUNT_CLI="$SHORT_ID_COUNT"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#args[@]} > 0 )); then
    die "Unknown argument(s): ${args[*]}"
  fi

  validate_short_id_count "$SHORT_ID_COUNT" || die "Invalid shortId count: ${SHORT_ID_COUNT}. Allowed range: 1-16"
}

main() {
  require_root
  detect_os
  parse_args "$@"

  if [[ "$NON_INTERACTIVE" == "true" && "$MODE" == "install" ]]; then
    die "Non-interactive install is not supported. Use interactive install or explicit update mode."
  fi

  case "$MODE" in
    install) install_mode ;;
    update) update_mode ;;
    repair) repair_mode ;;
    status)
      load_state || true
      status_mode
      ;;
    diagnose)
      load_state || true
      diagnose_mode
      ;;
    reprint) reprint_mode ;;
    rotate-shortid) rotate_shortid_mode ;;
    uninstall) uninstall_mode ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
