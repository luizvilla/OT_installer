# Plan — Linux Installer for OwnTech Environment Setup

## Status

Core installer: implemented and tested. All five planned scripts exist under `linux/`
(`install_owntech.sh`, `reset_environment.sh`, `test_hardening.sh`, `run_timed_install_test.sh`,
`build_platformio_bundle.sh`) and every phase, plus a full end-to-end run, an idempotent re-run, a
real reset+reinstall timed cycle, and a real bundle build/consume round-trip, have been verified
against a real `ubuntu:24.04` Docker container (non-root user, passwordless sudo — see "Container-based
development loop" below). See "Implementation notes" at the end of this doc for what testing actually
found and changed versus this plan's original design.

GUI wizard (`.deb` + Zenity): implemented and tested end-to-end (including a real forced-failure
retry/cancel run and a full genuine build through to `firmware.elf`/`firmware.bin`), except a literal
human click-through of the Applications-menu launch on this real machine, which needs the user's `sudo`
password and an actual mouse click — see "GUI wizard (.deb + Zenity)" below for design and full results.

## Problem

`../windows_installer_plan.md` automated Steps 1–6 of `docs/environment_setup.md` on Windows and
explicitly called out Linux as a **non-goal for v1**: "different tooling and failure modes, separate
effort if pursued later." That effort starts here. The underlying problem is the same one the Windows
side identified — this is a reliability problem, not a communication one. A newcomer following the
manual doc on Linux hits a different set of silent failure modes than on Windows (distro package
manager quirks, USB serial permissions, `python3-venv` not being bundled with `python3`), but the shape
of the problem — too many steps with silent failure modes before ever seeing a blinking LED — is
identical.

## Goals

- Automate the same Steps 1–6 on Debian/Ubuntu: project folder, VS Code, PlatformIO extension,
  cloning Core, and a first build.
- Fail fast and specific, same philosophy as Windows: every phase validates its own outcome and
  reports what went wrong and how to fix it.
- Idempotent: safe to re-run on a machine that's already partially set up.
- Also fix a Linux-specific failure mode Windows never had: USB-serial permissions for the SPIN
  board, so users don't hit a silent "permission denied" the first time they try to upload.
- Docs stay the detailed manual reference; this installer becomes the recommended fast path, same as
  on Windows.

## Non-goals (v1)

- Distros other than Debian/Ubuntu (Fedora/RHEL via `dnf`, Arch via `pacman`, etc.) — different
  package managers and failure modes, a separate effort if pursued later, exactly how Windows itself
  scoped out Linux/macOS from its own v1.
- Board upload itself (Steps 7–8) — hardware-dependent, stays manual, same as Windows. This plan does
  fix the *permission* precondition for upload (see `serial-permissions` phase below), but not the
  upload step itself.
- A GUI wizard — start as a script only, same sequencing the Windows side used (`install_owntech.ps1`
  was proven reliable via real-machine testing *before* `wizard/OwnTechInstaller.iss` was built on top
  of it). Only invest in a GUI here if the plain-script UX turns out to actually matter to users.
- Requiring the whole script to run as root. Individual commands that need privilege escalation
  (`apt-get install`, `usermod -aG dialout`) go through `sudo` themselves; the script as a whole runs
  as the invoking user, so cloned repos, VS Code extensions, and the PlatformIO venv stay owned by
  that user rather than root.

## Approach

A Bash script, `install_owntech.sh`, driving `apt-get`, structured as discrete phases with explicit
checks between them — the same shape as `install_owntech.ps1`, adapted to Linux tooling. Bash was
chosen over Python specifically to avoid a chicken-and-egg problem: Python is one of the things this
script installs, so the script itself can't depend on it being present yet. This mirrors and reuses
the same phase/state/retry architecture Windows already proved out, rather than inventing a different
structure for Linux.

Rationale for `apt` over a universal method (curl-pipe-installers per tool, snap, etc.): it's the
native, auditable package manager for the target distros, matches how `winget` was chosen on Windows
(no bundled installer binaries to keep up to date, correct flags handled by the package manager
itself), and every tool needed here (`git`, `python3`, `cmake`) has a standard Debian/Ubuntu package.
VS Code is the one exception — it ships its own `.deb` rather than being in the default Ubuntu
repositories, addressed in its own phase below.

## Phases

Each phase is independently invocable via `--run-phase <name>` (mirrors `-RunPhase` on Windows), so a
future GUI wrapper — or a test harness — can drive one phase at a time and check its own exit code,
without re-deriving Pascal-side validation logic. State is persisted across phase invocations (since
each is a fresh process) to a flat file:

```
~/.local/state/owntech-installer/install_state_<md5-of-normalized-project-path>.env
```

This deliberately uses `KEY=value` shell-sourceable format, not JSON — bash has no built-in JSON
parsing, and the state here (`PROJECT_PATH`, `REPO_PATH`, `CORE_DIR`, `INSTALLED_GIT`,
`INSTALLED_PYTHON`, `INSTALLED_CMAKE`, `INSTALLED_CODE`) is flat enough that adding a `jq` dependency
just to read/write it isn't worth it. Each phase `source`s the file at start and rewrites it at end,
the same role `Get-InstallState`/`Save-InstallState` play on Windows. Kept outside the project folder
(`~/.local/state`, XDG-style) for the same reason as Windows' `%LOCALAPPDATA%` choice: a state file
living inside the project folder would make a fresh, empty folder look non-empty before anything is
actually cloned into it.

### Phase 0 — Preflight

- Verify the distro: read `/etc/os-release`, check `ID` or `ID_LIKE` contains `debian` or `ubuntu`.
  Fatal otherwise, with remediation pointing at this doc's non-goals (other distros not supported
  yet).
