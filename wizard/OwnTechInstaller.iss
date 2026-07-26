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
const
  // Same 9 rows as "GUI wizard design"/"Wizard build plan" in
  // windows_installer_plan.md. 'preflight' already ran on the path page;
  // 'summary' becomes the Completion page's own content -- neither gets a
  // checklist row here.
  PhaseCount = 9;

type
  TPhaseInfo = record
    Key: String;   // -RunPhase value
    Label_: String; // display text (Label is a reserved word)
  end;

var
  ProjectPathPage: TInputDirWizardPage;
  ChosenProjectPath: String;
  ProgressPage: TWizardPage;
  Phases: array[0..PhaseCount - 1] of TPhaseInfo;
  StatusLabels: array[0..PhaseCount - 1] of TNewStaticText;
  PhasesStarted: Boolean;

procedure InitPhaseList;
begin
  Phases[0].Key := 'git';         Phases[0].Label_ := 'Git';
  Phases[1].Key := 'python';      Phases[1].Label_ := 'Python';
  Phases[2].Key := 'cmake';       Phases[2].Label_ := 'CMake';
  Phases[3].Key := 'vscode';      Phases[3].Label_ := 'Visual Studio Code';
  Phases[4].Key := 'extensions';  Phases[4].Label_ := 'VS Code extensions';
  Phases[5].Key := 'clone';       Phases[5].Label_ := 'Clone OwnTech Core';
  Phases[6].Key := 'bundle';      Phases[6].Label_ := 'Fetch package bundle';
  Phases[7].Key := 'bootstrap';   Phases[7].Label_ := 'Bootstrap PlatformIO Core';
  Phases[8].Key := 'build';       Phases[8].Label_ := 'Build firmware';
end;

procedure CreateProgressPage;
var
  I: Integer;
  NameLabel: TNewStaticText;
  RowTop: Integer;
begin
  ProgressPage := CreateCustomPage(ProjectPathPage.ID, 'Installing OwnTech',
    'Each step below runs on its own -- seeing them complete one at a time is the point, ' +
    'not a single bar stuck for several minutes.');
  for I := 0 to PhaseCount - 1 do
  begin
    RowTop := I * 24;
    NameLabel := TNewStaticText.Create(ProgressPage);
    NameLabel.Parent := ProgressPage.Surface;
    NameLabel.Left := 0;
    NameLabel.Top := RowTop;
    NameLabel.Width := 220;
    NameLabel.Caption := Phases[I].Label_;

    StatusLabels[I] := TNewStaticText.Create(ProgressPage);
    StatusLabels[I].Parent := ProgressPage.Surface;
    StatusLabels[I].Left := 230;
    StatusLabels[I].Top := RowTop;
    StatusLabels[I].Width := 200;
    StatusLabels[I].Caption := 'Pending';
  end;
end;

procedure InitializeWizard;
begin
  InitPhaseList;

  ProjectPathPage := CreateInputDirPage(wpWelcome,
    'Choose Install Folder', 'Where should the OwnTech project be set up?',
    'Setup will create the project folder and clone the OwnTech Core repository into it. ' +
    'Avoid OneDrive-synced folders, spaces in the path, and very long paths.',
    False, '');
  ProjectPathPage.Add('');
  ProjectPathPage.Values[0] := 'C:\owntech';

  CreateProgressPage;

  // Files with Flags: dontcopy aren't auto-extracted to {tmp} -- without
  // this call, {tmp}\install_owntech.ps1 doesn't exist yet when RunPhase
  // first tries to use it.
  ExtractTemporaryFile('install_owntech.ps1');
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

// Runs one phase, retrying on failure until the user either succeeds or
// cancels. The dialog logic is deliberately uniform across all 9 phases --
// no per-phase fatal-vs-recoverable special-casing here, because the script
// already encodes that distinction via its own exit code: a gracefully
// degraded step (e.g. the optional VS Code extensions, or the bundle
// falling back to a live download) exits 0 just like full success, and only
// a genuinely fatal Stop-Install produces a non-zero exit. Reacting to exit
// code alone is sufficient and avoids duplicating the fatal/recoverable map
// from "GUI wizard design" a second time in Pascal.
function RunPhaseWithRetry(const PhaseIndex: Integer): Boolean;
var
  LogFile: String;
  LogTextRaw: AnsiString;
  FailureMsg: String;
  ExitCode, Choice: Integer;
  Retrying: Boolean;
begin
  Retrying := True;
  Result := False;
  while Retrying do
  begin
    StatusLabels[PhaseIndex].Caption := 'Running...';
    StatusLabels[PhaseIndex].Repaint;
    LogFile := ExpandConstant('{tmp}\phase_' + Phases[PhaseIndex].Key + '_log.txt');
    ExitCode := RunPhase(Phases[PhaseIndex].Key, ChosenProjectPath, LogFile);
    if ExitCode = 0 then
    begin
      StatusLabels[PhaseIndex].Caption := 'Done';
      StatusLabels[PhaseIndex].Repaint;
      Result := True;
      Retrying := False;
    end
    else
    begin
      StatusLabels[PhaseIndex].Caption := 'Failed';
      StatusLabels[PhaseIndex].Repaint;
      LogTextRaw := '';
      if FileExists(LogFile) then
        LoadStringFromFile(LogFile, LogTextRaw);
      FailureMsg := ExtractFailureMessage(String(LogTextRaw));
      Choice := MsgBox(Phases[PhaseIndex].Label_ + ' failed:' + #13#10#13#10 + FailureMsg,
        mbError, MB_RETRYCANCEL);
      if Choice = IDCANCEL then
        Retrying := False; // Result stays False
    end;
  end;
end;

procedure RunAllPhases;
var
  I: Integer;
begin
  for I := 0 to PhaseCount - 1 do
  begin
    if not RunPhaseWithRetry(I) then
    begin
      MsgBox('Setup cannot continue without completing this step.', mbError, MB_OK);
      WizardForm.Close;
      Exit;
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = ProgressPage.ID) and (not PhasesStarted) then
  begin
    PhasesStarted := True;
    RunAllPhases;
  end;
end;
