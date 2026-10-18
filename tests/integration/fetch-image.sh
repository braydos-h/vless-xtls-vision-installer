#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -Eeuo pipefail
os=${1:?OS required}
directory=${2:?destination required}
mkdir -p "$directory"
case "$os" in
  debian12)
    base=https://cloud.debian.org/images/cloud/bookworm/latest
    file=debian-12-genericcloud-amd64.qcow2
    sums=SHA512SUMS
    hash=sha512sum
    ;;
  debian13)
    base=https://cloud.debian.org/images/cloud/trixie/latest
    file=debian-13-genericcloud-amd64.qcow2
    sums=SHA512SUMS
    hash=sha512sum
    ;;
  ubuntu2204)
    base=https://cloud-images.ubuntu.com/jammy/current
    file=jammy-server-cloudimg-amd64.img
    sums=SHA256SUMS
    hash=sha256sum
    ;;
  ubuntu2404)
    base=https://cloud-images.ubuntu.com/noble/current
    file=noble-server-cloudimg-amd64.img
    sums=SHA256SUMS
    hash=sha256sum
    ;;
  ubuntu2604)
    base=https://cloud-images.ubuntu.com/resolute/current
    file=resolute-server-cloudimg-amd64.img
    sums=SHA256SUMS
    hash=sha256sum
    ;;
  *) exit 2 ;;
esac
curl --proto '=https' -fLSs --retry 3 --max-time 120 "$base/$sums" -o "$directory/checksums"
curl --proto '=https' -fLSs --retry 3 --max-time 600 "$base/$file" -o "$directory/disk.qcow2"
expected=$(awk -v f="$file" '$2==f || $2=="*"f {print $1}' "$directory/checksums")
[[ -n $expected && $($hash "$directory/disk.qcow2" | cut -d' ' -f1) == "$expected" ]]
