; OwnTech environment installer -- GUI wizard wrapping install_owntech.ps1.
; See windows_installer_plan.md, "Wizard build plan", for the step-by-step
; design this file implements incrementally.
;
; Build (from this directory):
;   & "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" OwnTechInstaller.iss
;
; Step 1 (this version): scaffold only -- Welcome and Completion pages, no
; real install logic yet. Purpose is validating the Inno Setup toolchain
; itself before adding real complexity on top of it.

#define MyAppName "OwnTech Environment Installer"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "OwnTech"
#define MyAppURL "https://github.com/owntech-foundation/Core"

[Setup]
AppId={{D664A725-9FB7-4EA8-BF5B-2DFCBCA24139}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
; Not a persistent application -- this wizard's own footprint is minimal, it
; exists to drive install_owntech.ps1 against a project folder the user
; chooses on a later page (added in step 2), not to "install itself"
; anywhere meaningful. DefaultDirName is still required by Inno Setup even
; so; kept in a low-privilege location consistent with PrivilegesRequired
; below.
DefaultDirName={localappdata}\OwnTechInstallerWizard
DisableProgramGroupPage=yes
; Preserves the constraint the whole underlying project has been built
; around: install_owntech.ps1 itself must work fully unelevated, and this
; wizard shouldn't require admin rights by default either.
PrivilegesRequired=lowest
OutputBaseFilename=OwnTechInstaller
OutputDir=dist
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Nothing bundled yet -- install_owntech.ps1 itself gets embedded in step 2.

[Run]
; Nothing to run yet -- real phase execution gets wired in step 4.
