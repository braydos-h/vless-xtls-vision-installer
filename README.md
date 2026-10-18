# 🚀 VLESS + REALITY + XTLS Vision Installer
### The Best Xray Installer Script You'll Find.

[![License: GPL-3.0-only](https://img.shields.io/badge/License-GPL--3.0--only-blue.svg)](LICENSE)
![OS: Debian 12/13, Ubuntu 22.04/24.04](https://img.shields.io/badge/OS-Debian%2012%2F13%20%7C%20Ubuntu%2022.04%2F24.04-2f6feb)
![Bash](https://img.shields.io/badge/Bash-5%2B-121011?logo=gnubash)
![Xray-core](https://img.shields.io/badge/Xray-core%20installer%20%26%20manager-0b7285)
[![GitHub last commit](https://img.shields.io/github/last-commit/braydos-h/vless-xtls-vision-installer)](https://github.com/braydos-h/vless-xtls-vision-installer/commits/main)

A security-focused, recoverable installer and lifecycle manager for a single Xray deployment using VLESS + REALITY + `xtls-rprx-vision`. It emphasizes safe activation, controlled host impact, and operational maintainability: strict profile validation, immutable deployment generations, atomic rollouts, rollback/recovery workflows, and explicit (not silent) hardening operations.

This project is designed to be practical for both first-time setup and long-term administration. It does **not** claim guaranteed censorship bypass, anonymity, universal DPI resistance, or universal client compatibility.

## ⚡ Quick Install

```bash
git clone https://github.com/braydos-h/vless-xtls-vision-installer.git
cd vless-xtls-vision-installer
sudo bash xray_reality_bootstrap.sh preflight
sudo bash xray_reality_bootstrap.sh install
```

> [!IMPORTANT]
> New-install support targets are Debian 12/13 and Ubuntu 22.04/24.04 (apt + systemd PID 1; amd64/arm64/armv7). See [Supported operating systems](#supported-operating-systems) and [Installation walkthrough](#installation-walkthrough).

After installation, the helper is available at `/usr/local/sbin/xray-reality-bootstrap`:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap diagnose
sudo /usr/local/sbin/xray-reality-bootstrap list-clients
sudo /usr/local/sbin/xray-reality-bootstrap export-client reality-main
```

## Table of Contents

- [⚡ Quick Install](#-quick-install)
- [Why Choose This Installer?](#why-choose-this-installer)
- [Features and capabilities](#features-and-capabilities)
- [Supported operating systems](#supported-operating-systems)
- [How REALITY + XTLS Vision works](#how-reality--xtls-vision-works)
- [Installation walkthrough](#installation-walkthrough)
- [Client management](#client-management)
- [Automated and advanced configuration](#automated-and-advanced-configuration)
- [Security architecture](#security-architecture)
- [Firewall and SSH hardening](#firewall-and-ssh-hardening)
- [Updating Xray](#updating-xray)
- [Backups, rollback, and recovery](#backups-rollback-and-recovery)
- [Diagnostics and troubleshooting](#diagnostics-and-troubleshooting)
- [FAQ](#faq)
- [Technical documentation](#technical-documentation)
- [License and acknowledgements](#license-and-acknowledgements)

## Why Choose This Installer?

- **Safer operations by design:** strict JSON/profile validation before activation, operation locking, automatic backups, durable journals, and rollback/recovery workflows.
- **Low host blast radius:** Xray runs as a dedicated restricted account, with least-privilege capability and systemd hardening.
- **Explicit host-impact controls:** firewall, SSH hardening, fail2ban, unattended upgrades, and optional loopback Nginx diagnostics are opt-in.
- **Operational lifecycle included:** install, update, client rotation/export, diagnostics, repair, backup, restore, and controlled uninstall.
- **Automation ready:** profile-driven non-interactive install with schema checks and dry-run planning.

## Features and capabilities

| Area | What it provides |
|---|---|
| Deployment safety | Versioned JSON state, validation before activation, immutable generations, atomic `current` symlink switch |
| Client lifecycle | `add-client`, `remove-client`, `list-clients`, `show-client`, `rotate-client`, `export-client`, `reprint` |
| Credential rotation | `rotate-shortid --migration-window SECONDS` + explicit `finalize-shortid` |
| Firewall behavior | Additive-only management (`table inet xray_bootstrap` for nftables, tagged additive rules for active UFW) |
| SSH controls | Separate `harden-ssh` / `restore-ssh` transaction with fresh-session confirmation |
| Update controls | Pinning, prerelease opt-in, release metadata checks, SHA-256 integrity checks, archive safety checks |
| Recovery toolkit | `backup`, `list-backups`, `restore`, `recover`, `repair`, `uninstall --yes` |
| Diagnostics | Structured redacted `status` / `diagnose`, plus optional end-to-end `test-client` |

> [!WARNING]
> REALITY shortIds are a **global accepted set** and are **not** cryptographically bound to individual UUIDs.

## Supported operating systems

Supported new-install targets:

- Debian 12, Debian 13
- Ubuntu 22.04, Ubuntu 24.04
- apt-based hosts with systemd as PID 1
- Architectures: `amd64`, `arm64`, `armv7`

These are support targets, **not** a claim that every target was fully runtime-tested in the same workspace. See [docs/TESTING.md](docs/TESTING.md) for precise validation scope.

Required tools used by the installer include Bash, Python 3, jq, OpenSSL, curl, util-linux, and iproute2. Git is required for checkout. Real install can bootstrap missing Python/jq and installs only missing selected dependencies; read-only commands do not install packages.

## How REALITY + XTLS Vision works

This installer configures VLESS over REALITY with:

- Flow: `xtls-rprx-vision`
- Transport: RAW/TCP
- Target/SNI probing that requires TLS 1.3, X25519, trusted certificate hostname match, and `h2`

Unauthenticated REALITY handshakes forward to the configured TLS target endpoint. `FALLBACK_PORT` is an alternate REALITY listener, not a separate bypass mode.

> [!CAUTION]
> Do not treat this as a guarantee of anonymity, censorship bypass, or universal DPI resistance.

## Installation walkthrough

### 1) Preflight and install

```bash
sudo bash xray_reality_bootstrap.sh preflight
sudo bash xray_reality_bootstrap.sh install
```

### 2) Understand defaults

Default behavior changes Xray only. By default:

- `FIREWALL_STYLE=none`
- `XRAY_UPDATE_POLICY=manual`
- `BLOCK_PRIVATE_OUTBOUND=yes` (application-level routing rules)
- `OS_PRIVATE_OUTBOUND=no` (no OS-level UID egress filter)
- `LISTEN_ADDRESS=::` (Linux usually accepts IPv4 too)

If IPv6 is unavailable, use `LISTEN_ADDRESS=0.0.0.0` in your profile.

### 3) Initial validation and export

```bash
sudo /usr/local/sbin/xray-reality-bootstrap diagnose
sudo /usr/local/sbin/xray-reality-bootstrap export-client reality-main
sudo /usr/local/sbin/xray-reality-bootstrap show-client reality-main
```

Exports are generated under `/root/xray-client-configs` (directory mode `700`, file mode `600`). `PUBLIC_IP` must be explicitly configured for usable exports. `qrencode` is optional and must be installed separately to generate QR files.

## Client management

```bash
sudo /usr/local/sbin/xray-reality-bootstrap add-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap remove-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap list-clients
sudo /usr/local/sbin/xray-reality-bootstrap show-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap rotate-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap export-client 'Alice laptop'
sudo /usr/local/sbin/xray-reality-bootstrap reprint
```

Global shortId rotation workflow:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap rotate-shortid --migration-window 604800
sudo /usr/local/sbin/xray-reality-bootstrap finalize-shortid
```

`show-client` prints credentials intentionally. Normal operations redact credentials.

## Automated and advanced configuration

Use `examples/profile.json` for reproducible installs:

```bash
sudo bash xray_reality_bootstrap.sh install --auto --non-interactive \
  --profile-json examples/profile.json --dry-run

sudo bash xray_reality_bootstrap.sh install --auto --non-interactive \
  --profile-json examples/profile.json --xray-version v26.3.27
```

Profile handling:

- Profile fields are strings.
- Unknown fields, duplicate keys, wrong types, and invalid values are rejected.
- Input must be UTF-8 JSON, regular file, max 2 MiB.
- Format `2` is current; valid legacy format `1` is normalized.

<details>
<summary><strong>Migration / legacy note (version 1)</strong></summary>

For version 1 deployments, read [CHANGELOG.md](CHANGELOG.md) and run `repair` with the new standalone script before normal lifecycle operations. Migration preserves valid identities/clients where state and config agree, rejects unsafe inconsistencies, and keeps legacy files for review rather than treating them as authoritative.

```bash
sudo bash xray_reality_bootstrap.sh repair
```

</details>

## Security architecture

Xray runs as dedicated `xray-bootstrap` with no login shell/home, with only `CAP_NET_BIND_SERVICE`. The service unit applies restrictions including read-only system filesystem, private temp, protected home/control groups/kernel settings, restricted namespaces/devices/SUID/realtime, memory W^X protection, limited address families, and writable logs only.

Deployment/state model includes strict versioned JSON, pre-activation validation, immutable generations, atomic pointer switch, operation locking, automatic backups, durable journals, rollback/recovery, and root-only secrets/state/backups/exports/logs.

> [!NOTE]
> These controls reduce blast radius. They are not a security guarantee and do not replace host hardening, patching, or access control.

## Firewall and SSH hardening

### Firewall behavior

- Never flushes rules, resets UFW, changes default policy, disables a firewall manager, or edits `/etc/nftables.conf`.
- Keeps Docker/VPN/fail2ban tables untouched.
- nftables ownership is limited to `table inet xray_bootstrap`.
- UFW rules are added only when UFW is already active, and only with installer tags.
- Rejects firewalld conflicts.

Transitions are validated before activation and require `confirm-host` in a fresh session within 180 seconds, or rollback occurs automatically:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap confirm-host
```

`repair` and `firewall-sync` are available for reconciliation.

### SSH hardening (explicit operation)

SSH hardening is a separate action using only `/etc/ssh/sshd_config.d/00-xray-bootstrap.conf`.

```bash
sudo /usr/local/sbin/xray-reality-bootstrap harden-ssh \
  --profile-json /root/ssh-profile.json --key-login-confirmed

sudo /usr/local/sbin/xray-reality-bootstrap restore-ssh
```

It retains original ports, validates with `sshd -t` and effective `sshd -T`, and requires fresh key-login confirmation before password auth is disabled.

> [!WARNING]
> Keep provider console access and your current working session while performing firewall/SSH transitions.

> [!IMPORTANT]
> Cloud/provider firewall policy is still the administrator's responsibility.

## Updating Xray

```bash
sudo /usr/local/sbin/xray-reality-bootstrap update
sudo /usr/local/sbin/xray-reality-bootstrap update --xray-version v26.3.27
```

Supports manual policy plus optional daily/weekly timer, version pinning, and prerelease opt-in. Update verification includes official GitHub release metadata, exact expected asset URL, advertised size, SHA-256 digest/checksum, archive safety checks, executable version check, and config-compatibility validation. Unpinned downgrade to older stable is skipped.

> [!NOTE]
> SHA-256 verification here provides integrity checking, not an independent publisher signature trust model.

## Backups, rollback, and recovery

```bash
sudo /usr/local/sbin/xray-reality-bootstrap backup
sudo /usr/local/sbin/xray-reality-bootstrap list-backups
sudo /usr/local/sbin/xray-reality-bootstrap restore BACKUP_ID
sudo /usr/local/sbin/xray-reality-bootstrap recover
sudo /usr/local/sbin/xray-reality-bootstrap repair
sudo /usr/local/sbin/xray-reality-bootstrap uninstall --yes
```

Backups contain live secrets and are not encrypted. Keep encrypted trusted off-server copies and never post backups, exports, or raw logs publicly.

Uninstall intentionally retains backups, credentials, exports, helper, and the service account for recovery. If managed SSH exists, restore it first and confirm the transition.

## Diagnostics and troubleshooting

`status` and `diagnose` emit structured redacted JSON for service/config/listeners/runtime identity/optional local site/firewall/timer/pending transition checks. They do **not** prove external connectivity.

Optional end-to-end test:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap test-client reality-main \
  --test-url https://www.cloudflare.com/cdn-cgi/trace
```

| Symptom | Check |
|---|---|
| Client timeout | Verify host + cloud firewall, public endpoint, server clock, and REALITY target/SNI settings |
| Probe/handshake failure | Confirm target supports TLS 1.3 + X25519 + h2 and certificate hostname match |
| Exports unusable | Set `PUBLIC_IP` explicitly, then re-run export/reprint |
| Firewall transition stuck | Use fresh-session `confirm-host` or run `recover` after interrupted transition |
| Private egress breaks name resolution | Re-check DNS resolver reachability and whether OS-level egress mode is required |

## FAQ

**Do I need to buy a domain/certificate for the proxy server?**  
No. REALITY SNI points to the TLS target used for camouflage probing. Clients can use your server public IP when `PUBLIC_IP` is set appropriately.

**Does this provide guaranteed censorship bypass or anonymity?**  
No. Deployment quality improves safety and recoverability, but there is no universal bypass/anonymity guarantee.

**Does private-route blocking isolate the whole host?**  
No. Application-level routing applies to proxy traffic. Host-level isolation requires separate controls (for example, optional UID-scoped nftables egress) and still has limitations.

**Can I rely on testing claims as production guarantees?**  
No. Current documented results are specific: 18 Python tests + 44 Bats tests passed in implementation workspace; real amd64 Xray `v26.3.27` and `v26.10.10` protocol tests passed; Debian 12 and Ubuntu 24.04 disposable amd64 lifecycle phases passed; Debian 13, Ubuntu 22.04, and ARM runtime integration remain locally unverified; hosted workflows were not executed in that workspace; no production VPS was modified.

## Technical documentation

- [docs/TESTING.md](docs/TESTING.md)
- [docs/AUDIT.md](docs/AUDIT.md)
- [CHANGELOG.md](CHANGELOG.md)
- [examples/profile.json](examples/profile.json)
- [scripts/build.sh](scripts/build.sh) — rebuild standalone artifact from `lib/`
- [scripts/check.sh](scripts/check.sh) — syntax + ShellCheck + shfmt + Python tests + Bats + JSON/profile validation + py_compile + reproducibility + docs/link/command checks

Upstream references:

- [XTLS REALITY](https://github.com/XTLS/REALITY)
- [Xray routing strategy](https://xtls.github.io/en/config/routing.html)
- [Xray Freedom outbound](https://xtls.github.io/en/config/outbounds/freedom.html)

## License and acknowledgements

Licensed under [GPL-3.0-only](LICENSE).

This project is a security/operations overhaul of the original installer by `braydos-h`, with updated deployment safety, host coexistence, lifecycle tooling, and validation coverage.
