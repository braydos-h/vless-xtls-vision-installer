#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Runs as root ONLY inside a disposable VM seeded by run-vm.sh.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 077
[[ $EUID == 0 && $(cat /root/.xray-disposable-test-vm) == DISPOSABLE_XRAY_TEST_VM ]] || exit 1
[[ $(cat /proc/1/comm) == systemd ]] || exit 1
cd /root/project
helper=/usr/local/sbin/xray-reality-bootstrap
wait_http_fixture() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if curl --noproxy '*' -gfsS --max-time 3 "$1" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  printf 'HTTP test fixture did not become ready: %s\n' "$1" >&2
  return 1
}
fixture_ssh_daemon() {
  # Guest-only preparation. Ubuntu's socket handoff can leave the listening
  # master outside systemd's MainPID tracking; KillMode=process then misses it.
  # Capture only port-22 listener PIDs, never established SSH session children.
  local pid attempt listeners
  mapfile -t listeners < <(ss -H -lntp 'sport = :22' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
  systemctl stop ssh.socket ssh.service
  for pid in "${listeners[@]}"; do
    if [[ $(readlink "/proc/$pid/exe" 2>/dev/null || :) == /usr/sbin/sshd ]]; then kill -TERM "$pid"; fi
  done
  for ((attempt = 0; attempt < 30; attempt++)); do
    [[ -n $(ss -H -lnt 'sport = :22') ]] || break
    sleep 1
  done
  [[ -z $(ss -H -lnt 'sport = :22') ]]
  systemctl disable ssh.socket
  systemctl enable ssh.service
  systemctl reset-failed ssh.service
  systemctl start ssh.service
  sshd -t
  bash -c 'source /root/project/xray_reality_bootstrap.sh; wait_ssh_listeners 22'
}
printf 'VM phase: %s\n' "${1:?phase required}"
case "${1:?phase required}" in
  core)
    python3 - >/root/profile.json <<'PYCODE'
import sys
sys.path.insert(0, 'lib')
import data
data.emit(data.profile({'PUBLIC_IP':'127.0.0.1', 'LISTEN_PORT':'443', 'LISTEN_ADDRESS':'::', 'XRAY_PIN':'v26.3.27'}))
PYCODE
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/profile.json
    jq '.identity,.clients,.short_ids' /etc/xray/current/state.json >/root/initial-credentials.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/profile.json
    jq '.identity,.clients,.short_ids' /etc/xray/current/state.json >/root/repeated-credentials.json
    cmp /root/initial-credentials.json /root/repeated-credentials.json
    "$helper" repair --non-interactive
    "$helper" status --json
    "$helper" update --xray-version v26.10.10 --allow-prerelease --non-interactive
    "$helper" update --xray-version v26.10.10 --allow-prerelease --non-interactive
    jq '.identity,.clients,.short_ids' /etc/xray/current/state.json >/root/updated-credentials.json
    cmp /root/initial-credentials.json /root/updated-credentials.json
    "$helper" add-client bob
    "$helper" export-client bob
    "$helper" rotate-client bob
    "$helper" remove-client bob
    "$helper" rotate-shortid --migration-window 0
    "$helper" finalize-shortid
    backup_id=$("$helper" backup)
    "$helper" add-client after-backup
    "$helper" restore "$backup_id"
    [[ $("$helper" list-clients | jq length) == 1 ]]
    bash "$0" core-verify
    ;;
  core-verify)
    "$helper" reprint
    "$helper" test-client reality-main --test-url https://www.cloudflare.com/cdn-cgi/trace
    systemd-analyze verify /etc/systemd/system/xray.service
    systemd-analyze security --no-pager xray.service >/root/systemd-security.txt
    [[ $(stat -c %a /etc/xray/current/state.json) == 600 ]]
    [[ $(stat -c %a /etc/xray/current/config.json) == 640 ]]
    if runuser -u xray-bootstrap -- test -r /etc/xray/current/state.json; then exit 1; fi
    runuser -u xray-bootstrap -- test -r /etc/xray/current/config.json
    ;;
  failed-activation)
    previous=$(readlink /etc/xray/current)
    # Candidate passes real syntax checks but exits on runtime activation.
    cat >/root/fail-activation.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/project/xray_reality_bootstrap.sh
