Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ConfigRoot = Join-Path $env:APPDATA "MarcaVecioStream"
$ConfigPath = Join-Path $ConfigRoot "config.json"
$StatePath = Join-Path $ConfigRoot "state.json"
$PidPath = Join-Path $ConfigRoot "telegram.pid"
$LogPath = Join-Path $ConfigRoot "telegram.log"

if (-not (Test-Path -LiteralPath $ConfigRoot)) {
    New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
}

Set-Content -LiteralPath $PidPath -Value $PID -Encoding UTF8

function Write-TelegramLog([string]$Message) {
    try {
        $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch {
    }
}

Write-TelegramLog "Avvio worker Telegram."

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
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [ordered]@{
        videoFolder             = [string](Get-PropertyValueOrDefault $raw "videoFolder" "")
        vlcPath                 = [string](Get-PropertyValueOrDefault $raw "vlcPath" "")
        webEnabled              = [bool](Get-PropertyValueOrDefault $raw "webEnabled" $true)
        webPort                 = [int](Get-PropertyValueOrDefault $raw "webPort" 8090)
        remoteToken             = [string](Get-PropertyValueOrDefault $raw "remoteToken" "")
        autoStartPlayback       = [bool](Get-PropertyValueOrDefault $raw "autoStartPlayback" $false)
        launchOnLogin           = [bool](Get-PropertyValueOrDefault $raw "launchOnLogin" $false)
        kioskMode               = [bool](Get-PropertyValueOrDefault $raw "kioskMode" $false)
        telegramEnabled         = [bool](Get-PropertyValueOrDefault $raw "telegramEnabled" $true)
        telegramBotToken        = [string](Get-PropertyValueOrDefault $raw "telegramBotToken" "")
        telegramLastUpdateId    = [int](Get-PropertyValueOrDefault $raw "telegramLastUpdateId" 0)
        telegramSubscribedChats = @(Get-PropertyValueOrDefault $raw "telegramSubscribedChats" @())
        ngrokEnabled            = [bool](Get-PropertyValueOrDefault $raw "ngrokEnabled" $true)
        ngrokAuthtoken          = [string](Get-PropertyValueOrDefault $raw "ngrokAuthtoken" "")
        ngrokPath               = [string](Get-PropertyValueOrDefault $raw "ngrokPath" "")
        ngrokDownloadUrl        = [string](Get-PropertyValueOrDefault $raw "ngrokDownloadUrl" "")
    }
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

function Save-Config($Config) {
    $json = $Config | ConvertTo-Json -Depth 6
    Write-JsonAtomically -Path $ConfigPath -Json $json
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }
    return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-TelegramApi([string]$BotToken, [string]$Method, $Body) {
    $uri = "https://api.telegram.org/bot$BotToken/$Method"
    return Invoke-RestMethod -Method Post -Uri $uri -Body $Body -ContentType "application/x-www-form-urlencoded"
}

function Send-TelegramMessage([string]$BotToken, [string]$ChatId, [string]$Text) {
    Invoke-TelegramApi -BotToken $BotToken -Method "sendMessage" -Body @{
        chat_id = $ChatId
        text    = $Text
    } | Out-Null
}

function Get-NgrokPublicUrl([int]$Port) {
    try {
        $response = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:4040/api/tunnels"
        $tunnels = @($response.tunnels)
        foreach ($tunnel in $tunnels) {
            if ($tunnel.public_url -and $tunnel.public_url.StartsWith("https://")) {
                $forwardsTo = [string]$tunnel.config.addr
                if ([string]::IsNullOrWhiteSpace($forwardsTo)) {
                    $forwardsTo = [string]$tunnel.forwards_to
                }
                if ($forwardsTo -match "(:|//)$Port$") {
                    return [string]$tunnel.public_url
                }
            }
        }

        foreach ($tunnel in $tunnels) {
            if ($tunnel.public_url -and $tunnel.public_url.StartsWith("https://")) {
                return [string]$tunnel.public_url
            }
        }
    }
    catch {
    }

    return ""
}

function Build-RemoteUrl($Config, [string]$PublicUrl) {
    if ([string]::IsNullOrWhiteSpace($PublicUrl)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($Config.remoteToken)) {
        return $PublicUrl
    }

    return "$PublicUrl/?token=$([uri]::EscapeDataString($Config.remoteToken))"
}

function Get-StatusText($Config, [string]$PublicUrl) {
    $state = Read-State
    $playback = "fermo"
    if ($state -and $state.playback -and $state.playback.isRunning) {
        $playback = "attivo"
    }

    $fileCount = 0
    if ($state -and $state.files) {
        $fileCount = @($state.files).Count
    }

    $remoteUrl = Build-RemoteUrl -Config $Config -PublicUrl $PublicUrl
    if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
        $remoteUrl = "ngrok non disponibile"
    }

    return "Marca Vecio Stream`nPlayback: $playback`nVideo: $fileCount`nInterfaccia: $remoteUrl"
}

function Get-ChatId($Update) {
    if ($Update.PSObject.Properties["message"] -and $Update.message -and $Update.message.PSObject.Properties["chat"] -and $Update.message.chat) {
        return [string]$Update.message.chat.id
    }
    return ""
}

