; The Windows installer (Inno Setup 6). Built by .github/workflows/windows-installer.yml:
;
;   ISCC /DSrcX64=dist\LongyanReader LongyanReader.iss                 LongyanReader-Setup-<version>-x64.exe
;   ISCC /DSrcArm64=dist-arm64\LongyanReader LongyanReader.iss         LongyanReader-Setup-<version>-arm64.exe
;   ISCC /DSrcX64=... /DSrcArm64=... LongyanReader.iss                 LongyanReader-Setup-<version>-x64-arm64.exe
;
; Each folder is the app folder windows.yml stages. The version is the app's own, read from
; LongyanReader.exe (<Version> in windows/LongyanReader/LongyanReader.csproj); /DAppVersion=
; overrides it. /DSign signs the setup and uninstaller with windows/installer/sign.ps1, which
; needs /Ssign=... on the command line (see the workflow).
;
; Per user, no admin prompt: %LOCALAPPDATA%\Programs\Longyan Reader, a Start menu shortcut,
; and an entry in Settings > Apps. The reading model isn't in here: the app downloads it.
; Opening at sign-in is the app's own setting (the welcome window, on by default).

#if !defined(SrcX64) && !defined(SrcArm64)
  #error Pass /DSrcX64=folder, /DSrcArm64=folder or both
#endif

#ifdef SrcX64
  #define VersionFrom SrcX64
#else
  #define VersionFrom SrcArm64
#endif

#ifndef AppVersion
  #define VMajor 0
  #define VMinor 0
  #define VRev 0
  #define VBuild 0
  #expr GetVersionComponents(VersionFrom + "\LongyanReader.exe", VMajor, VMinor, VRev, VBuild)
  #define AppVersion Str(VMajor) + "." + Str(VMinor) + "." + Str(VRev)
#endif

#if defined(SrcX64) && defined(SrcArm64)
  #define ArchName "x64-arm64"
#elif defined(SrcX64)
  #define ArchName "x64"
#else
  #define ArchName "arm64"
#endif

#ifndef OutputDir
  #define OutputDir "Output"
#endif

