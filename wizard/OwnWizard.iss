; OwnWizard -- GUI wizard wrapping install_owntech.ps1. Renamed from
; "OwnTech Environment Installer": it's meant to be run more than once per
; machine (first-time environment setup, then again for each new project via
; "New Project" mode), so "Installer" undersold what it actually is.
; See windows_installer_plan.md, "Wizard build plan", for the step-by-step
; design this file implements incrementally.
;
; Build (from this directory):
;   & "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" OwnWizard.iss
;
; Step 2: embeds a pinned copy of install_owntech.ps1 and adds the
; path-selection page, validated via a real "-RunPhase preflight" call
; (not a Pascal-side reimplementation of Test-ProjectPath's rules -- avoids
; the two copies drifting apart). The embedded script is pinned at build
; time rather than fetched live from GitHub, so a given wizard build is
; reproducible; rebuild and republish the wizard to pick up script changes.
;
; Step 3 (this version): "New Project" mode. One fixed workspace folder per
; machine (default C:\owntech) now holds every project as a named subfolder
; -- including the first one, which is no longer special-cased into the
; workspace root directly. A small marker file
; (%LOCALAPPDATA%\OwnTechInstaller\workspace_root.txt) records the chosen
; workspace after a successful first run, so a later run can skip straight
; to "what do you want to call this project?" instead of asking the user to
; navigate to a folder again -- see windows_installer_plan.md, "New Project
; mode", for the full design.

#define MyAppName "OwnWizard"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "OwnTech"
#define MyAppURL "https://github.com/owntech-foundation/Core"