init_paths
MODE=test
setup_traps
lock_operation
load_deployment
real=$(readlink -f "$CURRENT/xray")
reuse_candidate
candidate=$WORK/fault-injection
mkdir "$candidate"
printf '#!/usr/bin/env bash\ncase "$*" in *-test*|x25519*|version) exec %q "$@";; *) exit 23;; esac\n' "$real" >"$candidate/xray"
chmod 755 "$candidate/xray"
CANDIDATE=$candidate
stage_generation
activate_generation
commit_transaction
EOF
    if bash /root/fail-activation.sh; then
      echo 'Expected activation failure' >&2
      exit 1
    fi
    [[ $(readlink /etc/xray/current) == "$previous" ]]
    "$helper" diagnose
    bash "$0" host-extras
    ;;
  host-extras)
    jq '.options | .CAMOUFLAGE_ENABLED="yes" | .FAIL2BAN_ENABLED="yes" | .XRAY_UPDATE_POLICY="weekly"' /etc/xray/current/state.json >/root/extras-profile.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/extras-profile.json
    [[ $(stat -c %U /var/log/xray) == root ]]
    if runuser -u xray-bootstrap -- touch /var/log/xray/unauthorized; then exit 1; fi
    curl -fsS http://127.0.0.1:18080/healthz | grep -x ok >/dev/null
    ss -H -lnt 'sport = :18080' | grep '127.0.0.1:18080' >/dev/null
    fail2ban-client status xray-bootstrap-sshd
    systemctl is-active --quiet xray-update.timer
    jq '.identity,.clients,.short_ids' /etc/xray/current/state.json >/root/before-timer-credentials.json
    systemctl start xray-update.service
    [[ $(systemctl show -p Result --value xray-update.service) == success ]]
    jq '.identity,.clients,.short_ids' /etc/xray/current/state.json >/root/after-timer-credentials.json
    cmp /root/before-timer-credentials.json /root/after-timer-credentials.json
    "$helper" diagnose
    jq '.options | .CAMOUFLAGE_ENABLED="no" | .FAIL2BAN_ENABLED="no" | .XRAY_UPDATE_POLICY="manual"' /etc/xray/current/state.json >/root/extras-off.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/extras-off.json
    [[ ! -f /etc/nginx/conf.d/xray-camouflage.conf && ! -f /etc/fail2ban/jail.d/xray-bootstrap.local ]]
    systemctl is-active --quiet fail2ban
    if systemctl is-active --quiet xray-update.timer; then exit 1; fi
    if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
      sha256sum /etc/apt/apt.conf.d/20auto-upgrades >/root/apt-policy-before.sha256
      jq '.options | .UNATTENDED_UPGRADES_ENABLED="yes"' /etc/xray/current/state.json >/root/apt-conflict.json
      if bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/apt-conflict.json; then exit 1; fi
      sha256sum -c /root/apt-policy-before.sha256
      [[ ! -f /etc/apt/apt.conf.d/52xray-bootstrap-upgrades ]]
    fi
    ;;
  nft)
    apt-get install -y nftables
    nft add table inet administrator_sentinel
    nft add chain inet administrator_sentinel input '{ type filter hook input priority 0; policy accept; }'
    jq '.options | .FIREWALL_STYLE="nftables"' /etc/xray/current/state.json >/root/nft-profile.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/nft-profile.json
    nft list table inet administrator_sentinel
    ;;
  nft-expire)
    readlink /etc/xray/current >/root/before-expiry.pointer
    jq '.options | .LISTEN_PORT="18444"' /etc/xray/current/state.json >/root/expire-profile.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/expire-profile.json
    ;;
  verify-expiry)
    [[ ! -d /var/lib/xray-bootstrap/pending ]]
    [[ $(readlink /etc/xray/current) == "$(cat /root/before-expiry.pointer)" ]]
    "$helper" diagnose
    nft list table inet administrator_sentinel
    ;;
  nft-repair)
    "$helper" repair
    nft list table inet administrator_sentinel
    ;;
  clear-firewall) "$helper" clear-firewall ;;
  ufw)
    apt-get install -y ufw
    ufw allow 22/tcp comment administrator-ssh
    ufw allow 2222/tcp comment administrator-ssh-migration
    ufw allow 19009/tcp comment administrator-sentinel
    ufw --force enable
    jq '.options | .FIREWALL_STYLE="ufw"' /etc/xray/current/state.json >/root/ufw-profile.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/ufw-profile.json
    ufw status | grep administrator-sentinel >/dev/null
    ;;
  ssh)
    sha256sum /etc/ssh/sshd_config >/root/ssh-before.sha256
    jq '.options | .SSH_HARDENING="yes" | .SSH_PORT="2222" | .CHANGE_SSH_PORT="yes" | .DISABLE_PASSWORD_AUTH="yes"' /etc/xray/current/state.json >/root/ssh-profile.json
    if systemctl is-active --quiet ssh.socket; then
      if "$helper" harden-ssh --profile-json /root/ssh-profile.json --key-login-confirmed; then exit 1; fi
      [[ ! -d /var/lib/xray-bootstrap/pending ]]
      fixture_ssh_daemon
    fi
    # An earlier administrator setting must cause refusal and rollback.
    printf 'PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/00-administrator-test.conf
    if "$helper" harden-ssh --profile-json /root/ssh-profile.json --key-login-confirmed; then exit 1; fi
    [[ ! -d /var/lib/xray-bootstrap/pending ]]
    grep -qx 'PasswordAuthentication yes' /etc/ssh/sshd_config.d/00-administrator-test.conf
    rm -f /etc/ssh/sshd_config.d/00-administrator-test.conf
    "$helper" harden-ssh --profile-json /root/ssh-profile.json --key-login-confirmed
    sshd -T | grep -x 'port 22' >/dev/null
    sshd -T | grep -x 'port 2222' >/dev/null
    sha256sum -c /root/ssh-before.sha256
    ;;
  recovery-workspace)
    # Exercise a fresh recovery process, rather than inheriting install's WORK.
    if nft list table inet xray_bootstrap >/dev/null 2>&1; then exit 1; fi
    printf 'administrator temporary-path sentinel\n' >/nft-batch
    cp /nft-batch /root/recovery-workspace.expected
    nft -f - <<'NFT'
