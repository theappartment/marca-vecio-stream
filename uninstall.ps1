param(
    [switch]$CleanupOnly,
    [switch]$RemoveUserData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$appName = "Marca Vecio Stream"
$configRoot = Join-Path $env:APPDATA "MarcaVecioStream"
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "$appName.lnk"
$startMenuShortcutPath = Join-Path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs") "$appName.lnk"
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "$appName.lnk"
$currentScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$installRoot = if ($currentScriptPath) { Split-Path -Parent $currentScriptPath } else { Join-Path $env:ProgramFiles "MarcaVecioStream" }

function Remove-IfExists([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -Recurse
    }
}

function Read-PidFile([string]$Path) {
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

function Stop-ProcessIfRunning([int]$ProcessId) {
    if (-not $ProcessId) {
        return
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        $process.WaitForExit(5000) | Out-Null
    }
    catch {
    }
}

function Stop-AppProcessesByPid {
    foreach ($pidFileName in @("telegram.pid", "webserver.pid", "ngrok.pid")) {
        $pidFilePath = Join-Path $configRoot $pidFileName
        $processId = Read-PidFile -Path $pidFilePath
        Stop-ProcessIfRunning -ProcessId $processId
        if (Test-Path -LiteralPath $pidFilePath) {
            Remove-Item -LiteralPath $pidFilePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-AppProcessesByPath {
    $expectedPaths = @(
        (Join-Path $installRoot "MarcaVecioStream.exe"),
        (Join-Path $installRoot "WebServer.exe"),
        (Join-Path $installRoot "TelegramWorker.exe"),
        (Join-Path $installRoot "UpdateWorker.exe"),
        (Join-Path $installRoot "tools\ngrok\ngrok.exe")
    )

    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            if ($process.Path -and ($expectedPaths -contains $process.Path)) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            }
        }
        catch {
        }
    }
}

function Stop-AppProcessesByExecutablePath {
    $expectedPaths = @(
        (Join-Path $installRoot "MarcaVecioStream.exe"),
        (Join-Path $installRoot "WebServer.exe"),
        (Join-Path $installRoot "TelegramWorker.exe"),
        (Join-Path $installRoot "UpdateWorker.exe"),
        (Join-Path $installRoot "tools\ngrok\ngrok.exe")
    )

    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop
        foreach ($process in $processes) {
            if ($process.ExecutablePath -and ($expectedPaths -contains $process.ExecutablePath)) {
                Stop-ProcessIfRunning -ProcessId ([int]$process.ProcessId)
            }
        }
    }
    catch {
    }
}

function Stop-AppProcessesByNameFallback {
    foreach ($name in @("TelegramWorker", "WebServer", "MarcaVecioStream")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.Path -and $_.Path.StartsWith($installRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id $_.Id -Force -ErrorAction Stop
                }
            }
            catch {
            }
        }
    }
}

function Remove-Shortcuts {
    foreach ($path in @($desktopShortcutPath, $startMenuShortcutPath, $startupShortcutPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

Stop-AppProcessesByPid
Stop-AppProcessesByPath
Stop-AppProcessesByExecutablePath
Stop-AppProcessesByNameFallback
Start-Sleep -Milliseconds 500
Stop-AppProcessesByPid
Stop-AppProcessesByPath
Stop-AppProcessesByExecutablePath
Stop-AppProcessesByNameFallback
Remove-Shortcuts

if ($CleanupOnly) {
    Write-Host "Cleanup processi completato."
    return
}

if ($RemoveUserData -and (Test-Path -LiteralPath $configRoot)) {
    Remove-Item -LiteralPath $configRoot -Force -Recurse -ErrorAction SilentlyContinue
}

if ($currentScriptPath -and ($currentScriptPath.StartsWith($installRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
    Write-Host "Cleanup completato. Per rimuovere i file dell'app usa il disinstallatore di Windows."
    return
}

if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$appName rimossa."
