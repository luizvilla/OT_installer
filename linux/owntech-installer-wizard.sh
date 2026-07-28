#!/usr/bin/env bash
#
# GUI wizard for the OwnTech environment installer -- a Zenity front-end
# around install_owntech.sh, mirroring wizard/OwnTechInstaller.iss on
# Windows: a thin wrapper that shells out to the real script's
# --run-phase calls rather than reimplementing its logic (validation
# rules included -- see below).
#
# Standalone/development state (this commit): welcome screen, folder
# picker, real preflight validation, tailored reuse/nest confirmation.
# Progress-dialog phase wiring and the finish screen land in later
# commits -- see linux_installer_plan.md's GUI wizard section.
#
# Usage:
#   ./owntech-installer-wizard.sh
#
# Needs a real desktop session (zenity opens real windows) -- not the
# disposable Docker container used for install_owntech.sh's own testing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="${INSTALL_SCRIPT:-$SCRIPT_DIR/install_owntech.sh}"
APP_TITLE="OwnTech Environment Installer"

if ! command -v zenity >/dev/null 2>&1; then
    echo "zenity is required to run this wizard. Install it with: sudo apt install zenity" >&2
    exit 1
fi
if [ ! -x "$INSTALL_SCRIPT" ]; then
    echo "Could not find install_owntech.sh at $INSTALL_SCRIPT (set \$INSTALL_SCRIPT to override)." >&2
    exit 1
fi

# Sourcing (safe: the BASH_SOURCE guard in install_owntech.sh skips its
# argument-parsing/dispatch block when sourced, same trick
# test_hardening.sh already relies on) gives direct access to
# resolve_repo_path/test_complete_clone -- the real functions the script
# itself uses to decide whether a chosen folder already holds a clone, so
# the wizard's reuse/nest confirmation can't drift from what the script
# will actually do.
# shellcheck disable=SC1090
source "$INSTALL_SCRIPT"

strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*m//g'
}

# ----------------------------------------------------------------------------
# Welcome
# ----------------------------------------------------------------------------
if ! zenity --info --title="$APP_TITLE" --width=420 --ok-label="Next" \
    --text="This wizard installs everything needed to build and flash OwnTech Core firmware: git, CMake, VS Code (with the PlatformIO/CMake extensions), and a first PlatformIO build.\n\nClick Next to choose a project folder." \
    2>/dev/null
then
    exit 0
fi

# ----------------------------------------------------------------------------
# Folder picker + real preflight validation, looping back on failure
# ----------------------------------------------------------------------------
DEFAULT_PROJECT_PATH="$HOME/owntech"
PROJECT_PATH=""

while true; do
    chosen="$(zenity --file-selection --directory \
        --title="Choose (or create) a project folder" \
        --filename="$DEFAULT_PROJECT_PATH/" 2>/dev/null)"
    if [ -z "$chosen" ]; then
        exit 0
    fi
    chosen="${chosen%/}"

    preflight_output="$("$INSTALL_SCRIPT" --run-phase preflight --project-path "$chosen" --non-interactive 2>&1)"
    preflight_exit=$?
    clean_output="$(printf '%s' "$preflight_output" | strip_ansi)"

    if [ "$preflight_exit" -ne 0 ]; then
        reason="$(printf '%s\n' "$clean_output" | grep -A2 '^\s*\[FAILED\]' | sed -E 's/^\s*\[FAILED\]\s*//; s/^\s*How to fix:\s*//')"
        [ -z "$reason" ] && reason="$clean_output"
        zenity --error --title="$APP_TITLE" --width=420 --text="$reason" 2>/dev/null
        continue
    fi

    # Tailored reuse/nest confirmation (mirrors Windows' 2baaf62): checks
    # for an existing project specifically via the same logic
    # resolve_repo_path/test_complete_clone use internally, and phrases
    # the confirmation around what will actually happen -- not a generic
    # "overwrite?" scare.
    repo_path="$(resolve_repo_path "$chosen")"
    if [ -d "$repo_path/.git" ] && test_complete_clone "$repo_path"; then
        if ! zenity --question --title="$APP_TITLE" --width=420 \
            --text="An OwnTech Core checkout already exists at:\n$repo_path\n\nThe installer will reuse it and skip steps that are already done. Continue?" \
            2>/dev/null
        then
            continue
        fi
    elif [ "$repo_path" != "$chosen" ]; then
        if ! zenity --question --title="$APP_TITLE" --width=460 \
            --text="The folder:\n$chosen\nalready contains files.\n\nTo avoid overwriting anything, the Core repository will be cloned into a new subfolder instead:\n$repo_path\n\nContinue?" \
            2>/dev/null
        then
            continue
        fi
    fi

    PROJECT_PATH="$chosen"
    break
done

# Placeholder for the remainder of the wizard (progress dialog wired to
# real phases, finish screen) -- lands in the next commit, same
# incremental order the Windows wizard was built in (static UI first,
# then wired to real phases).
zenity --info --title="$APP_TITLE" --width=420 \
    --text="Validation passed for:\n$PROJECT_PATH\n\n(Progress dialog wiring comes next.)" \
    2>/dev/null
