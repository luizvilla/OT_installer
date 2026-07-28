#!/usr/bin/env bash
#
# Automated test suite for install_owntech.sh (Linux port of test_hardening.ps1):
#
#   1. Bad-path tests: real child-process invocations of install_owntech.sh with
#      deliberately invalid -project-path values, asserting fatal cases exit 1
#      with the expected reason, and warn-only cases (cloud-sync folder, deep
#      nesting -- not fatal here, unlike their Windows counterparts; see
#      linux_installer_plan.md's Phase 0 section for why) exit 0 with the
#      expected warning text.
#   2. Unit-level retry()/backoff tests: install_owntech.sh is sourced (safe
#      since the BASH_SOURCE guard skips its dispatch block when sourced) so
#      retry() can be exercised directly against controllable fake commands --
#      deterministic and fast, no real network/HTTP server needed to prove the
#      exact mechanism (3 attempts, 2s/4s backoff) every apt/curl/git call in
#      the real script depends on.
#   3. apt package-manager retry, against a REAL apt-get and a package name
#      guaranteed not to exist -- deterministic (a nonexistent package fails
#      identically every attempt) without needing a shim, and sidesteps a real
#      problem a PATH-based fake 'apt-get' would hit: install_owntech.sh calls
#      apt-get via 'sudo', and sudo's own secure_path (where configured)
#      resolves apt-get itself, ignoring the caller's PATH entirely.
#   4. Per-phase invocation test: runs all --run-phase values in order as
#      separate child processes against one project path, then compares the
#      resulting state file against one produced by a normal full (no
#      --run-phase) run against a second path -- proving the per-phase
#      mechanism reproduces a full run's result, not just that each phase runs
#      without error in isolation. Uses --skip-build-test on both sides so the
#      comparison doesn't pay for two real toolchain downloads/builds; that
#      cost is already covered by the container-based manual testing described
#      in linux_installer_plan.md.
#
# Usage:
#   ./test_hardening.sh
#
# Safe to run repeatedly. Groups 1-4 all use /tmp-based throwaway paths and
# clean up after themselves -- unlike reset_environment.sh, nothing here
# uninstalls real tooling, so this is safe even outside a disposable
# container/VM (though Group 3 does perform two real, harmless 'apt-get
# update'/'apt-get install' attempts against a bogus package name).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_owntech.sh"

PASS_COUNT=0
FAIL_COUNT=0

