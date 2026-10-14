Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Get-AppRootPath {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.PSObject.Properties["Path"] -and $MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    return (Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
}

function Get-PreferredNgrokPath {
    $appLocalPath = Join-Path $DefaultNgrokInstallRoot "ngrok.exe"
    if (Test-Path -LiteralPath $appLocalPath) {
        return $appLocalPath
    }

    return (Join-Path $FallbackNgrokInstallRoot "ngrok.exe")
}

$AppName = "Marca Vecio Stream"
$AppRoot = Get-AppRootPath
$ConfigRoot = Join-Path $env:APPDATA "MarcaVecioStream"
$ConfigPath = Join-Path $ConfigRoot "config.json"
$PlaylistPath = Join-Path $ConfigRoot "playlist.m3u"
$StatePath = Join-Path $ConfigRoot "state.json"
$CommandRoot = Join-Path $ConfigRoot "commands"
$WebServerPidPath = Join-Path $ConfigRoot "webserver.pid"
$TelegramPidPath = Join-Path $ConfigRoot "telegram.pid"
$NgrokPidPath = Join-Path $ConfigRoot "ngrok.pid"
$NgrokConfigPath = Join-Path $ConfigRoot "ngrok.yml"
$SupportedExtensions = @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".m4v", ".webm")
$DefaultTelegramBotToken = ""
$DefaultNgrokAuthtoken = ""
$DefaultNgrokDownloadUrl = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
$DefaultNgrokInstallRoot = Join-Path $AppRoot "tools\ngrok"
$FallbackNgrokInstallRoot = Join-Path $env:LOCALAPPDATA "MarcaVecioStream\tools\ngrok"
$AppIconPath = Join-Path (Split-Path -Parent $AppRoot) "logoapp.ico"
$AppImagePath = Join-Path (Split-Path -Parent $AppRoot) "logoapp.png.jpg"
$script:CurrentVlcProcess = $null
$script:ApplicationClosing = $false
. (Join-Path $AppRoot 'MediaCatalog.ps1')
. (Join-Path $AppRoot 'PlaybackSurface.ps1')
. (Join-Path $AppRoot 'PlaybackController.ps1')
$script:ConfigWriteStamp = ""
$script:WebServerOwnedPid = $null
$script:TelegramWorkerOwnedPid = $null
$script:NgrokOwnedPid = $null
$script:TelegramConfig = [ordered]@{
    telegramEnabled         = $true
    telegramBotToken        = $DefaultTelegramBotToken
    telegramLastUpdateId    = 0
    telegramSubscribedChats = @()
}
$script:NgrokConfig = [ordered]@{
    ngrokEnabled     = $true
    ngrokAuthtoken   = $DefaultNgrokAuthtoken
    ngrokPath        = (Get-PreferredNgrokPath)
    ngrokDownloadUrl = $DefaultNgrokDownloadUrl
}

function Write-AppLog([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $ConfigRoot)) {
            New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
        }
        $logPath = Join-Path $ConfigRoot "app.log"
        $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    }
    catch {
    }
}

Write-AppLog "Avvio applicazione."

function Write-JsonAtomically([string]$Path, [string]$Json) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    Set-Content -LiteralPath $tempPath -Value $Json -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Set-WindowIcon($Window) {
    try {
        $sourcePath = if (Test-Path -LiteralPath $AppIconPath) { $AppIconPath } else { $AppImagePath }
        if (Test-Path -LiteralPath $sourcePath) {
            $uri = New-Object System.Uri($sourcePath)
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage($uri)
            $Window.Icon = $bitmap
        }
    }
    catch {
        Write-AppLog ("Impossibile applicare l'icona: " + $_.Exception.Message)
    }
}

foreach ($path in @($ConfigRoot, $CommandRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function New-RandomToken {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).Replace("+", "A").Replace("/", "B").TrimEnd("=")
}

function Get-DefaultConfig {
    return [ordered]@{
        videoFolder       = ""
        vlcPath           = ""
        webEnabled        = $true
        webPort           = 8090
        remoteToken       = (New-RandomToken)
        autoStartPlayback = $false
        launchOnLogin     = $false
        kioskMode         = $false
        telegramEnabled   = $true
        telegramBotToken  = $DefaultTelegramBotToken
        telegramLastUpdateId = 0
        telegramSubscribedChats = @()
        ngrokEnabled      = $true
        ngrokAuthtoken    = $DefaultNgrokAuthtoken
        ngrokPath         = (Get-PreferredNgrokPath)
        ngrokDownloadUrl  = $DefaultNgrokDownloadUrl
    }
}

function Find-VlcPath {
    foreach ($candidate in @(
        "C:\Program Files\VideoLAN\VLC\vlc.exe",
        "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

function Get-ValueOrDefault($Value, $DefaultValue) {
    if ($null -ne $Value -and "$Value" -ne "") {
        return $Value
    }

    return $DefaultValue
}

function Get-PropertyValueOrDefault($Object, [string]$Name, $DefaultValue) {
    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return (Get-ValueOrDefault $property.Value $DefaultValue)
}

function Normalize-Config([psobject]$Raw) {
    $defaults = Get-DefaultConfig
    $telegramChats = @()
    $rawTelegramChats = Get-PropertyValueOrDefault -Object $Raw -Name "telegramSubscribedChats" -DefaultValue @()
    if ($null -ne $rawTelegramChats) {
        $telegramChats = @($rawTelegramChats | Where-Object { $_ })
    }
    return [ordered]@{
        videoFolder       = [string](Get-PropertyValueOrDefault $Raw "videoFolder" $defaults.videoFolder)
        vlcPath           = [string](Get-PropertyValueOrDefault $Raw "vlcPath" $defaults.vlcPath)
        webEnabled        = [bool](Get-PropertyValueOrDefault $Raw "webEnabled" $defaults.webEnabled)
        webPort           = [int](Get-PropertyValueOrDefault $Raw "webPort" $defaults.webPort)
        remoteToken       = [string](Get-PropertyValueOrDefault $Raw "remoteToken" $defaults.remoteToken)
        autoStartPlayback = [bool](Get-PropertyValueOrDefault $Raw "autoStartPlayback" $defaults.autoStartPlayback)
        launchOnLogin     = [bool](Get-PropertyValueOrDefault $Raw "launchOnLogin" $defaults.launchOnLogin)
        kioskMode         = [bool](Get-PropertyValueOrDefault $Raw "kioskMode" $defaults.kioskMode)
        telegramEnabled   = [bool](Get-PropertyValueOrDefault $Raw "telegramEnabled" $true)
        telegramBotToken  = [string](Get-PropertyValueOrDefault $Raw "telegramBotToken" $DefaultTelegramBotToken)
        telegramLastUpdateId = [int](Get-PropertyValueOrDefault $Raw "telegramLastUpdateId" 0)
        telegramSubscribedChats = $telegramChats
        ngrokEnabled      = [bool](Get-PropertyValueOrDefault $Raw "ngrokEnabled" $true)
        ngrokAuthtoken    = [string](Get-PropertyValueOrDefault $Raw "ngrokAuthtoken" $DefaultNgrokAuthtoken)
        ngrokPath         = [string](Get-PropertyValueOrDefault $Raw "ngrokPath" (Get-PreferredNgrokPath))
        ngrokDownloadUrl  = [string](Get-PropertyValueOrDefault $Raw "ngrokDownloadUrl" $DefaultNgrokDownloadUrl)
    }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $config = Get-DefaultConfig
        if ([string]::IsNullOrWhiteSpace($config.vlcPath)) {
            $config.vlcPath = Find-VlcPath
        }
        Save-Config -Config $config
        return $config
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $config = Normalize-Config -Raw $raw
            if ([string]::IsNullOrWhiteSpace($config.remoteToken)) {
                $config.remoteToken = New-RandomToken
            }
            if ([string]::IsNullOrWhiteSpace($config.vlcPath)) {
                $config.vlcPath = Find-VlcPath
            }
            if ($config.ngrokPath -like "*\src\tools\ngrok\ngrok.exe") {
                $config.ngrokPath = Get-PreferredNgrokPath
            }
            $bundledNgrokPath = Join-Path $DefaultNgrokInstallRoot "ngrok.exe"
            if ((Test-Path -LiteralPath $bundledNgrokPath) -and ($config.ngrokPath -ne $bundledNgrokPath)) {
                $config.ngrokPath = $bundledNgrokPath
            }
            return $config
        }
        catch {
            if ($attempt -lt 2) {
                Start-Sleep -Milliseconds 250
                continue
            }

            Write-AppLog "Configurazione non valida letta. Ripristino valori predefiniti."
            $config = Get-DefaultConfig
            $config.vlcPath = Find-VlcPath
            Save-Config -Config $config
            return $config
        }
    }
}

function Save-Config($Config) {
    $payload = [ordered]@{
        videoFolder       = [string]$Config.videoFolder
        vlcPath           = [string]$Config.vlcPath
        webEnabled        = [bool]$Config.webEnabled
        webPort           = [int]$Config.webPort
        remoteToken       = [string]$Config.remoteToken
        autoStartPlayback = [bool]$Config.autoStartPlayback
        launchOnLogin     = [bool]$Config.launchOnLogin
        kioskMode         = [bool]$Config.kioskMode
        telegramEnabled   = [bool]$Config.telegramEnabled
        telegramBotToken  = [string]$Config.telegramBotToken
        telegramLastUpdateId = [int]$Config.telegramLastUpdateId
        telegramSubscribedChats = @($Config.telegramSubscribedChats)
        ngrokEnabled      = [bool]$Config.ngrokEnabled
        ngrokAuthtoken    = [string]$Config.ngrokAuthtoken
        ngrokPath         = [string]$Config.ngrokPath
        ngrokDownloadUrl  = [string]$Config.ngrokDownloadUrl
    }

    $json = $payload | ConvertTo-Json -Depth 6
    Write-JsonAtomically -Path $ConfigPath -Json $json
    $script:ConfigWriteStamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc.Ticks.ToString()
}

function Get-VideoFiles([string]$FolderPath) {
    return @(Get-MediaFiles $FolderPath)
}

function Stop-Playback {
    Stop-ControlledPlayback
    Update-Status 'Playback fermato.'
}

function Show-ConfigurationWindow {
    if ($script:ApplicationClosing) { return }
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) { $window.WindowState = [Windows.WindowState]::Normal }
    if (-not $window.IsVisible) { $window.Show() }
    $window.Activate() | Out-Null
    $window.Focus() | Out-Null
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).EnsureHandle()
    [MarcaVecio.PlaybackKeyboard]::BringToForeground($hwnd)
    Write-StateFile
}

