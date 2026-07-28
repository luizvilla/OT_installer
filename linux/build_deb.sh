#!/usr/bin/env bash
#
# Builds the owntech-installer .deb package.
#
# Assembles a build tree from linux/debian/ (packaging metadata) plus a
# pinned copy of the installer scripts, then runs dpkg-deb --build on it.
#
# The packaged copies of install_owntech.sh/reset_environment.sh are pinned
# at build time (copied in below), not fetched live -- a given .deb build
# stays reproducible; rebuild-and-republish is how script changes propagate.
# Same rationale Windows uses for its own embedded script copy in
# OwnTechInstaller.iss.
#
# Usage:
#   ./build_deb.sh
#   ./build_deb.sh --version 0.2.0 --out-file owntech-installer_0.2.0_all.deb
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="0.1.0"
OUT_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --out-file) OUT_FILE="$2"; shift 2 ;;
        --out-file=*) OUT_FILE="${1#*=}"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--version X.Y.Z] [--out-file FILE]
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$OUT_FILE" ]; then
    OUT_FILE="owntech-installer_${VERSION}_all.deb"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found -- install the 'dpkg-dev' package (or run this on a Debian/Ubuntu host)." >&2
    exit 1
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

cp -r "$SCRIPT_DIR/debian/." "$build_dir/"

# Version is baked in here at build time, not templated in the repo file --
# so 'cat linux/debian/DEBIAN/control' in the repo always reads as the
# current in-progress version without needing a rebuild first.
sed -i "s/^Version:.*/Version: $VERSION/" "$build_dir/DEBIAN/control"

payload_dir="$build_dir/opt/owntech-installer"
mkdir -p "$payload_dir"
cp "$SCRIPT_DIR/install_owntech.sh" "$payload_dir/"
cp "$SCRIPT_DIR/reset_environment.sh" "$payload_dir/"

find "$build_dir" -type d -exec chmod 755 {} \;
chmod 755 "$payload_dir"/*.sh
chmod 644 "$build_dir/DEBIAN/control"

dpkg-deb --build --root-owner-group "$build_dir" "$OUT_FILE"

out_path="$(realpath "$OUT_FILE")"
printf '\nBuilt: %s\n\n' "$out_path"
printf 'Install:   sudo apt install ./%s\n' "$(basename "$OUT_FILE")"
printf 'Remove:    sudo apt remove owntech-installer\n'
