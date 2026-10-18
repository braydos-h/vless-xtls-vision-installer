#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
probe_reality() {
  local target sni host rc
  target=$(profile_opt DEST_ENDPOINT)
  sni=$(profile_opt SERVER_NAME)
  require_tools openssl timeout getent
  host=${target%:*}
  host=${host#[}
  host=${host%]}
  if getent ahosts "$host" >"$WORK/dns-probe" 2>&1; then :; else
    rc=$?
    log "[FAIL] DNS resolution failed: getent ahosts $host for REALITY endpoint $target (exit $rc). Check the hostname and resolver configuration."
    return "$rc"
  fi
  # Explicit version/group/ALPN, trusted certificate and matching SNI.
  if timeout 20 openssl s_client -connect "$target" -servername "$sni" \
    -tls1_3 -groups X25519 -alpn h2 -verify_hostname "$sni" -verify_return_error \
    </dev/null >"$WORK/tls-probe" 2>&1; then :; else
    rc=$?
    log "[FAIL] REALITY TLS negotiation failed: endpoint=$target SNI=$sni; openssl s_client TLS 1.3/X25519/h2 certificate verification (exit $rc)."
    # OpenSSL output contains public peer data, never deployment credentials.
    tail -n 20 "$WORK/tls-probe" >&2
    [[ $rc != 124 ]] || log 'TLS probe timed out after 20 seconds; check endpoint reachability and outbound access.'
    return "$rc"
  fi
  if ! grep -Eq 'TLSv1.3|TLS 1.3' "$WORK/tls-probe"; then
    log "[FAIL] REALITY endpoint=$target SNI=$sni did not negotiate TLS 1.3. Choose a TLS 1.3 target."
    return 1
  fi
  if ! grep -q 'ALPN protocol: h2' "$WORK/tls-probe"; then
    log "[FAIL] REALITY endpoint=$target SNI=$sni did not negotiate HTTP/2 (h2). Choose an h2-capable target."
    return 1
  fi
  log 'REALITY target negotiated verified TLS 1.3 with X25519 and h2. This does not guarantee camouflage on every network.'
}
