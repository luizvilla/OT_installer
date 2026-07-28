#!/usr/bin/env bash
#
# OwnTech environment installer (Linux / Debian & Ubuntu, apt-based).
#
# Automates Steps 1-6 of docs/environment_setup.md: project folder, VS Code,
# PlatformIO extension, cloning Core, and a first build. See
# linux_installer_plan.md for the full design (phases, rationale, testing).
#
# Idempotent: safe to re-run on a machine that's already partially set up.
# Each phase validates its own outcome and reports what failed, why, and how
# to fix it, rather than trusting a package manager's exit code blindly.
#
# Usage:
#   ./install_owntech.sh
#   ./install_owntech.sh --project-path ~/owntech
#   ./install_owntech.sh --project-path ~/owntech --skip-build-test
#   ./install_owntech.sh --project-path ~/owntech --bundle-url <url> --bundle-sha256 <sha256>
#   ./install_owntech.sh --run-phase git --project-path ~/owntech --non-interactive
#   ./install_owntech.sh --list-phases
#
# Not 'set -e': native commands (apt-get, git, curl, code) that exit non-zero
# for routine, recoverable reasons need to be checked and handled explicitly
# per call (see retry()/apt_install_verify()) rather than killing the whole
# script the instant any single command anywhere fails. Same rationale as
# install_owntech.ps1's $ErrorActionPreference = 'Continue'.
set -uo pipefail

# Forces apt to take its default answer for any package's debconf prompts
# instead of trying (and, without a real terminal, failing) to ask
# interactively. Confirmed via a real container run: even a plain 'apt-get
# install curl' walks through several debconf frontends before falling back
# to one that works, in ~4s of pure overhead -- a package that actually has a
# yes/no or license prompt (unlike anything installed today) would otherwise
# hang the whole script waiting for input that can never arrive.
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

ALL_PHASES=(preflight git python cmake vscode extensions clone bundle bootstrap build serial-permissions summary)
REPO_URL='https://github.com/owntech-foundation/Core'
SCRIPT_START=$(date +%s)

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

write_phase() {
    local elapsed=$(( $(date +%s) - SCRIPT_START ))
    printf '\n\033[1;36m== [%02d:%02d] %s ==\033[0m\n' "$((elapsed / 60))" "$((elapsed % 60))" "$1"
}

write_info() { printf '  %s\n' "$1"; }
write_ok()   { printf '  \033[32m[ok] %s\033[0m\n' "$1"; }
write_warn() { printf '  \033[33m[warn] %s\033[0m\n' "$1" >&2; }

stop_install() {
    local reason="$1" remediation="${2:-}"
    local elapsed=$(( $(date +%s) - SCRIPT_START ))
    printf '\n\033[31m  [FAILED] %s\033[0m\n' "$reason" >&2
    if [ -n "$remediation" ]; then
        printf '\033[31m  How to fix: %s\033[0m\n' "$remediation" >&2
    fi
    printf '\nInstaller stopped after %02d:%02d:%02d. Re-run the script after fixing the issue above; already-completed steps will be skipped.\n' \
        "$((elapsed / 3600))" "$(((elapsed % 3600) / 60))" "$((elapsed % 60))" >&2
    exit 1
}

# ----------------------------------------------------------------------------
# General helpers
# ----------------------------------------------------------------------------

# Absorbs transient network blips without requiring the user to notice a
# failure and manually re-run the whole script. Mirrors install_owntech.ps1's
# Invoke-WithRetry: 3 attempts, 2s/4s exponential backoff.
retry() {
    local description="$1"
    shift
    local max_attempts=3 delay=2 attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            return 1
        fi
        write_warn "$description failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# curl isn't guaranteed present the way Invoke-WebRequest is built into
# PowerShell -- ensure it exists before any phase that needs to download
# something (VS Code .deb, get-platformio.py, a package bundle).
ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi
    write_info "curl not found -- installing it (needed to download VS Code, PlatformIO bootstrap, etc.)..."
    if ! retry "apt-get update" sudo apt-get update -qq; then
        stop_install "Could not run 'apt-get update' to install curl." \
            "Check your internet connection / apt sources, then re-run this script."
    fi
    if ! retry "curl install (apt)" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates; then
        stop_install "Could not install curl via apt." \
            "Try 'sudo apt-get install -y curl ca-certificates' manually, then re-run this script."
    fi
    write_ok "curl installed."
}

