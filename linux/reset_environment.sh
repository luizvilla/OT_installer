#!/usr/bin/env bash
#
# Reset script for OwnTech environment-setup dry runs (Linux / Debian & Ubuntu).
#
# Uninstalls Git, CMake, VS Code (via apt) and removes leftover config/cache
# folders (PlatformIO core -- including a redirected core dir from a
# low-disk run of install_owntech.sh, VS Code settings, gitconfig, pip
# cache) so the next install pass starts from a genuinely clean machine.
#
# Python 3 itself is NOT removed even with --include-python: unlike on
# Windows (where Python is a distinct optional package), python3 on
# Debian/Ubuntu is a base system dependency many other packages and admin
# tools rely on -- removing it risks breaking the machine, not just this
# project. --include-python only removes python3-venv/python3-pip, the
# packages install_owntech.sh actually adds on top of a stock python3.
#
# Usage:
#   ./reset_environment.sh
#   ./reset_environment.sh --project-path ~/owntech --include-python --non-interactive
#
# Only run this on a disposable test machine/container/VM -- not your
# everyday dev machine -- it uninstalls real tooling.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

PROJECT_PATH=""
INCLUDE_PYTHON=0
NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --project-path) PROJECT_PATH="$2"; shift 2 ;;
        --project-path=*) PROJECT_PATH="${1#*=}"; shift ;;
        --include-python) INCLUDE_PYTHON=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--project-path PATH] [--include-python] [--non-interactive]
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

APPS_TO_REMOVE=(git cmake code)
if [ "$INCLUDE_PYTHON" -eq 1 ]; then
    APPS_TO_REMOVE+=(python3-venv python3-pip)
    # python3-venv is a thin meta-package depending on a version-specific
    # implementation (e.g. python3.12-venv). Confirmed via a real test:
    # 'apt-get remove --autoremove python3-venv' only cascades to the
    # versioned package when THIS invocation is what removes the
    # meta-package -- if it was already gone from an earlier reset, the
    # versioned package is left orphaned with nothing left to trigger the
    # cascade. Target it explicitly instead of relying on that cascade.
    if command -v python3 >/dev/null 2>&1; then
        py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)"
        if [ -n "$py_ver" ]; then
            APPS_TO_REMOVE+=("python${py_ver}-venv")
        fi
    fi
fi

FOLDERS_TO_DELETE=(
    "$HOME/.platformio"
    "$HOME/.config/Code"
    "$HOME/.cache/pip"
)

# install_owntech.sh redirects PlatformIO's core dir off a tight $HOME
# filesystem (resolve_core_dir) and persists it via a marker block in
# ~/.profile -- pick up the real location from there if present, the same
# way the Windows script reads it back from the registry.
REDIRECTED_CORE_DIR=""
if [ -f "$HOME/.profile" ]; then
    REDIRECTED_CORE_DIR="$(grep -A1 '^# owntech-installer: PLATFORMIO_CORE_DIR$' "$HOME/.profile" 2>/dev/null | sed -n '2p' | sed -E 's/^export PLATFORMIO_CORE_DIR="(.*)"$/\1/')"
fi
if [ -n "$REDIRECTED_CORE_DIR" ]; then
    FOLDERS_TO_DELETE+=("$REDIRECTED_CORE_DIR")
fi

printf '\033[1;36m== OwnTech environment reset ==\033[0m\n'
printf 'This will remove (apt): %s\n' "${APPS_TO_REMOVE[*]}"
printf 'And delete these folders if present:\n'
for f in "${FOLDERS_TO_DELETE[@]}"; do printf '  %s\n' "$f"; done
printf '  %s/.gitconfig\n' "$HOME"
if [ -n "$REDIRECTED_CORE_DIR" ]; then
    printf 'And remove the PLATFORMIO_CORE_DIR marker block from ~/.profile (%s).\n' "$REDIRECTED_CORE_DIR"
fi
printf '\n'

if [ -z "$PROJECT_PATH" ] && [ "$NON_INTERACTIVE" -ne 1 ]; then
    read -r -p "Path to your cloned project folder to also delete (leave blank to skip): " PROJECT_PATH
fi

if [ "$NON_INTERACTIVE" -ne 1 ]; then
    read -r -p "Type YES to continue: " confirm
    if [ "$confirm" != "YES" ]; then
        printf '\033[33mAborted.\033[0m\n'
        exit 0
    fi
fi

if ! command -v apt-get >/dev/null 2>&1; then
    printf '\033[33mapt-get not found -- skipping package removal; uninstall these manually.\033[0m\n'
else
    for pkg in "${APPS_TO_REMOVE[@]}"; do
        printf '\033[1;36mRemoving %s...\033[0m\n' "$pkg"
        # --autoremove: plain 'apt-get remove' leaves orphaned dependencies
        # behind -- confirmed via a real test, 'apt-get remove python3-venv'
        # only drops that meta-package while python3.12-venv (the actual
        # implementation) stays installed, so 'python3 -m venv' keeps working
        # and a subsequent install_owntech.sh run wrongly sees it as already
        # satisfied instead of genuinely reset.
        sudo env DEBIAN_FRONTEND=noninteractive apt-get remove --autoremove -y "$pkg" 2>&1 || true
    done

    if [ "$INCLUDE_PYTHON" -ne 1 ]; then
        printf '\nChecking for a python3 install (not auto-removed; pass --include-python to remove python3-venv/python3-pip alongside it)...\n'
        if command -v python3 >/dev/null 2>&1; then
            printf 'Found: %s. python3 itself is never removed by this script (see header comment) -- remove manually if you really need to.\n' "$(python3 --version 2>&1)"
        else
            printf 'No python3 install found.\n'
        fi
    fi
fi

printf '\n'
for folder in "${FOLDERS_TO_DELETE[@]}"; do
    if [ -e "$folder" ]; then
        printf '\033[1;36mDeleting %s...\033[0m\n' "$folder"
        rm -rf "$folder"
    fi
done

if [ -n "$REDIRECTED_CORE_DIR" ] && [ -f "$HOME/.profile" ]; then
    printf '\033[1;36mRemoving PLATFORMIO_CORE_DIR marker block from ~/.profile...\033[0m\n'
    awk 'BEGIN{skip=0} $0=="# owntech-installer: PLATFORMIO_CORE_DIR"{skip=2; next} skip>0{skip--; next} {print}' "$HOME/.profile" > "$HOME/.profile.tmp" && mv "$HOME/.profile.tmp" "$HOME/.profile"
fi

gitconfig="$HOME/.gitconfig"
if [ -f "$gitconfig" ]; then
    printf '\033[1;36mDeleting %s...\033[0m\n' "$gitconfig"
    rm -f "$gitconfig"
fi

if [ -n "$PROJECT_PATH" ] && [ -e "$PROJECT_PATH" ]; then
    printf '\033[1;36mDeleting project folder %s...\033[0m\n' "$PROJECT_PATH"
    rm -rf "$PROJECT_PATH"
fi

printf '\n\033[1;36m== PATH entries worth a manual glance ==\033[0m\n'
printf '%s\n' "$PATH" | tr ':' '\n' | grep -E 'git|python|cmake|[Vv][Ss] ?[Cc]ode' || true

printf '\n\033[32mDone.\033[0m Unlike Windows, no reboot is needed -- open a new shell (PATH changes need a fresh session, same as after any apt install) before your next timed/recording pass.\n'
