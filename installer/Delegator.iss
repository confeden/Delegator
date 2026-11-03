#define MyAppName "Delegator"
#define MyAppVersion "0.10.0"
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

[InstallDelete]
Type: files; Name: "{app}\runtime\benchmark.ps1"

[Files]
Source: "..\target\release\delegator.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\target\release\delegator-core.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\theme.json"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\CHANGELOG.md"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\README.md"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\background.js"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\content.js"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\door.js"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\manifest.json"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\extensions\gemini-web-bridge\visible.js"; DestDir: "{app}\extensions\gemini-web-bridge"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\scripts\DELEGATOR.md"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\scripts\BENCHMARK.md"; DestDir: "{app}\runtime"; Flags: ignoreversion
Source: "..\coding-bench\code_rules.py"; DestDir: "{app}\runtime\coding-bench"; Flags: ignoreversion
Source: "..\coding-bench\grade_run.py"; DestDir: "{app}\runtime\coding-bench"; Flags: ignoreversion
Source: "..\coding-bench\start.py"; DestDir: "{app}\runtime\coding-bench"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\code.py.txt"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\code2.py.txt"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\data.csv"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\data2.csv"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\logs.json"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\mixed.txt"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\prose.txt"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\random.bin"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\corpus\syslog2.txt"; DestDir: "{app}\runtime\coding-bench\hidden\compress\corpus"; Flags: ignoreversion
Source: "..\coding-bench\hidden\compress\score_compress.py"; DestDir: "{app}\runtime\coding-bench\hidden\compress"; Flags: ignoreversion
Source: "..\coding-bench\hidden\routing\instances.json"; DestDir: "{app}\runtime\coding-bench\hidden\routing"; Flags: ignoreversion
Source: "..\coding-bench\hidden\routing\score_routing.py"; DestDir: "{app}\runtime\coding-bench\hidden\routing"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\index.json"; DestDir: "{app}\runtime\coding-bench\hidden\sat"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\01_factoring.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\02_sudoku.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\03_parity.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\04_factoring.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\05_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\06_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\07_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\08_planted3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\09_planted3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\10_color3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\11_random5.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\12_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\13_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\14_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\15_color3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\16_color3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\17_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\18_php.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\19_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\20_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\21_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\22_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\23_coloring.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\24_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\25_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\26_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\27_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\28_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\29_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\30_coloring.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\31_coloring.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\32_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\33_php.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\34_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\35_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\36_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\37_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\38_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\39_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\40_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\sat\instances\41_random3.cnf"; DestDir: "{app}\runtime\coding-bench\hidden\sat\instances"; Flags: ignoreversion
Source: "..\coding-bench\hidden\score_sat.py"; DestDir: "{app}\runtime\coding-bench\hidden"; Flags: ignoreversion
Source: "..\coding-bench\template\bench.py"; DestDir: "{app}\runtime\coding-bench\template"; Flags: ignoreversion
Source: "..\coding-bench\template\code_rules.py"; DestDir: "{app}\runtime\coding-bench\template"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\check.py"; DestDir: "{app}\runtime\coding-bench\template\compress"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\codec.py"; DestDir: "{app}\runtime\coding-bench\template\compress"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\README.md"; DestDir: "{app}\runtime\coding-bench\template\compress"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\samples\code.py.txt"; DestDir: "{app}\runtime\coding-bench\template\compress\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\samples\data.csv"; DestDir: "{app}\runtime\coding-bench\template\compress\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\samples\logs.json"; DestDir: "{app}\runtime\coding-bench\template\compress\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\compress\samples\prose.txt"; DestDir: "{app}\runtime\coding-bench\template\compress\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\REPORT.md"; DestDir: "{app}\runtime\coding-bench\template"; Flags: ignoreversion
Source: "..\coding-bench\template\routing\check.py"; DestDir: "{app}\runtime\coding-bench\template\routing"; Flags: ignoreversion
Source: "..\coding-bench\template\routing\instances.py"; DestDir: "{app}\runtime\coding-bench\template\routing"; Flags: ignoreversion
Source: "..\coding-bench\template\routing\README.md"; DestDir: "{app}\runtime\coding-bench\template\routing"; Flags: ignoreversion
Source: "..\coding-bench\template\routing\routing.py"; DestDir: "{app}\runtime\coding-bench\template\routing"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\check.py"; DestDir: "{app}\runtime\coding-bench\template\sat"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\README.md"; DestDir: "{app}\runtime\coding-bench\template\sat"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\color3_v60_unsat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\factor_12_sat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\factor_12_unsat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\parity_40_unsat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\php_5_4_unsat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\planted_n1000_sat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\r3_n60_a_sat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\r3_n60_b_sat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\r3_n90_a_sat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\samples\r3_n90_b_sat.cnf"; DestDir: "{app}\runtime\coding-bench\template\sat\samples"; Flags: ignoreversion
Source: "..\coding-bench\template\sat\solver.py"; DestDir: "{app}\runtime\coding-bench\template\sat"; Flags: ignoreversion
Source: "..\dist\pyembed\python.exe"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\python3.dll"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\python312.dll"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\python312.zip"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\vcruntime140.dll"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\vcruntime140_1.dll"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\libffi-8.dll"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_asyncio.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_bz2.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_ctypes.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_decimal.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_elementtree.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_lzma.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_multiprocessing.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_overlapped.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_queue.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_socket.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_uuid.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\_zoneinfo.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\pyexpat.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\select.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
Source: "..\dist\pyembed\unicodedata.pyd"; DestDir: "{app}\runtime\python"; Flags: ignoreversion
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
; Autostart is ONE mechanism: this shortcut in the Startup folder (0.9.21+). The
; app owns it from then on (autostart.rs), so the tray can switch it off without a
; reinstall. The 0.9.22 installer wrote nothing here and switched autostart OFF on
; the next upgrade - the check below now reads this shortcut as the earlier answer.
Name: "{userstartup}\Delegator"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--background"; Tasks: startup; Check: ShouldSetAutostart

; A Run value from 0.8.x-0.9.20 would start Delegator twice with the shortcut;
; delegator.exe migrates it into the shortcut at launch, and this removes it now.
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Delegator"; Flags: deletevalue

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
  GHadAutostart := FileExists(ExpandConstant('{userstartup}\Delegator.lnk')) or
    RegValueExists(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Delegator');
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