# Generic apt-based install+verify, for the simple cases (git, cmake) --
# mirrors Install-WingetApp's shape without the winget-specific plumbing.
apt_install_verify() {
    local pkg_name="$1" verify_cmd="$2" display_name="$3"

    if command -v "$verify_cmd" >/dev/null 2>&1; then
        write_ok "$display_name already installed, skipping."
        return 0
    fi

    write_info "Installing $display_name ($pkg_name) via apt..."
    if ! retry "apt-get update" sudo apt-get update -qq; then
        stop_install "Could not run 'apt-get update' before installing $display_name." \
            "Check your internet connection / apt sources, then re-run this script."
    fi
    if ! retry "$display_name install (apt)" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg_name"; then
        stop_install "$display_name install failed (apt-get) after retries." \
            "Try running 'sudo apt-get install -y $pkg_name' manually to see the full error."
    fi

    if ! command -v "$verify_cmd" >/dev/null 2>&1; then
        stop_install "$display_name was installed by apt but '$verify_cmd' is still not on PATH." \
            "Open a new terminal (PATH changes need a fresh shell) and re-run this script."
    fi
    write_ok "$display_name installed."
}

install_vscode_extension() {
    local ext_id="$1" display_name="$2" required="${3:-}"

    if code --list-extensions 2>/dev/null | grep -qxF "$ext_id"; then
        write_ok "$display_name extension already installed."
        return 0
    fi

    write_info "Installing $display_name extension..."
    code --install-extension "$ext_id" --force >/dev/null 2>&1

    if ! code --list-extensions 2>/dev/null | grep -qxF "$ext_id"; then
        if [ "$required" = "required" ]; then
            stop_install "$display_name extension did not appear in 'code --list-extensions' after install." \
                "Open VS Code, go to Extensions, and install '$display_name' manually, then re-run this script."
        fi
        write_warn "$display_name extension did not appear after install -- continuing without it (not required for the build)."
        return 0
    fi
    write_ok "$display_name extension installed."
}

# Idempotently sets one KEY="VALUE" export in ~/.profile, replacing any
# earlier marker+export pair this script added for the same variable rather
# than accumulating duplicates across repeated runs.
persist_env_var() {
    local var_name="$1" var_value="$2"
    local marker="# owntech-installer: $var_name"
    local profile="$HOME/.profile"
    touch "$profile"
    awk -v m="$marker" 'BEGIN{skip=0} $0==m{skip=2; next} skip>0{skip--; next} {print}' "$profile" > "${profile}.tmp" && mv "${profile}.tmp" "$profile"
    {
        echo "$marker"
        echo "export $var_name=\"$var_value\""
    } >> "$profile"
}

# ----------------------------------------------------------------------------
# State persistence
# ----------------------------------------------------------------------------
#
# Carries state across process boundaries for --run-phase -- each isolated
# phase invocation is a fresh process with no memory of what earlier phases
# computed, unlike a default full run (which keeps everything in shell
# variables in one process). Deliberately KEY=value (sourceable), not JSON:
# bash has no built-in JSON support and this state is flat enough that a jq
# dependency isn't worth adding. Kept outside the project folder (XDG state
# dir) for the same reason as Windows' %LOCALAPPDATA% choice: a state file
# living inside the project folder would make a fresh, empty folder look
# non-empty before anything is actually cloned into it.

PROJECT_PATH=""
REPO_PATH=""
CORE_DIR=""
INSTALLED_GIT=0
INSTALLED_PYTHON=0
INSTALLED_CMAKE=0
INSTALLED_CODE=0
GROUP_CHANGED=0

state_file_path() {
    local project_path="$1"
    local state_dir="$HOME/.local/state/owntech-installer"
    mkdir -p "$state_dir"
    local normalized="${project_path%/}"
    local hash
    hash="$(printf '%s' "$normalized" | md5sum | awk '{print $1}')"
    printf '%s/install_state_%s.env\n' "$state_dir" "$hash"
}

load_state() {
    local path
    path="$(state_file_path "$1")"
    REPO_PATH=""
    CORE_DIR=""
    INSTALLED_GIT=0
    INSTALLED_PYTHON=0
    INSTALLED_CMAKE=0
    INSTALLED_CODE=0
    GROUP_CHANGED=0
    if [ -f "$path" ]; then
        # shellcheck disable=SC1090
        source "$path"
    fi
}