[Setup]
; Never change: Windows knows the installed app by it, and upgrades find the old one with it.
AppId={{E0CE80DD-FDC0-4DB6-97BE-2EAA3F95E820}
AppName=Longyan Reader
AppVersion={#AppVersion}
AppVerName=Longyan Reader {#AppVersion}
AppPublisher=mapuchuu
AppPublisherURL=https://github.com/mapuchuu/longyan-reader
AppSupportURL=https://github.com/mapuchuu/longyan-reader/issues
AppUpdatesURL=https://github.com/mapuchuu/longyan-reader/releases
AppCopyright=Copyright (c) 2026 mapuchuu
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Longyan Reader
VersionInfoDescription=Longyan Reader Setup

PrivilegesRequired=lowest
DefaultDirName={userpf}\Longyan Reader
DisableDirPage=yes
DisableProgramGroupPage=yes
UsedUserAreasWarning=no
SetupMutex=LongyanReaderSetup
MinVersion=10.0

#if defined(SrcX64) && defined(SrcArm64)
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
#elif defined(SrcX64)
; Windows on ARM runs the x64 build too, emulated.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#endif

; The [Code] below asks the app to exit first; this closes it if it's still open after that.
CloseApplications=force
RestartApplications=no

OutputDir={#OutputDir}
OutputBaseFilename=LongyanReader-Setup-{#AppVersion}-{#ArchName}
SetupIconFile=..\LongyanReader\LongyanReader.ico
; From images.ps1; without them, Inno Setup's own pictures.
#ifdef SmallImage
WizardSmallImageFile={#SmallImage}
#endif
#ifdef LargeImage
WizardImageFile={#LargeImage}
#endif
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes
UninstallDisplayName=Longyan Reader
UninstallDisplayIcon={app}\LongyanReader.exe

#ifdef Sign
SignTool=sign
SignedUninstaller=yes
#endif

[Messages]
FinishedLabel=Longyan Reader is installed. It runs from its icon in the notification area, next to the clock.
FinishedLabelNoIcons=Longyan Reader is installed. It runs from its icon in the notification area, next to the clock.

[InstallDelete]
; An upgrade replaces the whole app, so files an older version had and this one doesn't go too.
; Only when the folder really is the app's.
Type: filesandordirs; Name: "{app}\*"; Check: IsAppFolder

[Files]
#if defined(SrcX64) && defined(SrcArm64)
Source: "{#SrcX64}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: not IsArm64
Source: "{#SrcArm64}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsArm64
#elif defined(SrcX64)
Source: "{#SrcX64}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#else
Source: "{#SrcArm64}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif

[Icons]
Name: "{autoprograms}\Longyan Reader"; Filename: "{app}\LongyanReader.exe"

[Run]
Filename: "{app}\LongyanReader.exe"; Description: "Open Longyan Reader"; Flags: nowait postinstall skipifsilent
; A silent upgrade (as an update would run it) opens the app again if it was open.
Filename: "{app}\LongyanReader.exe"; Flags: nowait; Check: ReopenSilently

[Code]
const
  AppMutex = 'LongyanReader.Windows';
  QuitEventName = 'LongyanReader.Windows.Quit';
  EVENT_MODIFY_STATE = $0002;
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  RunName = 'Longyan Reader';

var
  WasRunning: Boolean;

function OpenEvent(dwDesiredAccess: DWORD; bInheritHandle: BOOL; lpName: String): THandle;
  external 'OpenEventW@kernel32.dll stdcall';
function SetEvent(hEvent: THandle): BOOL;
  external 'SetEvent@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

function AppRunning: Boolean;
begin
  Result := CheckForMutexes(AppMutex);
end;

function IsAppFolder: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\LongyanReader.exe'));
end;

function ReopenSilently: Boolean;
begin
  Result := WizardSilent and WasRunning;
end;

{ The copy in this folder only: a copy elsewhere, from a zip, keeps running. Stop: end it;
  else wait up to 10 seconds for it to end. }
procedure ProcessHere(Stop: Boolean);
var
  Code: Integer;
  Action: String;
begin
  if Stop then Action := 'Stop-Process -Force' else Action := 'Wait-Process -Timeout 10';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -Command "Get-Process LongyanReader -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ''' +
    ExpandConstant('{app}') + '\*'' } | ' + Action + '"', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

{ The app exits as from its menu when the event is set (App.cs), freeing the model first.
  Up to 10 seconds; true when it's gone. }
function AskAppToExit: Boolean;
var
  Event: THandle;
  I: Integer;
begin
  Result := not AppRunning;
  if Result then exit;
  Event := OpenEvent(EVENT_MODIFY_STATE, False, QuitEventName);
  if Event <> 0 then
  begin
    SetEvent(Event);
    CloseHandle(Event);
    Log('Asked Longyan Reader to exit');
  end
  else
    Log('Longyan Reader is running but has no exit event (an older build)');
  for I := 1 to 40 do
  begin
    if not AppRunning then break;
    Sleep(250);
  end;
  Result := not AppRunning;
  { The mutex goes a moment before the process: a folder it has open can't be deleted. }
  if Result then ProcessHere(False);
  if Result then Log('Longyan Reader exited') else Log('Longyan Reader is still running');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  WasRunning := AppRunning;
  { If it's still open, Restart Manager (CloseApplications) closes it next. }
  AskAppToExit;
  Result := '';
end;

{ Open at sign-in, when it opens this copy. }
procedure RemoveRunValue;
var
  Command: String;
begin
  if RegQueryStringValue(HKCU, RunKey, RunName, Command) and
     (Pos(Lowercase(ExpandConstant('{app}')), Lowercase(Command)) > 0) then
  begin
    RegDeleteValue(HKCU, RunKey, RunName);
    RegDeleteValue(HKCU, ApprovedKey, RunName);
    Log('Removed open at sign-in');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data, Question: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    if not AskAppToExit then ProcessHere(True);
    RemoveRunValue;
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    { History, settings, logs and the model. Kept unless the reader says to delete them; a
      silent uninstall keeps them. }
    Data := ExpandConstant('{localappdata}\LongyanReader');
    if DirExists(Data) and not UninstallSilent then
    begin
      Question := 'Also delete your lookup history and settings?';
      if FileExists(Data + '\models\qwen3.5-4b-q4_k_m.gguf') then
        Question := 'Also delete your lookup history, settings and the reading model (2.7 GB)?';
      if SuppressibleMsgBox(Question + #13#10#13#10 + 'Keep them if you might install Longyan Reader again.',
         mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
      begin
        DelTree(Data, True, True, True);
        Log('Deleted ' + Data);
      end;
    end;
  end;
end;
