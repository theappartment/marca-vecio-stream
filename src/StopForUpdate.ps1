param([Parameter(Mandatory=$true)][string]$InstallRoot, [switch]$FunctionsOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-UpdateProcessPath([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    foreach ($relative in @('MarcaVecioStream.exe','WebServer.exe','TelegramWorker.exe','UpdateWorker.exe','tools\ngrok\ngrok.exe')) {
        if ($fullPath.Equals((Join-Path $rootPath $relative),[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-UpdateProcesses([string]$Root) {
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='MarcaVecioStream.exe' OR Name='WebServer.exe' OR Name='TelegramWorker.exe' OR Name='UpdateWorker.exe' OR Name='ngrok.exe'" -ErrorAction Stop)
    return @($candidates | Where-Object { Test-UpdateProcessPath $_.ExecutablePath $Root } | Sort-Object @{Expression={ if ($_.Name -eq 'MarcaVecioStream.exe') { 0 } else { 1 } }})
}

function Stop-ProcessesForUpdate([string]$Root) {
    # Close the main app first so it cannot recreate helpers while updating.
    foreach ($candidate in @(Get-UpdateProcesses $Root)) {
        $live = Get-Process -Id ([int]$candidate.ProcessId) -ErrorAction SilentlyContinue
        if (-not $live) { continue }
        if (-not (Test-UpdateProcessPath $live.Path $Root)) { continue }
        Stop-Process -Id $live.Id -Force -ErrorAction Stop
        $live.WaitForExit(5000) | Out-Null
    }
    if (@(Get-UpdateProcesses $Root).Count -gt 0) { throw 'Alcuni processi di Marca Vecio Stream sono ancora attivi.' }
}

if (-not $FunctionsOnly) {
    try { Stop-ProcessesForUpdate $InstallRoot; exit 0 }
    catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
}
