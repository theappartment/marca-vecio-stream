#define MyAppName "Marca Vecio Stream"
#define MyAppVersion "1.3.2"
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
Source: "src\StopForUpdate.ps1"; Flags: dontcopy
Source: "dist\MarcaVecioStream.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\WebServer.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\TelegramWorker.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\MediaCatalog.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\PlaybackController.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\PlaybackSurface.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\launcher.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "dist\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "dist\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\logoapp.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\logoapp.png.jpg"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\web\index.html"; DestDir: "{app}\web"; Flags: ignoreversion
Source: "dist\tools\ngrok\ngrok.exe"; DestDir: "{app}\tools\ngrok"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\UpdateWorker.exe"
Type: files; Name: "{app}\UpdateWorker.ps1"
Type: files; Name: "{app}\UpdateClient.ps1"
Type: files; Name: "{app}\UpdateUi.ps1"

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

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
  Parameters: String;
begin
  Result := '';
  ExtractTemporaryFile('StopForUpdate.ps1');
  Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\StopForUpdate.ps1') + '" -InstallRoot "' +
    ExpandConstant('{app}') + '"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := 'Impossibile arrestare i processi di Marca Vecio Stream. Chiudi l''app e riprova.'
  else if ExitCode <> 0 then
    Result := 'I processi di Marca Vecio Stream sono ancora attivi. Termina WebServer e TelegramWorker da Gestione attivita e riprova.';
end;
