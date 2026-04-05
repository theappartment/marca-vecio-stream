Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distRoot = Join-Path $projectRoot "dist"
$webDistRoot = Join-Path $distRoot "web"
$ngrokDistRoot = Join-Path $distRoot "tools\ngrok"
$iconPath = Join-Path $projectRoot "logoapp.ico"

if (-not (Test-Path -LiteralPath $distRoot)) {
    New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $webDistRoot)) {
    New-Item -ItemType Directory -Path $webDistRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ngrokDistRoot)) {
    New-Item -ItemType Directory -Path $ngrokDistRoot -Force | Out-Null
}

Import-Module ps2exe

$meta = @{
    title       = "Marca Vecio Stream"
    description = "Player Windows con VLC, pannello web, Telegram e ngrok."
    company     = "The Appartment"
    product     = "Marca Vecio Stream"
    copyright   = "The Appartment"
    version     = "1.0.0.0"
}

Invoke-ps2exe -inputFile (Join-Path $projectRoot "src\MarcaVecioPlayer.ps1") `
    -outputFile (Join-Path $distRoot "MarcaVecioStream.exe") `
    -iconFile $iconPath `
    -noConsole -STA -x64 -DPIAware `
    -title $meta.title -description $meta.description -company $meta.company -product $meta.product -copyright $meta.copyright -version $meta.version

Invoke-ps2exe -inputFile (Join-Path $projectRoot "src\WebServer.ps1") `
    -outputFile (Join-Path $distRoot "WebServer.exe") `
    -iconFile $iconPath `
    -noConsole -STA -x64 `
    -title "Marca Vecio Stream Web Server" -description $meta.description -company $meta.company -product $meta.product -copyright $meta.copyright -version $meta.version

Invoke-ps2exe -inputFile (Join-Path $projectRoot "src\TelegramWorker.ps1") `
    -outputFile (Join-Path $distRoot "TelegramWorker.exe") `
    -iconFile $iconPath `
    -noConsole -STA -x64 `
    -title "Marca Vecio Stream Telegram Worker" -description $meta.description -company $meta.company -product $meta.product -copyright $meta.copyright -version $meta.version

Copy-Item -LiteralPath (Join-Path $projectRoot "src\web\index.html") -Destination (Join-Path $webDistRoot "index.html") -Force
if (Test-Path -LiteralPath (Join-Path $projectRoot "src\tools\ngrok\ngrok.exe")) {
    try {
        Copy-Item -LiteralPath (Join-Path $projectRoot "src\tools\ngrok\ngrok.exe") -Destination (Join-Path $ngrokDistRoot "ngrok.exe") -Force
    }
    catch {
        Write-Warning "Impossibile aggiornare ngrok in dist perche il file e in uso. Mantengo la copia esistente."
    }
}
Copy-Item -LiteralPath (Join-Path $projectRoot "logoapp.ico") -Destination (Join-Path $distRoot "logoapp.ico") -Force
Copy-Item -LiteralPath (Join-Path $projectRoot "logoapp.png.jpg") -Destination (Join-Path $distRoot "logoapp.png.jpg") -Force
Copy-Item -LiteralPath (Join-Path $projectRoot "README.md") -Destination (Join-Path $distRoot "README.md") -Force

Write-Host ""
Write-Host "Build completata in:"
Write-Host $distRoot
