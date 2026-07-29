# Third-party licenses in the PlatformIO bundle

`build_platformio_bundle.sh` / `build_platformio_bundle.ps1` package a fully-populated PlatformIO core
dir's `packages/` and `platforms/` folders (toolchain, Zephyr framework, HAL modules, build tools) into a
distributable archive, published as a GitHub Release asset so a fresh install doesn't have to download
everything from scratch. This document records what's actually inside that archive, license-wise, and
how that was verified -- see the parent request in project history for the full method (real populated
`~/.platformio`, cross-referenced against a real build's `compile_commands.json` to find where vendor
source actually lands, since Zephyr's module layout hides the real fetched sources under a non-obvious
`framework-zephyr/_pio/modules/` path rather than the more visible `framework-zephyr/modules/`, which
only holds near-empty Zephyr-side glue/Kconfig stubs).

**Verdict: no proprietary, export-restricted, or otherwise sensitive content found.** Everything below is
legitimate open source, used within its own terms. Two minor gaps are noted (see "Known gaps").

## Components and licenses

| Component | License | Notes |
|---|---|---|
| Zephyr framework, CMSIS, CMSIS-DSP, zcbor, thingset-node-c | Apache-2.0 | |
| STM32 HAL (`hal_stm32`) | Apache-2.0 / BSD-3-Clause | Dual, per-file, per its own `LICENSE` |
| littlefs | BSD-3-Clause | |
| tinycrypt | BSD-3-Clause | Per-file header (Intel Corporation), no standalone `LICENSE` file |
| FatFs | "FatFs License" (bespoke, BSD-1-Clause-style) | Non-SPDX name, but no real restriction: redistribution permitted, attribution-only condition |
| SEGGER RTT/SystemView | Redistribution permitted, single condition (keep copyright notice) | The "All rights reserved" banner at the top of each file is standard boilerplate, not a restriction -- the actual grant right below it is a simple attribution-only license |
| GCC toolchain (gcc, binutils, gdb, newlib, and 18 more) | GPL-2/3 + GCC Runtime Library Exception | Ships a complete `distro-info/licenses/<component>/` folder per bundled component, including `COPYING.RUNTIME` (the exception that keeps your own compiled firmware from being GPL-encumbered just because GCC built it) |
| OpenOCD + deps (libusb, hidapi, libftdi, autoconf, ...) | GPL-2.0 | Same -- ships a complete `distro-info/licenses/` folder |
| CMake, Ninja, SCons | BSD-3-Clause / Apache-2.0 / MIT | |
| dfu-util (via `tool-stm32duino`) | GPL-2.0 | Actual source + `COPYING` bundled, not just a binary |

## Known gaps

**`tool-dtc`** (device tree compiler, GPL-2.0-or-later) and **`tool-gperf`** (GPL-3.0-or-later) are
shipped by PlatformIO's own registry as bare prebuilt binaries -- no license text and no source bundled
alongside them, just the binary plus `package.json`. Redistributing this bundle carries that gap forward.

Strictly, GPL requires the binary's license text and either the corresponding source or a written offer
for it. Actual risk is low -- both are small, well-known, widely-distributed upstream projects with
trivially available source -- but nothing currently documents this, so noting it here rather than
leaving it silent:

- dtc source: https://git.kernel.org/pub/scm/utils/dtc/dtc.git
- gperf source: https://www.gnu.org/software/gperf/

If republishing a bundle for wider distribution, consider bundling each tool's license text (and a
pointer to the source URLs above) alongside the archive, or noting the exception in the release
description.

## Re-verifying after a bundle refresh

Regenerate this analysis whenever `platformio.ini` / `west.yml` bump a framework or toolchain version,
or add a new dependency:

1. Populate a real core dir (a full `install_owntech.sh`/`install_owntech.ps1` run, or `pio run` in a
   Core checkout).
2. For each entry under `packages/` and `platforms/`, check for an embedded `LICENSE`/`COPYING` file and
   `package.json`'s `license` field.
3. Cross-reference a real build's `compile_commands.json` (`.pio/build/<env>/compile_commands.json`) to
   confirm where the actually-compiled source for each HAL/library really lives -- don't rely on the
   more visible `framework-zephyr/modules/` path alone; check `framework-zephyr/_pio/modules/` too.
4. Confirm `build_platformio_bundle.sh`/`.ps1` isn't excluding anything (they currently don't -- plain
   `tar czf`/`Compress-Archive` with no excludes, so everything found above travels with the archive).