save_state() {
    local path
    path="$(state_file_path "$PROJECT_PATH")"
    {
        printf 'PROJECT_PATH=%q\n' "$PROJECT_PATH"
        printf 'REPO_PATH=%q\n' "$REPO_PATH"
        printf 'CORE_DIR=%q\n' "$CORE_DIR"
        printf 'INSTALLED_GIT=%q\n' "$INSTALLED_GIT"
        printf 'INSTALLED_PYTHON=%q\n' "$INSTALLED_PYTHON"
        printf 'INSTALLED_CMAKE=%q\n' "$INSTALLED_CMAKE"
        printf 'INSTALLED_CODE=%q\n' "$INSTALLED_CODE"
        printf 'GROUP_CHANGED=%q\n' "$GROUP_CHANGED"
    } > "$path"
}

# ----------------------------------------------------------------------------
# Phase 0 - Preflight
# ----------------------------------------------------------------------------

validate_project_path() {
    local path="$1"
    case "$path" in
        *" "*)
            stop_install "Project path '$path' contains spaces." \
                "Choose a path with no spaces, e.g. $HOME/owntech." ;;
    esac

    if [ "${#path}" -ge 4096 ]; then
        stop_install "Project path '$path' is ${#path} characters; must be under 4096." \
            "Choose a shorter path, e.g. $HOME/owntech."
    fi
    if [ "${#path}" -ge 200 ]; then
        write_warn "Project path '$path' is quite long (${#path} chars). Consider a shorter path to avoid issues with some toolchains."
    fi

    case "$path" in
        *Dropbox*|*Nextcloud*|*OneDrive*)
            write_warn "Project path '$path' looks like it's inside a cloud-sync folder (Dropbox/Nextcloud/OneDrive). Sync clients can lock files mid-build; consider a path outside any sync folder." ;;
    esac

    local depth
    depth=$(printf '%s' "${path%/}" | tr -cd '/' | wc -c)
    if [ "$depth" -gt 6 ]; then
        write_warn "Project path '$path' is nested $depth levels deep. Prefer a path close to \$HOME (e.g. $HOME/owntech) to avoid issues later."
    fi

    write_ok "Project path '$path' passes validation (no spaces, length OK)."
}

