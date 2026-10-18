#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
install_dependencies() {
  local packages=(ca-certificates curl openssl jq python3 iproute2 util-linux)
  local missing=() package
  [[ $(opt FIREWALL_STYLE) != nftables ]] || packages+=(nftables)
  [[ $(opt FIREWALL_STYLE) != ufw ]] || packages+=(ufw)
  [[ $(opt CAMOUFLAGE_ENABLED) != yes ]] || packages+=(nginx)
  # The managed journal jail needs python3-systemd/nft. Distribution defaults
  # may also enable a file-backed sshd jail, which needs the local syslog daemon.
  [[ $(opt FAIL2BAN_ENABLED) != yes ]] || packages+=(fail2ban python3-systemd nftables rsyslog logrotate)
  [[ $(opt UNATTENDED_UPGRADES_ENABLED) != yes ]] || packages+=(unattended-upgrades)
  for package in "${packages[@]}"; do
    if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) != 'install ok installed' ]]; then
      missing+=("$package")
    fi
  done
  if ((${#missing[@]} == 0)); then
    log 'Dependencies already installed; retaining existing package versions.'
    return 0
  fi
  retry env DEBIAN_FRONTEND=noninteractive apt-get update
  retry env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove --no-install-recommends "${missing[@]}"
}
configure_host_extras() {
  if [[ $(opt CAMOUFLAGE_ENABLED) == yes ]]; then
    touch "$JOURNAL/pending/nginx-changed"
    # Loopback diagnostics site, deliberately unrelated to REALITY TLS forwarding.
    cat >"$WORK/nginx.conf" <<EOF
# Managed by xray-reality-bootstrap v2
server {
    listen 127.0.0.1:$(opt CAMOUFLAGE_WEB_PORT);
    server_name _;
    location = /healthz { default_type text/plain; return 200 "ok\n"; }
    location / { default_type text/html; return 200 "<h1>Service gateway</h1>"; }
}
EOF
    atomic_managed_file "$WORK/nginx.conf" "$NGINX_FILE" 644
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    [[ $(curl -fsS --max-time 5 "http://127.0.0.1:$(opt CAMOUFLAGE_WEB_PORT)/healthz") == ok ]] || die 'Managed Nginx health endpoint did not return the expected response.'
  elif [[ -f $NGINX_FILE ]] && grep -q 'Managed by xray-reality-bootstrap v2' "$NGINX_FILE"; then
    touch "$JOURNAL/pending/nginx-changed"
    rm -f -- "$NGINX_FILE"
    nginx -t
    if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
  fi
  configure_fail2ban
  if [[ $(opt UNATTENDED_UPGRADES_ENABLED) == yes ]]; then
    [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]] || die 'Administrator unattended-upgrades policy exists. Leave installer option disabled and manage it directly.'
    cat >"$WORK/apt-policy" <<'EOF'
// Managed by xray-reality-bootstrap v2
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    atomic_managed_file "$WORK/apt-policy" "$APT_FILE" 644
  elif [[ -f $APT_FILE ]] && grep -q 'Managed by xray-reality-bootstrap v2' "$APT_FILE"; then
    rm -f -- "$APT_FILE"
  fi
}

wait_fail2ban() {
  local attempts=0
  while ((attempts < 30)); do
    if fail2ban-client ping >/dev/null 2>&1; then return 0; fi
    attempts=$((attempts + 1))
    sleep 1
  done
  return 1
}
configure_fail2ban() {
  if [[ $(opt FAIL2BAN_ENABLED) == yes ]]; then
    # Existing administrator sshd jail remains unchanged. Never disable fail2ban.
    touch "$JOURNAL/pending/f2b-changed"
    local ssh_ports
    ssh_ports=$(opt SSH_PORT)
    if command -v sshd >/dev/null; then
      ssh_ports=$(sshd -T | awk '$1=="port" {ports=ports sep $2; sep=","} END{print ports}')
    fi
    [[ $ssh_ports =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || die 'Cannot determine SSH ports for fail2ban.'
    cat >"$WORK/fail2ban" <<EOF
# Managed by xray-reality-bootstrap v2
[xray-bootstrap-sshd]
enabled = true
filter = sshd
backend = systemd
banaction = nftables-multiport
port = $ssh_ports
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    atomic_managed_file "$WORK/fail2ban" "$F2B_FILE" 644
    if ! fail2ban-client -t >"$WORK/fail2ban-test" 2>&1; then
      atomic_file "$WORK/fail2ban-test" "$JOURNAL/fail2ban-validation.log" 600
      die "Fail2ban configuration is invalid. Inspect $JOURNAL/fail2ban-validation.log privately and resolve administrator jail backend/log paths."
    fi
    systemctl enable --now fail2ban
    touch "$JOURNAL/pending/f2b-changed"
    wait_fail2ban || die 'Fail2ban control socket did not become ready. Inspect its service journal privately.'
    fail2ban-client reload
    fail2ban-client status xray-bootstrap-sshd >"$WORK/fail2ban-status" 2>&1
  elif [[ -f $F2B_FILE ]] && grep -q 'Managed by xray-reality-bootstrap v2' "$F2B_FILE"; then
    touch "$JOURNAL/pending/f2b-changed"
    rm -f -- "$F2B_FILE"
    if systemctl is-active --quiet fail2ban; then
      wait_fail2ban || die 'Fail2ban is active but its control socket is unavailable.'
      fail2ban-client reload
    fi
  fi
}
