# Audit before implementation (2026-10-13)

All four tracked files were read before changes. The original entry point was
3,000 lines of Bash, with no tests or CI. LICENSE is GPL-3.0; the README's MIT
claim was incorrect.

| Lifecycle | Original defect | Replacement design |
|---|---|---|
| install / repair | `flush ruleset`, UFW reset, manager shutdown, forward drop break SSH, Docker and VPNs | Own table / tagged additive rules; never change host policy |
| install / repair | primary sshd_config edited and SSH restarted before firewall | Separate optional drop-in operation, retained ports, timed recovery |
| update | live executable overwritten before test; RETURN trap can clean staging too early | Immutable deployment generations, validation before atomic pointer switch |
| configuration | direct writes leave config, keys and state inconsistent | Config, state and binary activate with one symlink rename; durable journal |
| state | root `source` of editable state | Strict data-only migration and versioned JSON |
| private egress | AsIs bypasses IP rule for hostnames; IPv4-only inbound | IPOnDemand, explicit CIDRs, dual-family DNS; optional per-service kernel restrictions |
| REALITY | unauthenticated TLS incorrectly described as local HTTP fallback | Forward to REALITY TLS target; remove misleading VLESS HTTP fallbacks |
| TLS probe | successful TLS 1.2 accepted | TLS 1.3, X25519, certificate/hostname and h2 checks |
| identity | odd hex shortIds accepted; fragile awk key parsing | strict even-length hex; public key derived from private key |
| systemd | runs as root, writes to all /run, unsupported HUP reload | dedicated account, restricted paths; validated restart |
| optional hardening | disables existing fail2ban, overwrites apt and jail policy | dedicated managed files, opt-in; leave administrator policies alone |
| diagnostics | always exit success; raw journal and credentials | bounded redacted checks and structured output with failure status |
| uninstall | replaces administrator SSH configuration with stale backup | remove only owned files; keep legacy backup for manual review |
| profiles | line-oriented awk JSON parsing, insecure auto defaults | strict parser, one default profile, schema migration |

Additional findings: retry captured the status of `until` rather than the failing
command; port arithmetic permits integer overflow; client filenames allow `..`;
Nginx server_name input can inject directives; update metadata is parsed by
line-order-dependent regex; no operation lock; no archive traversal check; no
space checks; exports printed during unattended install; no rollback after
service failure; untested OS versions advertised as tested.

Upstream references checked during the audit:

- [REALITY example and requirements](https://github.com/XTLS/REALITY)
- [Routing strategy](https://xtls.github.io/en/config/routing.html)
- [Freedom outbound](https://xtls.github.io/en/config/outbounds/freedom.html)
- [Xray transport parser](https://github.com/XTLS/Xray-core/blob/main/infra/conf/transport_internet.go)
- [VLESS inbound implementation](https://github.com/XTLS/Xray-core/blob/main/proxy/vless/inbound/inbound.go)
- [Release metadata](https://api.github.com/repos/XTLS/Xray-core/releases/latest)

Current examples use `target`, RAW and client `password`. Compatibility aliases
must be checked with real release executables, not inferred from comments.
IP routing does not replace the connection destination, so routing checks alone
cannot guarantee DNS-rebinding prevention. Kernel enforcement closes this gap
but also affects REALITY forwarding and service DNS.

Privileged integration tests use separate disposable guests, rather than the
workspace host's services or firewall. QEMU tools and verified cloud images were
provisioned under temporary paths, with TCG software emulation. Mocked tests
remain distinct from those kernel/systemd tests. See
[validation coverage](TESTING.md) for actual results and unverified targets.
