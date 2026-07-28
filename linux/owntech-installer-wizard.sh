#!/usr/bin/env bash
#
# GUI wizard for the OwnTech environment installer -- a Zenity front-end
# around install_owntech.sh, mirroring wizard/OwnTechInstaller.iss on
# Windows: a thin wrapper that shells out to the real script's
# --run-phase calls rather than reimplementing its logic (validation
# rules included -- see below).
#
# Standalone/development state (this commit): welcome screen, folder
# picker, real preflight validation, tailored reuse/nest confirmation, a
# progress dialog wired to every real phase (via --list-phases /
# --run-phase) with a Retry/Cancel dialog on fatal failure, and a finish
# screen (open in VS Code, remaining manual steps). Desktop-entry
# packaging lands in a later commit -- see linux_installer_plan.md's GUI
# wizard section.
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

# Pulls the reason + remediation out of a captured stop_install() call --
# falls back to the whole (cleaned) output if the [FAILED] marker isn't
# found, so a failure is never shown as a blank dialog.
get_failure_reason() {
    local clean reason
    clean="$(printf '%s' "$1" | strip_ansi)"
    reason="$(printf '%s\n' "$clean" | grep -A2 '^\s*\[FAILED\]' | sed -E 's/^\s*\[FAILED\]\s*//; s/^\s*How to fix:\s*//')"
    [ -z "$reason" ] && reason="$clean"
    printf '%s' "$reason"
}

# Human-readable label per phase for the progress dialog -- purely cosmetic
# (falls back to the raw phase name for anything not listed here), so this
# can never drift into an incorrect *behavior*, unlike the validation rules
# and phase list itself, which are always asked of the real script instead
# of being duplicated here.
declare -A PHASE_LABELS=(
    [preflight]="Checking system requirements"
    [git]="Installing git"
    [python]="Checking Python"
    [cmake]="Installing CMake"
    [vscode]="Installing VS Code"
    [extensions]="Installing VS Code extensions"
    [clone]="Cloning the OwnTech Core repository"
    [bundle]="Seeding the PlatformIO package cache"
    [bootstrap]="Bootstrapping PlatformIO Core"
    [build]="Building firmware for the first time"
    [serial-permissions]="Setting up USB serial permissions"
    [summary]="Finishing up"
)

