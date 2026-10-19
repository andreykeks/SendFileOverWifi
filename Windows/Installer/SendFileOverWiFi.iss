#ifndef AppVersion
  #define AppVersion "1.0"
#endif

#define AppName "SendFile over WiFi"
#define AppExeName "SendFileOverWiFi.exe"
#define AppPublisher "SendFile over WiFi"

[Setup]
AppId={{B56CC80B-6C22-4388-8FC6-1DAB0E4B59B0}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#SourcePath}\..\artifacts\{#AppVersion}
OutputBaseFilename=SendFileOverWiFi-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=win64
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no
WizardStyle=modern
SetupIconFile={#SourcePath}\..\assets\logo.ico
UninstallDisplayIcon={app}\{#AppExeName}
SignTool=sendfile
SignedUninstaller=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "{#SourcePath}\..\SendFileOverWiFi\bin\x64\Release\net8.0-windows10.0.17763.0\win-x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsX64Compatible and not IsArm64
Source: "{#SourcePath}\..\SendFileOverWiFi\bin\ARM64\Release\net8.0-windows10.0.17763.0\win-arm64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsArm64

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent unchecked