- Verify `apt-get` is on PATH (should always be true if the distro check passed, but check anyway —
  same defensive style as Windows' `Test-WingetAvailable`).
- Resolve the project path (flag, or prompt, or a `--non-interactive` default of `~/owntech`).
- Validate the project path:
  - No spaces — kept even though Linux handles spaces in paths fine at the shell level, because
    PlatformIO/Zephyr's toolchain packaging has shown whitespace-path bugs that are toolchain-side,
    not OS-side (Windows hit this via a spaced *username* under `%USERPROFILE%`; a spaced Linux path
    would hit the same underlying PlatformIO/Zephyr bug).
  - Not under a known cloud-sync folder — check for `Dropbox`, `Nextcloud`, `OneDrive` as path
    substrings, **warn only, not fatal** (unlike Windows' fatal OneDrive check): Linux has no single
    dominant sync client, so this is a softer, more speculative check than the Windows one.
  - Path length — Linux path limits (4096 total, 255 per component) are far looser than Windows' 260
    chars, so this becomes a warn-only sanity check at a much higher threshold, not a fatal gate.
- Disk space via `df --output=avail -B1G <path>` (or equivalent), same 5GB minimum floor as Windows.
- PlatformIO core-dir redirect logic: mostly moot on Linux (`$HOME` and the project path are usually
  the same filesystem), but keep the same *shape* of check — if `df` on `$HOME`'s filesystem shows
  under 8GB free and the project path resolves to a different filesystem, redirect
  `PLATFORMIO_CORE_DIR` to `<project-path>/.platformio_core` and persist it (in the user's shell rc
  file, e.g. append an export line to `~/.profile`, since Linux has no registry to write a durable
  env var into the way Windows does).
- Detect already-installed components: `command -v git`, `command -v python3` (+ `python3 --version`
  matching `^Python 3`), `command -v cmake`, `command -v code`.
- Create the project folder if missing.
- Write the state file.

### Phase 1a — `git`

`sudo apt-get update && sudo apt-get install -y git`. Verify via `command -v git`. Fatal with
remediation ("check your internet connection / apt sources, then re-run") if still missing after
install.

### Phase 1b — `python`

`sudo apt-get install -y python3 python3-venv python3-pip`.

**Real, Debian-specific gotcha worth its own explicit check, not just an apt install line**:
`python3-venv` is a separate apt package, not pulled in automatically by plain `python3` on
Ubuntu/Debian. Without it, `get-platformio.py`'s venv bootstrap (Phase 5b/`bootstrap`) doesn't fail
loudly — it silently produces a broken venv missing `ensurepip`, and the failure only surfaces later,
confusingly, inside the bootstrap phase. This is exactly the class of failure mode this whole project
exists to catch (compare to Windows' Python-Store-alias-stub check in `Test-PythonReal`), so the
`python` phase verifies `python3 -m venv --help` actually works (not just that `python3` is on PATH)
before considering itself done, and if not, gives the specific remediation ("run `sudo apt-get install
python3-venv`") rather than a generic failure.

### Phase 1c — `cmake`

`sudo apt-get install -y cmake`. Verify via `command -v cmake`.

### Phase 2 — `vscode`

Download the official `.deb` from `https://update.code.visualstudio.com/latest/linux-deb-x64/stable`,
then `sudo apt install ./vscode.deb` (not `dpkg -i`, so apt resolves the `.deb`'s own dependencies).
The official `.deb`'s postinst script registers Microsoft's apt repository automatically, so a later
plain `apt upgrade` keeps VS Code current — simpler than manually importing the GPG key and apt source
line by hand, and gets the same end state. Verify via `command -v code`.

### Phase 3 — `extensions`

Identical to Windows: `code --install-extension platformio.platformio-ide --force` (required, fatal if
missing after install), then `shd101wyy.markdown-preview-enhanced` and `mhutchie.git-graph` (optional,
warn-only, non-fatal). No `sudo` needed — extensions install into the user's own VS Code profile.

### Phase 4 — `clone`

Same logic as Windows' `Invoke-CloneCore`/`Get-RepoPath`:
- If the project folder already has a `.git` dir, reuse it directly.
- Else if the project folder is non-empty (and isn't our clone), clone into a `Core` subfolder instead
  of colliding with existing contents.
- Verify a complete clone via `git rev-parse HEAD` (not just `.git` presence) — auto-heal an
  incomplete/corrupt clone (from an interrupted previous run) by removing and re-cloning, same as
  Windows.
- Verify the resulting branch is `main`; fatal with remediation otherwise.
- Apply the same `.vscode/settings.json` patch disabling
  `platformio-ide.autoRebuildAutocompleteIndex`, merging into any existing settings rather than
  overwriting them.

### Phase 5a — `bundle` (optional optimization)

Same idea as Windows' `Invoke-BundleSeed`, but the artifact itself is Linux/x86_64-specific — a
`platformio_core_linux_x64.tar.gz` of a populated `~/.platformio/{packages,platforms}`, built by a
future `build_platformio_bundle.sh` maintainer tool. Architecture-specific because the toolchain
binaries inside differ from the Windows bundle; the Windows bundle can't be reused here.

Extraction uses plain `tar xzf` — no equivalent of the Windows `7za.exe` workaround is expected to be
needed, since that whole detour existed because Windows Explorer's `Expand-Archive` plus Defender's
on-access scanning made extraction dramatically slower than the archive's compression alone would
predict. Linux has no on-access AV scanning by default and `tar`/`gzip` extraction of many small files
is not known to have an analogous bottleneck; this should be confirmed once real timing data exists,
but there's no a-priori reason to pre-build a workaround for a problem that may not occur.

Same fallback behavior as Windows: if the bundle can't be fetched, verified (checksum), or extracted,
skip it silently and let the `build` phase's normal `pio run` fetch everything from scratch.

### Phase 5b — `bootstrap`

Same `get-platformio.py` bootstrap script Windows uses (it's cross-platform already), run via
`python3` instead of `python`, producing the same `<core dir>/penv` layout the VS Code PlatformIO
extension itself expects — same rationale as Windows: a plain `pip install platformio` builds fine but
doesn't produce that layout, so the extension doesn't recognize it as done and silently redoes the
work.

### Phase 5c — `build`

Same `pio run` smoke-test build inside the cloned repo. Fatal, no retry, same "print last 25 lines of
build output" behavior on failure.

### Phase `serial-permissions` — new, no Windows analog

Windows confirmed (on real hardware, `windows_installer_plan.md`, "SPIN board USB/upload path verified
on real hardware") that no driver was needed at all for the SPIN board. Linux has a different, real
failure mode instead: accessing a USB-serial device (typically `/dev/ttyACM0` or `/dev/ttyUSB0`)
without root requires the invoking user's account to be a member of the `dialout` group (on
Debian/Ubuntu); if the board exposes itself via an ST-Link/CMSIS-DAP-style debug probe, that
conventionally also needs a udev rules file granting non-root access to that specific USB
vendor/product ID.

This phase:
- Checks group membership (`groups "$USER"` or `id -nG`), and if `dialout` is missing, runs
  `sudo usermod -aG dialout "$USER"`.
- **Warns explicitly and loudly** that a group change via `usermod` does **not** take effect in the
  current login session — the user must fully log out and back in (a new terminal is not enough,
  unlike re-reading `PATH`), a genuinely different gotcha from anything Windows has, and one that
  silently confuses users if unstated (they'll retry the upload in the same session, still fail, and
  have no reason to suspect a logout is what's actually needed).
- Leaves actual udev-rule installation as an open decision (see below) pending whether OwnTech ships
  a rules file for the board's specific debug-probe hardware — installing a *generic* rules file here
  without knowing the exact VID/PID would be guessing, not automating a known-good procedure.
- Does not attempt the upload itself — same non-goal boundary as Windows' Steps 7–8.

### Phase — `summary`

Same content as Windows' Phase 6: total elapsed time, which components were pre-existing vs. installed
by this run, project folder location, and remaining manual steps — connect the SPIN board via USB-C,
Build (checkmark) then Upload (arrow) in VS Code — plus, if the `serial-permissions` phase changed
group membership this run, a repeated reminder to log out and back in first.

## Error-handling philosophy

Identical in spirit to Windows' `Stop-Install`: a `stop_install "<reason>" "<remediation>"` bash
function that prints both, then `exit 1`. Every fatal error carries a specific, actionable remediation
string, not a generic failure. A `retry` helper (3 attempts, 2s/4s exponential backoff) wraps every
`apt-get`, `git clone`, and `curl` network call — the same role `Invoke-WithRetry` plays on Windows.
Recoverable-vs-fatal classification mirrors the Windows table:

| Step | Recoverable? | On exhausted failure |
|---|---|---|
| `git`/`python`/`cmake`/`vscode` (apt/curl) | Retry w/ backoff | Fatal |
| PlatformIO IDE extension | No retry | Fatal (required) |
| Markdown Preview / Git Graph extensions | No retry | Warning only, continues |
| Clone OwnTech Core | Retry w/ backoff + auto-heal incomplete clone | Fatal |
| Fetch package bundle | Retry w/ backoff | Falls back gracefully (not fatal) |
| Bootstrap PlatformIO Core | Download has retry; running it does not | Fatal |
| Build firmware | No retry | Fatal (show last 25 log lines) |
| `serial-permissions` group change | N/A (single `usermod` call) | Warn, non-fatal — board upload just won't work until fixed, but doesn't block the rest of setup |
| Preflight checks | N/A — validation, not network calls | Fatal |

## Testing plan (executed — see "Implementation notes" for what it found)

### Container-based development loop (primary iteration method)

Unlike Windows — where the disposable "reset machine" had to be a real box or a VM — most of this
script's phases have no hardware dependency at all, which makes a plain container the fast, safe,
default way to iterate while writing `install_owntech.sh`, reserving a real machine/VM for the one
phase that genuinely needs one. Confirmed workable on the dev machine this plan was written on:
Docker is installed and the daemon is active there (`systemctl is-active docker` → `active`); the
invoking user just needs to either prefix commands with `sudo docker ...` or be added to the
`docker` group (`sudo usermod -aG docker $USER`, then a full log-out/log-in — the same "group change
needs a real login, not just a new terminal" caveat as the `serial-permissions` phase's `dialout`
change below, not a coincidence, both are Linux group-membership semantics).

**Recipe:**

1. Base image `ubuntu:24.04` — matches the plan's target distro exactly (not just "some Ubuntu").
2. Inside the container, create a non-root user with passwordless sudo before running anything
   (`useradd -m tester && usermod -aG sudo,dialout tester`), and run `install_owntech.sh` as that
   user, not as root. This matters beyond realism: the script's design explicitly runs unprivileged
   and elevates individual commands via `sudo`, not the whole process — testing as root would mask
   bugs in that split, and VS Code's own CLI is known to behave differently (and worse) under root.
3. Mount or `docker cp` the script in (`docker run --rm -it -v "$(pwd)":/opt/owntech ubuntu:24.04
   bash`), then run phases one at a time via `--run-phase`, checking exit codes and the resulting
   state file the same way `test_hardening.sh`'s per-phase-equivalence test will.
4. Throw the container away (`--rm`) and start fresh for the next cycle, rather than relying on
   `reset_environment.sh` to perfectly clean it — a disposable container already *is* the disposable
   machine the Windows-side testing philosophy called for, just cheaper to obtain than a VM.

**Coverage — what a container validates vs. doesn't:**

| Phase | Container-testable? |
|---|---|
| `preflight`, `git`, `python`, `cmake`, `vscode`, `extensions`, `clone`, `bundle`, `bootstrap`, `build` | Yes — pure apt/CLI/network work, no hardware involved |
| `serial-permissions` (dialout group, udev rules) | No — containers have no systemd/udev by default and no real USB device unless explicitly passed through (`--device=/dev/ttyACM0`), which defeats the point of a throwaway container |
| Actually plugging in and uploading to the SPIN board | No — needs real hardware regardless, same as Windows |

So a container covers everything through a real firmware build — the large majority of the script —
and should be the default place bugs get found first. A real machine (or a VM with USB passthrough)
is only strictly required for the `serial-permissions` phase and the final hardware-upload
verification, mirroring how the Windows plan itself needed real hardware just for its own SPIN-board
USB check.

### Scripted test tooling (mirrors Windows' test tooling, adapted)

- **`test_hardening.sh`** — equivalent of `test_hardening.ps1`, 4 groups, all passing (~40s total in
  the test container). Two groups ended up implemented differently than originally proposed here, for
  reasons worth recording: (2) `retry()`'s backoff/recovery is unit-tested directly against
  controllable fake counter-based commands, by `source`-ing `install_owntech.sh` itself (see
  "Implementation notes" — this required a `BASH_SOURCE` guard around the script's dispatch block, not
  originally planned) — simpler and more deterministic than standing up a real HTTP server, while still
  exercising the exact function every network call depends on. (3) apt-retry is tested against a real
  `apt-get` and a package name guaranteed not to exist, rather than a PATH-based `apt-get` shim: since
  `install_owntech.sh` invokes apt via `sudo`, a shim would need to survive `sudo`'s own `secure_path`
  (which resolves `apt-get` itself, ignoring the caller's `PATH` where configured) — a real nonexistent
  package sidesteps that entirely and is just as deterministic (it fails identically every attempt).
  (1) bad-path cases and (4) per-phase-vs-full-run equivalence were implemented as originally planned.
- **`reset_environment.sh`** — equivalent of `reset_environment.ps1`: `apt-get remove` the installed
  packages, delete `~/.platformio` (or the redirected core dir), VS Code config
  (`~/.config/Code`), `~/.gitconfig`, pip cache — for repeatable dry runs on a disposable test
  machine. Same explicit warning as Windows: only for disposable test VMs/containers, never a
  daily-driver machine — `apt-get remove git`/`cmake` would happily remove tooling other software on
  a real host actually depends on, unlike the Flatpak-style isolation VS Code itself happens to have.
  Mainly useful for a real-machine/VM test pass; largely superseded by "just discard the container"
  during container-based iteration.
- **`run_timed_install_test.sh`** — equivalent of `run_timed_install_test.ps1`: chains reset → timed
  install, appends to a `install_timing_history.csv` for comparing install time across runs (e.g.
  bundle vs. no-bundle).
- Real-machine (or VM with USB passthrough) test pass on at least one current Ubuntu LTS release,
  specifically to exercise `serial-permissions` and actual board upload — the parts a container
  can't reach — before treating this as proven, same bar Windows held itself to before building the
  wizard on top.

## Open decisions

- Whether to ship a project-specific udev rules file for the SPIN board's debug probe as part of
  `serial-permissions`, once the exact USB VID/PID is known — currently just warns and fixes group
  membership.
- Whether `sudo` credentials should be front-loaded with one `sudo -v` call at the start of a phase
  that needs it (so the password prompt happens once, predictably, at phase start) vs. letting each
  individual `sudo apt-get`/`sudo usermod` call prompt inline — a UX detail worth deciding once the
  script is actually run interactively a few times, not before.
- Whether Fedora/Arch support is worth pursuing after Debian/Ubuntu v1 is proven, and if so, whether
  that becomes distro-detection branching in the same script or genuinely separate scripts per distro
  family.
- Whether this installer replaces Steps 1–6 in `environment_setup.md` outright for Linux users, or
  the docs keep the manual steps with a "Quick install" callout, same open question Windows left
  unresolved for itself.
- GUI wizard — deferred per this session's decision; revisit only if the plain-script UX turns out to
  matter to users, same bar Windows set for itself before building `wizard/OwnTechInstaller.iss`.

## Related files

- [`install_owntech.sh`](install_owntech.sh) — the installer, implementing all phases above (0–6 plus
  `serial-permissions`). Reports per-phase elapsed time and a total install time, same as Windows.
- [`reset_environment.sh`](reset_environment.sh) — resets a disposable test machine/container to a
  clean state between test passes; supports `--include-python` and `--non-interactive`.
- [`build_platformio_bundle.sh`](build_platformio_bundle.sh) — packages a populated PlatformIO core
  dir's `packages`/`platforms` into a Linux/x86_64 `.tar.gz` for the `bundle` phase's `--bundle-url`.
- [`run_timed_install_test.sh`](run_timed_install_test.sh) — chains reset → timed install, appends each
  cycle's result to `install_timing_history.csv`.
- [`test_hardening.sh`](test_hardening.sh) — automated test suite (4 groups, all passing).

## Implementation notes

Real corrections found only by testing against an actual `ubuntu:24.04` container — none of these were
anticipated when this doc was first written, same pattern Windows' own implementation notes describe
(e.g. its `pip install platformio` → `get-platformio.py` switch):

- **`python3 -m venv --help` does not test whether venv actually works — a real false positive, not a
  hypothetical one.** It exits 0 unconditionally, because the `--help` text ships as part of core
  `python3` regardless of whether the real implementation package (`python3.12-venv` on 24.04) is
  installed. The actual Debian/Ubuntu failure ("ensurepip is not available") only appears when a real
  venv is created. This silently passed on exactly the broken state the `python` phase exists to catch
  — confirmed by deliberately removing `python3.12-venv` and watching the old check report success
  anyway. Fixed with a `python3_venv_functional()` helper that creates a real venv in a temp dir and
  checks `bin/pip` exists, then cleans up; wired into preflight detection, the `python` phase's
  pre-check, and its post-install verification.
- **`$USER` is not reliably set** — confirmed absent under `docker exec` (unlike a normal interactive
  login shell), which under this script's `set -u` turned every reference in `serial-permissions` into
  a hard crash the moment the phase ran. Fixed by using `id -un` instead, which works regardless of how
  the process was started.
- **Plain `apt-get remove` leaves orphaned dependencies behind.** `reset_environment.sh --include-python`
  removing `python3-venv` (a thin meta-package) doesn't cascade to the versioned implementation package
  (`python3.12-venv`) unless `--autoremove` is passed *and* that specific invocation is what actually
  removes the meta-package — if it was already gone from an earlier reset, the versioned package is
  left behind, orphaned but still fully functional, defeating the reset's purpose. Fixed by adding
  `--autoremove` and also explicitly targeting the versioned package name (computed from the running
  `python3`'s own version) rather than relying on the cascade alone.
- **`sudo` doesn't forward the parent process's exported environment by default.** `DEBIAN_FRONTEND=
  noninteractive` exported at the top of `install_owntech.sh` never reached the actual `apt-get`
  processes running under `sudo` — confirmed via a real run, where a plain `apt-get install curl` cycled
  through several debconf frontends (Dialog → Readline → Teletype) before falling back to one that
  works. Harmless for every package this script installs today, but a package with a real yes/no or
  license prompt would hang indefinitely waiting for input from a script that can never provide it.
  Fixed by passing it explicitly per call site: `sudo env DEBIAN_FRONTEND=noninteractive apt-get ...`.
- **A `BASH_SOURCE[0] == $0` guard, not originally planned, was needed to make `install_owntech.sh`
  safely `source`-able** for `test_hardening.sh`'s unit-level `retry()` tests — without it, sourcing the
  file to reach its internal functions also ran its entire bottom dispatch block against whatever `$@`
  happened to be in the sourcing shell (empty, for `test_hardening.sh`), triggering a real full install
  as a side effect. The guard itself was verified correct in isolation before this was traced to a much
  more mundane cause during actual testing: the test container simply still had the pre-guard copy of
  the script when first tested, so re-copying (not more debugging) fixed it.
- **Real timing/size data, `ubuntu:24.04` test container**: a from-scratch `bootstrap`+`build` (toolchain
  download + real Zephyr firmware build, producing genuine `firmware.elf`/`.bin`/`.mcuboot.bin`) took
  2m 48s and left `~/.platformio` at 2.5 GB. A full reset→reinstall cycle via `run_timed_install_test.sh`
  took 38s (reset) + 4m 40s (install). A `build_platformio_bundle.sh` tarball of that same 2.5 GB core dir
  compressed to 0.50 GB, and round-tripped correctly end-to-end (built, downloaded via `curl file://`,
  checksum-verified, extracted) with the restored `packages`/`platforms` matching the original exactly.
  No `7za.exe`-equivalent workaround was needed for extraction speed, as anticipated in the Phase 5a
  section above — plain `tar xzf` was never a bottleneck in testing.
- Headless VS Code CLI operations (`code --install-extension`, `--list-extensions`) worked without any
  display/Xvfb workaround in the container — a real, unresolved-until-tested worry noted implicitly by
  the container-testing section above, resolved cleanly in practice.

## GUI wizard (`.deb` + Zenity)

**Status: implemented and tested end-to-end**, except one item only the user can do (confirming the
Applications-menu entry launches on this real machine — see "Outstanding" below). Packages
`install_owntech.sh` as a GUI-installable `.deb` with a Zenity wizard front-end, mirroring
`wizard/OwnTechInstaller.iss` on Windows: a thin wrapper that shells out to the real script's
`--run-phase`/`--list-phases` calls rather than reimplementing any of its logic (validation rules
included). Confirmed with the user: Zenity (already on Ubuntu Desktop, no new runtime dependency),
Applications-menu launch (not auto-launch from `postinst` — reaching a logged-in user's display session
from a root postinst is fragile and against Debian convention), local build/install/test only for this
pass (publishing is a separate later decision).

### Design

- New files live in `linux/`: `linux/debian/` (`DEBIAN/control`, `DEBIAN/prerm`, and a `.desktop` entry
  under `usr/share/applications/`), `linux/build_deb.sh` (assembles the payload and runs
  `dpkg-deb --build`), and `linux/owntech-installer-wizard.sh` (the Zenity GUI). Package layout:
  `/opt/owntech-installer/{install_owntech.sh,reset_environment.sh,owntech-installer-wizard.sh}`,
  `usr/share/applications/owntech-installer.desktop` (`Exec=/opt/owntech-installer/
  owntech-installer-wizard.sh`), `Depends: bash, zenity`, architecture `all`.
- The packaged copies of the scripts are **pinned at build time** — `build_deb.sh` copies the live
  `linux/*.sh` files into the build tree at build time, not fetched live. A given `.deb` build stays
  reproducible; rebuild-and-republish is how script changes propagate. Same rationale as Windows pinning
  its own embedded script copy in the `.iss`.
- The wizard reuses the real script for validation exactly like Windows' wizard does: it calls
  `--run-phase preflight` and surfaces *its* result, and it *sources* `install_owntech.sh` (safe — the
  `BASH_SOURCE[0] == $0` guard added for `test_hardening.sh` also makes this safe) to call
  `resolve_repo_path`/`test_complete_clone` directly for the reuse/nest confirmation, rather than
  reimplementing either set of rules in a second place where they could drift.
- Progress is per-phase completion state fetched live via `install_owntech.sh --list-phases`, not
  hardcoded — an improvement over the Windows wizard, which hardcoded its 9 checklist rows despite
  `-ListPhases` being available there too. This also means the wizard's phase count/order can never drift
  from the script's own `ALL_PHASES` array.
- Rebased Windows wizard history (`04d580e` through `6fb5be2`, now on `linux_branch`) informed this
  design directly: `04d580e`'s `PLATFORMIO_CORE_DIR` env-propagation bug across `-RunPhase` process
  boundaries turned out to have a real, previously-unverified Linux analog (see Step 0 below);
  `2baaf62`'s tailored overwrite/reuse wording (not a generic "overwrite?" scare) and its real per-step
  progress became this wizard's reuse/nest confirmation and `--list-phases`-driven progress bar
  respectively; `6f7fcb5`'s left-unfixed "build phase looks frozen" gap is being fixed here rather than
  repeated (explanatory text before the `build` phase); `6bb4ddd`'s `code --disable-workspace-trust` is
  reused directly for the finish screen.

### Build/test results

- **Step 0 — `PLATFORMIO_CORE_DIR` gap (fix confirmed real, not hypothetical)**: `phase_build`'s
  `"$pio_exe" run` call did *not* export `PLATFORMIO_CORE_DIR` inline, unlike `phase_bootstrap`'s own
  call — `load_state()` sources `CORE_DIR` as a plain, non-exported shell variable, so a redirected core
  dir would silently be lost the moment `build` ran as its own `--run-phase` process (exactly the class
  of bug fixed on the Windows side in `04d580e`). Verified with a fake `platformio` binary that reports
  what it saw in its own environment: a negative control (reverting the fix) reproduced the failure
  (`PLATFORMIO_CORE_DIR=UNSET` in the child, build reported failed) before confirming the fix resolves
  it. Fixed in `install_owntech.sh`.
- **Step 1 — Debian packaging skeleton**: `linux/debian/DEBIAN/control` + `linux/build_deb.sh` built and
  verified in a fresh `ubuntu:24.04` container — `apt install ./*.deb` lands both scripts executable at
  `/opt/owntech-installer/`, `apt remove owntech-installer` cleans up fully.
- **Step 2 — standalone Zenity wizard**: welcome screen, folder picker, real `--run-phase preflight`
  validation (loops back to the picker with the captured failure text on a fatal error), tailored
  reuse/nest confirmation. All three required scenarios (bad path, existing complete clone, fresh empty
  path) verified via a scripted `zenity` fake that drives the wizard's *real* control-flow logic
  deterministically (own zenity binary shadowed via `PATH`, canned responses per dialog type), plus a
  real-display render check, plus a live launch on the real desktop. **Non-obvious environment finding**:
  this dev machine's shell (a Snap-VS-Code integrated terminal) inherits `GTK_PATH`/`GTK_EXE_PREFIX`/
  `GDK_PIXBUF_MODULE*`/`GSETTINGS_SCHEMA_DIR`/`LOCPATH`/`GIO_MODULE_DIR`/`GTK_IM_MODULE_FILE`/
  `XDG_DATA_DIRS`/`LD_LIBRARY_PATH` env vars pointing at the snap's bundled (incompatible) GTK libraries
  — launching `zenity` with those inherited causes a `symbol lookup error` unrelated to the wizard
  itself. Unsetting them fixes it; a normal launch (e.g. from the Applications menu once packaged) is
  unaffected.
- **Step 3 — progress dialog wired to real phases**: phases fetched live via `--list-phases` (never
  hardcoded, unlike Windows' checklist, which hardcoded 9 rows despite `-ListPhases` being available
  there too — this can't drift from `ALL_PHASES`). A persistent `zenity --progress` process is driven
  through a file descriptor opened via process substitution rather than a one-shot pipe, so a
  `zenity --question`
  Retry/Cancel dialog can run concurrently on a fatal `--run-phase` failure with the progress dialog
  still visible underneath; Retry re-invokes just that phase, Cancel explicitly kills the progress
  dialog process (rather than leaving it stuck below 100%). Added explanatory text before the `build`
  phase specifically — fixing the exact "looks frozen" gap Windows flagged but left open in `6f7fcb5`.
  Verified against a fake install-script stub with configurable failure injection and a scripted zenity
  fake: all-phases-succeed (correct percentage sequence), fail-then-retry, fail-then-cancel (confirmed
  no lingering zenity process).
- **Step 4 — finish dialog**: offers to open the repo in VS Code via `code --disable-workspace-trust`
  (reused directly from the Windows wizard's `6bb4ddd`, already verified session-only/safe), then shows
  the remaining manual steps (connect board, Build, Upload) reusing `phase_summary`'s own framing, plus
  the dialout-group reminder when `serial-permissions` actually changed something. Reloads state
  (`load_state`) rather than recomputing `REPO_PATH`/`GROUP_CHANGED` itself, so it always reflects what
  `phase_clone`/`phase_serial_permissions` actually decided and persisted. Verified both branches (Open
  in VS Code vs. Skip; with and without `GROUP_CHANGED`) against fake `zenity`/`code` binaries logging
  their invocations.
- **Step 5 — desktop-entry integration**: `linux/debian/usr/share/applications/owntech-installer.desktop`
  (`Exec=/opt/owntech-installer/owntech-installer-wizard.sh`), `zenity` added to `Depends`. Verified in a
  fresh container: install pulls in `zenity` correctly, all three scripts plus the `.desktop` file land
  correctly, `desktop-file-validate` reports it valid, removal cleans up both the scripts and the
  `.desktop` entry fully. **Outstanding**: confirming the entry actually appears in the Applications menu
  and launches correctly from there on a real logged-in desktop session needs a real `sudo` password and
  a literal mouse click on this machine — both outside what this agent can do non-interactively. Asked
  the user to run `sudo apt install ./owntech-installer_<version>_all.deb` and try launching it from the
  Applications menu themselves.
- **Step 6 — forced-failure retry/cancel + safe removal**: forced a *real* failure (disabled apt's
  `sources.list.d` entry in a fresh container, with `curl` pre-installed so the failure surfaces at the
  `git` phase rather than preflight) and drove the wizard with a scripted zenity fake. Cancel: the real
  captured failure reason ("Git install failed (apt-get) after retries...") displayed correctly, Cancel
  aborted cleanly with no lingering zenity process and `git` correctly left uninstalled. Retry: the
  fake's `--question` handler restored the apt sources (simulating the user fixing the real problem)
  before returning Retry; the wizard re-ran just the `git` phase, which then succeeded, and — as a bonus
  full end-to-end proof — every phase after it (`python` through `summary`, including a real `build`)
  completed with no further prompts, producing genuine `firmware.elf`/`firmware.bin` and correctly adding
  the test user to the `dialout` group. `DEBIAN/prerm` added as a deliberate, documented no-op (dpkg's
  own removal already only deletes the files this package shipped, so there's nothing safer left to do)
  — verified empirically: after seeding fake user data (`~/.platformio` with a fake `penv/bin/platformio`,
  `~/.gitconfig`, `~/.config/Code`, a fake cloned project with its own `.git`), `apt remove
  owntech-installer` removed exactly `/opt/owntech-installer/` and the `.desktop` entry, leaving every
  piece of simulated user data untouched.

### Outstanding

- A literal human click-through of the Applications-menu launch on this real machine (Step 5's last
  piece) — needs the user's `sudo` password and an actual mouse click, neither available to this agent
  non-interactively.
- Publishing the `.deb` anywhere (a GitHub Release, a PPA, etc.) was explicitly out of scope for this
  pass, mirroring Windows' own deliberate deferral of wizard hosting — a separate decision for later.