# Runs every phase --list-phases reports (never hardcoded, so this can't
# drift from install_owntech.sh's own ALL_PHASES) against $PROJECT_PATH,
# driving a zenity --progress dialog via fd 3 (a persistent zenity process
# started through process substitution, not a one-shot pipe -- this lets a
# zenity --question Retry/Cancel dialog run *concurrently* on fatal
# failure, with the progress dialog still visible underneath, then either
# resume feeding fd 3 (Retry) or explicitly kill it (Cancel/exhausted).
run_install_with_progress() {
    local -a phases
    mapfile -t phases < <("$INSTALL_SCRIPT" --list-phases)
    local total=${#phases[@]} i=0

    exec 3> >(zenity --progress --title="$APP_TITLE" --width=500 \
        --no-cancel --auto-close --text="Starting install..." 2>/dev/null)
    local zenity_pid=$!

    local phase label pct output exit_code reason
    for phase in "${phases[@]}"; do
        i=$((i + 1))
        pct=$(( (i - 1) * 100 / total ))
        label="${PHASE_LABELS[$phase]:-Running: $phase}"
        printf '%s\n# %s (%d/%d)\n' "$pct" "$label" "$i" "$total" >&3

        if [ "$phase" = "build" ]; then
            printf '# %s\n' "$label -- this can take several minutes with no visible progress" >&3
        fi

        while true; do
            output="$("$INSTALL_SCRIPT" --run-phase "$phase" --project-path "$PROJECT_PATH" --non-interactive 2>&1)"
            exit_code=$?
            if [ "$exit_code" -eq 0 ]; then
                break
            fi

            reason="$(get_failure_reason "$output")"
            if zenity --question --title="$APP_TITLE" --width=460 \
                --ok-label="Retry" --cancel-label="Cancel install" \
                --text="Step '$label' failed:\n\n$reason\n\nRetry this step?" \
                2>/dev/null
            then
                continue
            else
                exec 3>&-
                kill "$zenity_pid" 2>/dev/null
                wait "$zenity_pid" 2>/dev/null
                return 1
            fi
        done
    done

    printf '100\n# Done.\n' >&3
    exec 3>&-
    wait "$zenity_pid" 2>/dev/null
    return 0
}

# Reads PROJECT_PATH (global). Reloads state rather than recomputing
# repo_path/GROUP_CHANGED itself -- REPO_PATH is whatever phase_clone
# actually decided and persisted (accounts for the nested-subfolder case),
# and GROUP_CHANGED reflects whether serial-permissions really changed
# anything this run.
show_finish_screen() {
    load_state "$PROJECT_PATH"

    if zenity --question --title="$APP_TITLE" --width=420 \
        --ok-label="Open in VS Code" --cancel-label="Skip" \
        --text="Setup complete for:\n$REPO_PATH\n\nOpen the project in VS Code now?" \
        2>/dev/null
    then
        # --disable-workspace-trust: session-only, verified-safe flag
        # reused directly from the Windows wizard's 6bb4ddd.
        code --disable-workspace-trust "$REPO_PATH" >/dev/null 2>&1 &
        disown
    fi

    local group_note=""
    if [ "$GROUP_CHANGED" -eq 1 ]; then
        group_note="\n\nReminder: you were just added to the 'dialout' group -- log out and back in before step 3 below will work."
    fi

    # Reuses phase_summary's own framing for the remaining manual steps.
    zenity --info --title="$APP_TITLE" --width=460 \
        --text="Remaining manual steps:\n\n1. Connect your SPIN board via USB-C (its PWR LED should light up).\n2. In VS Code, use the Build (check mark) icon in the status bar.\n3. Then Upload (arrow icon) to flash the board and see the LED blink.${group_note}" \
        2>/dev/null
}

main() {
    # ------------------------------------------------------------------------
    # Welcome
    # ------------------------------------------------------------------------
    if ! zenity --info --title="$APP_TITLE" --width=420 --ok-label="Next" \
        --text="This wizard installs everything needed to build and flash OwnTech Core firmware: git, CMake, VS Code (with the PlatformIO/CMake extensions), and a first PlatformIO build.\n\nClick Next to choose a project folder." \
        2>/dev/null
    then
        exit 0
    fi

    # ------------------------------------------------------------------------
    # Folder picker + real preflight validation, looping back on failure
    # ------------------------------------------------------------------------
    local default_project_path="$HOME/owntech"
    PROJECT_PATH=""

    while true; do
        local chosen
        chosen="$(zenity --file-selection --directory \
            --title="Choose (or create) a project folder" \
            --filename="$default_project_path/" 2>/dev/null)"
        if [ -z "$chosen" ]; then
            exit 0
        fi
        chosen="${chosen%/}"

        local preflight_output preflight_exit
        preflight_output="$("$INSTALL_SCRIPT" --run-phase preflight --project-path "$chosen" --non-interactive 2>&1)"
        preflight_exit=$?

        if [ "$preflight_exit" -ne 0 ]; then
            zenity --error --title="$APP_TITLE" --width=420 --text="$(get_failure_reason "$preflight_output")" 2>/dev/null
            continue
        fi

        # Tailored reuse/nest confirmation (mirrors Windows' 2baaf62): checks
        # for an existing project specifically via the same logic
        # resolve_repo_path/test_complete_clone use internally, and phrases
        # the confirmation around what will actually happen -- not a generic
        # "overwrite?" scare.
        local repo_path
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

    # ------------------------------------------------------------------------
    # Progress dialog wired to real phases
    # ------------------------------------------------------------------------
    if run_install_with_progress; then
        show_finish_screen
    else
        zenity --error --title="$APP_TITLE" --width=420 \
            --text="Installation cancelled." 2>/dev/null
    fi
}

# Same BASH_SOURCE guard idiom as install_owntech.sh, for the same reason:
# lets this file be sourced (to reach run_install_with_progress,
# resolve_repo_path, etc. directly) without a real wizard run as a side
# effect -- e.g. for scripted zenity-fake testing of the control flow.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
