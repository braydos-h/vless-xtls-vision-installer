#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
probe_reality() {
  local target sni
  target=$(profile_opt DEST_ENDPOINT)
  sni=$(profile_opt SERVER_NAME)
  require_tools openssl timeout
  # Explicit version/group/ALPN, trusted certificate and matching SNI.
  if ! timeout 20 openssl s_client -connect "$target" -servername "$sni" \
    -tls1_3 -groups X25519 -alpn h2 -verify_hostname "$sni" -verify_return_error \
    </dev/null >"$WORK/tls-probe" 2>&1; then
    die 'REALITY target probe failed. Check endpoint reachability, TLS 1.3, X25519 and certificate/SNI; choose another target.'
  fi
  grep -Eq 'TLSv1.3|TLS 1.3' "$WORK/tls-probe" || die 'Target did not negotiate TLS 1.3.'
  grep -q 'ALPN protocol: h2' "$WORK/tls-probe" || die 'Target did not negotiate HTTP/2 (h2). Choose an h2-capable TLS site.'
  log 'REALITY target negotiated verified TLS 1.3 with X25519 and h2. This does not guarantee camouflage on every network.'
}
