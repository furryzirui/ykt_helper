#ifndef AppVersion
  #error AppVersion must be supplied by package.ps1
#endif
#ifndef BuildDir
  #error BuildDir must be supplied by package.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by package.ps1
#endif
#ifndef RepoRoot
  #error RepoRoot must be supplied by package.ps1
#endif

[Setup]
AppId={{9D76E409-E9A0-4501-AB73-927AE66F01D8}
AppName=ykt_helper
AppVersion={#AppVersion}
AppPublisher=紫锐飞跃
AppPublisherURL=https://github.com/furryzirui/ykt_helper
AppSupportURL=https://github.com/furryzirui/ykt_helper/issues
AppUpdatesURL=https://github.com/furryzirui/ykt_helper/releases
DefaultDirName={localappdata}\Programs\ykt_helper
DefaultGroupName=ykt_helper
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=ykt_helper-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile={#RepoRoot}\LICENSE
UninstallDisplayIcon={app}\ykt_helper.exe
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RepoRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\ykt_helper"; Filename: "{app}\ykt_helper.exe"
Name: "{autodesktop}\ykt_helper"; Filename: "{app}\ykt_helper.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ykt_helper.exe"; Description: "{cm:LaunchProgram,ykt_helper}"; Flags: nowait postinstall skipifsilent
