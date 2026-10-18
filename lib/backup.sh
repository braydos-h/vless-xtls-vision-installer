#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
backup_mode() {
  local backup id f n=0
  id=$(new_id)
  backup=$BACKUPS/$id
  install -d -m 700 "$BACKUPS" "$backup" "$backup/managed"
  if [[ -L $CURRENT ]]; then
    cp -a --dereference "$CURRENT" "$backup/deployment"
  else
    load_deployment
    install -d -m 700 "$backup/deployment"
    install -m 600 "$DESIRED" "$backup/deployment/state.json"
    install -m 600 "$XRAY_DIR/config.json" "$backup/deployment/config.json"
    install -m 755 "$BIN" "$backup/deployment/xray"
  fi
  for f in "${MANAGED_FILES[@]}"; do
    if [[ -f $f && ! -L $f ]]; then
      cp -a -- "$f" "$backup/managed/$n.data"
      printf '%s\n' "$f" >"$backup/managed/$n.path"
    fi
    n=$((n + 1))
  done
  printf '2\n' >"$backup/format"
  # Manifest generated with relative paths; restoration never executes manifests.
  # shellcheck disable=SC2094
  (cd "$backup" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
  chmod -R go-rwx "$backup"
  sync -f "$backup"
  printf '%s\n' "$id"
}
validate_backup() {
  local backup=$1
  [[ -d $backup && ! -L $backup ]] || die 'Unsupported backup.'
  # Restrict contents before checking hashes, disallow links, special files and unmanifested data.
  python3 - "$backup" <<'PY'
import hashlib, os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
paths = list(root.rglob('*'))
for path in [root, *paths]:
    if path.is_symlink() or not (path.is_file() or path.is_dir()):
        sys.exit('Unsafe backup file')
    info = path.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o022:
        sys.exit('Backup must be owned by the restoring user and not writable by other users')
if not (root / 'format').is_file() or (root / 'format').stat().st_size != 2 or (root / 'format').read_bytes() != b'2\n':
    sys.exit('Unsupported backup format')
if (root / 'SHA256SUMS').stat().st_size > 1024 * 1024:
    sys.exit('Oversized backup manifest')
expected = {}
for line in (root / 'SHA256SUMS').read_text().splitlines():
    m = re.fullmatch(r'([0-9a-f]{64})  (\./[A-Za-z0-9._/-]+)', line)
    if not m or '..' in m[2].split('/') or m[2] in expected:
        sys.exit('Invalid backup manifest')
    expected[m[2]] = m[1]
actual = set()
for path in paths:
    if path.is_file() and path != root / 'SHA256SUMS':
        relative = './' + str(path.relative_to(root))
        actual.add(relative)
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if expected.get(relative) != digest.hexdigest():
            sys.exit('Backup checksum mismatch')
if actual != set(expected):
    sys.exit('Backup manifest file set mismatch')
PY
  data state "$backup/deployment/state.json" >"$WORK/restore-state"
  data config "$WORK/restore-state" >"$WORK/restore-config"
  # Legacy backup configurations may include old but valid fallback fields.
  validate_xray "$backup/deployment/xray" "$WORK/restore-config" "$backup/deployment"
}
restore_mode() {
  [[ $NAME =~ ^[0-9]{8}T[0-9]{6}-[a-f0-9]{12}$ ]] || die 'restore requires a backup ID from list-backups.'
  workspace
  local backup=$BACKUPS/$NAME
  validate_backup "$backup"
  if [[ -f $STATE_FILE || -f $XRAY_DIR/bootstrap-state.env ]]; then backup_mode >/dev/null; fi
  if [[ -f $STATE_FILE ]]; then
    jq --slurpfile live "$STATE_FILE" '.options += ($live[0].options | {SSH_HARDENING,SSH_PORT,CHANGE_SSH_PORT,DISABLE_PASSWORD_AUTH,HAS_SSH_KEYS})' "$WORK/restore-state" >"$WORK/restore-next"
    mv "$WORK/restore-next" "$WORK/restore-state"
  fi
  DESIRED=$WORK/restore-state
  CANDIDATE=$backup/deployment
  CANDIDATE_VERSION=$(jq -r '.xray_version' "$DESIRED")
  ensure_account
  stage_generation
  activate_generation
  configure_host_extras
  configure_timer
  apply_firewall
  finish_install
  log 'Deployment restored. Managed proxy/host rules regenerated from saved options. Archived files are retained for private comparison. SSH settings were preserved.'
}
list_backups_mode() {
  [[ -d $BACKUPS ]] || return 0
  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}
