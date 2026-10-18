# Validation and coverage

Run all local static and unit checks:

```bash
bash scripts/check.sh
```

This runs Bash syntax, ShellCheck, shfmt, Python data tests, Bats operation tests,
JSON profile validation, Python compilation, standalone build reproducibility,
and local Markdown-link/command checks. Tests use temporary paths. Bats service,
firewall and timer commands are mocked to exercise failure handling without
altering the host. Such tests do not prove kernel/systemd/SSH integration.

Run actual Xray protocol tests with an official, verified executable:

```bash
bash scripts/fetch-test-xray.sh v26.3.27 /tmp/xray-test
python3 tests/integration/protocol.py /tmp/xray-test/unpack/xray
```

The protocol fixture starts real Xray server/client processes and local TLS, DNS
and HTTP endpoints on ephemeral loopback ports. It tests VLESS + REALITY + Vision,
unauthenticated TLS forwarding to the target, multiple clients, UUID revocation,
shortId overlap/finalization, alternate-listener exports, address-family fallback,
and IPv4/IPv6/mapped-IP/private-DNS blocking with successful unfiltered controls. New
Freedom finalRules are tested separately on releases with that feature. These
are process/protocol integration tests; they do not run the host installer or
establish service-manager or firewall safety.

## Disposable VM lifecycle suite

Never run `vm-suite.sh` on a normal host. It requires a marker seeded only by the
VM launcher. Use verified official cloud images and disposable overlay disks:

```bash
# Dependencies on the test machine: qemu-system-x86, qemu-utils,
# cloud-image-utils, openssh-client, util-linux, curl, jq, Python 3.
bash tests/integration/fetch-image.sh debian12 /tmp/xray-cloud
bash tests/integration/run-vm.sh /tmp/xray-cloud/disk.qcow2
```

Image options: `debian12`, `debian13`, `ubuntu2204`, `ubuntu2404`, `ubuntu2604`. Downloads use
upstream HTTPS/checksums. QEMU uses TCG by default (slow but no KVM requirement);
set `VM_ACCEL=kvm` only on an isolated runner with KVM access. On small test hosts,
set `VM_MEMORY_MB=768` and run guests sequentially. Networking uses
QEMU user networking and loopback SSH forwarding, not host firewall modification.
The guest has its own systemd, kernel and privileged firewall operations. SSH
keys and disks are temporary. Private VM console logs, keys and disks are not
uploaded as CI artifacts; workflow logs contain redacted operation output.

The guest suite exercises fresh/automatic/repeated install, repair, real pinned
updates and skipping, runtime activation failure/rollback, client management,
rotation, backup/restore, actual service permissions, end-to-end requests,
Nginx/fail2ban opt-in and opt-out, an actual scheduled updater invocation,
administrator apt-policy refusal, legacy migration,
nftables and UFW coexistence, SSH migration/confirmation/restoration and
uninstall. Timed expiry paths are included separately from explicit confirmation.
It is intentionally manual CI (`workflow_dispatch`, `vm_tests=true`) and does
not execute privileged guest workloads from arbitrary pull requests.

Static/unit and process/protocol jobs run on every push and PR. The five-OS VM
matrix runs only when explicitly dispatched. The automated suites currently use
amd64. arm64/armv7 release selection is supported but full runtime integration
must be checked on those architectures separately.

## Ubuntu 26.04 repair validation (2026-10-18)

- `bash scripts/check.sh`: 18 Python tests and 67 Bats tests passed in isolated
  Alpine and Ubuntu 26.04 WSL2 guests. Bash syntax, ShellCheck (including Ubuntu's
  newer indirect-mock checks), shfmt, JSON examples, Python compilation,
  generated standalone reproducibility and documentation checks passed.
- New regressions cover all five supported releases; unsupported OS/architecture;
  root/non-root; missing dependencies; storage/systemd/IPv6 failures; free,
  occupied, uninspectable and managed listeners; invalid profiles; matching Apple
  SNI/target; actual interactive wizard input through a pseudo-terminal; clean
  standalone/install validation exits; DNS/TLS/ALPN/timeouts; download/package/
  systemd exit codes; and original-error preservation through rollback.
- Canonical Ubuntu 26.04 amd64 base rootfs SHA-256 was verified as
  `046fcabb7f16f45a80ae11824664f2a07e01386c6fb1ed9dc1e225a66a6553a2`.
  The disposable guest used systemd 259 as PID 1, Python 3.14.4, OpenSSL 3.5.5,
  iproute2 6.19, and util-linux 2.41.3 from Ubuntu repositories.
