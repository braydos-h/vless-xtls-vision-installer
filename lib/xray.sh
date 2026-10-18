#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
arch_asset() {
  case "$(uname -m)" in
    x86_64 | amd64) printf '%s' Xray-linux-64.zip ;;
    aarch64 | arm64) printf '%s' Xray-linux-arm64-v8a.zip ;;
    armv7l) printf '%s' Xray-linux-arm32-v7a.zip ;;
    *)
      log "[FAIL] Unsupported architecture: $(uname -m). Supported: x86_64/amd64, aarch64/arm64, armv7l."
      return 1
      ;;
  esac
}
download() {
  local rc
  [[ $1 == https://* ]] || die 'Downloads require HTTPS.'
  if retry curl --proto '=https' --proto-redir '=https' -fLSs --connect-timeout 15 --max-time 180 "$1" -o "$2"; then return 0; else rc=$?; fi
  log "ERROR: Download failed: HTTPS GET $1 (curl exit $rc; see curl error above)."
  return "$rc"
}
validate_xray() {
  local binary=$1 config=$2 assets=$3
  jq -e 'type=="object"' "$config" >/dev/null
  if ! XRAY_LOCATION_ASSET="$assets" "$binary" run -test -format json -config "$config" >"$WORK/config-test.log" 2>&1; then
    die 'Xray rejected configuration. Active deployment is preserved; inspect the configuration privately.'
  fi
}
prepare_candidate() {
  workspace
  local asset tag url digest dgst api requested available
  requested=${PIN:-$(profile_opt XRAY_PIN)}
  api=$requested
  asset=$(arch_asset)
  if [[ -d $XRAY_DIR ]]; then
    available=$(df -Pk "$XRAY_DIR" | awk 'NR==2 {print $4}')
  else
    available=$(df -Pk / | awk 'NR==2 {print $4}')
  fi
  [[ $available =~ ^[0-9]+$ && $available -ge 524288 ]] || die 'At least 512 MiB free space is required to stage an update.'
  if [[ -n $api ]]; then
    [[ $api =~ ^v[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || die 'Invalid --xray-version release tag.'
    api="https://api.github.com/repos/XTLS/Xray-core/releases/tags/$api"
  else api=https://api.github.com/repos/XTLS/Xray-core/releases/latest; fi
  download "$api" "$WORK/release.json"
  tag=$(jq -er '.tag_name | select(test("^v[0-9]{1,3}\\.[0-9]{1,2}\\.[0-9]{1,2}$"))' "$WORK/release.json")
  jq -e '.draft==false and (.prerelease|type=="boolean") and (.assets|type=="array")' "$WORK/release.json" >/dev/null || die 'Release metadata is invalid or draft.'
  if [[ $(jq -r '.prerelease' "$WORK/release.json") == true && ${ALLOW_PRERELEASE_CLI:-false} != true && $(profile_opt ALLOW_PRERELEASE) != yes ]]; then
    die 'Pinned release is marked prerelease upstream. Review release notes and explicitly opt in with --allow-prerelease.'
  fi
  [[ -z $requested || $tag == "$requested" ]] || die 'Release tag mismatch.'
  jq --arg asset "$asset" '[.assets[] | select(.name==$asset)] | if length==1 then .[0] else error("asset missing or duplicate") end' "$WORK/release.json" >"$WORK/asset.json"
  url=$(jq -er '.browser_download_url' "$WORK/asset.json")
  [[ $url == "https://github.com/XTLS/Xray-core/releases/download/$tag/$asset" ]] || die 'Unexpected release asset URL.'
  digest=$(jq -r '.digest // ""' "$WORK/asset.json")
  if [[ ! $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
    dgst=$(jq -er --arg name "$asset.dgst" '[.assets[] | select(.name==$name)] | select(length==1) | .[0].browser_download_url' "$WORK/release.json")
    [[ $dgst == "$url.dgst" ]] || die 'Unexpected checksum URL.'
    download "$dgst" "$WORK/release.dgst"
    digest=$(sed -nE 's/^[[:space:]]*(SHA2-256|SHA256)[[:space:]]*=[[:space:]]*([a-fA-F0-9]{64})[[:space:]]*$/sha256:\2/p' "$WORK/release.dgst")
  fi
  [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]] || die 'No unambiguous SHA-256 checksum; refusing release.'
  digest=${digest,,}
  CANDIDATE_VERSION=$tag
  if [[ $MODE == update && -f $STATE_FILE && -z $PIN && -z $(profile_opt XRAY_PIN) ]] && jq -e --arg tag "$tag" '(.xray_version|ltrimstr("v")|split(".")|map(tonumber)) > ($tag|ltrimstr("v")|split(".")|map(tonumber))' "$STATE_FILE" >/dev/null; then
    log 'SKIPPED: upstream stable release is older than the installed version. Pin explicitly to downgrade.'
    UPDATE_SKIPPED=true
    return 0
  fi
  if [[ $MODE == update && -f $STATE_FILE && $(jq -r '.xray_version' "$STATE_FILE") == "$tag" && (-z $PIN || $(jq -r '.options.XRAY_PIN' "$STATE_FILE") == "$PIN") ]]; then
    log "SKIPPED: Xray $tag is already deployed."
    UPDATE_SKIPPED=true
    return 0
  fi
  download "$url" "$WORK/release.zip"
  [[ $(stat -c %s "$WORK/release.zip") == "$(jq -r '.size' "$WORK/asset.json")" ]] || die 'Release asset size mismatch.'
  [[ $(sha256sum "$WORK/release.zip" | cut -d' ' -f1) == "${digest#sha256:}" ]] || die 'Release SHA-256 checksum mismatch.'
  CANDIDATE=$WORK/candidate
  data extract "$WORK/release.zip" "$CANDIDATE"
  [[ -f $CANDIDATE/xray && ! -L $CANDIDATE/xray ]] || die 'Release is missing the executable.'
  chmod 755 "$CANDIDATE/xray"
  "$CANDIDATE/xray" version >"$WORK/version"
  [[ $(head -n 1 "$WORK/version") == "Xray ${tag#v} "* ]] || die 'Candidate execution/version verification failed.'
  if [[ -f $CONFIG_FILE ]]; then validate_xray "$CANDIDATE/xray" "$CONFIG_FILE" "$CANDIDATE"; fi
}
reuse_candidate() {
  if [[ -L $CURRENT ]]; then CANDIDATE=$(readlink -f "$CURRENT"); else CANDIDATE=$WORK/candidate; fi
  if [[ ! -L $CURRENT ]]; then
    install -d -m 700 "$CANDIDATE"
    install -m 755 "$BIN" "$CANDIDATE/xray"
    local f
    for f in geoip.dat geosite.dat; do
      if [[ -f /usr/local/share/xray/$f ]]; then cp /usr/local/share/xray/"$f" "$CANDIDATE/$f"; fi
    done
  fi
  CANDIDATE_VERSION=$(jq -r '.xray_version' "$DESIRED")
}
update_mode() {
  [[ -f $UNIT ]] || die 'Xray runtime is not installed. Run install, repair or restore first.'
  load_deployment
  jq '.options' "$DESIRED" >"$WORK/options.json"
  PROFILE=$WORK/options.json
  UPDATE_SKIPPED=false
  prepare_candidate
  [[ $UPDATE_SKIPPED == false ]] || return 0
  # Scheduled no-change checks must not accumulate full binary backups. Take
  # the recovery snapshot only after staging succeeds, before any deployment edit.
  backup_mode >/dev/null
  jq --arg version "$CANDIDATE_VERSION" --arg pin "$PIN" \
    '.xray_version=$version | if $pin!="" then .options.XRAY_PIN=$pin else . end' "$DESIRED" >"$WORK/next"
  mv "$WORK/next" "$DESIRED"
  if [[ ${ALLOW_PRERELEASE_CLI:-false} == true ]]; then
    jq '.options.ALLOW_PRERELEASE="yes"' "$DESIRED" >"$WORK/next"
    mv "$WORK/next" "$DESIRED"
  fi
  ensure_account
  stage_generation
  persist_helper
  activate_generation
  configure_timer
  commit_transaction
}
