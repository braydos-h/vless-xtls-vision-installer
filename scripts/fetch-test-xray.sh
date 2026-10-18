#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Download official pinned test binaries with API SHA-256 verification.
set -Eeuo pipefail
version=${1:?release tag required}
directory=${2:?output directory required}
[[ $version =~ ^v[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]
mkdir -p "$directory"
curl --proto '=https' -fLSs --retry 3 --max-time 180 "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version" -o "$directory/release.json"
url=$(jq -er '.assets[] | select(.name=="Xray-linux-64.zip") | .browser_download_url' "$directory/release.json")
digest=$(jq -er '.assets[] | select(.name=="Xray-linux-64.zip") | .digest | select(test("^sha256:[a-f0-9]{64}$"))' "$directory/release.json")
[[ $url == "https://github.com/XTLS/Xray-core/releases/download/$version/Xray-linux-64.zip" ]]
curl --proto '=https' --proto-redir '=https' -fLSs --retry 3 --max-time 180 "$url" -o "$directory/release.zip"
[[ $(sha256sum "$directory/release.zip" | cut -d' ' -f1) == "${digest#sha256:}" ]]
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$project/lib/data.py" extract "$directory/release.zip" "$directory/unpack"
chmod 755 "$directory/unpack/xray"
"$directory/unpack/xray" version
