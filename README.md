# VLESS + REALITY + XTLS Vision installer

A Bash installer and management tool for one Xray server, with separate clients,
validated updates and recoverable configuration changes. This is the version 2
security overhaul of braydos-h's original installer. Licensed under GPL-3.0;
see [LICENSE](LICENSE).

**Start with `preflight`. The default installation changes Xray only: SSH,
firewall policy, fail2ban and OS updates require explicit options.** This tool
cannot establish whether your provider's firewall permits inbound connections.

## Requirements

The supported targets are Debian **12/13** and Ubuntu **22.04/24.04**, using apt
and systemd as PID 1. Architectures: amd64, arm64 and armv7. Other distributions
and releases are rejected by installation preflight. These are support targets,
not a claim that every target was tested here; see [testing coverage](docs/TESTING.md).

Use a VPS with root/sudo access, at least 512 MiB free disk for staging (more for
backups), working DNS, accurate time, and outbound HTTPS. Retain provider console
access. No domain purchase or certificate for the proxy server is necessary:
clients can connect to the server's public IP. The REALITY SNI names the TLS
target, **not** a domain that must point to your VPS.

Bash, Python 3, jq, OpenSSL, curl, util-linux and iproute2 are required. A real
install bootstraps Python/jq when missing and installs the remaining dependencies.
Only missing prerequisite packages are requested. Apt resolves their dependencies
using your configured repositories; no general host upgrade is requested.
Read-only commands never install packages. For preflight on a fresh machine:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates jq python3 openssl curl iproute2 util-linux git
```

The committed `xray_reality_bootstrap.sh` contains all modules and Python data
code. It runs on its own; no remote shell code is sourced. Git is needed only
for the checkout commands below. Keep LF line endings.

## Security architecture

Installation and management run as root. Xray runs as the dedicated
`xray-bootstrap` account with no login shell or home directory. It receives only
`CAP_NET_BIND_SERVICE`, uses a read-only system filesystem, private temporary
space, and restrictions on devices, namespaces, kernel settings and privileges.
Only its pre-created log files are writable in `/var/log/xray`; root owns that
directory so the service cannot replace file paths during maintenance.

The service can read its mode-640 configuration, including the private key it
needs for REALITY. Saved identities/state, backups, exports and operation logs
remain root-only. Configuration is validated as the service account before
activation. These controls limit a compromised service; they do not replace
administrator access controls or timely security updates.

## First installation

```bash
git clone https://github.com/braydos-h/vless-xtls-vision-installer.git
cd vless-xtls-vision-installer
sudo bash xray_reality_bootstrap.sh preflight
sudo bash xray_reality_bootstrap.sh install
```

The wizard asks for the target, proxy ports, server public IP/hostname, client
name, firewall option, update policy, private-egress filtering and optional local
web diagnostics. IPv6 `::` is the default listener (Linux normally also accepts
IPv4); use `LISTEN_ADDRESS=0.0.0.0` if IPv6 is disabled. An occupied proxy port
prevents installation unless its listener is an existing Xray process.

Installation checks that the target negotiates **TLS 1.3, X25519 and h2**, with a
trusted certificate matching the SNI. Endpoint forms are `name:port`, `IPv4:port`
and `[IPv6]:port`. SNI must be an ASCII fully qualified hostname; use punycode
for international domain names. A successful probe does not guarantee universal
client compatibility or resistance to traffic classification.

After installation:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap diagnose
sudo /usr/local/sbin/xray-reality-bootstrap list-clients
sudo /usr/local/sbin/xray-reality-bootstrap export-client reality-main
sudo /usr/local/sbin/xray-reality-bootstrap show-client reality-main
```

`show-client` deliberately prints a credential-bearing URI. Other normal
operations print no client credentials. Export filenames use a hash of the client
name, allowing Unicode names without path traversal. URI, Xray/v2rayN/v2rayNG
JSON and sing-box outbound JSON are written under `/root/xray-client-configs`
with mode 600 and directory mode 700. Install `qrencode` yourself for optional
PNG/text QR exports. Import the URI in clients that do not accept raw core JSON;
application import formats vary. The sing-box output is an outbound object to
insert into that application's config, not a complete sing-box installation.

## Automated installation and defaults

Copy [examples/profile.json](examples/profile.json), set `PUBLIC_IP` to your
server address, and review the options. All fields are strings; unknown fields,
wrong types, duplicate JSON keys and invalid values are rejected.
JSON inputs must be regular UTF-8 files no larger than 2 MiB.

