param([string]$CompilerPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    $CompilerPath,
    (Join-Path $projectRoot '.build-tools\InnoSetup\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Users\Niccolo\AppData\Local\Programs\Inno Setup 6\ISCC.exe'
)
$isccPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot "dist\MarcaVecioStream.exe"))) {
    throw "Build EXE non trovata. Esegui prima .\build-exe.ps1"
}

if (-not $isccPath) {
    throw 'Compilatore Inno Setup non trovato. Installa Inno Setup o passa -CompilerPath.'
}

& $isccPath (Join-Path $projectRoot "installer.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup ha restituito $LASTEXITCODE" }

Write-Host ""
Write-Host "Setup creato in:"
Write-Host (Join-Path $projectRoot "release\MarcaVecioStream-Setup.exe")