table inet xray_bootstrap {
  comment "xray-reality-bootstrap managed"
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport 443 accept comment "recovery-baseline"
  }
}
NFT
    bash - <<'SHELL'
set -Eeuo pipefail
source /root/project/xray_reality_bootstrap.sh
init_paths
MODE=repair
setup_traps
lock_operation
workspace
begin_transaction
touch "$JOURNAL/pending/firewall-changed"
nft add rule inet xray_bootstrap input tcp dport 19099 accept comment recovery-extra
TX_ACTIVE=false
SHELL
    "$helper" recover
    cmp /nft-batch /root/recovery-workspace.expected
    nft list table inet xray_bootstrap >/root/recovered-table.nft
    grep recovery-baseline /root/recovered-table.nft >/dev/null
    if grep recovery-extra /root/recovered-table.nft; then exit 1; fi
    nft list table inet administrator_sentinel
    nft delete table inet xray_bootstrap
    rm /nft-batch /root/recovery-workspace.expected
    "$helper" diagnose
    ;;
  nft-egress)
    target_ip=$(getent ahostsv4 www.cloudflare.com | awk 'NR==1{print $1}')
    jq --arg target "$target_ip:443" '.options | .OS_PRIVATE_OUTBOUND="yes" | .DEST_ENDPOINT=$target' /etc/xray/current/state.json >/root/egress-profile.json
    bash xray_reality_bootstrap.sh install --auto --non-interactive --profile-json /root/egress-profile.json
    nft list chain inet xray_bootstrap output | grep 'skuid' >/dev/null
    ;;
  egress-check)
    systemd-run --unit=xray-test-private --collect python3 -m http.server 19001 --bind 127.0.0.1
    systemd-run --unit=xray-test-private6 --collect python3 -m http.server 19002 --bind ::1
    wait_http_fixture http://127.0.0.1:19001/
    wait_http_fixture 'http://[::1]:19002/'
    if runuser -u xray-bootstrap -- curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:19001/ >/dev/null; then exit 1; fi
    if runuser -u xray-bootstrap -- curl --noproxy '*' -gfsS --max-time 3 'http://[::1]:19002/' >/dev/null; then exit 1; fi
    systemctl stop xray-test-private xray-test-private6
    ;;
  restore-ssh) "$helper" restore-ssh ;;
  inactive-nginx)
    systemctl stop nginx
    printf '# Managed by xray-reality-bootstrap v2\n' >/etc/nginx/conf.d/xray-camouflage.conf
    bash - <<'SHELL'
