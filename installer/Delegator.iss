#define MyAppName "Delegator"
#define MyAppVersion "0.5.18"
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
Name: "startup"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:AdditionalTasks}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:DesktopShortcut}"; GroupDescription: "{cm:AdditionalTasks}"; Flags: unchecked

[Files]
Source: "..\target\release\delegator.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\target\release\delegator-core.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\theme.json"; DestDir: "{app}\resources"; Flags: ignoreversion
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
Source: "..\scripts\gemini-delegate.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\gemini-delegate.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\opencode-delegate.cmd"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\opencode-delegate.ps1"; DestDir: "{app}\runtime"; Flags: ignoreversion

[Icons]
Name: "{group}\Delegator"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Delegator"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\Delegator"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--background"; Tasks: startup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--remove-hooks"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveIdeHooks"
Filename: "{cmd}"; Parameters: "/c taskkill /IM delegator-core.exe /T /F >nul 2>nul"; Flags: runhidden waituntilterminated; RunOnceId: "StopCore"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/c taskkill /IM delegator.exe /T /F >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/c taskkill /IM delegator-core.exe /T /F >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{cmd}'), '/c taskkill /IM CodexDelegateStatus.exe /T /F >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  DeleteFile(ExpandConstant('{userstartup}\CodexDelegateStatus.lnk'));
  DeleteFile(ExpandConstant('{userstartup}\Delegator Status.lnk'));
  Result := '';
end;
