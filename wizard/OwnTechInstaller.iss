; OwnTech environment installer -- GUI wizard wrapping install_owntech.ps1.
; See windows_installer_plan.md, "Wizard build plan", for the step-by-step
; design this file implements incrementally.
;
; Build (from this directory):
;   & "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" OwnTechInstaller.iss
;
; Step 2 (this version): embeds a pinned copy of install_owntech.ps1 and adds
; the path-selection page, validated via a real "-RunPhase preflight" call
; (not a Pascal-side reimplementation of Test-ProjectPath's rules -- avoids
; the two copies drifting apart). The embedded script is pinned at build
; time rather than fetched live from GitHub, so a given wizard build is
; reproducible; rebuild and republish the wizard to pick up script changes.

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
; dontcopy: extracted to {tmp} for use during Setup only, not left behind in
; DefaultDirName -- this wizard doesn't install a persistent application.
Source: "..\install_owntech.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Run]
; Nothing to run yet -- real phase execution gets wired in step 4.

[Code]
var
  ProjectPathPage: TInputDirWizardPage;
  ChosenProjectPath: String;

procedure InitializeWizard;
begin
  ProjectPathPage := CreateInputDirPage(wpWelcome,
    'Choose Install Folder', 'Where should the OwnTech project be set up?',
    'Setup will create the project folder and clone the OwnTech Core repository into it. ' +
    'Avoid OneDrive-synced folders, spaces in the path, and very long paths.',
    False, '');
  ProjectPathPage.Add('');
  ProjectPathPage.Values[0] := 'C:\owntech';
end;

// Extracts the "[FAILED] ..." / "How to fix: ..." lines Stop-Install already
// writes, rather than dumping the whole console log -- that text is already
// specific and user-facing, written for exactly this purpose.
function ExtractFailureMessage(const LogText: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Reason, Remediation: String;
begin
  Reason := '';
  Remediation := '';
  Lines := StringSplit(LogText, [#13#10, #10], stExcludeEmpty);
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Pos('[FAILED]', Lines[I]) > 0 then
      Reason := Trim(Copy(Lines[I], Pos('[FAILED]', Lines[I]) + Length('[FAILED]'), MaxInt));
    if Pos('How to fix:', Lines[I]) > 0 then
      Remediation := Trim(Copy(Lines[I], Pos('How to fix:', Lines[I]) + Length('How to fix:'), MaxInt));
  end;
  if Reason <> '' then
  begin
    Result := Reason;
    if Remediation <> '' then
      Result := Result + #13#10#13#10 + 'How to fix: ' + Remediation;
  end
  else
    Result := LogText; // fallback: something failed that didn't go through Stop-Install
end;

// Runs one -RunPhase in a hidden cmd.exe (needed for '>' output redirection,
// which Exec's Params doesn't interpret on its own -- it's not a shell) and
// returns the process exit code. LogFile captures combined stdout+stderr so
// a failure's Stop-Install message can be surfaced in the wizard's own UI.
function RunPhase(const PhaseName, ProjPath, LogFile: String): Integer;
var
  ResultCode: Integer;
  ScriptPath, Params: String;
begin
  ScriptPath := ExpandConstant('{tmp}\install_owntech.ps1');
  Params := Format('/C powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s" -RunPhase %s -ProjectPath "%s" -NonInteractive > "%s" 2>&1', [ScriptPath, PhaseName, ProjPath, LogFile]);
  if Exec(ExpandConstant('{cmd}'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode
  else
    Result := -1;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  LogFile, FailureMsg: String;
  LogTextRaw: AnsiString;
  ExitCode: Integer;
begin
  Result := True;
  if CurPageID = ProjectPathPage.ID then
  begin
    ChosenProjectPath := ProjectPathPage.Values[0];
    LogFile := ExpandConstant('{tmp}\preflight_log.txt');
    WizardForm.Cursor := crHourglass;
    try
      ExitCode := RunPhase('preflight', ChosenProjectPath, LogFile);
    finally
      WizardForm.Cursor := crDefault;
    end;
    if ExitCode <> 0 then
    begin
      LogTextRaw := '';
      if FileExists(LogFile) then
        LoadStringFromFile(LogFile, LogTextRaw);
      FailureMsg := ExtractFailureMessage(String(LogTextRaw));
      MsgBox('This folder can''t be used:' + #13#10#13#10 + FailureMsg, mbError, MB_OK);
      Result := False;
    end;
  end;
end;
