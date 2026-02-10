# VLESS + REALITY + XTLS Vision Bootstrap Installer

A production-oriented **single-file Bash installer** for deploying **Xray-core** with **VLESS + REALITY + XTLS Vision** on a fresh Linux VPS.

This project is for operators who want a setup that is:
- fast to deploy,
- repeatable to re-run,
- opinionated on security hardening,
- and easy to maintain over time.

---

## What this installer does

`xray_reality_bootstrap.sh` handles a full lifecycle:

- interactive install + reconfiguration wizard,
- Xray install/update/repair workflows,
- REALITY key + UUID + shortId management,
- generated client outputs (URI, JSON, QR),
- firewall + SSH hardening integration,
- optional fail2ban and unattended upgrades,
- optional scheduled Xray updates via systemd timer,
- diagnostics/status/reprint/shortId rotation operations.

Supported modes:

```bash
install | update | repair | status | diagnose | reprint | rotate-shortid | uninstall
```

---

## Why use this vs other approaches?

There are many ways to deploy Xray. This repo sits in the middle ground between "manual config editing" and "full control panel stack."

| Approach | Pros | Cons | Best for |
|---|---|---|---|
| Manual Xray setup (raw docs + hand editing) | Maximum control, minimal abstraction | Easy to miss hardening steps; slower repeatability | Experts who want total manual control |
| Xray panel/web UI ecosystems | Friendly UX; multi-user management | More moving parts (DB, web panel, extra services), larger attack surface | Commercial/multi-tenant operations |
| **This script (single Bash bootstrap)** | Fast, transparent, no panel dependency, repeatable operations, built-in hardening workflow | Single-node/operator focused, Linux + root oriented, opinionated defaults | Self-hosters, small teams, infra engineers |

### Practical comparison highlights

- **Compared to manual setup:** you get safer defaults and fewer "forgot to configure X" mistakes.
- **Compared to heavy panel stacks:** you keep operational footprint small and close to upstream Xray behavior.
- **Compared to copy-paste scripts:** this one includes maintenance commands (`repair`, `diagnose`, `reprint`, `rotate-shortid`) for day-2 operations.

---

## Requirements

- Debian/Ubuntu-like host with `systemd`
- root privileges (`sudo -i` or `sudo bash ...`)
- public VPS/IP and a domain you control
- DNS A/AAAA record pointed to your server
- outbound network access to install packages and download Xray

> The script is intended for fresh hosts and will apply system-level changes (firewall, SSH hardening choices, services).

---

## Quick start

```bash
# 1) Clone or copy this repository to the server
cd /root
git clone <your-fork-or-this-repo-url> vless-xtls-vision-installer
cd vless-xtls-vision-installer

# 2) Run installer
sudo bash xray_reality_bootstrap.sh install
```

Then follow the wizard prompts.

---

## Wizard flow (what you will be asked)

The installer asks for:

1. **ServerName + DEST endpoint** (REALITY camouflage target)
2. **Primary listen port + optional fallback port**
3. **Firewall style** (`nftables` or `ufw`)
4. **SSH hardening options** (port change, password auth toggle)
5. **Update policy** (OS unattended upgrades + Xray manual/weekly/daily)
6. **Logging profile** (`minimal` or `verbose`)
7. **Client profile naming + shortId count + private IP egress policy**

It also validates DEST reachability/TLS viability before finalizing configuration.

---

## Commands you will use after install

From the repository copy:

```bash
sudo bash xray_reality_bootstrap.sh status
sudo bash xray_reality_bootstrap.sh diagnose
sudo bash xray_reality_bootstrap.sh update
sudo bash xray_reality_bootstrap.sh repair
sudo bash xray_reality_bootstrap.sh reprint
sudo bash xray_reality_bootstrap.sh rotate-shortid
sudo bash xray_reality_bootstrap.sh uninstall
```

After first install, the script also persists itself as:

```bash
sudo /usr/local/sbin/xray-reality-bootstrap <mode>
```

---

## Generated client files

Client artifacts are written to:

```bash
/root/xray-client-configs
```

Typical outputs include:
- primary/fallback `vless://` URI text files,
- v2rayN / v2rayNG JSON,
- sing-box JSON (plus Apple-client compatible copy),
- shortId list,
- summary text,
- QR text/PNG (when `qrencode` is available).

Keep these files secret. They include credentials and connection metadata.

---

## Security and ops notes

- The script is opinionated but still requires operator judgment.
- Test SSH access in a second session before confirming SSH hardening changes.
- Back up `/etc/xray` and client artifacts before major changes.
- Prefer `diagnose` before troubleshooting manually.
- Use `rotate-shortid` periodically if your threat model benefits from routine identifier rotation.

---

## Common workflow examples

### 1) Initial deployment

```bash
sudo bash xray_reality_bootstrap.sh install
```

### 2) Weekly maintenance check

```bash
sudo bash xray_reality_bootstrap.sh status
sudo bash xray_reality_bootstrap.sh diagnose
```

### 3) Update Xray binary safely

```bash
sudo bash xray_reality_bootstrap.sh update
```

### 4) Regenerate/share client exports without changing secrets

```bash
sudo bash xray_reality_bootstrap.sh reprint
```

### 5) Rotate REALITY shortIds only

```bash
sudo bash xray_reality_bootstrap.sh rotate-shortid
```

---

## Troubleshooting

If clients fail to connect:

1. Run:
   ```bash
   sudo bash xray_reality_bootstrap.sh diagnose
   ```
2. Check service logs:
   ```bash
   sudo journalctl -u xray -xe --no-pager
   ```
3. Validate config:
   ```bash
   sudo /usr/local/bin/xray -test -config /etc/xray/config.json
   ```
4. Confirm domain/DNS, destination endpoint correctness, and firewall rules.

---

## Who this project is ideal for

- operators comfortable with Linux shell,
- users who want a transparent script (not a black-box panel),
- people running one/few nodes and valuing reproducibility.

If you need large-scale user lifecycle management, billing, role-based access, and dashboard workflows, you may outgrow this model and prefer a full management platform.

---

## License

MIT (see `LICENSE`).
