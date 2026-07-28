# OT_installer

A project dedicated to an OT_installer: sets up the tools needed to build and flash OwnTech Core
firmware (git, CMake, VS Code with the PlatformIO/CMake extensions, a first PlatformIO build) via a
GUI wizard called **OwnWizard**, on both Windows and Linux.

Each platform has its own backend script (`install_owntech.ps1` / `linux/install_owntech.sh`) plus a
thin GUI wizard wrapped around it. The wizard never reimplements the backend's logic — it shells out
to it — so the two stay in sync by construction.

## Building OwnWizard for Windows

Requires [Inno Setup 6](https://jrsoftware.org/isinfo.php).

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" wizard\OwnWizard.iss
```

Run from the repository root (or `cd wizard` first and drop the `wizard\` prefix). This embeds a
pinned copy of `install_owntech.ps1` from the repo root into the build, so the produced installer is
reproducible — rebuild and redistribute `OwnWizard.exe` whenever `install_owntech.ps1` changes.

Output: `wizard\dist\OwnWizard.exe`.

## Building OwnWizard for Linux

Requires `dpkg-dev` (for `dpkg-deb`) on a Debian/Ubuntu host.

```bash
cd linux
./build_deb.sh
```

This assembles `linux/debian/` (packaging metadata) plus a pinned copy of `install_owntech.sh`,
`reset_environment.sh`, and `ownwizard.sh` into the package payload, then runs `dpkg-deb --build`.
Same reproducibility rationale as the Windows build — rebuild and redistribute the `.deb` whenever
those scripts change.

Output: `linux/ownwizard_<version>_all.deb`.

Install and remove:

```bash
sudo apt install ./ownwizard_<version>_all.deb
sudo apt remove ownwizard
```

Once installed, "OwnWizard" appears in the Applications menu, or can be run directly:

```bash
/opt/ownwizard/ownwizard.sh
```

See [linux/linux_installer_plan.md](linux/linux_installer_plan.md) for the full design, phase
breakdown, and test results behind the Linux port, and `windows_installer_plan.md` for the Windows
side's equivalent.
