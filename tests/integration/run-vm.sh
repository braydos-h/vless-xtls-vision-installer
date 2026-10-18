#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# The disk image must be downloaded and checksum-verified before this script.
set -Eeuo pipefail
umask 077
image=${1:?path to verified cloud disk image required}
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
for tool in qemu-system-x86_64 qemu-img cloud-localds ssh-keygen ssh python3 setsid; do command -v "$tool" >/dev/null; done
work=$(mktemp -d)
vm_pid=''
port=''
new_port=''
cleanup() {
  local rc=$?
  if ((rc != 0)) && [[ ${KEEP_FAILED_VM:-0} == 1 ]]; then
    printf '%s\n' "$port" >"$work/ssh-port"
    printf '%s\n' "$new_port" >"$work/new-ssh-port"
    printf '%s\n' "$vm_pid" >"$work/vm-pid"
    printf 'Failed VM retained for private debugging: %s\n' "$work" >&2
    exit "$rc"
  fi
  if ((rc != 0)); then
    [[ ! -f $work/qemu.log ]] || tail -n 20 "$work/qemu.log" >&2
    [[ ! -f $work/console.log ]] || tail -n 20 "$work/console.log" >&2
  fi
  if [[ -n $vm_pid ]] && kill -0 "$vm_pid" 2>/dev/null; then
    kill "$vm_pid"
    wait "$vm_pid" || :
  fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
new_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat >"$work/user-data" <<EOF
#cloud-config
users:
  - name: root
    ssh_authorized_keys:
      - $(cat "$work/key.pub")
disable_root: false
ssh_pwauth: false
write_files:
  - path: /root/.xray-disposable-test-vm
    permissions: '0600'
    content: DISPOSABLE_XRAY_TEST_VM
EOF
printf 'instance-id: xray-test-%s\nlocal-hostname: xray-test\n' "$port" >"$work/meta-data"
cloud-localds "$work/seed.img" "$work/user-data" "$work/meta-data"
qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$image")" "$work/disk.qcow2" 12G
# A separate session keeps KEEP_FAILED_VM useful when the invoking terminal
# closes. Normal cleanup still terminates and waits for this child.
setsid qemu-system-x86_64 -accel "${VM_ACCEL:-tcg}" -m "${VM_MEMORY_MB:-2048}" -smp 2 -display none \
  -drive "file=$work/disk.qcow2,if=virtio,format=qcow2" -drive "file=$work/seed.img,if=virtio,format=raw" \
  -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22,hostfwd=tcp:127.0.0.1:$new_port-:2222" \
  -serial "file:$work/console.log" >"$work/qemu.log" 2>&1 &
vm_pid=$!
ssh_args=(-i "$work/key" -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work/known_hosts" -o ConnectTimeout=15)
remote() { ssh "${ssh_args[@]}" -p "$port" root@127.0.0.1 "$@"; }
ready=false
for ((i = 0; i < 180; i++)); do
  kill -0 "$vm_pid" || exit 1
  if remote 'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null; then
    ready=true
    break
  fi
  sleep 5
done
[[ $ready == true ]]
remote 'cloud-init status --wait; mkdir -p /root/project'
tar -C "$project" --exclude=__pycache__ -cf - LICENSE README.md CHANGELOG.md .gitattributes .gitignore .shellcheckrc .github examples lib scripts src tests docs xray_reality_bootstrap.sh | remote 'tar -xf - -C /root/project'
remote 'bash /root/project/tests/integration/vm-suite.sh core'
remote 'bash /root/project/tests/integration/vm-suite.sh failed-activation'
remote 'bash /root/project/tests/integration/vm-suite.sh nft'
remote '/usr/local/sbin/xray-reality-bootstrap confirm-host'
remote 'bash /root/project/tests/integration/vm-suite.sh nft-expire'
# shellcheck disable=SC2016
# Allow the 180-second watchdog, bounded lock wait and slow TCG recovery.
remote 'for i in $(seq 1 180); do test -d /var/lib/xray-bootstrap/pending || exit 0; sleep 5; done; exit 1'
remote 'bash /root/project/tests/integration/vm-suite.sh verify-expiry'
remote 'bash /root/project/tests/integration/vm-suite.sh nft-repair'
remote '/usr/local/sbin/xray-reality-bootstrap confirm-host'
remote 'bash /root/project/tests/integration/vm-suite.sh nft-egress'
remote '/usr/local/sbin/xray-reality-bootstrap confirm-host'
remote 'bash /root/project/tests/integration/vm-suite.sh egress-check'
remote 'bash /root/project/tests/integration/vm-suite.sh clear-firewall'
remote '/usr/local/sbin/xray-reality-bootstrap confirm-host'
remote 'bash /root/project/tests/integration/vm-suite.sh ufw'
remote '/usr/local/sbin/xray-reality-bootstrap confirm-host'
remote 'bash /root/project/tests/integration/vm-suite.sh recovery-workspace'
remote 'bash /root/project/tests/integration/vm-suite.sh ssh'
ssh "${ssh_args[@]}" -p "$new_port" root@127.0.0.1 '/usr/local/sbin/xray-reality-bootstrap confirm-host --key-login-confirmed'
remote 'bash /root/project/tests/integration/vm-suite.sh restore-ssh'
remote '/usr/local/sbin/xray-reality-bootstrap confirm-host'
remote 'bash /root/project/tests/integration/vm-suite.sh uninstall'
remote 'bash /root/project/tests/integration/vm-suite.sh inactive-nginx'
remote 'bash /root/project/tests/integration/vm-suite.sh socket-transition'
remote 'sshd -t'
printf 'PASS: disposable VM lifecycle suite\n'