function Update-Status([string]$Message) {
    $statusText.Text = $Message
}

function Ensure-ValidVlcSetup {
    $vlcPath = $vlcPathTextBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($vlcPath) -or -not (Test-Path -LiteralPath $vlcPath)) {
        throw "Seleziona un percorso valido per vlc.exe."
    }

    return @{
        vlcPath     = $vlcPath
    }
}

function Ensure-ValidLocalVideoSetup {
    $setup = Ensure-ValidVlcSetup
    $videoFolder = $videoFolderTextBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($videoFolder) -or -not (Test-Path -LiteralPath $videoFolder)) {
        throw "Seleziona una cartella contenuti valida."
    }

    $setup.videoFolder = $videoFolder
    return $setup
}

function Start-PlaySelected([string]$FileName) {
    $setup = Ensure-ValidLocalVideoSetup
    $target = (Get-MediaView $setup.videoFolder).items | Where-Object { $_.Name -eq $FileName -and $_.enabled -and -not $_.pendingDelete } | Select-Object -First 1
    if (-not $target) {
        throw "Contenuto non trovato o disattivato: $FileName"
    }
    Start-ControlledPlayback $setup.vlcPath $setup.videoFolder $FileName
}

function Start-PlayAll {
    $setup = Ensure-ValidLocalVideoSetup
    $items = @((Get-MediaView $setup.videoFolder).items | Where-Object { $_.enabled -and -not $_.pendingDelete })
    if ($items.Count -eq 0) {
        Stop-Playback
        Set-PlaybackNotice 'Rotazione fermata: nessun contenuto attivo.'
        return
    }
    Start-ControlledPlayback $setup.vlcPath $setup.videoFolder
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath("Startup")
    return Join-Path $startupDir "$AppName.lnk"
}

function Configure-LaunchOnLogin([bool]$Enabled) {
    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $launcherPath = Join-Path $AppRoot "launcher.vbs"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $exePath = Join-Path $AppRoot 'MarcaVecioStream.exe'
        $shortcut.TargetPath = $(if ([IO.File]::Exists($exePath)) { $exePath } else { $launcherPath })
        $shortcut.WorkingDirectory = $AppRoot
        $shortcut.Save()
    }
    elseif (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

function Read-PidFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return [int](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    }
    catch {
        return $null
    }
}

function Stop-WebServerProcess {
    $processId = Read-PidFile -Path $WebServerPidPath
    if ($processId) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $process.Kill()
            $process.WaitForExit(3000) | Out-Null
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $WebServerPidPath) {
        Remove-Item -LiteralPath $WebServerPidPath -Force
    }
}

function Test-HelperProcess($Process, [string]$ExecutablePath, [string]$ScriptPath) {
    try {
        if ($Process.Path -and $Process.Path.Equals($ExecutablePath,[StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Process.ProcessName -in @('powershell','pwsh')) {
            $details = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $Process.Id) -ErrorAction Stop
            return ($details.CommandLine -and $details.CommandLine.IndexOf(('"' + $ScriptPath + '"'),[StringComparison]::OrdinalIgnoreCase) -ge 0)
        }
    } catch { }
    return $false
}

function Start-WebServerProcess {
    $config = Get-CurrentConfigFromUi
    if (-not $config.webEnabled) {
        Stop-WebServerProcess
        return
    }

    $existingPid = Read-PidFile -Path $WebServerPidPath
    if ($existingPid) {
        try {
            $existing = Get-Process -Id $existingPid -ErrorAction Stop
            if (-not $existing.HasExited -and (Test-HelperProcess $existing (Join-Path $AppRoot 'WebServer.exe') (Join-Path $AppRoot 'WebServer.ps1'))) {
                $script:WebServerOwnedPid = $existingPid
                return
            }
        }
        catch {
        }
    }

    $exePath = Join-Path $AppRoot "WebServer.exe"
    if (Test-Path -LiteralPath $exePath) {
        $proc = Start-Process -FilePath $exePath -WindowStyle Hidden -PassThru
    }
    else {
        $scriptPath = Join-Path $AppRoot "WebServer.ps1"
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-WindowStyle", "Hidden",
                "-File", "`"$scriptPath`""
            ) `
            -PassThru
    }
    $script:WebServerOwnedPid = $proc.Id
}

function Restart-WebServerProcess {
    Stop-WebServerProcess
    Start-Sleep -Milliseconds 300
    Start-WebServerProcess
}

function Ensure-NgrokConfigFile($Config) {
    $folder = Split-Path -Parent $NgrokConfigPath
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $content = @(
        "version: 2"
        "authtoken: $($Config.ngrokAuthtoken)"
        "web_addr: 127.0.0.1:4040"
        "log_level: info"
    )
    Set-Content -LiteralPath $NgrokConfigPath -Value $content -Encoding UTF8
}

function Get-NgrokPublicUrl([int]$Port) {
    try {
        $response = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:4040/api/tunnels"
        $tunnels = @($response.tunnels)
        foreach ($tunnel in $tunnels) {
            if ($tunnel.public_url -and $tunnel.public_url.StartsWith("https://")) {
                $target = [string]$tunnel.config.addr
                if ([string]::IsNullOrWhiteSpace($target)) {
                    $target = [string]$tunnel.forwards_to
                }
                if ($target -match "(:|//)$Port$") {
                    return [string]$tunnel.public_url
                }
            }
        }
    }
    catch {
    }

    return ""
}

function Stop-NgrokProcess {
    $processId = Read-PidFile -Path $NgrokPidPath
    if ($processId) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $process.Kill()
            $process.WaitForExit(3000) | Out-Null
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $NgrokPidPath) {
        Remove-Item -LiteralPath $NgrokPidPath -Force
    }
}