function Get-MessageText($Update) {
    if ($Update.PSObject.Properties["message"] -and $Update.message -and $Update.message.PSObject.Properties["text"] -and $Update.message.text) {
        return [string]$Update.message.text
    }
    return ""
}

function Add-SubscribedChat($Config, [string]$ChatId) {
    $current = @($Config.telegramSubscribedChats | Where-Object { $_ })
    if ($current -notcontains $ChatId) {
        $current += $ChatId
    }
    $Config.telegramSubscribedChats = $current
}

function Remove-SubscribedChat($Config, [string]$ChatId) {
    $Config.telegramSubscribedChats = @($Config.telegramSubscribedChats | Where-Object { $_ -ne $ChatId })
}

function Process-Updates($Config, [string]$PublicUrl) {
    if ([string]::IsNullOrWhiteSpace($Config.telegramBotToken)) {
        return [ordered]@{
            hasChanges        = $false
            lastUpdateChanged = $false
        }
    }

    $hasChanges = $false
    $lastUpdateChanged = $false
    $response = Invoke-TelegramApi -BotToken $Config.telegramBotToken -Method "getUpdates" -Body @{
        offset          = $Config.telegramLastUpdateId + 1
        timeout         = 20
        allowed_updates = '["message"]'
    }

    foreach ($update in @($response.result)) {
        $Config.telegramLastUpdateId = [int]$update.update_id
        $lastUpdateChanged = $true
        $chatId = Get-ChatId -Update $update
        $text = (Get-MessageText -Update $update).Trim()
        if ([string]::IsNullOrWhiteSpace($chatId)) {
            continue
        }

        switch -Regex ($text) {
            '^/start' {
                Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId $chatId -Text "Bot pronto. Usa /subscribe per ricevere la URL aggiornata, /url per il link attuale, /status per lo stato player."
            }
            '^/subscribe' {
                Add-SubscribedChat -Config $Config -ChatId $chatId
                $hasChanges = $true
                $message = "Iscrizione attiva."
                $remoteUrl = Build-RemoteUrl -Config $Config -PublicUrl $PublicUrl
                if (-not [string]::IsNullOrWhiteSpace($remoteUrl)) {
                    $message += "`nInterfaccia: $remoteUrl"
                }
                Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId $chatId -Text $message
            }
            '^/unsubscribe' {
                Remove-SubscribedChat -Config $Config -ChatId $chatId
                $hasChanges = $true
                Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId $chatId -Text "Iscrizione rimossa."
            }
            '^/url' {
                $remoteUrl = Build-RemoteUrl -Config $Config -PublicUrl $PublicUrl
                if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
                    $remoteUrl = "ngrok non disponibile al momento."
                }
                Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId $chatId -Text "Interfaccia remota: $remoteUrl"
            }
            '^/status' {
                Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId $chatId -Text (Get-StatusText -Config $Config -PublicUrl $PublicUrl)
            }
            default {
                Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId $chatId -Text "Comandi: /subscribe /unsubscribe /url /status"
            }
        }
    }

    return [ordered]@{
        hasChanges        = $hasChanges
        lastUpdateChanged = $lastUpdateChanged
    }
}

function Broadcast-NewUrl($Config, [string]$PublicUrl) {
    $remoteUrl = Build-RemoteUrl -Config $Config -PublicUrl $PublicUrl
    if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
        return
    }

    foreach ($chatId in @($Config.telegramSubscribedChats | Where-Object { $_ })) {
        try {
            Send-TelegramMessage -BotToken $Config.telegramBotToken -ChatId ([string]$chatId) -Text "Nuova URL interfaccia: $remoteUrl"
        }
        catch {
        }
    }
}

$lastPublicUrl = ""

try {
    while ($true) {
        $config = Load-Config
        if (-not $config.telegramEnabled -or [string]::IsNullOrWhiteSpace($config.telegramBotToken)) {
            Write-TelegramLog "Telegram disabilitato o token mancante."
            Start-Sleep -Seconds 10
            continue
        }

        $publicUrl = Get-NgrokPublicUrl -Port $config.webPort
        if ($publicUrl -ne $lastPublicUrl -and -not [string]::IsNullOrWhiteSpace($publicUrl)) {
            Broadcast-NewUrl -Config $config -PublicUrl $publicUrl
            $lastPublicUrl = $publicUrl
        }

        $result = $null
        try {
            $result = Process-Updates -Config $config -PublicUrl $publicUrl
        }
        catch {
            Write-TelegramLog ("Errore Process-Updates: " + $_.Exception.Message)
            Start-Sleep -Seconds 5
        }

        if ($result -and ($result.hasChanges -or $result.lastUpdateChanged)) {
            Save-Config -Config $config
        }

        Start-Sleep -Milliseconds 500
    }
}
finally {
    Write-TelegramLog "Chiusura worker Telegram."
    if (Test-Path -LiteralPath $PidPath) {
        Remove-Item -LiteralPath $PidPath -Force
    }
}