record_result() {
    local name="$1" passed="$2" detail="$3"
    if [ "$passed" -eq 1 ]; then
        printf '\033[32m[PASS]\033[0m %s -- %s\n' "$name" "$detail"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '\033[31m[FAIL]\033[0m %s -- %s\n' "$name" "$detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

printf '\033[1;36m===================================================\033[0m\n'
printf '\033[1;36m Hardening test suite\033[0m\n'
printf '\033[1;36m===================================================\033[0m\n'

# ----------------------------------------------------------------------------
# Group 1: Bad-path validation
# ----------------------------------------------------------------------------
printf '\n\033[1;36m== Group 1: Bad-path validation ==\033[0m\n'

test_fatal_path() {
    local name="$1" path="$2" pattern="$3"
    local out
    out="$("$INSTALL_SCRIPT" --run-phase preflight --project-path "$path" --non-interactive 2>&1)"
    local exit_code=$?
    local matched=0
    printf '%s' "$out" | grep -q "$pattern" && matched=1
    if [ "$exit_code" -eq 1 ] && [ "$matched" -eq 1 ]; then
        record_result "$name" 1 "exit=$exit_code (want 1), pattern matched"
    else
        record_result "$name" 0 "exit=$exit_code (want 1), pattern-matched=$([ "$matched" -eq 1 ] && echo yes || echo no)"
        printf '  --- tail of output ---\n'
        printf '%s\n' "$out" | tail -10
    fi
}

test_warn_only_path() {
    local name="$1" path="$2" pattern="$3"
    local out
    out="$("$INSTALL_SCRIPT" --run-phase preflight --project-path "$path" --non-interactive 2>&1)"
    local exit_code=$?
    local matched=0
    printf '%s' "$out" | grep -qE "$pattern" && matched=1
    rm -rf "$path"
    if [ "$exit_code" -eq 0 ] && [ "$matched" -eq 1 ]; then
        record_result "$name" 1 "exit=$exit_code (want 0), warning matched"
    else
        record_result "$name" 0 "exit=$exit_code (want 0), warning-matched=$([ "$matched" -eq 1 ] && echo yes || echo no)"
        printf '  --- tail of output ---\n'
        printf '%s\n' "$out" | tail -10
    fi
}

test_fatal_path "Path with a space" "/tmp/owntech test dir $$" "contains spaces"

long_path="/tmp/$(printf 'a%.0s' $(seq 1 4200))"
test_fatal_path "Path over 4096 chars" "$long_path" "must be under 4096"

test_warn_only_path "Path containing Dropbox (warn-only, not fatal)" "/tmp/Dropbox-$$/owntech" "cloud-sync folder"

deep_path="/tmp/owntech-deep-$$/a/b/c/d/e/f/g/owntech"
test_warn_only_path "Deeply nested path (warn-only, not fatal)" "$deep_path" "nested [0-9]+ levels deep"
rm -rf "/tmp/owntech-deep-$$"

# ----------------------------------------------------------------------------
# Group 2: retry() backoff/recovery (unit-level, via sourcing)
# ----------------------------------------------------------------------------
printf '\n\033[1;36m== Group 2: retry() backoff/recovery (unit-level) ==\033[0m\n'

# shellcheck disable=SC1090
source "$INSTALL_SCRIPT"

test_retry_recovers() {
    local counter_file
    counter_file="$(mktemp)"
    echo 0 > "$counter_file"

    flaky_test_command() {
        local count
        count=$(( $(cat "$counter_file") + 1 ))
        echo "$count" > "$counter_file"
        [ "$count" -ge 3 ]
    }

    if retry "flaky test command" flaky_test_command; then
        record_result "retry() recovers after transient failures" 1 "succeeded on attempt $(cat "$counter_file")"
    else
        record_result "retry() recovers after transient failures" 0 "did not succeed within 3 attempts"
    fi
    rm -f "$counter_file"
}

test_retry_exhausts() {
    local counter_file start_ts end_ts elapsed attempts
    counter_file="$(mktemp)"
    echo 0 > "$counter_file"

    always_fails_test_command() {
        local count
        count=$(( $(cat "$counter_file") + 1 ))
        echo "$count" > "$counter_file"
        return 1
    }

    start_ts=$(date +%s)
    if retry "always-fails test command" always_fails_test_command; then
        record_result "retry() reports failure after exhausting attempts" 0 "retry incorrectly returned success"
    else
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        attempts="$(cat "$counter_file")"
        if [ "$attempts" -eq 3 ] && [ "$elapsed" -ge 5 ]; then
            record_result "retry() reports failure after exhausting attempts" 1 "3 attempts, ${elapsed}s elapsed (want >=5s for 2s+4s backoff)"
        else
            record_result "retry() reports failure after exhausting attempts" 0 "attempts=$attempts (want 3), elapsed=${elapsed}s (want >=5s)"
        fi
    fi
    rm -f "$counter_file"
}

test_retry_recovers
test_retry_exhausts

# ----------------------------------------------------------------------------
# Group 3: apt package-manager retry (real apt-get, guaranteed-bogus package)
# ----------------------------------------------------------------------------
printf '\n\033[1;36m== Group 3: apt package-manager retry (real apt-get) ==\033[0m\n'

test_apt_retry_exhausts() {
    if ! command -v apt-get >/dev/null 2>&1; then
        record_result "apt_install_verify retries then fails (bogus package)" 1 "skipped: apt-get not available on this host"
        return 0
    fi
    local start_ts end_ts elapsed out exit_code
    start_ts=$(date +%s)
    out="$(apt_install_verify "owntech-definitely-not-a-real-package-xyz123" "owntech-definitely-not-a-real-command-xyz123" "Bogus Test Package" 2>&1)"
    exit_code=$?
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    if [ "$exit_code" -eq 1 ] && [ "$elapsed" -ge 5 ]; then
        record_result "apt_install_verify retries then fails (bogus package)" 1 "exit=$exit_code, elapsed=${elapsed}s (want >=5s for 2s+4s backoff)"
    else
        record_result "apt_install_verify retries then fails (bogus package)" 0 "exit=$exit_code (want 1), elapsed=${elapsed}s (want >=5s)"
        printf '%s\n' "$out" | tail -10
    fi
}

test_apt_retry_exhausts

# ----------------------------------------------------------------------------
# Group 4: per-phase invocation matches a full run
# ----------------------------------------------------------------------------
printf '\n\033[1;36m== Group 4: per-phase invocation matches a full run ==\033[0m\n'

test_per_phase_equivalence() {
    local full_path="/tmp/owntech-test-full-$$"
    local phased_path="/tmp/owntech-test-phased-$$"
    local full_log="/tmp/owntech-full-run-$$.log"
    local phased_log="/tmp/owntech-phased-run-$$.log"
    rm -rf "$full_path" "$phased_path"
    : > "$phased_log"

    "$INSTALL_SCRIPT" --project-path "$full_path" --non-interactive --skip-build-test >"$full_log" 2>&1
    local full_exit=$?

    local phase phased_exit=0 this_exit
    for phase in $("$INSTALL_SCRIPT" --list-phases); do
        "$INSTALL_SCRIPT" --run-phase "$phase" --project-path "$phased_path" --non-interactive --skip-build-test >>"$phased_log" 2>&1
        this_exit=$?
        if [ "$this_exit" -ne 0 ]; then
            phased_exit=$this_exit
        fi
    done

    # Compare state files field-by-field, excluding PROJECT_PATH/REPO_PATH --
    # those inherently differ, since $full_path and $phased_path are
    # deliberately two different paths.
    local full_state phased_state
    full_state="$(state_file_path "$full_path")"
    phased_state="$(state_file_path "$phased_path")"

    local fields_match=1 field full_val phased_val
    for field in CORE_DIR INSTALLED_GIT INSTALLED_PYTHON INSTALLED_CMAKE INSTALLED_CODE GROUP_CHANGED; do
        full_val="$(grep "^${field}=" "$full_state" 2>/dev/null)"
        phased_val="$(grep "^${field}=" "$phased_state" 2>/dev/null)"
        if [ "$full_val" != "$phased_val" ]; then
            fields_match=0
        fi
    done

    if [ "$full_exit" -eq 0 ] && [ "$phased_exit" -eq 0 ] && [ "$fields_match" -eq 1 ]; then
        record_result "Per-phase invocation reproduces a full run's state" 1 "full_exit=$full_exit, phased_exit=$phased_exit, fields match"
    else
        record_result "Per-phase invocation reproduces a full run's state" 0 "full_exit=$full_exit, phased_exit=$phased_exit, fields_match=$fields_match"
        printf '  --- full run log tail ---\n'; tail -15 "$full_log"
        printf '  --- phased run log tail ---\n'; tail -15 "$phased_log"
    fi

    rm -rf "$full_path" "$phased_path" "$full_log" "$phased_log"
}

test_per_phase_equivalence

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
printf '\n\033[1;36m===================================================\033[0m\n'
printf '\033[1;36m %d passed, %d failed\033[0m\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '\033[1;36m===================================================\033[0m\n'

[ "$FAIL_COUNT" -eq 0 ]