function Start-NgrokProcess {
    $config = Get-CurrentConfigFromUi
    if (-not $config.ngrokEnabled -or [string]::IsNullOrWhiteSpace($config.ngrokAuthtoken) -or -not $config.webEnabled) {
        Stop-NgrokProcess
        return
    }

    if (-not (Test-Path -LiteralPath $config.ngrokPath)) {
        Update-Status "ngrok non trovato. Usa 'Installa/aggiorna ngrok' nelle impostazioni."
        return
    }

    $existingPid = Read-PidFile -Path $NgrokPidPath
    if ($existingPid) {
        try {
            $existing = Get-Process -Id $existingPid -ErrorAction Stop
            if (-not $existing.HasExited -and (Test-HelperProcess $existing $config.ngrokPath '')) {
                $script:NgrokOwnedPid = $existingPid
                return
            }
        }
        catch {
        }
    }

    Ensure-NgrokConfigFile -Config $config

    $proc = Start-Process -FilePath $config.ngrokPath `
        -ArgumentList @(
            "http",
            [string]$config.webPort,
            "--config", "`"$NgrokConfigPath`"",
            "--log", "stdout"
        ) `
        -WindowStyle Hidden `
        -PassThru
    $script:NgrokOwnedPid = $proc.Id
    Set-Content -LiteralPath $NgrokPidPath -Value $proc.Id -Encoding UTF8
}

function Restart-NgrokProcess {
    Stop-NgrokProcess
    Start-Sleep -Milliseconds 500
    Start-NgrokProcess
}

function Stop-TelegramWorkerProcess {
    $processId = Read-PidFile -Path $TelegramPidPath
    if ($processId) {
        try {
            Write-AppLog "Arresto worker Telegram."
            $process = Get-Process -Id $processId -ErrorAction Stop
            $process.Kill()
            $process.WaitForExit(3000) | Out-Null
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $TelegramPidPath) {
        Remove-Item -LiteralPath $TelegramPidPath -Force
    }
}

function Start-TelegramWorkerProcess {
    $config = Get-CurrentConfigFromUi
    if (-not $config.telegramEnabled -or [string]::IsNullOrWhiteSpace($config.telegramBotToken)) {
        Stop-TelegramWorkerProcess
        return
    }

    $existingPid = Read-PidFile -Path $TelegramPidPath
    if ($existingPid) {
        try {
            $existing = Get-Process -Id $existingPid -ErrorAction Stop
            if (-not $existing.HasExited -and (Test-HelperProcess $existing (Join-Path $AppRoot 'TelegramWorker.exe') (Join-Path $AppRoot 'TelegramWorker.ps1'))) {
                $script:TelegramWorkerOwnedPid = $existingPid
                return
            }
        }
        catch {
        }
    }

    $exePath = Join-Path $AppRoot "TelegramWorker.exe"
    if (Test-Path -LiteralPath $exePath) {
        $proc = Start-Process -FilePath $exePath -WindowStyle Hidden -PassThru
    }
    else {
        $scriptPath = Join-Path $AppRoot "TelegramWorker.ps1"
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-WindowStyle", "Hidden",
                "-File", "`"$scriptPath`""
            ) `
            -PassThru
    }
    $script:TelegramWorkerOwnedPid = $proc.Id
    Write-AppLog ("Worker Telegram avviato. PID=" + $proc.Id)
}

function Restart-TelegramWorkerProcess {
    Stop-TelegramWorkerProcess
    Start-Sleep -Milliseconds 300
    Start-TelegramWorkerProcess
}

function Install-NgrokBinary {
    $config = Get-CurrentConfigFromUi
    if ([string]::IsNullOrWhiteSpace($config.ngrokDownloadUrl)) {
        throw "URL di download ngrok non configurata."
    }

    Stop-NgrokProcess

    $targetPath = $config.ngrokPath
    $zipPath = Join-Path $env:TEMP "marca-vecio-ngrok.zip"
    $targetDir = $null

    function Get-NgrokFallbackTarget {
        $fallbackPath = Join-Path $FallbackNgrokInstallRoot "ngrok.exe"
        $fallbackDir = Split-Path -Parent $fallbackPath
        if (-not (Test-Path -LiteralPath $fallbackDir)) {
            New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
        }
        $ngrokPathTextBox.Text = $fallbackPath
        Save-CurrentConfigFromUi
        $updatedConfig = Get-CurrentConfigFromUi
        return @{
            Path = $fallbackPath
            Dir = $fallbackDir
            Config = $updatedConfig
        }
    }

    $targetDir = Split-Path -Parent $targetPath

    if (-not (Test-Path -LiteralPath $targetDir)) {
        try {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        catch {
            $fallbackTarget = Get-NgrokFallbackTarget
            $targetPath = $fallbackTarget.Path
            $targetDir = $fallbackTarget.Dir
            $config = $fallbackTarget.Config
        }
    }

    Invoke-WebRequest -Uri $config.ngrokDownloadUrl -OutFile $zipPath

    try {
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $targetDir -Force
    }
    catch {
        if ($targetPath -ne (Join-Path $FallbackNgrokInstallRoot "ngrok.exe")) {
            $fallbackTarget = Get-NgrokFallbackTarget
            $targetPath = $fallbackTarget.Path
            $targetDir = $fallbackTarget.Dir
            $config = $fallbackTarget.Config
            if (Test-Path -LiteralPath $targetPath) {
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
            }
            Expand-Archive -LiteralPath $zipPath -DestinationPath $targetDir -Force
        }
        else {
            throw
        }
    }

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $targetPath)) {
        throw "Installazione ngrok non riuscita."
    }
}

function Get-ContentPreviewBitmap($Item) {
    if (-not (Get-Variable ContentPreviewCache -Scope Script -ErrorAction SilentlyContinue)) { $script:ContentPreviewCache = @{} }
    $key = $Item.fullName+'|'+$Item.modifiedTicks+'|'+$Item.size
    if ($script:ContentPreviewCache.ContainsKey($key)) { return $script:ContentPreviewCache[$key] }
    $previewPath = if ($Item.kind -in @('slide','background')) { $Item.fullName } else { Get-MediaPreview $Item.fullName $vlcPathTextBox.Text }
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit(); $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $stream = [IO.File]::Open($previewPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $bitmap.StreamSource = $stream; $bitmap.DecodePixelWidth = 280
        $bitmap.EndInit(); $bitmap.Freeze()
    } finally { $stream.Dispose() }
    $script:ContentPreviewCache[$key] = $bitmap
    return $bitmap
}

