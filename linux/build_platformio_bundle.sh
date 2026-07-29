#!/usr/bin/env bash
#
# Packages a fully-populated PlatformIO core dir's `packages/` and
# `platforms/` folders into a distributable tarball -- the content that
# ordinarily gets fetched fresh from the network the first time PlatformIO
# builds an OwnTech Core project (toolchain, Zephyr framework, HAL modules).
#
# Linux/x86_64-specific: the toolchain binaries inside differ from Windows'
# equivalent bundle, so that one can't be reused here and this one can't be
# reused there. Extraction (in install_owntech.sh's 'bundle' phase) uses
# plain 'tar xzf' -- Windows needed a standalone 7za.exe because Explorer's
# Expand-Archive plus Defender's on-access scanning made extraction
# dramatically slower than compression alone would predict; Linux has no
# equivalent on-access AV scanning by default, so that whole workaround isn't
# expected to be needed here (confirm with real timing if this ever becomes
# a bottleneck, rather than assuming).
#
# Publish the resulting tarball as a GitHub Release asset, then pass its
# download URL (and the SHA256 this script prints) to install_owntech.sh via
# --bundle-url/--bundle-sha256. A fresh machine then only downloads whatever
# PlatformIO decides is missing or out of date on top of the bundle, instead
# of the full set from scratch. Every run after a machine's first already
# reuses its own local cache regardless -- this only speeds up first-ever
# installs.
#
# Regenerate and re-publish whenever platformio.ini / west.yml bump a
# framework or toolchain version. An install using a stale bundle still works
# correctly ('pio run' fetches whatever's missing or mismatched) -- it just
# won't save any download time for the parts that changed since the bundle
# was built.
#
# Before (re-)publishing, see ../THIRD_PARTY_LICENSES.md -- a license
# inventory of everything this script archives (toolchain, Zephyr framework,
# HAL modules, build tools), verified against a real populated core dir. Two
# known gaps (tool-dtc, tool-gperf: GPL binaries with no bundled license
# text) are documented there; re-check it if platformio.ini/west.yml add a
# new dependency.
#
# Usage:
#   ./build_platformio_bundle.sh --core-dir ~/.platformio
#   ./build_platformio_bundle.sh --core-dir ~/.platformio --out-file bundle.tar.gz
#
# Get --core-dir from install_owntech.sh's own output (it prints the
# redirected core dir if $HOME's filesystem was tight) or from
# $PLATFORMIO_CORE_DIR, falling back to $HOME/.platformio if that's unset.
set -uo pipefail

CORE_DIR=""
OUT_FILE="platformio_bundle_linux_x64_$(date +%Y%m%d).tar.gz"

while [ $# -gt 0 ]; do
    case "$1" in
        --core-dir) CORE_DIR="$2"; shift 2 ;;
        --core-dir=*) CORE_DIR="${1#*=}"; shift ;;
        --out-file) OUT_FILE="$2"; shift 2 ;;
        --out-file=*) OUT_FILE="${1#*=}"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 --core-dir PATH [--out-file FILE]
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$CORE_DIR" ]; then
    echo "--core-dir is required." >&2
    exit 1
fi
if [ ! -d "$CORE_DIR" ]; then
    echo "CoreDir '$CORE_DIR' does not exist." >&2
    exit 1
fi

to_tar=()
[ -d "$CORE_DIR/packages" ] && to_tar+=(packages)
[ -d "$CORE_DIR/platforms" ] && to_tar+=(platforms)

if [ "${#to_tar[@]}" -eq 0 ]; then
    echo "Neither 'packages' nor 'platforms' found under $CORE_DIR -- run a successful build first (install_owntech.sh, or 'pio run' in a Core checkout) so PlatformIO populates them." >&2
    exit 1
fi

rm -f "$OUT_FILE"

printf '\033[1;36mArchiving %s from %s into %s ...\033[0m\n' "${to_tar[*]}" "$CORE_DIR" "$OUT_FILE"

# -C "$CORE_DIR" so the tarball's internal paths are 'packages/...' and
# 'platforms/...' -- matching what install_owntech.sh's 'tar xzf ... -C
# <core dir>' expects when it extracts back into a fresh core dir on
# another machine.
tar czf "$OUT_FILE" -C "$CORE_DIR" "${to_tar[@]}"

out_path="$(realpath "$OUT_FILE")"
size_bytes=$(stat -c%s "$out_path")
size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')
hash=$(sha256sum "$out_path" | awk '{print $1}')

printf '\n\033[32mDone: %s (%s GB)\033[0m\n' "$out_path" "$size_gb"
printf 'SHA256: %s\n\n' "$hash"

size_exceeds_2gb=$(awk -v b="$size_bytes" 'BEGIN { print (b > 2147483648) ? 1 : 0 }')
if [ "$size_exceeds_2gb" -eq 1 ]; then
    printf '\033[33mWARNING: %s GB exceeds GitHub'"'"'s per-file release asset limit (2GB).\033[0m\n' "$size_gb"
    printf '\033[33mSplit '"'"'packages'"'"' and '"'"'platforms'"'"' into two separate archives/releases, and\033[0m\n'
    printf '\033[33mupdate install_owntech.sh'"'"'s phase_bundle to fetch and extract both.\033[0m\n\n'
fi

printf 'Next steps:\n'
printf '  1. gh release create <tag> "%s" --title "PlatformIO package bundle <tag>"\n' "$out_path"
printf '     (or upload to an existing release: gh release upload <tag> "%s")\n' "$out_path"
printf '  2. Run the installer with:\n'
printf '     ./install_owntech.sh --bundle-url <release-asset-download-url> --bundle-sha256 %s\n' "$hash"