check_disk_space() {
    local path="$1" min_gb="$2"
    local check_path="$path"
    while [ ! -d "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path="$(dirname "$check_path")"
    done
    local avail_gb
    avail_gb="$(df --output=avail -BG "$check_path" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [ -z "$avail_gb" ]; then
        write_warn "Could not determine free space for $path -- skipping disk space check."
        return 0
    fi
    if [ "$avail_gb" -lt "$min_gb" ]; then
        stop_install "Only ${avail_gb}GB free for $path; at least ${min_gb}GB is recommended (PlatformIO downloads several hundred MB of toolchains on first build)." \
            "Free up disk space and re-run this script."
    fi
    write_ok "${avail_gb}GB free for $path (minimum ${min_gb}GB)."
}

# Mirrors Set-PlatformIOCoreDir: redirect PlatformIO's core dir onto the
# project's own filesystem if $HOME's filesystem is tight on space. Mostly
# moot on Linux (project path and $HOME are usually the same filesystem) but
# kept for machines where they genuinely differ (e.g. a separate /home or
# data partition).
resolve_core_dir() {
    local project_path="$1"
    local default_core_dir="$HOME/.platformio"

    local check_path="$project_path"
    while [ ! -d "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path="$(dirname "$check_path")"
    done

    local home_fs project_fs home_avail_gb
    home_fs="$(df --output=source "$HOME" 2>/dev/null | tail -n1)"
    project_fs="$(df --output=source "$check_path" 2>/dev/null | tail -n1)"
    home_avail_gb="$(df --output=avail -BG "$HOME" 2>/dev/null | tail -n1 | tr -dc '0-9')"

    if [ "$home_fs" = "$project_fs" ] || [ -z "$home_avail_gb" ] || [ "$home_avail_gb" -ge 8 ]; then
        CORE_DIR="$default_core_dir"
        return 0
    fi

    CORE_DIR="$project_path/.platformio_core"
    write_warn "\$HOME's filesystem has only ${home_avail_gb}GB free; redirecting PlatformIO's package cache to $CORE_DIR instead."
    persist_env_var "PLATFORMIO_CORE_DIR" "$CORE_DIR"
    export PLATFORMIO_CORE_DIR="$CORE_DIR"
}

phase_preflight() {
    printf '\033[1;36m===================================================\033[0m\n'
    printf '\033[1;36m OwnTech environment installer\033[0m\n'
    printf '\033[1;36m===================================================\033[0m\n'

    write_phase "Phase 0: Preflight"

    if [ ! -r /etc/os-release ]; then
        stop_install "Could not read /etc/os-release to detect the Linux distribution." \
            "This installer currently supports Debian/Ubuntu only."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    local is_debian_like=0
    if [ "${ID:-}" = "ubuntu" ] || [ "${ID:-}" = "debian" ]; then
        is_debian_like=1
    elif printf '%s' "${ID_LIKE:-}" | grep -qw debian; then
        is_debian_like=1
    fi
    if [ "$is_debian_like" -ne 1 ]; then
        stop_install "Detected distro '${PRETTY_NAME:-unknown}', which is not Debian/Ubuntu-based." \
            "This installer currently only supports Debian/Ubuntu (apt-based) distros. See linux_installer_plan.md non-goals."
    fi
    write_ok "Detected ${PRETTY_NAME:-Debian/Ubuntu-based distro}."

    if ! command -v apt-get >/dev/null 2>&1; then
        stop_install "apt-get is not available on this machine." \
            "This installer requires a Debian/Ubuntu-based distro with apt."
    fi
    write_ok "apt-get is available."

    ensure_curl

    if [ -z "$PROJECT_PATH" ]; then
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            PROJECT_PATH="$HOME/owntech"
        else
            local input_path
            read -r -p "Project folder to create/use [$HOME/owntech]: " input_path
            PROJECT_PATH="${input_path:-$HOME/owntech}"
        fi
    fi
    PROJECT_PATH="${PROJECT_PATH%/}"

    validate_project_path "$PROJECT_PATH"
    check_disk_space "$PROJECT_PATH" 5
    resolve_core_dir "$PROJECT_PATH"

    if [ ! -d "$PROJECT_PATH" ]; then
        if ! mkdir -p "$PROJECT_PATH"; then
            stop_install "Could not create project folder $PROJECT_PATH." \
                "Check that you have write permission to this location, then re-run this script."
        fi
        write_ok "Created project folder $PROJECT_PATH."
    else
        write_ok "Project folder $PROJECT_PATH already exists."
    fi

    INSTALLED_GIT=0; INSTALLED_PYTHON=0; INSTALLED_CMAKE=0; INSTALLED_CODE=0
    if command -v git >/dev/null 2>&1; then INSTALLED_GIT=1; write_ok "git already detected on PATH."; fi
    if command -v python3 >/dev/null 2>&1 && python3 -m venv --help >/dev/null 2>&1; then
        INSTALLED_PYTHON=1; write_ok "python3 (with venv support) already detected on PATH."
    fi
    if command -v cmake >/dev/null 2>&1; then INSTALLED_CMAKE=1; write_ok "cmake already detected on PATH."; fi
    if command -v code >/dev/null 2>&1; then INSTALLED_CODE=1; write_ok "code already detected on PATH."; fi

    save_state
}

# ----------------------------------------------------------------------------
# Phase 1 - Prerequisites
# ----------------------------------------------------------------------------

phase_git() {
    write_phase "Phase 1a: Install Git"
    apt_install_verify "git" "git" "Git"
}

phase_python() {
    write_phase "Phase 1b: Install Python"

    if command -v python3 >/dev/null 2>&1 && python3 -m venv --help >/dev/null 2>&1; then
        write_ok "Python 3 (with venv support) already installed, skipping."
        return 0
    fi

    write_info "Installing Python 3 (with venv/pip) via apt..."
    if ! retry "apt-get update" sudo apt-get update -qq; then
        stop_install "Could not run 'apt-get update' before installing Python 3." \
            "Check your internet connection / apt sources, then re-run this script."
    fi
    if ! retry "Python 3 install (apt)" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip; then
        stop_install "Python 3 install failed (apt-get) after retries." \
            "Try 'sudo apt-get install -y python3 python3-venv python3-pip' manually to see the full error."
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        stop_install "Python 3 was installed by apt but 'python3' is still not on PATH." \
            "Open a new terminal (PATH changes need a fresh shell) and re-run this script."
    fi

    # Real, Debian/Ubuntu-specific gotcha: python3-venv is a separate apt
    # package, not pulled in automatically by plain python3. Without it,
    # get-platformio.py's venv bootstrap (the 'bootstrap' phase) doesn't fail
    # loudly -- it silently produces a broken venv missing ensurepip, and the
    # failure only surfaces later, confusingly, inside that phase instead of
    # here where the actual cause is.
    if ! python3 -m venv --help >/dev/null 2>&1; then
        stop_install "'python3-venv' did not install correctly -- 'python3 -m venv' is not functional." \
            "Run 'sudo apt-get install --reinstall python3-venv' and re-run this script."
    fi

    write_ok "Python 3 (with venv support) installed."
}

phase_cmake() {
    write_phase "Phase 1c: Install CMake"
    apt_install_verify "cmake" "cmake" "CMake"
}

# ----------------------------------------------------------------------------
# Phase 2 - VS Code
# ----------------------------------------------------------------------------

phase_vscode() {
    write_phase "Phase 2: Install Visual Studio Code"

    if command -v code >/dev/null 2>&1; then
        write_ok "VS Code already installed, skipping."
        return 0
    fi

    write_info "Downloading the official VS Code .deb..."
    local deb_path
    deb_path="$(mktemp --suffix=.deb)"
    if ! retry "VS Code .deb download" curl -fsSL -o "$deb_path" "https://update.code.visualstudio.com/latest/linux-deb-x64/stable"; then
        rm -f "$deb_path"
        stop_install "Could not download the VS Code .deb package after retries." \
            "Check your internet connection, then re-run this script."
    fi

    # apt (not dpkg) so its own dependencies get resolved. The official .deb's
    # postinst also registers Microsoft's apt repo, so 'apt upgrade' keeps VS
    # Code current afterward without this script doing anything further.
    if ! retry "VS Code install (apt)" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_path"; then
        rm -f "$deb_path"
        stop_install "VS Code .deb install failed (apt-get) after retries." \
            "Try 'sudo apt-get install -y $deb_path' manually to see the full error."
    fi
    rm -f "$deb_path"

    if ! command -v code >/dev/null 2>&1; then
        stop_install "VS Code was installed but 'code' is still not on PATH." \
            "Open a new terminal (PATH changes need a fresh shell) and re-run this script."
    fi
    write_ok "VS Code installed."
}

phase_extensions() {
    write_phase "Phase 3: Install PlatformIO IDE extension"
    install_vscode_extension "platformio.platformio-ide" "PlatformIO IDE" required
    # Not build-critical -- failing to install either of these shouldn't stop
    # the rest of setup, unlike PlatformIO IDE itself.
    install_vscode_extension "shd101wyy.markdown-preview-enhanced" "Markdown Preview Enhanced"
    install_vscode_extension "mhutchie.git-graph" "Git Graph"
}

# ----------------------------------------------------------------------------
# Phase 4 - Clone Core
# ----------------------------------------------------------------------------

resolve_repo_path() {
    local project_path="$1"
    if [ -d "$project_path/.git" ]; then
        printf '%s\n' "$project_path"
        return 0
    fi
    if [ -d "$project_path" ] && [ -n "$(ls -A "$project_path" 2>/dev/null)" ]; then
        printf '%s/Core\n' "$project_path"
        return 0
    fi
    printf '%s\n' "$project_path"
}

test_complete_clone() {
    local repo_path="$1"
    [ -d "$repo_path/.git" ] || return 1
    git -C "$repo_path" rev-parse HEAD >/dev/null 2>&1
}

set_vscode_autorebuild_setting() {
    local repo_path="$1"
    local vscode_dir="$repo_path/.vscode"
    local settings_path="$vscode_dir/settings.json"
    mkdir -p "$vscode_dir"
    # python3 (guaranteed present by this point) handles the JSON merge --
    # simpler and more correct than hand-rolling JSON parsing in bash, and
    # avoids overwriting any settings already present in the upstream repo.
    python3 - "$settings_path" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}
settings['platformio-ide.autoRebuildAutocompleteIndex'] = False
with open(path, 'w') as f:
    json.dump(settings, f, indent=4)
PYEOF
    write_ok "Disabled PlatformIO's automatic IntelliSense index rebuild in $settings_path."
}

phase_clone() {
    write_phase "Phase 4: Clone the Core repository"

    local repo_path
    repo_path="$(resolve_repo_path "$PROJECT_PATH")"

    local has_git_dir=0
    [ -d "$repo_path/.git" ] && has_git_dir=1

    if [ "$has_git_dir" -eq 1 ] && test_complete_clone "$repo_path"; then
        write_ok "Core repository already cloned at $repo_path, skipping clone."
    else
        if [ "$has_git_dir" -eq 1 ]; then
            write_warn "Found an incomplete or corrupted clone at $repo_path (likely from an interrupted previous run) -- removing it and re-cloning."
        fi
        write_info "Cloning $REPO_URL into $repo_path ..."
        if ! retry "git clone" bash -c "rm -rf '$repo_path' && git clone '$REPO_URL' '$repo_path'"; then
            stop_install "git clone failed." \
                "Check your internet connection and that $repo_path doesn't already contain conflicting files, then re-run this script."
        fi
        write_ok "Cloned into $repo_path."
    fi

    local branch
    branch="$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ "$branch" != "main" ]; then
        stop_install "Repository at $repo_path is on branch '$branch', not 'main'." \
            "Run 'git -C $repo_path checkout main' and re-run this script."
    fi
    write_ok "On branch 'main'."

    set_vscode_autorebuild_setting "$repo_path"

    REPO_PATH="$repo_path"
    save_state
}

# ----------------------------------------------------------------------------
# Phase 5 - Smoke-test build
# ----------------------------------------------------------------------------

phase_bundle() {
    if [ "$SKIP_BUILD_TEST" -eq 1 ]; then
        write_phase "Phase 5a: Fetch package bundle (skipped via --skip-build-test)"
        return 0
    fi
    write_phase "Phase 5a: Fetch package bundle"

    if [ -z "$BUNDLE_URL" ]; then
        write_info "No bundle URL provided -- skipping (the build phase will fetch everything fresh)."
        return 0
    fi

    local packages_dir="$CORE_DIR/packages" platforms_dir="$CORE_DIR/platforms"
    if [ -d "$packages_dir" ] || [ -d "$platforms_dir" ]; then
        write_ok "PlatformIO packages/platforms already present in $CORE_DIR, skipping bundle download."
        return 0
    fi

    write_info "Downloading pre-baked PlatformIO package bundle (avoids fetching the full toolchain/framework set from scratch)..."
    local tarball
    tarball="$(mktemp --suffix=.tar.gz)"
    if ! retry "package bundle download" curl -fsSL -o "$tarball" "$BUNDLE_URL"; then
        write_warn "Could not download package bundle -- falling back to a full download during the build."
        rm -f "$tarball"
        return 0
    fi

    if [ -n "$BUNDLE_SHA256" ]; then
        local actual_hash
        actual_hash="$(sha256sum "$tarball" | awk '{print $1}')"
        if [ "$actual_hash" != "$BUNDLE_SHA256" ]; then
            write_warn "Package bundle checksum mismatch (expected $BUNDLE_SHA256, got $actual_hash) -- discarding and falling back to a full download."
            rm -f "$tarball"
            return 0
        fi
    fi

    mkdir -p "$CORE_DIR"
    if tar xzf "$tarball" -C "$CORE_DIR"; then
        write_ok "Pre-baked package bundle extracted into $CORE_DIR. Any packages missing or out of date will still be fetched normally by the build below."
    else
        write_warn "Could not extract package bundle -- falling back to a full download during the build."
    fi
    rm -f "$tarball"
}

phase_bootstrap() {
    if [ "$SKIP_BUILD_TEST" -eq 1 ]; then
        write_phase "Phase 5b: Bootstrap PlatformIO Core (skipped via --skip-build-test)"
        return 0
    fi
    write_phase "Phase 5b: Bootstrap PlatformIO Core"

    local pio_exe="$CORE_DIR/penv/bin/platformio"
    if [ -x "$pio_exe" ]; then
        write_ok "PlatformIO Core already bootstrapped at $CORE_DIR, skipping."
        return 0
    fi

    # Same get-platformio.py bootstrap the VS Code extension itself uses --
    # it creates a self-contained venv at <core dir>/penv. A plain
    # 'pip install platformio' builds fine but does NOT create that layout,
    # so the extension doesn't recognize it as done and reinstalls its own
    # copy from scratch when the folder is opened.
    write_info "Bootstrapping PlatformIO Core into $CORE_DIR (same layout the VS Code extension expects, so it won't redo this)..."
    local bootstrap_script
    bootstrap_script="$(mktemp --suffix=.py)"
    if ! retry "get-platformio.py download" curl -fsSL -o "$bootstrap_script" "https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py"; then
        rm -f "$bootstrap_script"
        stop_install "Failed to download the PlatformIO Core bootstrap script." \
            "Check your internet connection, then re-run this script."
    fi

    PLATFORMIO_CORE_DIR="$CORE_DIR" python3 "$bootstrap_script"
    local bootstrap_exit=$?
    rm -f "$bootstrap_script"

    if [ "$bootstrap_exit" -ne 0 ] || [ ! -x "$pio_exe" ]; then
        stop_install "PlatformIO Core bootstrap failed (exit code $bootstrap_exit)." \
            "Check your internet connection, then re-run this script (or re-run with --skip-build-test to skip this check)."
    fi
    write_ok "PlatformIO Core bootstrapped at $CORE_DIR."
}

phase_build() {
    if [ "$SKIP_BUILD_TEST" -eq 1 ]; then
        write_phase "Phase 5c: Build firmware (skipped via --skip-build-test)"
        return 0
    fi
    write_phase "Phase 5c: Build firmware"

    local pio_exe="$CORE_DIR/penv/bin/platformio"
    write_info "Running first build in $REPO_PATH (this downloads toolchains/framework packages on first run, can take several minutes)..."

    local build_log
    build_log="$(mktemp)"
    if ! (cd "$REPO_PATH" && "$pio_exe" run) > "$build_log" 2>&1; then
        printf '\n  \033[33mLast 25 lines of build output:\033[0m\n'
        tail -n 25 "$build_log"
        rm -f "$build_log"
        stop_install "First build failed." \
            "See the build output above. Common causes: interrupted network mid-download, or a missing system library. See docs/environment_setup.md#troubleshooting."
    fi
    rm -f "$build_log"
    write_ok "Build succeeded."
}

# ----------------------------------------------------------------------------
# Phase - USB serial permissions (no Windows analog)
# ----------------------------------------------------------------------------
#
# Windows confirmed (on real hardware) that no driver was needed at all for
# the SPIN board. Linux has a real, different failure mode instead: without
# 'dialout' group membership, accessing a USB-serial device
# (/dev/ttyACM0-style) requires root. This phase only fixes that
# precondition -- actual board upload stays manual, same non-goal boundary as
# Windows' Steps 7-8.

phase_serial_permissions() {
    write_phase "Phase: USB serial permissions"

    if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
        write_ok "User '$USER' is already in the 'dialout' group."
        return 0
    fi

    write_info "Adding '$USER' to the 'dialout' group (needed for USB-serial access to the SPIN board without root)..."
    if ! sudo usermod -aG dialout "$USER"; then
        write_warn "Could not add '$USER' to the 'dialout' group -- board upload may fail with a permission error until this is fixed manually ('sudo usermod -aG dialout $USER')."
        return 0
    fi

    # A group change via usermod does NOT take effect in the current login
    # session -- unlike a PATH change, a new terminal alone is not enough,
    # only a full logout/login is. Silently confusing if unstated: the user
    # would retry the upload in the same session, still fail, and have no
    # reason to suspect a logout is what's actually needed.
    write_warn "Added '$USER' to the 'dialout' group. This does NOT take effect in your current session -- log out and log back in (a new terminal is not enough) before trying to upload to the board."
    GROUP_CHANGED=1
    save_state
}

# ----------------------------------------------------------------------------
# Phase - Summary
# ----------------------------------------------------------------------------

phase_summary() {
    write_phase "Phase: Summary"

    local elapsed=$(( $(date +%s) - SCRIPT_START ))
    printf '\n\033[32mSetup complete.\033[0m\n\n'
    printf '  Total install time: %02d:%02d:%02d\n' "$((elapsed / 3600))" "$(((elapsed % 3600) / 60))" "$((elapsed % 60))"
    printf '  Project folder: %s\n\n' "$REPO_PATH"
    printf '  Component status:\n'
    printf '    - git: %s\n' "$([ "$INSTALLED_GIT" -eq 1 ] && echo 'already present' || echo 'installed by this script')"
    printf '    - python3: %s\n' "$([ "$INSTALLED_PYTHON" -eq 1 ] && echo 'already present' || echo 'installed by this script')"
    printf '    - cmake: %s\n' "$([ "$INSTALLED_CMAKE" -eq 1 ] && echo 'already present' || echo 'installed by this script')"
    printf '    - code: %s\n\n' "$([ "$INSTALLED_CODE" -eq 1 ] && echo 'already present' || echo 'installed by this script')"

    printf '  Remaining manual steps:\n'
    printf '    1. Connect your SPIN board via USB-C (its PWR LED should light up).\n'
    printf '    2. In VS Code, use the Build (check mark) icon in the status bar.\n'
    printf '    3. Then Upload (arrow icon) to flash the board and see the LED blink.\n\n'

    if [ "$GROUP_CHANGED" -eq 1 ]; then
        printf '  \033[33mReminder: you were just added to the '"'"'dialout'"'"' group -- log out and back in before step 3 will work.\033[0m\n\n'
    fi

    if [ "$NON_INTERACTIVE" -ne 1 ]; then
        local open_code
        read -r -p "Open the project in VS Code now? [Y/n] " open_code
        if [[ ! "$open_code" =~ ^[Nn] ]]; then
            code "$REPO_PATH" >/dev/null 2>&1 &
        fi
    fi
}

# ----------------------------------------------------------------------------
# Argument parsing / dispatch
# ----------------------------------------------------------------------------

SKIP_BUILD_TEST=0
NON_INTERACTIVE=0
BUNDLE_URL=""
BUNDLE_SHA256=""
RUN_PHASE=""
LIST_PHASES=0

print_usage() {
    cat <<EOF
Usage: $0 [options]

  --project-path PATH     Project folder to create/use (default: prompt, or \$HOME/owntech with --non-interactive)
  --skip-build-test       Skip the bundle/bootstrap/build phases (Phase 5)
  --non-interactive       Never prompt; use defaults
  --bundle-url URL        Pre-baked PlatformIO packages/platforms tarball to seed a fresh core dir from
  --bundle-sha256 HASH    Expected SHA256 of --bundle-url's tarball
  --run-phase NAME        Run a single named phase in isolation (see --list-phases)
  --list-phases           Print phase names, one per line, and exit
  -h, --help              Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project-path) PROJECT_PATH="$2"; shift 2 ;;
        --project-path=*) PROJECT_PATH="${1#*=}"; shift ;;
        --skip-build-test) SKIP_BUILD_TEST=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --bundle-url) BUNDLE_URL="$2"; shift 2 ;;
        --bundle-url=*) BUNDLE_URL="${1#*=}"; shift ;;
        --bundle-sha256) BUNDLE_SHA256="$2"; shift 2 ;;
        --bundle-sha256=*) BUNDLE_SHA256="${1#*=}"; shift ;;
        --run-phase) RUN_PHASE="$2"; shift 2 ;;
        --run-phase=*) RUN_PHASE="${1#*=}"; shift ;;
        --list-phases) LIST_PHASES=1; shift ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 1 ;;
    esac