function New-ContentRow($Item,$Bitmap,[string]$PreviewStatus) {
    if (-not ('MarcaVecio.ContentRow' -as [type])) {
        # Real CLR properties keep WPF bindings independent of PowerShell's
        # descriptors for properties attached later with Add-Member.
        Add-Type -ReferencedAssemblies PresentationCore,WindowsBase -TypeDefinition @'
namespace MarcaVecio {
    public sealed class ContentRow {
        public string name {get;set;}
        public string role {get;set;}
        public string kind {get;set;}
        public bool enabled {get;set;}
        public bool priority {get;set;}
        public int durationSeconds {get;set;}
        public bool pendingDelete {get;set;}
        public int order {get;set;}
        public long size {get;set;}
        public string modifiedAt {get;set;}
        public long modifiedTicks {get;set;}
        public string fullName {get;set;}
        public System.Windows.Media.Imaging.BitmapSource previewBitmap {get;set;}
        public string previewStatus {get;set;}
    }
}
'@
    }
    $row = New-Object MarcaVecio.ContentRow
    foreach ($name in @('name','role','kind','enabled','priority','durationSeconds','pendingDelete','order','size','modifiedAt','modifiedTicks','fullName')) {
        $row.$name = $Item.$name
    }
    $row.previewBitmap = $Bitmap; $row.previewStatus = $PreviewStatus
    return $row
}

function Refresh-VideoList {
    if (-not [IO.Directory]::Exists($videoFolderTextBox.Text)) { $videoListBox.ItemsSource = @(); return }
    $view = Get-MediaView $videoFolderTextBox.Text
    $items = @(foreach ($item in $view.items) {
        $bitmap = $null; $previewStatus = ''
        try { if (-not $item.pendingDelete) { $bitmap = Get-ContentPreviewBitmap $item } }
        catch {
            $previewStatus = 'Anteprima non disponibile'
            Write-AppLog ('Anteprima non disponibile per '+$item.name+': '+$_.Exception.Message)
        }
        New-ContentRow $item $bitmap $previewStatus
    })
    $selectedName = if ($videoListBox.SelectedItem) { $videoListBox.SelectedItem.name } else { '' }
    $videoListBox.ItemsSource = $null
    $videoListBox.ItemsSource = $items
    $videoListBox.SelectedItem = $items | Where-Object { $_.name -eq $selectedName } | Select-Object -First 1
    $videoCountText.Text = "Contenuti: $($items.Count) - Le modifiche entrano al prossimo contenuto."
    $script:UpdatingContentUi = $true
    $priorityFrequencyCombo.SelectedIndex = $view.priorityFrequency - 2
    if (-not $globalSlideDurationTextBox.IsKeyboardFocusWithin) { $globalSlideDurationTextBox.Text = [string]$view.slideDurationSeconds }
    $script:UpdatingContentUi = $false
}

function Get-PlaybackState {
    $isRunning = ($script:PlaybackMode -ne 'stopped' -and $null -ne $script:PlaybackSurface)
    $processId = if ($isRunning) { [Diagnostics.Process]::GetCurrentProcess().Id } else { $null }

    return [ordered]@{
        isRunning = ($isRunning -and $script:PlaybackMode -ne 'stopped')
        processId = $processId
        mode = $script:PlaybackMode
        currentName = $(if ($script:PlaybackCurrent) { $script:PlaybackCurrent.name } else { '' })
        message = $script:PlaybackMessage
        error = $script:PlaybackError
        pendingChanges = ($script:PlaybackMode -ne 'stopped' -and $script:PlaybackSignature -ne $script:PlaybackAppliedSignature)
    }
}

function Get-CurrentConfigFromUi {
    return [ordered]@{
        videoFolder       = $videoFolderTextBox.Text.Trim()
        vlcPath           = $vlcPathTextBox.Text.Trim()
        webEnabled        = [bool]$webEnabledCheckBox.IsChecked
        webPort           = [int]$webPortTextBox.Text
        remoteToken       = $tokenTextBox.Text.Trim()
        autoStartPlayback = [bool]$autoStartPlaybackCheckBox.IsChecked
        launchOnLogin     = [bool]$launchOnLoginCheckBox.IsChecked
        kioskMode         = [bool]$kioskModeCheckBox.IsChecked
        telegramEnabled   = [bool]$telegramEnabledCheckBox.IsChecked
        telegramBotToken  = [string]$telegramTokenPasswordBox.Password
        telegramLastUpdateId = [int]$script:TelegramConfig.telegramLastUpdateId
        telegramSubscribedChats = @($script:TelegramConfig.telegramSubscribedChats)
        ngrokEnabled      = [bool]$ngrokEnabledCheckBox.IsChecked
        ngrokAuthtoken    = [string]$ngrokAuthtokenPasswordBox.Password
        ngrokPath         = [string]$ngrokPathTextBox.Text.Trim()
        ngrokDownloadUrl  = [string]$script:NgrokConfig.ngrokDownloadUrl
    }
}

function Apply-ConfigToUi($Config) {
    $videoFolderTextBox.Text = $Config.videoFolder
    $vlcPathTextBox.Text = $Config.vlcPath
    $webEnabledCheckBox.IsChecked = $Config.webEnabled
    $webPortTextBox.Text = [string]$Config.webPort
    $tokenTextBox.Text = $Config.remoteToken
    $autoStartPlaybackCheckBox.IsChecked = $Config.autoStartPlayback
    $launchOnLoginCheckBox.IsChecked = $Config.launchOnLogin
    $kioskModeCheckBox.IsChecked = $Config.kioskMode
    $webUrlText.Text = "http://127.0.0.1:$($Config.webPort)/"
    $telegramEnabledCheckBox.IsChecked = $Config.telegramEnabled
    $telegramTokenPasswordBox.Password = $Config.telegramBotToken
    $script:TelegramConfig = [ordered]@{
        telegramEnabled         = [bool]$Config.telegramEnabled
        telegramBotToken        = [string]$Config.telegramBotToken
        telegramLastUpdateId    = [int]$Config.telegramLastUpdateId
        telegramSubscribedChats = @($Config.telegramSubscribedChats)
    }
    $ngrokEnabledCheckBox.IsChecked = $Config.ngrokEnabled
    $ngrokAuthtokenPasswordBox.Password = $Config.ngrokAuthtoken
    $ngrokPathTextBox.Text = $Config.ngrokPath
    $script:NgrokConfig = [ordered]@{
        ngrokEnabled     = [bool]$Config.ngrokEnabled
        ngrokAuthtoken   = [string]$Config.ngrokAuthtoken
        ngrokPath        = [string]$Config.ngrokPath
        ngrokDownloadUrl = [string]$Config.ngrokDownloadUrl
    }
}

function Save-CurrentConfigFromUi {
    $current = Get-CurrentConfigFromUi
    Save-Config -Config $current
}

