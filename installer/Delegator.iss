#define MyAppName "Delegator"
#define MyAppVersion "0.9.0"
#define MyAppPublisher "Delegator"
#define MyAppExeName "delegator.exe"

[Setup]
AppId={{9E3EA6A8-CE3B-4B2C-A70D-17B2D79C772E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Delegator
DefaultGroupName=Delegator
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
; Autostart must be ON by default on EVERY install, not only the first one.
; With the default (yes) Setup replays the remembered task set, and this app's
; `startup` task used to carry `checkedonce`: every upgrade since silently
; unticked it, so `Inno Setup: Selected Tasks` here was empty and a silent
; upgrade registered no autostart at all.
UsePreviousTasks=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=DelegatorSetup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern dynamic
SetupIconFile=..\assets\delegator.ico
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile=..\LICENSE
VersionInfoVersion={#MyAppVersion}.0
VersionInfoProductName={#MyAppName}
VersionInfoDescription=Delegator Windows installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
english.AutoStart=Start Delegator automatically with Windows
english.DesktopShortcut=Create a desktop shortcut
english.AdditionalTasks=Additional tasks:
english.LaunchApp=Launch Delegator
russian.AutoStart=Запускать Delegator автоматически вместе с Windows
russian.DesktopShortcut=Создать ярлык на рабочем столе
russian.AdditionalTasks=Дополнительные задачи:
russian.LaunchApp=Запустить Delegator

[Tasks]
Name: "startup"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:AdditionalTasks}"
Name: "desktopicon"; Description: "{cm:DesktopShortcut}"; GroupDescription: "{cm:AdditionalTasks}"; Flags: unchecked

[Files]
Source: "..\target\release\delegator.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\target\release\delegator-core.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\theme.json"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\*"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\scripts\DELEGATOR.md"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\BENCHMARK.md"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\benchmark.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate-micro.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate-micro.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate-plan.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate-plan.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate-parallel.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\ai-delegate-parallel.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\delegator-common.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\model-ratings.json"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\cursor-hook.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\cursor-hook.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\gemini-delegate.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\gemini-delegate.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\opencode-delegate.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\opencode-delegate.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion

[Icons]
Name: "{group}\Delegator"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Delegator"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

; Autostart is ONE mechanism: this Run value. A Startup-folder shortcut as well
; would start Delegator twice at logon, and the second copy raises the first
; one's window. The tray owns the same value, so it can be switched off without
; reinstalling; delegator.exe deletes the shortcut older versions left behind.
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Delegator"; ValueData: """{app}\{#MyAppExeName}"" --background"; Flags: uninsdeletevalue; Tasks: startup; Check: ShouldSetAutostart
; Unticking the task must MEAN something on an upgrade: without this the value
; written by an earlier install would simply stay and autostart would not go away.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Delegator"; Flags: deletevalue; Tasks: not startup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--remove-hooks"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveIdeHooks"
Filename: "{app}\{#MyAppExeName}"; Parameters: "--disable-autostart"; Flags: runhidden waituntilterminated; RunOnceId: "DisableAutostart"
Filename: "{cmd}"; Parameters: "/c taskkill /IM delegator-core.exe /T /F >nul 2>nul"; Flags: runhidden waituntilterminated; RunOnceId: "StopCore"

[Code]
var
  GWasInstalled: Boolean;
  GHadAutostart: Boolean;

function InitializeSetup(): Boolean;
begin
  { Read BEFORE anything is written. The in-app update button runs this
    installer with /SILENT, where nobody can answer the task checkbox and the
    defaults apply - so without the check below every update would switch
    autostart back ON for a user who had just turned it off in the tray. The
    GUID must stay equal to AppId above. }
  GWasInstalled := RegKeyExists(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{9E3EA6A8-CE3B-4B2C-A70D-17B2D79C772E}_is1');
  GHadAutostart := RegValueExists(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Delegator');
  Result := True;
end;

function ShouldSetAutostart: Boolean;
begin
  if WizardSilent then begin
    { A first install has no earlier answer, so autostart is on by default.
      An upgrade has one, and it wins. }
    Result := (not GWasInstalled) or GHadAutostart;
  end else begin
    { The checkbox was on screen: whatever it says IS the answer. }
    Result := True;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/c taskkill /IM delegator.exe /T /F >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/c taskkill /IM delegator-core.exe /T /F >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/c taskkill /IM CodexDelegateStatus.exe /T /F >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  DeleteFile(ExpandConstant('{userstartup}\CodexDelegateStatus.lnk'));
  DeleteFile(ExpandConstant('{userstartup}\Delegator Status.lnk'));
  { Autostart moved to the Run value above; leaving this behind would start
    Delegator twice at logon. delegator.exe removes it too, for an install that
    never ran this installer version. }
  DeleteFile(ExpandConstant('{userstartup}\Delegator.lnk'));
  Result := '';
end;