```bash
sudo bash xray_reality_bootstrap.sh install --auto --non-interactive \
  --profile-json examples/profile.json --dry-run
sudo bash xray_reality_bootstrap.sh install --auto --non-interactive \
  --profile-json examples/profile.json --xray-version v26.3.27
```

`--auto` without a profile uses deployed options, a legacy options file if present,
or the same defaults as the wizard. `install` without `--auto` requires a terminal.
The wizard preserves existing credentials and clients when reconfiguring.

| Option | Default | Meaning |
|---|---|---|
| `LISTEN_PORT`, `FALLBACK_PORT` | `443`, empty | Main and optional alternate REALITY listeners |
| `LISTEN_ADDRESS` | `::` | Literal address to bind |
| `PUBLIC_IP` | empty | Your IP/hostname; required for usable exports |
| `FIREWALL_STYLE` | `none` | `none`, `nftables`, or already-active `ufw` |
| `BLOCK_PRIVATE_OUTBOUND` | `yes` | Application routing block, with limitations below |
| `OS_PRIVATE_OUTBOUND` | `no` | Per-service UID kernel egress block; requires nftables |
| `DNS_SERVERS` | `1.1.1.1,2606:4700:4700::1111` | Comma-separated resolver IPs; choose your own if preferred |
| `SSH_HARDENING` | `no` | Enable a separate `harden-ssh` operation |
| `CHANGE_SSH_PORT`, `DISABLE_PASSWORD_AUTH` | `no`, `no` | Explicit SSH requests; original ports retained |
| `FAIL2BAN_ENABLED`, `UNATTENDED_UPGRADES_ENABLED` | `no`, `no` | Optional managed host files |
| `XRAY_UPDATE_POLICY`, `XRAY_PIN` | `manual`, empty | Manual/daily/weekly and optional release tag |
| `ALLOW_PRERELEASE` | `no` | Explicit permission to install an upstream prerelease |
| `LOG_PROFILE` | `minimal` | Warning/error logs; `verbose` also logs access |
| `SHORT_ID_COUNT` | `3` | Initial number of accepted random shortIds, 1–16 |
| `CAMOUFLAGE_ENABLED`, `CAMOUFLAGE_WEB_PORT` | `no`, `18080` | Optional loopback HTTP diagnostics site |

`PROFILE_NAME` names the initial client. `SHORT_ID_LABEL` and `HAS_SSH_KEYS`
remain supported metadata for legacy profiles; neither proves authentication.
`profile_format` is now `"2"`; valid version 1 string profiles are normalized.
Security defaults are identical for interactive and automatic installation.
Advanced timeout fields preserve legacy values: handshake 12 seconds, idle 600,
uplink-only 4 and downlink-only 10. `XRAY_HANDSHAKE_TIMEOUT_SEC` accepts 1–60,
`XRAY_CONN_IDLE_TIMEOUT_SEC` 1–86400, and `XRAY_UPLINK_ONLY_TIMEOUT_SEC` /
`XRAY_DOWNLINK_ONLY_TIMEOUT_SEC` 0–3600 (decimal strings).

## Firewall coexistence

The installer never flushes the host ruleset, resets UFW, changes default policy,
disables a firewall manager or edits `/etc/nftables.conf`. Docker, VPN forwarding
and fail2ban tables remain untouched.

For nftables it owns only `table inet xray_bootstrap`, an input chain with
`policy accept`, and optionally an output chain limiting the Xray UID. **This
is additive, not a host firewall.** An accept in this table cannot override a drop
in another base chain. Open the proxy ports through your existing host and cloud
firewall when necessary. A separate systemd unit restores the owned table on
boot; a later administrator ruleset flush can still remove it. Use diagnostics
and `repair` after such a change.

UFW must already be enabled and configured for SSH. The installer adds rules
commented `xray-bootstrap-PORT`, skips existing administrator rules, and removes
only its tagged rules. It never enables or resets UFW. IPv6 listeners require
UFW IPv6 support. firewalld conflicts are rejected; use `none` with firewalld.
Manager changes require `clear-firewall` and confirmation first.

Changes are checked before activation (`nft -c` or UFW dry-run) and a systemd
watchdog is armed. The change remains pending for **180 seconds**:

```bash
# From a NEW SSH session, after testing the proxy externally:
sudo /usr/local/sbin/xray-reality-bootstrap confirm-host
```

If not confirmed, recovery restores the previous deployment and installer-owned
rules. If you lose access, wait for recovery and use the VPS console. A reboot
removes transient timers: the durable journal remains, and `recover` is required.
The watchdog waits for a held installer lock, so a hung operation can delay
recovery; use the console to terminate it. No local check proves external access.

