Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AppRootPath {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.PSObject.Properties["Path"] -and $MyInvocation.MyCommand.Path) {
        return (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }

    return (Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
}

$AppName = "Marca Vecio Stream"
$AppRoot = Get-AppRootPath
$ConfigRoot = Join-Path $env:APPDATA "MarcaVecioStream"
$ConfigPath = Join-Path $ConfigRoot "config.json"
$StatePath = Join-Path $ConfigRoot "state.json"
$CommandRoot = Join-Path $ConfigRoot "commands"
$WebRoot = Join-Path $AppRoot "web"
$IndexPath = Join-Path $WebRoot "index.html"
$LogoJpgPath = Join-Path $AppRoot "logoapp.png.jpg"
$LogoIcoPath = Join-Path $AppRoot "logoapp.ico"
$PidPath = Join-Path $ConfigRoot "webserver.pid"
$SupportedExtensions = @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".m4v", ".webm")

foreach ($path in @($ConfigRoot, $CommandRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

Set-Content -LiteralPath $PidPath -Value $PID -Encoding UTF8

function Write-JsonAtomically([string]$Path, [string]$Json) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    Set-Content -LiteralPath $tempPath -Value $Json -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configurazione non trovata."
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [ordered]@{
        videoFolder       = [string](Get-PropertyValueOrDefault $raw "videoFolder" "")
        vlcPath           = [string](Get-PropertyValueOrDefault $raw "vlcPath" "")
        webEnabled        = [bool](Get-PropertyValueOrDefault $raw "webEnabled" $true)
        webPort           = [int](Get-PropertyValueOrDefault $raw "webPort" 8090)
        remoteToken       = [string](Get-PropertyValueOrDefault $raw "remoteToken" "")
        autoStartPlayback = [bool](Get-PropertyValueOrDefault $raw "autoStartPlayback" $false)
        launchOnLogin     = [bool](Get-PropertyValueOrDefault $raw "launchOnLogin" $false)
        kioskMode         = [bool](Get-PropertyValueOrDefault $raw "kioskMode" $false)
        telegramEnabled   = [bool](Get-PropertyValueOrDefault $raw "telegramEnabled" $true)
        telegramBotToken  = [string](Get-PropertyValueOrDefault $raw "telegramBotToken" "")
        telegramLastUpdateId = [int](Get-PropertyValueOrDefault $raw "telegramLastUpdateId" 0)
        telegramSubscribedChats = @(Get-PropertyValueOrDefault $raw "telegramSubscribedChats" @())
        ngrokEnabled      = [bool](Get-PropertyValueOrDefault $raw "ngrokEnabled" $true)
        ngrokAuthtoken    = [string](Get-PropertyValueOrDefault $raw "ngrokAuthtoken" "")
        ngrokPath         = [string](Get-PropertyValueOrDefault $raw "ngrokPath" "")
        ngrokDownloadUrl  = [string](Get-PropertyValueOrDefault $raw "ngrokDownloadUrl" "")
    }
}

function Save-Config($Config) {
    $json = $Config | ConvertTo-Json -Depth 6
    Write-JsonAtomically -Path $ConfigPath -Json $json
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [ordered]@{
            appName  = $AppName
            playback = [ordered]@{ isRunning = $false; processId = $null }
            config   = [ordered]@{}
            files    = @()
        }
    }

    return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Command($Action, $Data) {
    $payload = [ordered]@{
        action    = $Action
        data      = $Data
        createdAt = (Get-Date).ToString("o")
    }
    $path = Join-Path $CommandRoot ("cmd-{0}.json" -f ([guid]::NewGuid().ToString("N")))
    $json = $payload | ConvertTo-Json -Depth 5
    Write-JsonAtomically -Path $path -Json $json
}

function Get-RequestBodyText([System.Net.HttpListenerRequest]$Request) {
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Send-Json($Response, $Object, [int]$StatusCode = 200) {
    $json = $Object | ConvertTo-Json -Depth 8
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.Close()
}

function Send-File($Response, [string]$Path, [string]$ContentType) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Response.StatusCode = 200
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

function Send-Logo($Response) {
    if (Test-Path -LiteralPath $LogoJpgPath) {
        Send-File -Response $Response -Path $LogoJpgPath -ContentType "image/jpeg"
        return
    }

    if (Test-Path -LiteralPath $LogoIcoPath) {
        Send-File -Response $Response -Path $LogoIcoPath -ContentType "image/x-icon"
        return
    }

    Send-Json -Response $Response -Object @{ error = "Logo not found" } -StatusCode 404
}

function Test-Authorized([System.Net.HttpListenerRequest]$Request, $Config) {
    if ([string]::IsNullOrWhiteSpace($Config.remoteToken)) {
        return $true
    }

    $token = $Request.Headers["X-Auth-Token"]
    if ([string]::IsNullOrWhiteSpace($token) -and $Request.QueryString["token"]) {
        $token = $Request.QueryString["token"]
    }

    return $token -eq $Config.remoteToken
}

function Get-SafeFileName([string]$FileName) {
    if ([string]::IsNullOrWhiteSpace($FileName)) {
        throw "Nome file mancante."
    }

    $nameOnly = [System.IO.Path]::GetFileName($FileName)
    if ($nameOnly -ne $FileName) {
        throw "Nome file non valido."
    }

    $extension = [System.IO.Path]::GetExtension($nameOnly).ToLowerInvariant()
    if ($SupportedExtensions -notcontains $extension) {
        throw "Estensione non supportata."
    }

    return $nameOnly
}

function Save-UploadedFile([System.Net.HttpListenerRequest]$Request, $Config) {
    if ([string]::IsNullOrWhiteSpace($Config.videoFolder) -or -not (Test-Path -LiteralPath $Config.videoFolder)) {
        throw "La cartella video configurata non e valida."
    }

    $fileName = Get-SafeFileName -FileName $Request.QueryString["filename"]
    $destination = Join-Path $Config.videoFolder $fileName
    $target = [System.IO.File]::Open($destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $Request.InputStream.CopyTo($target)
    }
    finally {
        $target.Dispose()
        $Request.InputStream.Dispose()
    }

    return $destination
}

function Remove-ManagedFile([string]$FileName, $Config) {
    if ([string]::IsNullOrWhiteSpace($Config.videoFolder) -or -not (Test-Path -LiteralPath $Config.videoFolder)) {
        throw "La cartella video configurata non e valida."
    }

    $safeName = Get-SafeFileName -FileName $FileName
    $path = Join-Path $Config.videoFolder $safeName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "File non trovato."
    }

    Remove-Item -LiteralPath $path -Force
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

function Merge-Settings($Current, $Incoming) {
    $next = [ordered]@{
        videoFolder       = [string](Get-ValueOrDefault $Incoming.videoFolder $Current.videoFolder)
        vlcPath           = [string](Get-ValueOrDefault $Incoming.vlcPath $Current.vlcPath)
        webEnabled        = [bool](Get-ValueOrDefault $Incoming.webEnabled $Current.webEnabled)
        webPort           = [int](Get-ValueOrDefault $Incoming.webPort $Current.webPort)
        remoteToken       = [string](Get-ValueOrDefault $Incoming.remoteToken $Current.remoteToken)
        autoStartPlayback = [bool](Get-ValueOrDefault $Incoming.autoStartPlayback $Current.autoStartPlayback)
        launchOnLogin     = [bool](Get-ValueOrDefault $Incoming.launchOnLogin $Current.launchOnLogin)
        kioskMode         = [bool](Get-ValueOrDefault $Incoming.kioskMode $Current.kioskMode)
        telegramEnabled   = [bool]$Current.telegramEnabled
        telegramBotToken  = [string]$Current.telegramBotToken
        telegramLastUpdateId = [int]$Current.telegramLastUpdateId
        telegramSubscribedChats = @($Current.telegramSubscribedChats)
        ngrokEnabled      = [bool]$Current.ngrokEnabled
        ngrokAuthtoken    = [string]$Current.ngrokAuthtoken
        ngrokPath         = [string]$Current.ngrokPath
        ngrokDownloadUrl  = [string]$Current.ngrokDownloadUrl
    }

    if ($next.webPort -lt 1024 -or $next.webPort -gt 65535) {
        throw "Porta web non valida."
    }
    if ([string]::IsNullOrWhiteSpace($next.remoteToken)) {
        throw "Il token remoto non puo essere vuoto."
    }

    return $next
}

$listener = [System.Net.HttpListener]::new()
$config = Load-Config
if (-not $config.webEnabled) {
    if (Test-Path -LiteralPath $PidPath) {
        Remove-Item -LiteralPath $PidPath -Force
    }
    exit 0
}

$listener.Prefixes.Add("http://127.0.0.1:$($config.webPort)/")
$listener.Start()

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            $config = Load-Config
            $path = $request.Url.AbsolutePath

            if ($path -eq "/" -or $path -eq "/index.html") {
                Send-File -Response $response -Path $IndexPath -ContentType "text/html; charset=utf-8"
                continue
            }

            if ($path -eq "/assets/logo") {
                Send-Logo -Response $response
                continue
            }

            if ($path -eq "/api/status" -and $request.HttpMethod -eq "GET") {
                if (-not (Test-Authorized -Request $request -Config $config)) {
                    Send-Json -Response $response -Object @{ error = "Unauthorized" } -StatusCode 401
                    continue
                }

                Send-Json -Response $response -Object (Read-State)
                continue
            }

            if (-not (Test-Authorized -Request $request -Config $config)) {
                Send-Json -Response $response -Object @{ error = "Unauthorized" } -StatusCode 401
                continue
            }

            if ($path -eq "/api/upload" -and $request.HttpMethod -eq "POST") {
                $savedPath = Save-UploadedFile -Request $request -Config $config
                Send-Json -Response $response -Object @{ ok = $true; path = $savedPath }
                continue
            }

            if ($path -eq "/api/files" -and $request.HttpMethod -eq "DELETE") {
                Remove-ManagedFile -FileName $request.QueryString["name"] -Config $config
                Send-Json -Response $response -Object @{ ok = $true }
                continue
            }

            if ($path -eq "/api/play-selected" -and $request.HttpMethod -eq "POST") {
                $body = Get-RequestBodyText -Request $request | ConvertFrom-Json
                Write-Command -Action "playSelected" -Data @{ fileName = [string]$body.fileName }
                Send-Json -Response $response -Object @{ ok = $true }
                continue
            }

            if ($path -eq "/api/play-all" -and $request.HttpMethod -eq "POST") {
                Write-Command -Action "playAll" -Data @{}
                Send-Json -Response $response -Object @{ ok = $true }
                continue
            }

            if ($path -eq "/api/stop" -and $request.HttpMethod -eq "POST") {
                Write-Command -Action "stop" -Data @{}
                Send-Json -Response $response -Object @{ ok = $true }
                continue
            }

            if ($path -eq "/api/settings" -and $request.HttpMethod -eq "POST") {
                $body = Get-RequestBodyText -Request $request | ConvertFrom-Json
                $nextConfig = Merge-Settings -Current $config -Incoming $body
                Save-Config -Config $nextConfig
                Write-Command -Action "reloadConfig" -Data @{}
                Send-Json -Response $response -Object @{ ok = $true; message = "Impostazioni salvate." }
                continue
            }

            Send-Json -Response $response -Object @{ error = "Not found" } -StatusCode 404
        }
        catch {
            Send-Json -Response $response -Object @{ error = $_.Exception.Message } -StatusCode 500
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    if (Test-Path -LiteralPath $PidPath) {
        Remove-Item -LiteralPath $PidPath -Force
    }
}
