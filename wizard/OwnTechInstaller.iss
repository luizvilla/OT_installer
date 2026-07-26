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
; chooses on a later page (the custom ProjectPathPage below), not to
; "install itself" anywhere meaningful. DefaultDirName is still required by
; Inno Setup even so; kept in a low-privilege location consistent with
; PrivilegesRequired below. DisableDirPage skips Inno Setup's own standard
; "Select Destination Location" page for it -- without this, it still shows
; up (confusingly, after the real work is already done, since that's where
; Inno Setup's normal flow places it) asking the user where to install the
; wizard itself, unrelated to and easily confused with the actual OwnTech
; project folder already chosen on the custom page earlier.
DefaultDirName={localappdata}\OwnTechInstallerWizard
DisableDirPage=yes
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
  ProgressBars: array[0..PhaseCount - 1] of TNewProgressBar;
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
    RowTop := I * 26;
    NameLabel := TNewStaticText.Create(ProgressPage);
    NameLabel.Parent := ProgressPage.Surface;
    NameLabel.Left := 0;
    NameLabel.Top := RowTop + 2;
    NameLabel.Width := 150;
    NameLabel.Caption := Phases[I].Label_;

    ProgressBars[I] := TNewProgressBar.Create(ProgressPage);
    ProgressBars[I].Parent := ProgressPage.Surface;
    ProgressBars[I].Left := 155;
    ProgressBars[I].Top := RowTop;
    ProgressBars[I].Width := 190;
    ProgressBars[I].Height := 16;
    ProgressBars[I].Min := 0;
    ProgressBars[I].Max := 100;
    ProgressBars[I].Position := 0;

    StatusLabels[I] := TNewStaticText.Create(ProgressPage);
    StatusLabels[I].Parent := ProgressPage.Surface;
    StatusLabels[I].Left := 355;
    StatusLabels[I].Top := RowTop + 2;
    StatusLabels[I].Width := 100;
    StatusLabels[I].Caption := 'Pending';
  end;
end;

// One row's visual state -- a real TNewProgressBar per phase, not just text.
// Still can't show a true 0-100% *within* a step (none of the phases expose
// a granular percentage signal -- see "GUI wizard design" in
// windows_installer_plan.md), and a blocking Exec call prevents the message
// loop from pumping, so npbstMarquee won't visibly animate *while* a step is
// running -- but each state change (pending -> running -> done/failed) still
// renders correctly at the moment it happens, via Repaint.
procedure SetPhaseVisualState(const PhaseIndex: Integer; const State: String);
begin
  if State = 'running' then
  begin
    StatusLabels[PhaseIndex].Caption := 'Running...';
    ProgressBars[PhaseIndex].Style := npbstMarquee;
  end
  else if State = 'done' then
  begin
    StatusLabels[PhaseIndex].Caption := 'Done';
    ProgressBars[PhaseIndex].Style := npbstNormal;
    ProgressBars[PhaseIndex].Position := ProgressBars[PhaseIndex].Max;
  end
  else if State = 'failed' then
  begin
    StatusLabels[PhaseIndex].Caption := 'Failed';
    ProgressBars[PhaseIndex].Style := npbstNormal;
    ProgressBars[PhaseIndex].Position := 0;
  end
  else // 'pending'
  begin
    StatusLabels[PhaseIndex].Caption := 'Pending';
    ProgressBars[PhaseIndex].Style := npbstNormal;
    ProgressBars[PhaseIndex].Position := 0;
  end;
  StatusLabels[PhaseIndex].Repaint;
  ProgressBars[PhaseIndex].Repaint;
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

function IsDirEmpty(const Path: String): Boolean;
var
  FindRec: TFindRec;
  Count: Integer;
begin
  Count := 0;
  if FindFirst(Path + '\*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
          Count := Count + 1;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
  Result := (Count = 0);
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

function RunAllPhases: Boolean; forward;

// Skips Inno Setup's standard "Ready to Install" confirmation -- same
// reasoning as DisableDirPage in [Setup]: all the real work already
// happened on the custom progress page, so a "click Install to begin"
// prompt at this point would be confusing (there's nothing left to start).
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = wpReady);
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

    // Confirm before reusing a non-empty folder -- easy to pick the same
    // path as an earlier run by mistake. Message reflects what actually
    // happens (install_owntech.ps1 is idempotent, never deletes unrelated
    // content) rather than implying data loss that won't occur.
    if DirExists(ChosenProjectPath) and (not IsDirEmpty(ChosenProjectPath)) then
    begin
      if DirExists(ChosenProjectPath + '\.git') then
      begin
        if MsgBox('The folder "' + ChosenProjectPath + '" already has an OwnTech project in it.' + #13#10#13#10 +
          'Setup will reuse what''s already there and skip any steps already completed.' + #13#10#13#10 +
          'Continue with this folder?', mbConfirmation, MB_YESNO) = IDNO then
        begin
          Result := False;
          Exit;
        end;
      end
      else
      begin
        if MsgBox('The folder "' + ChosenProjectPath + '" already exists and is not empty.' + #13#10#13#10 +
          'Setup will not delete anything already there, but will create a "Core" subfolder inside it ' +
          'for the OwnTech project rather than using this folder directly.' + #13#10#13#10 +
          'Continue with this folder?', mbConfirmation, MB_YESNO) = IDNO then
        begin
          Result := False;
          Exit;
        end;
      end;
    end;

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
  end
  else if CurPageID = ProgressPage.ID then
  begin
    Result := RunAllPhases;
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
    SetPhaseVisualState(PhaseIndex, 'running');
    LogFile := ExpandConstant('{tmp}\phase_' + Phases[PhaseIndex].Key + '_log.txt');
    ExitCode := RunPhase(Phases[PhaseIndex].Key, ChosenProjectPath, LogFile);
    if ExitCode = 0 then
    begin
      SetPhaseVisualState(PhaseIndex, 'done');
      Result := True;
      Retrying := False;
    end
    else
    begin
      SetPhaseVisualState(PhaseIndex, 'failed');
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

// Returns True only if every phase eventually succeeded (possibly after
// retries). Deliberately does NOT try to forcibly terminate Setup itself on
// failure -- both WizardForm.Close and Abort were tried and neither
// reliably stopped Setup when called from CurPageChanged (a passive
// notification callback, not one of Inno Setup's flow-control events) --
// see windows_installer_plan.md, "Wizard build results", for the full
// story. Returning False here and having NextButtonClick propagate that is
// the same well-established mechanism the path page already relies on to
// block advancement, instead of a special-case termination call.
function RunAllPhases: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to PhaseCount - 1 do
  begin
    if not RunPhaseWithRetry(I) then
    begin
      MsgBox('Setup cannot continue without completing this step.' + #13#10#13#10 +
        'Fix the issue above, then click Next to try again.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // Auto-starts the checklist the first time this page is reached, by
  // simulating a Next click -- which routes through NextButtonClick below,
  // the same reliable path a real click takes. Guarded so this only fires
  // once: if RunAllPhases returns False, Setup stays on this page (no page
  // change, so CurPageChanged doesn't fire again) and the user can retry by
  // clicking Next themselves, which is unaffected by this guard.
  if (CurPageID = ProgressPage.ID) and (not PhasesStarted) then
  begin
    PhasesStarted := True;
    WizardForm.NextButton.OnClick(WizardForm.NextButton);
  end;
end;