## SSH and optional host hardening

SSH is a separate opt-in workflow. Set `SSH_HARDENING=yes` in a profile and
configure the requested port/authentication settings. First test a fresh key
login and keep your current session open. Open the new port in the host/provider
firewalls yourself before migrating.

```bash
sudo /usr/local/sbin/xray-reality-bootstrap harden-ssh \
  --profile-json /root/ssh-profile.json --key-login-confirmed
# From a new SSH session on the requested port:
sudo /usr/local/sbin/xray-reality-bootstrap confirm-host --key-login-confirmed
```

The tool writes only `sshd_config.d/00-xray-bootstrap.conf`. It requires an
existing Include, checks `sshd -t` and effective `sshd -T` settings (including the
current login context), reloads SSH, checks listeners, and retains every original
port. Administrator precedence that prevents requested settings causes rollback.
Password disabling requires explicit `--key-login-confirmed`; `HAS_SSH_KEYS=yes`
is insufficient. You must actually verify the key login; the tool cannot prove
the remote authentication method. Match blocks for other users require separate
administrator testing. SSH socket activation is rejected for port migrations;
configure it through the console first.
Confirmation publishes the SSH metadata in a new deployment generation and
restarts an active Xray service; proxy sessions may reconnect. An inactive proxy
remains inactive.