- Actual `preflight` with no options returned 0. Preflight using
  `examples/ubuntu2604.json --network-check` also returned 0; Apple DNS and
  verified TLS 1.3/X25519/h2 succeeded from that environment.
- Actual `install --auto --non-interactive --profile-json examples/ubuntu2604.json
  --xray-version v26.3.27` completed. Xray reported `Configuration OK`, systemd
  reported the service active, `ss` showed its port 443 listener, and `diagnose`
  returned all health checks true with no pending transaction.
- Repeating installation preserved identity, clients, short IDs and rotation
  state. `systemd-analyze verify` passed. Managed firewall, SSH and apt-upgrade
  policy files and the automatic-update timer remained absent with default
  policies. Injecting a candidate that passes syntax checks but exits at runtime
  restored the previous generation and active listener with `ROLLED_BACK`.
- Real Xray `v26.3.27` and `v26.10.10` passed the existing process/protocol suite:
  `bash scripts/fetch-test-xray.sh VERSION /tmp/xray-test`, then
  `python3 tests/integration/protocol.py /tmp/xray-test/unpack/xray`.

The Ubuntu installation checks used a disposable WSL2 guest, not a fresh VPS or
an independent QEMU kernel. The expanded five-OS QEMU/hosted CI matrix was not
run in this repair session. Provider firewall and external client connectivity
still require verification on the target VPS. No production VPS was modified.

## Prior implementation results

- 18 Python test methods and 44 Bats tests passed, including real error-code
  propagation, lock contention, failed activation recovery, durable journals,
  symlink rejection, bounded JSON/FIFO input handling, checksum failure,
  insufficient space, rule ownership, delayed fail2ban readiness, service-unit
  rollback, private recovery workspaces, delayed SSH listener ownership,
  legacy bind-address preservation, skipped-update backup behavior and large UFW status output under
  pipefail. The complete check script also passed from a temporary project copy
  owned by `nobody`, without root privileges.
- Real amd64 Xray `v26.3.27` and `v26.10.10` binaries passed the protocol tests.
  `v26.3.27` archive matched API SHA-256
  `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae`.
  `v26.10.10` matched
  `72a5fde819713a103c6fc26a87aa025c1518c918a34eba4bc38d64dc0728e5d9`.
  The latter was an upstream prerelease and required explicit installer opt-in.
- Static checks and standalone reproducibility were run locally; see the final
  implementation report for exact commands and final counts.
- Debian 12 was exercised in a disposable amd64 QEMU guest with its own systemd
  and kernel. Fresh/repeated installation, repair, pinned updates, failed runtime
  activation recovery, client operations, backup/restore, low-port binding,
  Nginx/fail2ban, scheduled update execution, nftables timed rollback, IPv4/IPv6
  UID egress, UFW coexistence, SSH precedence refusal/migration/restoration and
  legacy identity preservation passed. Development failures were fixed and
  affected phases rerun using the retained disposable overlay. A full clean
  four-OS matrix is not claimed.
- An unconfirmed SSH transition also rolled back automatically after a test
  pipeline aborted; fresh access on the original port and the primary config
  checksum were verified afterward.
- Ubuntu 24.04 passed the same main lifecycle phases in a separate disposable
  amd64 QEMU guest, including actual nftables expiry/recovery, dual-family UID
  egress enforcement, UFW administrator-rule preservation, SSH precedence refusal,
  fresh key login on the additional port, confirmation and restoration, legacy
  identity/IPv4-binding preservation and uninstall. Fresh-process recovery also
  restored its owned nftables snapshot without touching an unrelated root-path
  sentinel. Removing an optional Nginx file while Nginx was stopped passed.
  Development runs resumed retained overlays after fixes; this is not an
  uninterrupted clean run of the final launcher. Slow TCG recovery required a
  longer harness deadline, and HTTP fixture readiness now uses polling.
- Debian 13, Ubuntu 22.04 and ARM runtime integration remain unverified locally.
  The hosted GitHub Actions workflows have not been executed in this workspace.
- No real production VPS, SSH service, firewall ruleset, apt policy or systemd
  service was modified during implementation.

Coverage still requires remaining distribution/architecture runs. Actual Docker
and VPN engines were not exercised; coexistence tests preserve unrelated firewall
tables/rules. No suite proves all DNS-rebinding/translation arrangements,
third-party GUI client import formats, cloud-firewall behavior or universal
camouflage.
