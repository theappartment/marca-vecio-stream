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
$DefaultTelegramBotToken = "8759940162:AAG3xV-dCYhXqGt-Rc-mYvhE8JCdxcaCF94"
$DefaultNgrokAuthtoken = "3BtfwEuyn8RUwoYQsN3GmrKgd4w_23EAfyFnAuAgw391HMXgk"
$DefaultNgrokDownloadUrl = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
$DefaultNgrokInstallRoot = Join-Path $AppRoot "tools\ngrok"
$FallbackNgrokInstallRoot = Join-Path $env:LOCALAPPDATA "MarcaVecioStream\tools\ngrok"
$AppIconPath = Join-Path (Split-Path -Parent $AppRoot) "logoapp.ico"
$AppImagePath = Join-Path (Split-Path -Parent $AppRoot) "logoapp.png.jpg"
$script:CurrentVlcProcess = $null
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
    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -LiteralPath $FolderPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $FolderPath -File |
        Where-Object { $SupportedExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object Name)
}

function Build-PlaylistFromEntries([string[]]$Entries) {
    $lines = @("#EXTM3U")
    foreach ($entry in $Entries) {
        $lines += $entry
    }
    Set-Content -LiteralPath $PlaylistPath -Value $lines -Encoding UTF8
    return $PlaylistPath
}

function Stop-Playback {
    if ($script:CurrentVlcProcess -and -not $script:CurrentVlcProcess.HasExited) {
        try {
            $script:CurrentVlcProcess.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 400
            if (-not $script:CurrentVlcProcess.HasExited) {
                Stop-Process -Id $script:CurrentVlcProcess.Id -Force
            }
        }
        catch {
        }
    }

    $script:CurrentVlcProcess = $null
}

function Start-VlcPlayback([string]$VlcPath, [string]$TargetPath) {
    Stop-Playback

    $arguments = @(
        "--fullscreen"
        "--video-on-top"
        "--loop"
        "--no-video-title-show"
        "--qt-start-minimized"
        $TargetPath
    )

    if (-not $TargetPath.ToLowerInvariant().EndsWith(".m3u")) {
        $arguments += "--play-and-exit"
    }
    else {
        $arguments += "--playlist-autostart"
    }

    $script:CurrentVlcProcess = Start-Process -FilePath $VlcPath -ArgumentList $arguments -PassThru
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
        throw "Seleziona una cartella video valida."
    }

    $setup.videoFolder = $videoFolder
    return $setup
}

function Start-PlaySelected([string]$FileName) {
    $setup = Ensure-ValidLocalVideoSetup
    $target = Get-VideoFiles -FolderPath $setup.videoFolder | Where-Object { $_.Name -eq $FileName } | Select-Object -First 1
    if (-not $target) {
        throw "Video non trovato: $FileName"
    }

    Start-VlcPlayback -VlcPath $setup.vlcPath -TargetPath $target.FullName
    Update-Status "Riproduzione avviata: $($target.Name)"
}

function Start-PlayAll {
    $setup = Ensure-ValidLocalVideoSetup
    $items = @(Get-VideoFiles -FolderPath $setup.videoFolder)
    if ($items.Count -eq 0) {
        throw "Nella cartella non ci sono video compatibili."
    }

    $playlist = Build-PlaylistFromEntries -Entries @($items | ForEach-Object { $_.FullName })
    Start-VlcPlayback -VlcPath $setup.vlcPath -TargetPath $playlist
    Update-Status "Playback cartella avviato in loop."
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
        $shortcut.TargetPath = $launcherPath
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
            if (-not $existing.HasExited) {
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
            if (-not $existing.HasExited) {
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
            if (-not $existing.HasExited) {
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

function Refresh-VideoList {
    $items = @(Get-VideoFiles -FolderPath $videoFolderTextBox.Text)
    $videoListBox.ItemsSource = $null
    $videoListBox.ItemsSource = $items
    $videoCountText.Text = "Video trovati: $($items.Count)"
}

function Get-PlaybackState {
    $isRunning = $false
    $processId = $null

    if ($script:CurrentVlcProcess) {
        try {
            $isRunning = -not $script:CurrentVlcProcess.HasExited
            if ($isRunning) {
                $processId = $script:CurrentVlcProcess.Id
            }
        }
        catch {
        }
    }

    return [ordered]@{
        isRunning = $isRunning
        processId = $processId
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
    $items = Get-VideoFiles -FolderPath $config.videoFolder
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
        files = @($items | ForEach-Object {
            [ordered]@{
                name       = $_.Name
                size       = $_.Length
                modifiedAt = $_.LastWriteTime.ToString("s")
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
            Update-Status "Errore durante la lettura di un comando remoto."
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
                <TextBlock Text="Playback VLC fullscreen/loop con controllo locale e pannello web remoto." Foreground="#D9E2EC" FontSize="14" Margin="0,6,0,0" />
            </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="Cartella video" FontWeight="SemiBold" />
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

            <GroupBox Header="Video disponibili" Margin="0,0,14,0">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <ListBox x:Name="VideoListBox" DisplayMemberPath="Name" BorderThickness="1" />
                    <TextBlock Grid.Row="1" x:Name="VideoCountText" Margin="0,10,0,0" Foreground="#486581" />
                </Grid>
            </GroupBox>

            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <Border Background="#F0F4F8" CornerRadius="12" Padding="14" Margin="0,0,0,12">
                        <StackPanel>
                            <TextBlock Text="Comandi playback" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" />
                            <Button x:Name="RefreshButton" Content="Aggiorna elenco" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="PlaySelectedButton" Content="Riproduci selezionato" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="PlayAllButton" Content="Riproduci tutta la cartella" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="StopButton" Content="Ferma playback" Height="38" Margin="0,0,0,10" />
                            <Button x:Name="OpenFolderButton" Content="Apri cartella video" Height="38" />
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
            <TextBlock x:Name="StatusText" Text="Pronto." Foreground="#102A43" />
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
    $dialog.Description = "Seleziona la cartella che contiene i video"
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
            throw "Seleziona un video dall'elenco."
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
        Write-StateFile
        Start-WebServerProcess
        Start-NgrokProcess
        Start-TelegramWorkerProcess
    }
    catch {
    }
    })
    $syncTimer.Start()

    $window.Add_ContentRendered({
    Refresh-VideoList
    Write-StateFile

    if ($autoStartPlaybackCheckBox.IsChecked) {
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
    $syncTimer.Stop()
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