To restore administrator settings, remove the owned drop-in transactionally:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap restore-ssh
# New session on an administrator-configured port, within 180 seconds:
sudo /usr/local/sbin/xray-reality-bootstrap confirm-host
```

Uninstall requires this confirmation first if the SSH drop-in exists. It never
restores an old copy of the entire primary SSH configuration.

fail2ban uses its own jail file and leaves existing jails/service policies alone.
This opt-in installs its journal/nft dependencies and rsyslog to support the
distribution's file-backed default SSH jail on minimal hosts. Packages remain
installed after opting out or uninstalling. Apt refuses operations that would
remove conflicting packages, including another syslog implementation; resolve
such conflicts as administrator before enabling this option. Invalid existing
jails cause rollback, with details in the root-only fail2ban validation log.
Opting out removes only its managed jail; the service remains available to other
jails. OS upgrades use a dedicated apt file and refuse to override an existing
`20auto-upgrades` policy. Existing apt policies can still take precedence: manage
your administrator policy directly. Optional Nginx binds only `127.0.0.1`, tests
syntax before reload, and leaves other sites untouched. Installing nginx can
activate the distribution's default site; review package defaults before opting
in on an existing server.

## Private destinations and REALITY behavior

With private blocking enabled, `IPOnDemand` resolves hostname destinations before
the first IP rule, unlike `AsIs`. `IPIfNonMatch` can defer resolution until after
other rules have matched and is unsuitable for a mandatory first IP guard.
The generated rules cover loopback, RFC1918, shared-address space, link-local,
multicast, documentation and several translation/tunnel/reserved ranges, in both
families. Mapped IPv6 addresses normalize to IPv4 within Xray. The list is
explicit and does not depend on an external geoip database.
Translation/tunnel prefixes are blocked conservatively, so this default can
prevent NAT64/6to4 destinations. Use native public IPv4/IPv6 destinations, or
review the implications before explicitly disabling the relevant guard.

Freedom uses built-in DNS through `sockopt.domainStrategy=UseIP`, with TCP Happy
Eyeballs to try another resolved address when a family is unreachable. On releases supporting `finalRules`, a
second check limits resolved/dialed destinations; explicit `BLOCK_PRIVATE_OUTBOUND=no`
allows private destinations even with newer upstream defaults. Older releases
lack that final check. Routing alone does not pin the address subsequently used
for a connection: resolver fallback, rebinding, translation and host routing can
matter. **Do not treat application routing as a guaranteed host isolation boundary.**
These application rules govern authenticated proxy requests; REALITY target
forwarding and core resolver traffic need the separate OS guard when isolation
from private destinations is required.
The tests cover deterministic literal addresses and private DNS responses, not
all DNS-rebinding scenarios.

`OS_PRIVATE_OUTBOUND=yes` adds nftables output restrictions for the dedicated
service UID, checking packet destinations after resolution. Replies to incoming
connections are allowed; new connections into blocked ranges are rejected. It
also affects REALITY target forwarding and resolver access. Preflight rejects private resolver/target combinations that this policy blocks. Use reachable public
resolvers/targets; local system resolvers, private targets and metadata services
can stop working. It cannot block every public IP belonging to your server or
protect against privileged host processes, policy routing or all translation
arrangements. It affects only Xray, not host-wide outbound policy.

An unauthenticated REALITY handshake is forwarded to the configured **TLS target**.
It is not sent to the local HTTP Nginx site. VLESS fallback processing happens
at a different layer, after transport establishment; redundant HTTP fallbacks
were removed. `FALLBACK_PORT` remains a supported **alternate REALITY listener**,
not a distinct bypass mechanism. No universal DPI-resistance claim is made.

See upstream [REALITY](https://github.com/XTLS/REALITY),
[routing](https://xtls.github.io/en/config/routing.html) and
[Freedom](https://xtls.github.io/en/config/outbounds/freedom.html).

## Clients and credential rotation

```bash
sudo /usr/local/sbin/xray-reality-bootstrap add-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap list-clients
sudo /usr/local/sbin/xray-reality-bootstrap export-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap show-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap rotate-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap remove-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap reprint
```

Each new client gets a unique UUID and shortId. Duplicate names and removal of
the last client are rejected. Changes validate the new server config, restart
an active Xray service, and roll back if startup fails. Inactive services remain
inactive; validate runtime health after starting them manually. A restart disconnects existing sessions.
Rotation/removal revokes the old UUID; distribute fresh exports after rotation.
Exports for removed/rotated clients are deleted locally, but external copies
cannot be deleted by this tool. Names are listed without UUIDs.

REALITY shortIds are a **global accepted set**, not cryptographically bound to
a client's UUID. A removed UUID is revoked even if its old shortId remains
accepted; shortIds are not independent per-client authorization credentials.

```bash
sudo /usr/local/sbin/xray-reality-bootstrap rotate-shortid --migration-window 604800
sudo /usr/local/sbin/xray-reality-bootstrap reprint
# Distribute exports. After the seven-day window:
sudo /usr/local/sbin/xray-reality-bootstrap finalize-shortid
```

During the window both old/new shortIds work, with each client's export pointing
to its new value. Finalization is explicit and refuses to run before the window
elapses. No automatic revocation occurs at the deadline. For an intentional
immediate cutover, use a zero-second window followed by finalization. UUIDs and
the server keypair stay unchanged.

## Updates, backup and recovery

```bash
sudo /usr/local/sbin/xray-reality-bootstrap backup
sudo /usr/local/sbin/xray-reality-bootstrap list-backups
sudo /usr/local/sbin/xray-reality-bootstrap update --xray-version v26.3.27
sudo /usr/local/sbin/xray-reality-bootstrap restore BACKUP_ID
sudo /usr/local/sbin/xray-reality-bootstrap recover
sudo /usr/local/sbin/xray-reality-bootstrap repair
```

Updates verify an official release's SHA-256 digest (or its labeled SHA-256
checksum), archive paths, advertised size, executable version, and compatibility
with the current config before activation. Checksums protect integrity but are
not an independent publisher-signature verification. Disk space is checked and
all mutations share `flock` locking. `XRAY_PIN` or `--xray-version` pins the version
for subsequent scheduled updates. Manual/daily/weekly use the same updater.
Prereleases are rejected unless `ALLOW_PRERELEASE=yes` or `--allow-prerelease`
is explicit; the CLI opt-in is saved with a successful update. The tested
`v26.10.10` release is marked prerelease upstream. Unpinned updates skip an older
stable release; downgrades require an explicit version pin.
Results report `SUCCEEDED`, `SKIPPED`, or `ROLLED_BACK`; failures return nonzero.

Config, state, keys, clients, binary and assets live in immutable deployment
generations. Validation runs as root and the restricted service account before a
single symlink rename activates a generation. An active service is restarted and its
listeners checked. Updates/client edits preserve an inactive service and report
that runtime health has not been tested; they require an installed runtime. Failure restores the prior pointer and managed files. Old
generations and journals are retained as last-known-good material; no automatic
pruning is performed. Interrupted operations block mutations until `recover`.
Do not edit deployed generations. Apply an edited profile with
`install --auto --profile-json PATH`; `repair` rebuilds the saved deployment.

Backups are mode-700 directories in `/var/backups/xray-bootstrap`. They include
the deployment, binary, credentials and snapshots of relevant managed files,
with strict manifests/checksums. A corrupt or linked backup is rejected before
restoration. Restoration validates and regenerates the proxy deployment and
managed host options; archived files remain for private comparison. It preserves
live SSH settings and does not overwrite unrelated administrator config. Restore
with firewall management enabled requires the same timed confirmation.
Pre-update/reconfigure/repair/restore/uninstall backups are automatic. Client-only
changes retain prior generations; use `backup` for an off-server recovery point.

Backups contain live secrets and are not encrypted. For an off-server copy,
archive the selected backup directory as root, encrypt it with a tool you trust,
and transfer it through an authenticated channel. Restore an unchanged backup
directory under the backup root, preserving permissions, then run `restore ID`.
Never post backups, exports or raw logs in public issues.

Uninstall with `--yes` removes owned runtime files/rules. It keeps backups,
credentials, exports, the helper and service account for recovery, and leaves
administrator firewall/SSH/security packages alone. Delete retained secret data
explicitly only after deciding recovery is no longer needed.

## Diagnostics and troubleshooting

`status` and `diagnose` emit the same structured, redacted JSON. They check service,
config, listeners, optional local web health, managed firewall presence, timer
and pending transactions, and return nonzero when a required local check fails.
They do not dump journal messages or credentials. Firewall presence cannot prove
that unrelated rules permit the connection; external connectivity is reported
as untested. For an optional protocol check:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap test-client reality-main \
  --test-url https://www.cloudflare.com/cdn-cgi/trace
sudo systemd-analyze security xray.service
```