done

run_single_phase() {
    local phase="$1"
    local valid=0 p
    for p in "${ALL_PHASES[@]}"; do
        [ "$p" = "$phase" ] && valid=1
    done
    if [ "$valid" -ne 1 ]; then
        echo "Unknown phase '$phase'. Valid phases: ${ALL_PHASES[*]}" >&2
        exit 1
    fi

    if [ "$phase" != "preflight" ]; then
        if [ -z "$PROJECT_PATH" ]; then
            echo "--project-path is required with --run-phase $phase (only 'preflight' can resolve/prompt for it)." >&2
            exit 1
        fi
        load_state "$PROJECT_PATH"
    fi

    case "$phase" in
        preflight) phase_preflight ;;
        git) phase_git ;;
        python) phase_python ;;
        cmake) phase_cmake ;;
        vscode) phase_vscode ;;
        extensions) phase_extensions ;;
        clone) phase_clone ;;
        bundle) phase_bundle ;;
        bootstrap) phase_bootstrap ;;
        build) phase_build ;;
        serial-permissions) phase_serial_permissions ;;
        summary) phase_summary ;;
    esac
}

if [ "$LIST_PHASES" -eq 1 ]; then
    printf '%s\n' "${ALL_PHASES[@]}"
    exit 0
fi

if [ -n "$RUN_PHASE" ]; then
    run_single_phase "$RUN_PHASE"
    exit 0
fi

# Default: no --run-phase, run every phase in order in this one process --
# behavior identical in shape to install_owntech.ps1's own default mode.
phase_preflight
phase_git
phase_python
phase_cmake
phase_vscode
phase_extensions
phase_clone
phase_bundle
phase_bootstrap
phase_build
phase_serial_permissions
phase_summary
