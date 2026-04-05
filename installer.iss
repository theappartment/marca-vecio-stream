#define MyAppName "Marca Vecio Stream"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "The Appartment"
#define MyAppExeName "MarcaVecioStream.exe"
#define MyAppSourceDir "dist"

[Setup]
AppId={{A0D96D1F-0D46-4B20-9F86-BF4EB8B82B0C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\MarcaVecioStream
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=release
OutputBaseFilename=MarcaVecioStream-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\logoapp.ico
SetupIconFile=logoapp.ico

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "Crea un collegamento sul Desktop"; GroupDescription: "Collegamenti:"

[Files]
Source: "dist\MarcaVecioStream.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\WebServer.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\TelegramWorker.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\logoapp.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\logoapp.png.jpg"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\web\index.html"; DestDir: "{app}\web"; Flags: ignoreversion
Source: "dist\tools\ngrok\ngrok.exe"; DestDir: "{app}\tools\ngrok"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\logoapp.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; IconFilename: "{app}\logoapp.ico"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Avvia {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -CleanupOnly"; Flags: runhidden waituntilterminated; RunOnceId: "CleanupRuntime"

[UninstallDelete]
Type: files; Name: "{app}\TelegramWorker.exe"
Type: files; Name: "{app}\WebServer.exe"
Type: files; Name: "{app}\MarcaVecioStream.exe"
Type: files; Name: "{app}\tools\ngrok\ngrok.exe"