function Write-StateFile {
    $config = Get-CurrentConfigFromUi
    $view = if ([IO.Directory]::Exists($config.videoFolder)) { Get-MediaView $config.videoFolder } else { [pscustomobject]@{ priorityFrequency = 2; slideDurationSeconds = 10; items = @() } }
    $payload = [ordered]@{
        generatedAt = (Get-Date).ToString("s")
        appName     = $AppName
        playback    = Get-PlaybackState
        config      = [ordered]@{
            videoFolder       = $config.videoFolder
            vlcPath           = $config.vlcPath
            webEnabled        = $config.webEnabled
            webPort           = $config.webPort
            autoStartPlayback = $config.autoStartPlayback
            launchOnLogin     = $config.launchOnLogin
            kioskMode         = $config.kioskMode
            remoteTokenSet    = (-not [string]::IsNullOrWhiteSpace($config.remoteToken))
            webUrl            = "http://127.0.0.1:$($config.webPort)/"
            telegramEnabled   = $config.telegramEnabled
            telegramSubscribedChats = @($config.telegramSubscribedChats).Count
            ngrokEnabled      = $config.ngrokEnabled
            ngrokInstalled    = (Test-Path -LiteralPath $config.ngrokPath)
            ngrokPublicUrl    = (Get-NgrokPublicUrl -Port $config.webPort)
        }
        priorityFrequency = $view.priorityFrequency
        slideDurationSeconds = $view.slideDurationSeconds
        files = @($view.items | ForEach-Object {
            [ordered]@{
                name = $_.name
                size = $_.size
                modifiedAt = $_.modifiedAt
                kind = $_.kind
                enabled = $_.enabled
                priority = $_.priority
                durationSeconds = $_.durationSeconds
                pendingDelete = $_.pendingDelete
                order = $_.order
            }
        })
    }

    $json = $payload | ConvertTo-Json -Depth 6
    Write-JsonAtomically -Path $StatePath -Json $json
}

