Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distRoot = Join-Path $projectRoot "dist"
$releaseRoot = Join-Path $projectRoot "release"
$stagingRoot = Join-Path $releaseRoot "installer-staging"
$packageName = "MarcaVecioStream-Setup.exe"
$packagePath = Join-Path $releaseRoot $packageName
$tempBuildRoot = Join-Path $env:TEMP "MarcaVecioStreamSetup"
$tempPackagePath = Join-Path $tempBuildRoot $packageName
$sedPath = Join-Path $releaseRoot "MarcaVecioStream.sed"

if (-not (Test-Path -LiteralPath (Join-Path $distRoot "MarcaVecioStream.exe"))) {
    throw "Build EXE non trovata. Esegui prima .\build-exe.ps1"
}

foreach ($path in @($releaseRoot, $stagingRoot)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

if (Test-Path -LiteralPath $tempBuildRoot) {
    Remove-Item -LiteralPath $tempBuildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tempBuildRoot -Force | Out-Null

function Copy-Staged([string]$RelativePath) {
    $source = Join-Path $projectRoot $RelativePath
    $destination = Join-Path $stagingRoot $RelativePath
    $destDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

$files = @(
    "install.ps1",
    "uninstall.ps1",
    "README.md",
    "logoapp.ico",
    "logoapp.png.jpg",
    "dist\MarcaVecioStream.exe",
    "dist\WebServer.exe",
    "dist\TelegramWorker.exe",
    "dist\web\index.html"
)

foreach ($file in $files) {
    Copy-Staged $file
}

$sourceFileEntries = @()
$stringFileEntries = @()
for ($i = 0; $i -lt $files.Count; $i++) {
    $sourceFileEntries += "%FILE$($i)%="
    $stringFileEntries += "FILE$($i)=\"$($files[$i])\""
}

$sedLines = @(
    "[Version]"
    "Class=IEXPRESS"
    "SEDVersion=3"
    "[Options]"
    "PackagePurpose=InstallApp"
    "ShowInstallProgramWindow=0"
    "HideExtractAnimation=1"
    "UseLongFileName=1"
    "InsideCompressed=0"
    "CAB_FixedSize=0"
    "CAB_ResvCodeSigning=0"
    "RebootMode=N"
    "InstallPrompt=%InstallPrompt%"
    "DisplayLicense=%DisplayLicense%"
    "FinishMessage=%FinishMessage%"
    "TargetName=%TargetName%"
    "FriendlyName=%FriendlyName%"
    "AppLaunched=%AppLaunched%"
    "PostInstallCmd=%PostInstallCmd%"
    "AdminQuietInstCmd=%AdminQuietInstCmd%"
    "UserQuietInstCmd=%UserQuietInstCmd%"
    "SourceFiles=SourceFiles"
    "[Strings]"
    "InstallPrompt="
    "DisplayLicense="
    "FinishMessage=Installazione completata."
    "TargetName=$tempPackagePath"
    "FriendlyName=Marca Vecio Stream Setup"
    "AppLaunched=powershell.exe -ExecutionPolicy Bypass -File install.ps1"
    "PostInstallCmd=<None>"
    "AdminQuietInstCmd="
    "UserQuietInstCmd="
) + $stringFileEntries + @(
    "[SourceFiles]"
    "SourceFiles0=$stagingRoot\\"
    "[SourceFiles0]"
) + $sourceFileEntries

Set-Content -LiteralPath $sedPath -Value $sedLines -Encoding ASCII

Get-Process iexpress -ErrorAction SilentlyContinue | Stop-Process -Force
& iexpress.exe /N /Q /M $sedPath | Out-Null

if (-not (Test-Path -LiteralPath $tempPackagePath)) {
    throw "IExpress non ha prodotto l'installer atteso."
}

Copy-Item -LiteralPath $tempPackagePath -Destination $packagePath -Force

Write-Host ""
Write-Host "Installer creato in:"
Write-Host $packagePath