This launches a temporary restricted client, sends one HTTPS request through the
proxy, then removes it. The test needs correct `PUBLIC_IP` and a reachable URL;
server-side hairpin routing may differ from a real remote client.

| Symptom | Check |
|---|---|
| Client timeout | Host/provider port rules, public IP, SNI/target and server time |
| Target probe fails | Endpoint formatting, DNS, TLS 1.3/X25519/h2, certificate hostname |
| Service fails | Run `diagnose`; privately inspect `/var/log/xray/error.log` and the journal |
| Mutation blocked | Pending watchdog confirmation or interrupted journal; run `recover` |
| Hostname fails with OS egress enabled | Public DNS reachability and local system resolver use |
| Clients fail after rotation | Export updated credentials; verify finalization timing |
| Export fails | Set `PUBLIC_IP` in a profile and reconfigure; no unreliable third-party IP detection |
| Firewall file exists but ports blocked | Inspect administrator base-chain drop rules; repair only owns its table |

Operation logs are root-only in `/var/lib/xray-bootstrap/operations.log` and
contain no command strings/credentials. Xray verbose logs may contain destinations
and identifying information; inspect them privately. Unexpected failures return
1 (or the failing command's code), invalid data returns 2, interruption returns
130. Diagnostic local-health failure returns 1.

## Upgrading from version 1

Read [CHANGELOG.md](CHANGELOG.md) and back up first. Run the new standalone script's
`repair` from the checkout to replace the persisted helper; invoking an old
installed helper still invokes the old unsafe code. Legacy `.env` state is parsed
as literal data, never sourced. Valid identities and all clients in the first
managed inbound are preserved; state/config disagreements are rejected. Odd-length
shortIds were invalid upstream and are rejected rather than silently rewritten.
Bash `printf %q` names, including octal UTF-8 escapes, migrate without executing
shell code. Unsupported shell expressions are rejected.
Migration preserves the deployed bind address, including the original IPv4-only
listener. Conflicting saved listener ports, SNI, target or transport credentials
cause refusal before activation; reconcile them through your console first.
Profiles without `LISTEN_ADDRESS` inherit the deployed binding; an explicit
new value remains available when you intend to change address families.

The active paths are now `/etc/xray/current/config.json` and
`/etc/xray/current/state.json`. The legacy files are retained for comparison and
are no longer authoritative. New profiles are under `current/options.json`;
pass a separate edited profile with `--profile-json`. Legacy host-wide firewall,
SSH, apt, Nginx and fail2ban changes cannot be safely distinguished from later
administrator changes: migration does not automatically undo or reapply them.
Review them through your provider console. Credentials remain stable, but the
new service account and removal of misleading HTTP fallbacks change service
architecture. Clients using `publicKey`/TCP aliases should continue to work;
new Xray exports use `password` and RAW. Only real validation can establish
compatibility with an arbitrary pinned release.

## Development and validation

Edit `lib/` and rebuild with `bash scripts/build.sh`. The standalone artifact is
committed and checked for reproducibility. Run `bash scripts/check.sh` with
ShellCheck, shfmt, Bats 1.5+, jq and Python installed. See [docs/TESTING.md](docs/TESTING.md)
for real protocol tests, disposable VM tests and the exact coverage gaps.
[docs/AUDIT.md](docs/AUDIT.md) records the initial audit and design rationale.