set -Eeuo pipefail
source /root/project/xray_reality_bootstrap.sh
init_paths
MODE=repair
setup_traps
lock_operation
load_deployment
begin_transaction
configure_host_extras
commit_transaction
SHELL
    [[ ! -f /etc/nginx/conf.d/xray-camouflage.conf ]]
    if systemctl is-active --quiet nginx; then exit 1; fi
    ;;
  socket-transition)
    systemctl disable --now ssh.service
    systemctl enable --now ssh.socket
    # Accept=yes distributions use ssh@.service per connection instead.
    if [[ $(systemctl show -p Accept --value ssh.socket) == no ]]; then systemctl start ssh.service; fi
    systemctl is-active --quiet ssh.socket
    if "$helper" harden-ssh --profile-json /root/ssh-profile.json --key-login-confirmed; then exit 1; fi
    [[ ! -d /var/lib/xray-bootstrap/pending ]]
    fixture_ssh_daemon
    sha256sum -c /root/ssh-before.sha256
    ;;
  uninstall)
    "$helper" uninstall --yes --non-interactive
    nft list table inet administrator_sentinel
    ufw status | grep administrator-sentinel >/dev/null
    if systemctl is-active --quiet xray; then exit 1; fi
    [[ ! -f /etc/systemd/system/xray.service ]]
    [[ ! -f /etc/ssh/sshd_config.d/00-xray-bootstrap.conf ]]
    bash "$0" legacy
    ;;
  legacy)
    # Recreate the original on-disk format using real keys/config/binary.
    python3 - <<'PY'
import json, pathlib, shlex, shutil
root = pathlib.Path('/etc/xray')
s = json.loads((root / 'current/state.json').read_text())
cfg = json.loads((root / 'current/config.json').read_text())
for inbound in cfg['inbounds']:
    inbound['tag'] = 'vless-reality-primary' if inbound['tag'].endswith('primary') else 'vless-reality-fallback'
    inbound['listen'] = '0.0.0.0'
    inbound['streamSettings']['network'] = 'tcp'
    reality = inbound['streamSettings']['realitySettings']
    reality['dest'] = reality.pop('target')
values = {**s['options'], 'XRAY_VERSION':s['xray_version'], 'UUID':s['clients'][0]['id'],
          'REALITY_PRIVATE_KEY':s['identity']['private_key'], 'REALITY_PUBLIC_KEY':s['identity']['public_key']}
values.pop('profile_format')
values.pop('LISTEN_ADDRESS')  # The original installer had an IPv4-only binding.
(root / 'config.json').write_text(json.dumps(cfg))
(root / 'config.json').chmod(0o600)
(root / 'bootstrap-state.env').write_text(''.join(k+'='+shlex.quote(v)+'\n' for k,v in values.items()))
(root / 'bootstrap-state.env').chmod(0o600)
pathlib.Path('/root/legacy-identity.json').write_text(json.dumps(s['identity']))
shutil.copyfile(root / 'current/xray', '/usr/local/bin/xray')
pathlib.Path('/usr/local/bin/xray').chmod(0o755)
(root / 'current').unlink()
PY
    bash xray_reality_bootstrap.sh repair
    jq -S '.identity' /etc/xray/current/state.json >/root/migrated-identity.json
    jq -S . /root/legacy-identity.json >/root/expected-identity.json
    cmp /root/migrated-identity.json /root/expected-identity.json
    [[ $(jq -r '.options.LISTEN_ADDRESS' /etc/xray/current/state.json) == 0.0.0.0 ]]
    "$helper" diagnose
    "$helper" uninstall --yes --non-interactive
    ;;
  *) exit 2 ;;
esac
