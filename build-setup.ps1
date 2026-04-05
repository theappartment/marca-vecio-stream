Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$isccPath = "C:\Users\Niccolo\AppData\Local\Programs\Inno Setup 6\ISCC.exe"

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot "dist\MarcaVecioStream.exe"))) {
    throw "Build EXE non trovata. Esegui prima .\build-exe.ps1"
}

if (-not (Test-Path -LiteralPath $isccPath)) {
    throw "ISCC.exe non trovato in $isccPath"
}

& $isccPath (Join-Path $projectRoot "installer.iss")

Write-Host ""
Write-Host "Setup creato in:"
Write-Host (Join-Path $projectRoot "release\MarcaVecioStream-Setup.exe")
