#!/usr/bin/env bash
#
# Resets the machine to a clean state, then runs install_owntech.sh timed, and
# appends the result to a CSV history -- so you can compare install time
# across runs (e.g. before/after publishing a --bundle-url bundle, or after a
# real regression) instead of eyeballing a single run's printed time.
#
# install_owntech.sh already prints its own total ("Total install time: ...")
# for any single run; this wrapper is for the reset+reinstall *cycle*, and
# for building up a comparable history across multiple cycles.
#
# Usage:
#   ./run_timed_install_test.sh --project-path ~/owntech
#   ./run_timed_install_test.sh --project-path ~/owntech --include-python
#   ./run_timed_install_test.sh --project-path ~/owntech --bundle-url <url> --bundle-sha256 <hash> --label with-bundle
#
# Only run this on a disposable test machine/container/VM -- see
# reset_environment.sh's own warning.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_PATH=""
INCLUDE_PYTHON=0
BUNDLE_URL=""
BUNDLE_SHA256=""
LABEL=""
HISTORY_CSV="$SCRIPT_DIR/install_timing_history.csv"

while [ $# -gt 0 ]; do
    case "$1" in
        --project-path) PROJECT_PATH="$2"; shift 2 ;;
        --project-path=*) PROJECT_PATH="${1#*=}"; shift ;;
        --include-python) INCLUDE_PYTHON=1; shift ;;
        --bundle-url) BUNDLE_URL="$2"; shift 2 ;;
        --bundle-url=*) BUNDLE_URL="${1#*=}"; shift ;;
        --bundle-sha256) BUNDLE_SHA256="$2"; shift 2 ;;
        --bundle-sha256=*) BUNDLE_SHA256="${1#*=}"; shift ;;
        --label) LABEL="$2"; shift 2 ;;
        --label=*) LABEL="${1#*=}"; shift ;;
        --history-csv) HISTORY_CSV="$2"; shift 2 ;;
        --history-csv=*) HISTORY_CSV="${1#*=}"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 --project-path PATH [--include-python] [--bundle-url URL --bundle-sha256 HASH] [--label TEXT] [--history-csv PATH]
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PROJECT_PATH" ]; then
    echo "--project-path is required." >&2
    exit 1
fi

printf '\033[1;36m===================================================\033[0m\n'
printf '\033[1;36m Timed install test cycle\033[0m\n'
printf '\033[1;36m===================================================\033[0m\n'

# --- Step 1: Reset ---
printf '\n\033[1;36m== Step 1/2: Reset environment ==\033[0m\n'
reset_start=$(date +%s)
reset_args=(--project-path "$PROJECT_PATH" --non-interactive)
[ "$INCLUDE_PYTHON" -eq 1 ] && reset_args+=(--include-python)
"$SCRIPT_DIR/reset_environment.sh" "${reset_args[@]}"
reset_exit=$?
reset_elapsed=$(( $(date +%s) - reset_start ))
printf '\nReset step took %02d:%02d:%02d (exit code %d).\n' \
    "$((reset_elapsed / 3600))" "$(((reset_elapsed % 3600) / 60))" "$((reset_elapsed % 60))" "$reset_exit"

# --- Step 2: Timed install ---
printf '\n\033[1;36m== Step 2/2: Timed install ==\033[0m\n'
log_path="$SCRIPT_DIR/install_timing_$(date +%Y%m%d_%H%M%S).log"

install_args=(--project-path "$PROJECT_PATH" --non-interactive)
[ -n "$BUNDLE_URL" ] && install_args+=(--bundle-url "$BUNDLE_URL")
[ -n "$BUNDLE_SHA256" ] && install_args+=(--bundle-sha256 "$BUNDLE_SHA256")

install_start=$(date +%s)
"$SCRIPT_DIR/install_owntech.sh" "${install_args[@]}" >"$log_path" 2>&1
install_exit=$?
install_elapsed=$(( $(date +%s) - install_start ))
install_time_fmt=$(printf '%02d:%02d:%02d' "$((install_elapsed / 3600))" "$(((install_elapsed % 3600) / 60))" "$((install_elapsed % 60))")

printf '\n'
if [ "$install_exit" -eq 0 ]; then
    printf '\033[32mInstall succeeded in %s.\033[0m\n' "$install_time_fmt"
else
    printf '\033[31mInstall FAILED (exit code %d) after %s. Log: %s\033[0m\n' "$install_exit" "$install_time_fmt" "$log_path"
    printf '\033[33mLast 15 lines:\033[0m\n'
    tail -15 "$log_path"
fi

# --- Record history ---
bundle_used=0
[ -n "$BUNDLE_URL" ] && bundle_used=1

if [ ! -f "$HISTORY_CSV" ]; then
    echo "Timestamp,Label,ProjectPath,IncludePython,BundleUsed,ResetExit,InstallExit,InstallTime,LogFile" > "$HISTORY_CSV"
fi
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LABEL" "$PROJECT_PATH" "$INCLUDE_PYTHON" "$bundle_used" \
    "$reset_exit" "$install_exit" "$install_time_fmt" "$log_path" >> "$HISTORY_CSV"

printf '\n\033[1;36mRecorded to %s\033[0m\n' "$HISTORY_CSV"
if [ -f "$HISTORY_CSV" ]; then
    printf '\n\033[1;36mHistory so far:\033[0m\n'
    column -s, -t "$HISTORY_CSV" 2>/dev/null || cat "$HISTORY_CSV"
fi
