# Changelog

## 2.0.0 — security and operational overhaul

- Replace destructive host firewall management with an owned nftables table or
  tagged additive UFW rules. Add validated transitions, timed rollback and explicit
  confirmation; preserve Docker/VPN/fail2ban and administrator policies.
- Move SSH changes to optional drop-ins with syntax/effective-setting checks,
  retained ports, explicit key confirmation, recovery and safe removal.
- Replace executable shell state/manual JSON with strict, versioned JSON and a
  literal migration parser. Reject unknown fields, duplicate keys,
  malformed ports/endpoints, and invalid shortIds.
- Activate binary, config, assets and state through an atomic deployment pointer.
  Stage and verify updates before activation; retain generations, serialize
  mutations, back up automatically, and recover failed/interrupted operations.
- Reject upstream prereleases without explicit opt-in and skip unpinned
  downgrades to older stable releases. Skip full deployment backups when an
  update check finds no version change.
- Correct private hostname routing using IPOnDemand, explicit reserved ranges and
  dual-family DNS. Add optional per-service kernel enforcement; account for newer
  Freedom finalRules and explicit private-network opt-out.
- Enable TCP Happy Eyeballs for resolved outbounds so an unreachable address
  family does not cause intermittent failures on IPv4-only or IPv6-only hosts.
- Correct REALITY forwarding documentation and remove redundant VLESS HTTP
  fallbacks. Preserve the alternate listener. Probe TLS 1.3/X25519/h2/certificates.
- Run Xray as a dedicated account with constrained writes and low-port capability.
  Keep its log directory root-owned to prevent service-controlled path swapping
  during privileged permission updates.
- Reject linked/oversized JSON inputs and unsafe lock files. Preserve auxiliary
  unit state during rollback, wait for fail2ban readiness, and avoid pipefail
  false results when inspecting large firewall or SSH command output.
- Preserve legacy IPv4 bindings and refuse inconsistent listener/REALITY state.
  Wait for daemon-owned SSH listeners after reload, including during recovery.
  Initialize recovery's private workspace before constructing firewall batches.
- Add client lifecycle, staged shortId rotation/finalization, backup/restore,
  preflight/dry-run, redacted structured diagnostics and optional protocol testing.
- Split sources into modules while retaining a standalone distributable. Add
  static/unit/protocol tests and isolated VM lifecycle CI. Correct GPL licensing.

### Compatibility changes

- No host hardening or scheduled updates by default; interactive/auto defaults
  agree. Existing legacy host changes require manual review and remain untouched.
- SSH changes are a separate command, with confirmation in a fresh session.
- Active files move to `/etc/xray/current/`; legacy files are retained. Profiles
  normalize to format 2. Credentials are preserved when state/config agree.
- Require Debian 12/13 or Ubuntu 22.04/24.04 for new installs. Other releases are
  not advertised as supported. New syntax is validated against each candidate.
- `PUBLIC_IP` is explicit, with no third-party public-IP lookup or unusable export
  placeholder. Exports use hashed filenames and are not printed except on request.
- ShortId rotation retains old values until explicit finalization. It no longer
  silently revokes all clients immediately.
- Uninstall retains recovery material and requires SSH restoration first if a
  managed SSH drop-in exists. This avoids restoring stale administrator configs.