function Process-CommandQueue {
    $commands = @(Get-ChildItem -LiteralPath $CommandRoot -Filter "*.json" -File | Sort-Object CreationTimeUtc)
    foreach ($file in $commands) {
        try {
            $command = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            switch ($command.action) {
                "playSelected" { Start-PlaySelected -FileName ([string]$command.data.fileName) }
                "playAll" { Start-PlayAll }
                "stop" {
                    Stop-Playback
                    Update-Status "Playback fermato."
                }
                "reloadConfig" {
                    $newConfig = Load-Config
                Apply-ConfigToUi -Config $newConfig
                Configure-LaunchOnLogin -Enabled $newConfig.launchOnLogin
                Refresh-VideoList
                Restart-WebServerProcess
                Restart-NgrokProcess
                Update-Status "Configurazione aggiornata dall'interfaccia web."
                }
                default {
                }
            }
        }
        catch {
            Set-PlaybackNotice ("Errore comando remoto: " + $_.Exception.Message) $true
        }
        finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Marca Vecio Stream"
        Height="760"
        Width="1060"
        MinHeight="680"
        MinWidth="940"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#102A43" CornerRadius="14" Padding="18" Margin="0,0,0,14">
            <StackPanel>
                <TextBlock Text="Marca Vecio Stream" Foreground="White" FontSize="28" FontWeight="Bold" />
                <TextBlock Text="Slide e video in rotazione, con priorita e controllo remoto." Foreground="#D9E2EC" FontSize="14" Margin="0,6,0,0" />
            </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="Cartella contenuti" FontWeight="SemiBold" />
                <TextBox x:Name="VideoFolderTextBox" Margin="0,6,12,0" Height="32" VerticalContentAlignment="Center" />
            </StackPanel>
            <Button x:Name="BrowseFolderButton" Grid.Column="1" Content="Sfoglia" Width="96" Height="32" VerticalAlignment="Bottom" />
        </Grid>

        <Grid Grid.Row="2" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="Percorso VLC" FontWeight="SemiBold" />
                <TextBox x:Name="VlcPathTextBox" Margin="0,6,12,0" Height="32" VerticalContentAlignment="Center" />
            </StackPanel>
            <Button x:Name="BrowseVlcButton" Grid.Column="1" Content="Seleziona VLC" Width="120" Height="32" VerticalAlignment="Bottom" Margin="0,0,12,0" />
            <Button x:Name="SaveSettingsButton" Grid.Column="2" Content="Salva tutto" Width="100" Height="32" VerticalAlignment="Bottom" />
        </Grid>

        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="320" />
            </Grid.ColumnDefinitions>

            <GroupBox Header="Slide e video" Margin="0,0,14,0">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <ListBox x:Name="VideoListBox" BorderThickness="1">
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <StackPanel Margin="4" Orientation="Horizontal">
                                    <Border Background="Black" Width="100" Height="70"><Grid><Image Source="{Binding previewBitmap}" Stretch="Uniform" /><TextBlock Text="{Binding previewStatus}" Foreground="White" FontSize="10" TextWrapping="Wrap" VerticalAlignment="Center" /></Grid></Border>
                                    <StackPanel Margin="8,0,0,0">
                                    <TextBlock Text="{Binding name}" FontWeight="SemiBold" />
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock Text="{Binding kind}" Margin="0,0,12,0" />
                                        <CheckBox IsChecked="{Binding enabled, Mode=OneWay}" Content="Attivo" IsHitTestVisible="False" Focusable="False" Margin="0,0,12,0" />
                                        <CheckBox IsChecked="{Binding priority, Mode=OneWay}" Content="Prioritaria" IsHitTestVisible="False" Focusable="False" />
                                    </StackPanel>
                                    </StackPanel>
                                </StackPanel>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>
                    <StackPanel Grid.Row="1" Margin="0,10,0,0">
                        <WrapPanel Margin="0,0,0,8">
                            <ComboBox x:Name="UploadCategoryCombo" Width="150" SelectedIndex="0" Margin="0,0,8,0"><ComboBoxItem Content="Loop normale" /><ComboBoxItem Content="Promo / evento" /><ComboBoxItem Content="Reel (video)" /><ComboBoxItem Content="Sfondo reel (foto)" /></ComboBox>
                            <Button x:Name="UploadMediaButton" Content="Carica slide / video" Padding="10,6" Margin="0,0,8,0" />
                            <Button x:Name="MoveUpButton" Content="Sposta su" Padding="10,6" Margin="0,0,8,0" />
                            <Button x:Name="MoveDownButton" Content="Sposta giu" Padding="10,6" />
                        </WrapPanel>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="140" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                            <Border Background="Black" Margin="0,0,10,0" Height="90"><Image x:Name="SlidePreview" Stretch="Uniform" /></Border>
                            <StackPanel Grid.Column="1">
                                <WrapPanel>
                                    <CheckBox x:Name="ContentEnabledCheckBox" Content="Attivo" Margin="0,0,12,6" />
                                    <CheckBox x:Name="ContentPriorityCheckBox" Content="Promo / evento" Margin="0,0,0,6" />
                                    <ComboBox x:Name="ContentRoleCombo" Width="135" Margin="8,0,0,6"><ComboBoxItem Content="Loop normale" /><ComboBoxItem Content="Reel" /><ComboBoxItem Content="Sfondo reel" /></ComboBox>
                                </WrapPanel>
                                <WrapPanel>
                                    <TextBlock Text="Durata slide (1-300 s)" VerticalAlignment="Center" Margin="0,0,8,0" />
                                    <TextBox x:Name="ContentDurationTextBox" Width="55" Height="26" />
                                </WrapPanel>
                                <WrapPanel Margin="0,6,0,0">
                                    <Button x:Name="SaveContentButton" Content="Salva contenuto" Padding="10,5" Margin="0,0,8,0" />
                                    <Button x:Name="DeleteContentButton" Content="Elimina" Padding="10,5" />
                                </WrapPanel>
                            </StackPanel>
                        </Grid>
                        <WrapPanel Margin="0,10,0,0">
                            <TextBlock Text="Apparizioni promo per giro (casuali)" VerticalAlignment="Center" Margin="0,0,8,0" />
                            <ComboBox x:Name="PriorityFrequencyCombo" Width="60"><ComboBoxItem Content="2" /><ComboBoxItem Content="3" /><ComboBoxItem Content="4" /><ComboBoxItem Content="5" /></ComboBox>
                        </WrapPanel>
                        <WrapPanel Margin="0,10,0,0">
                            <TextBlock Text="Durata tutte le immagini (s)" VerticalAlignment="Center" Margin="0,0,8,0" />
                            <TextBox x:Name="GlobalSlideDurationTextBox" Width="55" Height="26" Text="10" Margin="0,0,8,0" />
                            <Button x:Name="ApplySlideDurationButton" Content="Applica a tutte" Padding="10,5" />
                        </WrapPanel>
                        <TextBlock Text="Video normali: durata integrale. Reel: tre casuali, 30 s, in loop e senza audio. Sfondo: ultima immagine sfondo attiva." TextWrapping="Wrap" Foreground="#486581" Margin="0,5,0,0" />
                    </StackPanel>
                    <TextBlock Grid.Row="2" x:Name="VideoCountText" Margin="0,10,0,0" Foreground="#486581" TextWrapping="Wrap" />
                </Grid>
            </GroupBox>

            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <Border Background="#F0F4F8" CornerRadius="12" Padding="14" Margin="0,0,0,12">
                        <StackPanel>
                            <TextBlock Text="Comandi playback" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" />
                            <Button x:Name="RefreshButton" Content="Aggiorna elenco" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="PlaySelectedButton" Content="Riproduci selezionato" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="PlayAllButton" Content="Avvia rotazione" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="StopButton" Content="Ferma playback" Height="38" Margin="0,0,0,10" />
                            <TextBlock Text="Ctrl + Alt + S: ferma il player e torna all'app" TextWrapping="Wrap" Margin="0,0,0,10" Foreground="#486581" />
                            <Button x:Name="OpenFolderButton" Content="Apri cartella contenuti" Height="38" />
                        </StackPanel>
                    </Border>



                    <Border Background="#F8FAFC" CornerRadius="12" Padding="14" Margin="0,0,0,12">
                        <StackPanel>
                            <TextBlock Text="Startup e kiosk" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" />
                            <CheckBox x:Name="LaunchOnLoginCheckBox" Content="Avvia con Windows" Margin="0,0,0,8" />
                            <CheckBox x:Name="AutoStartPlaybackCheckBox" Content="Avvia automaticamente la playlist all'apertura" Margin="0,0,0,8" />
                            <CheckBox x:Name="KioskModeCheckBox" Content="Modalita kiosk: avvio playback e finestra minimizzata" />
                        </StackPanel>
                    </Border>

                    <Border Background="#F8FAFC" CornerRadius="12" Padding="14">
                        <StackPanel>
                            <TextBlock Text="Pannello web" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" />
                            <CheckBox x:Name="WebEnabledCheckBox" Content="Abilita pannello web locale" Margin="0,0,0,8" />
                            <TextBlock Text="Porta" FontWeight="SemiBold" />
                            <TextBox x:Name="WebPortTextBox" Height="32" Margin="0,6,0,10" VerticalContentAlignment="Center" />
                            <TextBlock Text="Token remoto" FontWeight="SemiBold" />
                            <TextBox x:Name="TokenTextBox" Height="32" Margin="0,6,0,10" VerticalContentAlignment="Center" />
                            <Button x:Name="GenerateTokenButton" Content="Rigenera token" Height="34" Margin="0,0,0,12" />
                            <TextBlock Text="URL locale" FontWeight="SemiBold" />
                            <TextBlock x:Name="WebUrlText" Margin="0,6,0,10" TextWrapping="Wrap" Foreground="#334E68" />
                            <Button x:Name="OpenWebUiButton" Content="Apri pannello web" Height="34" />
                        </StackPanel>
                    </Border>

                    <Border Background="#F8FAFC" CornerRadius="12" Padding="14" Margin="0,12,0,0">
                        <StackPanel>
                            <TextBlock Text="ngrok" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" />
                            <CheckBox x:Name="NgrokEnabledCheckBox" Content="Avvia ngrok automaticamente con l'app" Margin="0,0,0,8" />
                            <TextBlock Text="Authtoken ngrok" FontWeight="SemiBold" />
                            <PasswordBox x:Name="NgrokAuthtokenPasswordBox" Height="32" Margin="0,6,0,10" />
                            <TextBlock Text="Percorso ngrok.exe" FontWeight="SemiBold" />
                            <TextBox x:Name="NgrokPathTextBox" Height="32" Margin="0,6,0,10" VerticalContentAlignment="Center" />
                            <Button x:Name="InstallNgrokButton" Content="Installa/aggiorna ngrok" Height="34" Margin="0,0,0,12" />
                            <TextBlock TextWrapping="Wrap" Foreground="#52667A" Margin="0,0,0,14">
                                Modalita plug and play: l'app puo scaricare ngrok, avviare il tunnel e fornire la URL al bot Telegram.
                            </TextBlock>
                        </StackPanel>
                    </Border>

                    <Border Background="#F8FAFC" CornerRadius="12" Padding="14" Margin="0,12,0,0">
                        <StackPanel>
                            <TextBlock Text="Bot Telegram" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" />
                            <CheckBox x:Name="TelegramEnabledCheckBox" Content="Abilita notifiche Telegram e monitor URL ngrok" Margin="0,0,0,8" />
                            <TextBlock Text="Token bot" FontWeight="SemiBold" />
                            <PasswordBox x:Name="TelegramTokenPasswordBox" Height="32" Margin="0,6,0,10" />
                            <TextBlock TextWrapping="Wrap" Foreground="#52667A">
                                Comandi disponibili nel bot: /start, /subscribe, /unsubscribe, /url, /status
                            </TextBlock>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>
        </Grid>

        <Border Grid.Row="4" Background="#E6EEF5" CornerRadius="10" Padding="12" Margin="0,14,0,0">
            <TextBlock x:Name="StatusText" Text="Pronto." Foreground="#102A43" TextWrapping="Wrap" />
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
Set-WindowIcon -Window $window

$videoFolderTextBox = $window.FindName("VideoFolderTextBox")
$vlcPathTextBox = $window.FindName("VlcPathTextBox")
$browseFolderButton = $window.FindName("BrowseFolderButton")
$browseVlcButton = $window.FindName("BrowseVlcButton")
$saveSettingsButton = $window.FindName("SaveSettingsButton")
$videoListBox = $window.FindName("VideoListBox")
$videoCountText = $window.FindName("VideoCountText")
$priorityFrequencyCombo = $window.FindName('PriorityFrequencyCombo')
$globalSlideDurationTextBox = $window.FindName('GlobalSlideDurationTextBox')
$contentEnabledCheckBox = $window.FindName('ContentEnabledCheckBox')
$contentPriorityCheckBox = $window.FindName('ContentPriorityCheckBox')
$contentDurationTextBox = $window.FindName('ContentDurationTextBox')
$slidePreview = $window.FindName('SlidePreview')
$script:UpdatingContentUi = $false
$script:ContentUiSignature = ''

function Show-ContentSelection {
    $item = $videoListBox.SelectedItem
    $slidePreview.Source = $null
    $contentEnabledCheckBox.IsEnabled = ($null -ne $item -and -not $item.pendingDelete)
    $contentPriorityCheckBox.IsEnabled = ($null -ne $item -and $item.kind -eq 'slide' -and -not $item.pendingDelete)
    $contentDurationTextBox.IsEnabled = $contentPriorityCheckBox.IsEnabled
    $roleCombo = $window.FindName('ContentRoleCombo')
    $roleCombo.IsEnabled = ($null -ne $item -and -not $item.pendingDelete)
    if (-not $item) { return }
    $contentEnabledCheckBox.IsChecked = $item.enabled
    $contentPriorityCheckBox.IsChecked = $item.priority
    $contentDurationTextBox.Text = [string]$item.durationSeconds
    $window.FindName('ContentRoleCombo').SelectedIndex = switch ($item.kind) { 'reel' { 1 }; 'background' { 2 }; default { 0 } }
    $roleCombo.Items[1].IsEnabled = ($item.kind -in @('video','reel'))
    $roleCombo.Items[2].IsEnabled = ($item.kind -in @('slide','background'))
    if (-not $item.pendingDelete) {
        try {
            $slidePreview.Source = Get-ContentPreviewBitmap $item
        } catch { Update-Status 'Anteprima non disponibile: contenuto non leggibile.' }
    }
}

function Sync-ContentUi {
    Update-PlaybackCatalog $videoFolderTextBox.Text
    if ($script:ContentUiSignature -ne $script:PlaybackSignature) {
        Refresh-VideoList
        $script:ContentUiSignature = $script:PlaybackSignature
    }
}

function Invoke-ContentUiAction([scriptblock]$Action) {
    try { & $Action; Sync-ContentUi; Write-StateFile }
    catch { Update-Status $_.Exception.Message }
}

$videoListBox.Add_SelectionChanged({ Show-ContentSelection })
$window.FindName('ApplySlideDurationButton').Add_Click({
    Invoke-ContentUiAction {
        $seconds = 0
        if (-not [int]::TryParse($globalSlideDurationTextBox.Text, [ref]$seconds)) { throw 'Durata immagini: numero intero da 1 a 300 secondi.' }
        Set-MediaSlideDuration $videoFolderTextBox.Text $seconds
        Update-Status 'Durata applicata a tutte le immagini. I video restano completi.'
    }
})
$window.FindName('SaveContentButton').Add_Click({
    Invoke-ContentUiAction {
        $item = $videoListBox.SelectedItem
        if (-not $item) { throw 'Seleziona un contenuto.' }
        $changes = [pscustomobject]@{ enabled = [bool]$contentEnabledCheckBox.IsChecked }
        $changes | Add-Member role (@('loop','reel','background')[$window.FindName('ContentRoleCombo').SelectedIndex])
        if ($item.kind -eq 'slide') {
            $duration = 0
            if (-not [int]::TryParse($contentDurationTextBox.Text, [ref]$duration)) { throw 'Durata slide non valida.' }
            $changes | Add-Member priority ([bool]$contentPriorityCheckBox.IsChecked)
            $changes | Add-Member durationSeconds $duration
        }
        Update-MediaItem $videoFolderTextBox.Text $item.name $changes
        Update-Status 'Contenuto salvato. Aggiornamento automatico al prossimo contenuto.'
    }
})
$priorityFrequencyCombo.Add_SelectionChanged({
    if (-not $script:UpdatingContentUi -and $priorityFrequencyCombo.SelectedIndex -ge 0) {
        Invoke-ContentUiAction { Set-MediaFrequency $videoFolderTextBox.Text ($priorityFrequencyCombo.SelectedIndex + 2) }
    }
})
$window.FindName('DeleteContentButton').Add_Click({
    Invoke-ContentUiAction {
        $item = $videoListBox.SelectedItem
        if (-not $item) { throw 'Seleziona un contenuto.' }
        if ([Windows.MessageBox]::Show("Eliminare $($item.name)?", $AppName, 'YesNo', 'Question') -eq 'Yes') {
            Request-MediaDelete $videoFolderTextBox.Text $item.name
            Update-Status 'Eliminazione richiesta. Il contenuto in corso puo terminare.'
        }
    }
})
function Move-SelectedContent([int]$Direction) {
    Invoke-ContentUiAction {
        $names = @((Get-MediaView $videoFolderTextBox.Text).items | ForEach-Object { $_.name })
        $selected = $videoListBox.SelectedItem
        if (-not $selected) { return }
        $index = [array]::IndexOf($names, $selected.name)
        $next = $index + $Direction
        if ($index -lt 0 -or $next -lt 0 -or $next -ge $names.Count) { return }
        $swap = $names[$index]; $names[$index] = $names[$next]; $names[$next] = $swap
        Set-MediaOrder $videoFolderTextBox.Text $names
    }
}
$window.FindName('MoveUpButton').Add_Click({ Move-SelectedContent -1 })
$window.FindName('MoveDownButton').Add_Click({ Move-SelectedContent 1 })
$window.FindName('UploadMediaButton').Add_Click({
    Invoke-ContentUiAction {
        $uploadAsPromo = ($window.FindName('UploadCategoryCombo').SelectedIndex -eq 1)
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Multiselect = $true
        $dialog.Filter = 'Slide e video|*.jpg;*.jpeg;*.png;*.mp4;*.mkv;*.avi;*.mov;*.wmv;*.m4v;*.webm'
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            foreach ($path in $dialog.FileNames) {
                $stream = [IO.File]::OpenRead($path)
                $priority = $uploadAsPromo -and ([IO.Path]::GetExtension($path) -match '^\.(jpg|jpeg|png)$')
                $role = switch ($window.FindName('UploadCategoryCombo').SelectedIndex) { 2 { 'reel' }; 3 { 'background' }; default { 'loop' } }
                try { Save-MediaStream $videoFolderTextBox.Text ([IO.Path]::GetFileName($path)) $stream $stream.Length $priority $role | Out-Null }
                finally { $stream.Dispose() }
            }
            Update-Status 'Caricamento completato.'
        }
    }
})
$refreshButton = $window.FindName("RefreshButton")
$playSelectedButton = $window.FindName("PlaySelectedButton")
$playAllButton = $window.FindName("PlayAllButton")
$stopButton = $window.FindName("StopButton")
$openFolderButton = $window.FindName("OpenFolderButton")
$launchOnLoginCheckBox = $window.FindName("LaunchOnLoginCheckBox")
$autoStartPlaybackCheckBox = $window.FindName("AutoStartPlaybackCheckBox")
$kioskModeCheckBox = $window.FindName("KioskModeCheckBox")
$webEnabledCheckBox = $window.FindName("WebEnabledCheckBox")
$webPortTextBox = $window.FindName("WebPortTextBox")
$tokenTextBox = $window.FindName("TokenTextBox")
$generateTokenButton = $window.FindName("GenerateTokenButton")
$openWebUiButton = $window.FindName("OpenWebUiButton")
$webUrlText = $window.FindName("WebUrlText")
$ngrokEnabledCheckBox = $window.FindName("NgrokEnabledCheckBox")
$ngrokAuthtokenPasswordBox = $window.FindName("NgrokAuthtokenPasswordBox")
$ngrokPathTextBox = $window.FindName("NgrokPathTextBox")
$installNgrokButton = $window.FindName("InstallNgrokButton")
$telegramEnabledCheckBox = $window.FindName("TelegramEnabledCheckBox")
$telegramTokenPasswordBox = $window.FindName("TelegramTokenPasswordBox")
$statusText = $window.FindName("StatusText")

try {
    $config = Load-Config
    Apply-ConfigToUi -Config $config
    Configure-LaunchOnLogin -Enabled $config.launchOnLogin
    Refresh-VideoList
    Write-StateFile
    Start-WebServerProcess
    Start-NgrokProcess
    Start-TelegramWorkerProcess

    $browseFolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Seleziona la cartella che contiene slide e video"
    $dialog.ShowNewFolderButton = $true

    if (-not [string]::IsNullOrWhiteSpace($videoFolderTextBox.Text) -and (Test-Path -LiteralPath $videoFolderTextBox.Text)) {
        $dialog.SelectedPath = $videoFolderTextBox.Text
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $videoFolderTextBox.Text = $dialog.SelectedPath
        Save-CurrentConfigFromUi
        Refresh-VideoList
        Write-StateFile
        Update-Status "Cartella video aggiornata."
    }
})

    $browseVlcButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "VLC executable|vlc.exe"
    $dialog.Title = "Seleziona vlc.exe"
    $dialog.CheckFileExists = $true
    $dialog.FileName = "vlc.exe"

    if (-not [string]::IsNullOrWhiteSpace($vlcPathTextBox.Text) -and (Test-Path -LiteralPath $vlcPathTextBox.Text)) {
        $dialog.InitialDirectory = Split-Path -Path $vlcPathTextBox.Text -Parent
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $vlcPathTextBox.Text = $dialog.FileName
        Save-CurrentConfigFromUi
        Write-StateFile
        Update-Status "Percorso VLC aggiornato."
    }
})

    $generateTokenButton.Add_Click({
    $tokenTextBox.Text = New-RandomToken
    Update-Status "Nuovo token generato. Salva per applicarlo anche al pannello web."
    })

    $saveSettingsButton.Add_Click({
    try {
        $webPort = [int]$webPortTextBox.Text
        if ($webPort -lt 1024 -or $webPort -gt 65535) {
            throw "La porta web deve essere compresa tra 1024 e 65535."
        }

        if ([string]::IsNullOrWhiteSpace($tokenTextBox.Text.Trim())) {
            throw "Il token remoto non puo essere vuoto."
        }
        if ([string]::IsNullOrWhiteSpace($telegramTokenPasswordBox.Password.Trim())) {
            throw "Il token del bot Telegram non puo essere vuoto."
        }
        if ($ngrokEnabledCheckBox.IsChecked -and [string]::IsNullOrWhiteSpace($ngrokAuthtokenPasswordBox.Password.Trim())) {
            throw "L'authtoken ngrok non puo essere vuoto."
        }

        $current = Get-CurrentConfigFromUi
        Save-Config -Config $current
        Configure-LaunchOnLogin -Enabled $current.launchOnLogin
        Refresh-VideoList
        Write-StateFile
        Restart-WebServerProcess
        Restart-NgrokProcess
        Restart-TelegramWorkerProcess
        Update-Status "Impostazioni salvate correttamente."
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            $AppName,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        Update-Status $_.Exception.Message
    }
    })

    $refreshButton.Add_Click({
    Refresh-VideoList
    Write-StateFile
    Update-Status "Elenco aggiornato."
    })

    $playSelectedButton.Add_Click({
    try {
        $selected = $videoListBox.SelectedItem
        if (-not $selected) {
            throw "Seleziona un contenuto dall'elenco."
        }

        Start-PlaySelected -FileName $selected.Name
        Write-StateFile
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            $AppName,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        Update-Status $_.Exception.Message
    }
    })

    $playAllButton.Add_Click({
    try {
        Start-PlayAll
        Write-StateFile
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            $AppName,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        Update-Status $_.Exception.Message
    }
    })

    $stopButton.Add_Click({
    Stop-Playback
    Write-StateFile
    Update-Status "Playback fermato."
    })

    $openFolderButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($videoFolderTextBox.Text) -or -not (Test-Path -LiteralPath $videoFolderTextBox.Text)) {
        Update-Status "Seleziona prima una cartella valida."
        return
    }

    Start-Process explorer.exe -ArgumentList $videoFolderTextBox.Text
    })

    $openWebUiButton.Add_Click({
    $url = "http://127.0.0.1:$($webPortTextBox.Text)/"
    Start-Process $url
    })

    $installNgrokButton.Add_Click({
    try {
        Install-NgrokBinary
        Write-StateFile
        Restart-NgrokProcess
        Update-Status "ngrok installato o aggiornato correttamente."
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            $AppName,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        Update-Status $_.Exception.Message
    }
    })

    $syncTimer = New-Object System.Windows.Threading.DispatcherTimer
    $syncTimer.Interval = [TimeSpan]::FromSeconds(1)
    $syncTimer.Add_Tick({
    try {
        if (Test-Path -LiteralPath $ConfigPath) {
            $stamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc.Ticks.ToString()
            if ($stamp -ne $script:ConfigWriteStamp) {
                $updated = Load-Config
                Apply-ConfigToUi -Config $updated
                $script:ConfigWriteStamp = $stamp
                Configure-LaunchOnLogin -Enabled $updated.launchOnLogin
                Restart-WebServerProcess
                Restart-NgrokProcess
                Restart-TelegramWorkerProcess
                Refresh-VideoList
                Update-Status "Configurazione sincronizzata."
            }
        }

        Process-CommandQueue
        Sync-ContentUi
        if ([IO.Directory]::Exists($videoFolderTextBox.Text)) {
            $currentName = if ($script:PlaybackCurrent -and $script:PlaybackCurrent.folder -eq $videoFolderTextBox.Text) { $script:PlaybackCurrent.names } else { @() }
            Complete-MediaDeletes $videoFolderTextBox.Text $currentName
        }
        Write-StateFile
        Start-WebServerProcess
        Start-NgrokProcess
        Start-TelegramWorkerProcess
    }
    catch {
        Write-AppLog ('Errore sincronizzazione: ' + $_.Exception.Message)
        Update-Status $_.Exception.Message
    }
    })
    $syncTimer.Start()

    $playbackTimer = New-Object Windows.Threading.DispatcherTimer
    $playbackTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $playbackTimer.Add_Tick({ Update-ControlledPlayback })
    $playbackTimer.Start()

    $window.Add_ContentRendered({
    Refresh-VideoList
    Write-StateFile

    if ($autoStartPlaybackCheckBox.IsChecked -or $kioskModeCheckBox.IsChecked) {
        try {
            Start-PlayAll
            Write-StateFile
        }
        catch {
            Update-Status $_.Exception.Message
        }
    }

    if ($kioskModeCheckBox.IsChecked) {
        $window.WindowState = [System.Windows.WindowState]::Minimized
    }
    })

    $window.Add_Closing({
    $script:ApplicationClosing = $true
    $syncTimer.Stop()
    $playbackTimer.Stop()
    Stop-Playback
    if ($script:WebServerOwnedPid) {
        Stop-WebServerProcess
    }
    if ($script:NgrokOwnedPid) {
        Stop-NgrokProcess
    }
    if ($script:TelegramWorkerOwnedPid) {
        Stop-TelegramWorkerProcess
    }
    })

    [void]$window.ShowDialog()
}
catch {
    Write-AppLog ("Errore avvio: " + $_.Exception.Message)
    throw
}