[Setup]
AppId={{D664A725-9FB7-4EA8-BF5B-2DFCBCA24139}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
; Not a persistent application -- this wizard's own footprint is minimal, it
; exists to drive install_owntech.ps1 against a project folder composed on
; later pages (FolderPage/NamePage below), not to "install itself" anywhere
; meaningful. DefaultDirName is still required by
; Inno Setup even so; kept in a low-privilege location consistent with
; PrivilegesRequired below. DisableDirPage skips Inno Setup's own standard
; "Select Destination Location" page for it -- without this, it still shows
; up (confusingly, after the real work is already done, since that's where
; Inno Setup's normal flow places it) asking the user where to install the
; wizard itself, unrelated to and easily confused with the actual OwnTech
; project folder already chosen on the custom page earlier.
DefaultDirName={localappdata}\OwnWizard
DisableDirPage=yes
DisableProgramGroupPage=yes
; Preserves the constraint the whole underlying project has been built
; around: install_owntech.ps1 itself must work fully unelevated, and this
; wizard shouldn't require admin rights by default either.
PrivilegesRequired=lowest
OutputBaseFilename=OwnWizard
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
; Standard Inno Setup mechanism for "would you like to launch X now?" --
; renders as a checked-by-default checkbox on the Finished page, matching
; install_owntech.ps1's own [Y/n]-defaults-yes prompt for the same thing
; (which never fires here since every -RunPhase call uses -NonInteractive).
; skipifsilent: don't auto-launch during unattended/silent installs.
; --disable-workspace-trust: skips VS Code's "do you trust this folder?"
; prompt for THIS launch only (confirmed session-only, not a persistent or
; global setting -- https://code.visualstudio.com/docs/editor/workspace-trust)
; -- a reasonable trade-off for a folder this same script just freshly
; cloned from the official repo, without weakening trust for anything
; else the user opens later.
Filename: "{cmd}"; Parameters: "/C code --disable-workspace-trust ""{code:GetActualRepoPath}"""; Description: "Open the OwnTech project in VS Code"; Flags: postinstall skipifsilent runasoriginaluser nowait

[Code]
const
  // Same 9 rows as "GUI wizard design"/"Wizard build plan" in
  // windows_installer_plan.md. 'preflight' already ran on the path page;
  // 'summary' becomes the Completion page's own content -- neither gets a
  // checklist row here.
  PhaseCount = 9;

  // Pre-baked PlatformIO packages/platforms bundle -- lets the 'bundle'
  // phase seed a fresh machine's core dir instead of Phase 5 falling back to
  // a full toolchain/framework download from scratch. Cuts a genuine
  // from-scratch install from ~11 min to ~8 min (see
  // windows_installer_plan.md's timed comparisons). Published as a real
  // GitHub Release asset and verified end to end against this exact URL
  // (18.5s download, SHA256-checked, successful extraction) -- see "Full
  // timed cycle against the real public URL" in windows_installer_plan.md.
  // Safe to hardcode: install_owntech.ps1's own Invoke-BundleSeed treats any
  // failure here (unreachable URL, checksum mismatch, extraction failure) as
  // non-fatal and silently falls back to the full download, so an eventual
  // stale/deleted release asset degrades to today's behavior, not a break.
  BundleUrl = 'https://github.com/luizvilla/OT_installer/releases/download/pio-bundle-20260726/pio_bundle_v2.zip';
  BundleSha256 = 'A566EF91DF4A7E9F734E0058185037AF59C82469E76F176F3AC993326C28FD67';

type
  TPhaseInfo = record
    Key: String;   // -RunPhase value
    Label_: String; // display text (Label is a reserved word)
    TimeEstimate: String; // static "typically ~Xs" caption -- see InitPhaseList
  end;

var
  FolderPage: TInputDirWizardPage;   // workspace root -- shown only on a first-ever run
  NamePage: TInputQueryWizardPage;   // project name -- shown every run
  ProjectsRoot: String;              // the workspace folder (e.g. C:\owntech)
  ChosenProjectPath: String;         // ProjectsRoot + '\' + project name
  WorkspaceKnown: Boolean;           // True if workspace_root.txt existed at startup
  NameDefaultSet: Boolean;           // guards against re-clobbering a typed name on Back+Next
  ProgressPage: TWizardPage;
  Phases: array[0..PhaseCount - 1] of TPhaseInfo;
  StatusLabels: array[0..PhaseCount - 1] of TNewStaticText;
  ProgressBars: array[0..PhaseCount - 1] of TNewProgressBar;
  TimeLabels: array[0..PhaseCount - 1] of TNewStaticText;
  PhasesStarted: Boolean;

// TimeEstimate values are real per-phase durations pulled from an actual
// timed run of this exact 9-phase split (install_timing_20260726_095037.log,
// the "post-refactor-verification" row in install_timing_history.csv, bundle
// -backed, 8m13s total) -- not guesses. Git/Python/CMake are each shown as
// "usually <1 min" rather than that run's individual numbers (Python and
// CMake were already present on that test machine and finished near-
// instantly, which would understate a genuinely fresh machine) since a fresh
// winget install of any one of them lands in the same rough ballpark as
// Git's measured 59s there. Deliberately static -- set once here and never
// touched again by SetPhaseVisualState, per the decision not to fake a live
// counter (see "Timer-based progress bars" discussion in
// windows_installer_plan.md: a real one would need replacing the blocking
// Exec call with raw Win32 process polling, a much bigger and harder-to-
// verify change for a cosmetic improvement). Build's caption was originally
// a full sentence ("typically ~3 min, longer on a fresh machine") but got
// silently truncated by the fixed-width label it renders in (see
// CreateProgressPage) -- kept short like every other row's caption instead
// of widening the column further for one long string.
procedure InitPhaseList;
begin
  Phases[0].Key := 'git';         Phases[0].Label_ := 'Git';                      Phases[0].TimeEstimate := 'usually <1 min';
  Phases[1].Key := 'python';      Phases[1].Label_ := 'Python';                   Phases[1].TimeEstimate := 'usually <1 min';
  Phases[2].Key := 'cmake';       Phases[2].Label_ := 'CMake';                    Phases[2].TimeEstimate := 'usually <1 min';
  Phases[3].Key := 'vscode';      Phases[3].Label_ := 'Visual Studio Code';       Phases[3].TimeEstimate := 'typically ~1-2 min';
  Phases[4].Key := 'extensions';  Phases[4].Label_ := 'VS Code extensions';       Phases[4].TimeEstimate := 'typically ~30 sec';
  Phases[5].Key := 'clone';       Phases[5].Label_ := 'Clone OwnTech Core';       Phases[5].TimeEstimate := 'typically ~5 sec';
  Phases[6].Key := 'bundle';      Phases[6].Label_ := 'Fetch package bundle';     Phases[6].TimeEstimate := 'typically ~1-2 min';
  Phases[7].Key := 'bootstrap';   Phases[7].Label_ := 'Bootstrap PlatformIO Core'; Phases[7].TimeEstimate := 'typically ~1 min';
  Phases[8].Key := 'build';       Phases[8].Label_ := 'Build firmware';           Phases[8].TimeEstimate := 'typically 3-10 min';
end;

procedure CreateProgressPage;
var
  I: Integer;
  NameLabel: TNewStaticText;
  RowTop, RowHeight: Integer;
begin
  // Two rounds of real dry-run feedback found two separate bugs here, both
  // ultimately caused by the same thing: TNewStaticText defaults to
  // AutoSize = True, which silently ignores whatever Width/Height is
  // assigned and resizes the control to fit its own Caption instead. That's
  // why widening the name column "worked" for the horizontal overlap
  // (the bar was just moved far enough right to tolerate the real,
  // auto-computed width of the longest label) while the vertical gap
  // between the name and the time caption never actually grew -- both labels
  // had just been shifted up by the same 2px, not spaced further apart, and
  // AutoSize meant no explicitly-set Height was ever actually in effect to
  // reason about in the first place. Fix: AutoSize := False on every label
  // here, set *before* Width/Height/Caption so nothing recalculates them
  // afterward -- from here on, these numbers are the real, final layout, not
  // a starting guess a resize can silently override.
  RowHeight := 44; // widened again -- 16/14px label heights were too tight
                    // once AutoSize stopped silently expanding them:
                    // descenders (g/p/y) were getting clipped at the bottom
                    // of each fixed-height box. 20/16 below leaves real room
                    // for a full line including descenders, not just the
                    // cap-height.
  // AfterID = NamePage.ID -- NOT FolderPage.ID. FolderPage is skippable
  // (ShouldSkipPage), and Inno's page chain is defined by each page's own
  // AfterID at creation time, not by what's visible at runtime -- chaining
  // this to the wrong page here would compile fine but silently insert
  // Progress in the wrong slot.
  // No description text -- this page used to carry an explanatory paragraph
  // here, but the checklist below is self-explanatory and the text was
  // reported as just clutter above an already-busy page.
  ProgressPage := CreateCustomPage(NamePage.ID, 'Installing OwnTech', '');
  for I := 0 to PhaseCount - 1 do
  begin
    RowTop := I * RowHeight;

    NameLabel := TNewStaticText.Create(ProgressPage);
    NameLabel.Parent := ProgressPage.Surface;
    NameLabel.AutoSize := False;
    NameLabel.Left := 0;
    NameLabel.Top := RowTop;
    NameLabel.Width := 190;
    NameLabel.Height := 20;
    NameLabel.Caption := Phases[I].Label_;

    TimeLabels[I] := TNewStaticText.Create(ProgressPage);
    TimeLabels[I].Parent := ProgressPage.Surface;
    TimeLabels[I].AutoSize := False;
    TimeLabels[I].Left := 0;
    TimeLabels[I].Top := RowTop + 21; // below NameLabel's 20px height + 1px gap
    TimeLabels[I].Width := 190;
    TimeLabels[I].Height := 16;
    TimeLabels[I].Font.Color := clGrayText;
    TimeLabels[I].Font.Size := 7; // secondary info -- smaller and muted
    TimeLabels[I].Caption := Phases[I].TimeEstimate;

    ProgressBars[I] := TNewProgressBar.Create(ProgressPage);
    ProgressBars[I].Parent := ProgressPage.Surface;
    ProgressBars[I].Left := 195;
    ProgressBars[I].Top := RowTop + 1;
    ProgressBars[I].Width := 150;
    ProgressBars[I].Height := 16;
    ProgressBars[I].Min := 0;
    ProgressBars[I].Max := 100;
    ProgressBars[I].Position := 0;

    StatusLabels[I] := TNewStaticText.Create(ProgressPage);
    StatusLabels[I].Parent := ProgressPage.Surface;
    StatusLabels[I].AutoSize := False;
    StatusLabels[I].Left := 350;
    StatusLabels[I].Top := RowTop + 1;
    StatusLabels[I].Width := 105;
    StatusLabels[I].Height := 20; // 'Pending' has a descender (g) -- same
                                   // clipping risk as the name/time labels
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

// Path to the small marker file that remembers the chosen workspace root
// across separate wizard runs (separate processes -- nothing else persists
// in memory between them). Deliberately just a plain text file the user can
// delete to reset this choice, rather than a registry entry -- consistent
// with this wizard's low-footprint, no-persistent-install philosophy
// (PrivilegesRequired=lowest, no [Icons], no uninstall-relevant state).
function GetWorkspaceMarkerPath: String;
begin
  Result := ExpandConstant('{localappdata}\OwnTechInstaller\workspace_root.txt');
end;

procedure InitializeWizard;
var
  LoadedRootRaw: AnsiString;
  LoadedRoot: String;
begin
  InitPhaseList;

  // Reasserted on every page in CurPageChanged too -- Inno recalculates
  // button visibility per page, so a one-time call here alone wouldn't
  // stick. Needed here as well since CurPageChanged isn't guaranteed to
  // fire for the very first (Welcome) page display.
  WizardForm.BackButton.Visible := False;

  // Shown only on a first-ever run (see ShouldSkipPage) -- every project,
  // including the first, is created as a subfolder under this workspace
  // root rather than directly in it, so accepting every default still
  // reproduces today's C:\owntech example, just one level deeper
  // (C:\owntech\<name>).
  FolderPage := CreateInputDirPage(wpWelcome,
    'Choose OwnTech Workspace Folder', 'Where should your OwnTech projects be created?',
    'Setup will create this folder if it does not exist, and a separate subfolder inside it ' +
    'for each OwnTech project you set up here. Avoid OneDrive-synced folders, spaces in the ' +
    'path, and very long paths.',
    False, '');
  FolderPage.Add('');
  FolderPage.Values[0] := 'C:\owntech';

  // LoadStringFromFile requires an AnsiString target, not a plain String --
  // see ExtractFailureMessage's callers below for the same gotcha (a real
  // compile error hit earlier in this file).
  WorkspaceKnown := False;
  LoadedRootRaw := '';
  if LoadStringFromFile(GetWorkspaceMarkerPath, LoadedRootRaw) then
  begin
    LoadedRoot := Trim(String(LoadedRootRaw));
    if LoadedRoot <> '' then
    begin
      ProjectsRoot := LoadedRoot;
      WorkspaceKnown := True;
    end;
  end;

  // ADescription is overwritten dynamically in CurPageChanged (workspace
  // root isn't known yet at this point on a first-ever run -- it's set from
  // FolderPage a moment earlier in NextButtonClick). ASubCaption stays
  // static and is the only place the "new subfolder" explanation lives --
  // it used to also get repeated into Description, rendering twice on the
  // same page.
  NamePage := CreateInputQueryPage(FolderPage.ID,
    'Name Your Project', 'What would you like to call this project?',
    'This becomes a new subfolder with its own fresh clone of the OwnTech Core repository.');
  NamePage.Add('Project name:', False);

  CreateProgressPage;

  // Files with Flags: dontcopy aren't auto-extracted to {tmp} -- without
  // this call, {tmp}\install_owntech.ps1 doesn't exist yet when RunPhase
  // first tries to use it.
  ExtractTemporaryFile('install_owntech.ps1');
end;

// {code:GetActualRepoPath} in [Run]'s Parameters needs the *actual* clone
// location, not necessarily ChosenProjectPath verbatim -- Get-RepoPath (in
// install_owntech.ps1) nests into a Core subfolder instead of the chosen
// folder itself when that folder was non-empty and had no existing .git
// (the same case the overwrite-confirmation dialog already warns about).
// Mirrors that same decision here rather than reading it back from the
// state file, which would need replicating its MD5-based filename scheme
// in Pascal for comparatively little benefit.
function GetActualRepoPath(Param: String): String;
begin
  if DirExists(ChosenProjectPath + '\.git') then
    Result := ChosenProjectPath
  else if DirExists(ChosenProjectPath + '\Core\.git') then
    Result := ChosenProjectPath + '\Core'
  else
    Result := ChosenProjectPath; // shouldn't normally happen if clone succeeded
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
  ScriptPath, Params, ExtraArgs: String;
begin
  ScriptPath := ExpandConstant('{tmp}\install_owntech.ps1');
  // Only 'bundle' consumes -BundleUrl/-BundleSha256 (see Invoke-PhaseBundleFetch
  // in install_owntech.ps1) -- scoped here so every other phase's command line
  // is unchanged from before.
  ExtraArgs := '';
  if PhaseName = 'bundle' then
    ExtraArgs := Format(' -BundleUrl "%s" -BundleSha256 "%s"', [BundleUrl, BundleSha256]);
  Params := Format('/C powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s" -RunPhase %s -ProjectPath "%s" -NonInteractive%s > "%s" 2>&1', [ScriptPath, PhaseName, ProjPath, ExtraArgs, LogFile]);
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
// Also skips FolderPage once a workspace root is already known -- the
// user's already told Setup where their projects live, on some earlier run;
// asking again would be asking something the software already knows.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = wpReady) or ((PageID = FolderPage.ID) and WorkspaceKnown);
end;

// Test-ProjectPath (install_owntech.ps1) already validates the *composed*
// path for spaces/length/OneDrive -- genuinely sufficient for those, no
// need to duplicate them here. But it never sees the raw name in isolation,
// so a name with a filesystem-illegal character or a reserved Windows
// device name would otherwise only surface as a generic "Could not create
// project folder" from Invoke-PhasePreflight's own New-Item call -- correct,
// but vague, and costs a full process round trip to discover something
// cheap to reject here first.
function ValidateProjectName(const Name: String; var ErrorMsg: String): Boolean;
var
  IllegalChars: String;
  I: Integer;
  UpperName: String;
begin
  Result := True;
  ErrorMsg := '';

  if Name = '' then
  begin
    ErrorMsg := 'Enter a name for this project.';
    Result := False;
    Exit;
  end;

  // Test-ProjectPath (install_owntech.ps1) also rejects spaces, but only on
  // the *composed* path, after this page has already been left -- its
  // message ("choose a path... e.g. C:\owntech") is written for someone
  // typing a raw path, which was true before "New Project" mode but reads as
  // a stale/wrong message here, where the user only typed a name. Catching
  // it here with name-specific wording avoids that message ever surfacing
  // in this flow.
  if Pos(' ', Name) > 0 then
  begin
    ErrorMsg := 'Project name can''t contain spaces. Try dashes or underscores instead, e.g. "my-project".';
    Result := False;
    Exit;
  end;

  IllegalChars := '\/:*?"<>|';
  for I := 1 to Length(IllegalChars) do
  begin
    if Pos(IllegalChars[I], Name) > 0 then
    begin
      ErrorMsg := 'Project name can''t contain any of: ' + IllegalChars;
      Result := False;
      Exit;
    end;
  end;

  UpperName := Uppercase(Name);
  if (UpperName = 'CON') or (UpperName = 'PRN') or (UpperName = 'AUX') or (UpperName = 'NUL') or
     ((Length(UpperName) = 4) and (Copy(UpperName, 1, 3) = 'COM') and (UpperName[4] >= '1') and (UpperName[4] <= '9')) or
     ((Length(UpperName) = 4) and (Copy(UpperName, 1, 3) = 'LPT') and (UpperName[4] >= '1') and (UpperName[4] <= '9')) then
  begin
    ErrorMsg := '"' + Name + '" is a reserved Windows name and can''t be used as a project name.';
    Result := False;
    Exit;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  LogFile, FailureMsg, ProjectName, NameErrorMsg: String;
  LogTextRaw: AnsiString;
  ExitCode: Integer;
begin
  Result := True;
  if CurPageID = FolderPage.ID then
  begin
    ProjectsRoot := FolderPage.Values[0];
  end
  else if CurPageID = NamePage.ID then
  begin
    ProjectName := Trim(NamePage.Values[0]);
    if not ValidateProjectName(ProjectName, NameErrorMsg) then
    begin
      MsgBox(NameErrorMsg, mbError, MB_OK);
      Result := False;
      Exit;
    end;

    ChosenProjectPath := AddBackslash(ProjectsRoot) + ProjectName;

    // Confirm before reusing a non-empty folder -- easy to pick a name that
    // collides with an existing project by mistake. Message reflects what
    // actually happens (install_owntech.ps1 is idempotent, never deletes
    // unrelated content) rather than implying data loss that won't occur.
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
    end
    else if not WorkspaceKnown then
    begin
      // Remember the workspace root now that it's proven usable, so the
      // *next* run of this wizard can skip FolderPage entirely (see
      // ShouldSkipPage) instead of asking again for something already
      // decided. ForceDirectories guards against this running before
      // install_owntech.ps1 has ever created %LOCALAPPDATA%\OwnTechInstaller
      // itself (it normally has, via Get-StateFilePath, by the time preflight
      // above succeeds -- this is just cheap insurance against relying on
      // that ordering).
      ForceDirectories(ExpandConstant('{localappdata}\OwnTechInstaller'));
      SaveStringToFile(GetWorkspaceMarkerPath, AnsiString(ProjectsRoot), False);
      WorkspaceKnown := True;
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
  // Back doesn't cleanly support this wizard's flow -- pages have real side
  // effects on Next (preflight runs, confirmation dialogs, the workspace
  // marker gets written) that aren't designed to be undone by stepping
  // backward, and Inno recalculates button visibility on every page change
  // regardless of what a prior page did, so this has to be reasserted here
  // rather than once in InitializeWizard.
  WizardForm.BackButton.Visible := False;

  // By the time this page is reached, ProjectsRoot is already set either way
  // -- loaded from workspace_root.txt in InitializeWizard (returning user,
  // FolderPage skipped) or just captured from FolderPage.Values[0] in
  // NextButtonClick (first-ever run, which runs before this page-change
  // event fires). Description just says where the project will land (there's
  // no UI to change ProjectsRoot from here -- delete workspace_root.txt to
  // reset it) -- the "new subfolder" explanation itself lives only in
  // NamePage's static SubCaption, not repeated here. Also defaults the name
  // field: 'owntech-project' only on a genuine first run (nothing to collide
  // with yet), blank otherwise (defaulting to an old project's name would
  // just guarantee an immediate collision).
  if CurPageID = NamePage.ID then
  begin
    NamePage.Description := 'New projects are created under ' + ProjectsRoot + '.';
    if (not WorkspaceKnown) and (not NameDefaultSet) then
    begin
      NamePage.Values[0] := 'owntech-project';
      NameDefaultSet := True;
    end;
  end;

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
