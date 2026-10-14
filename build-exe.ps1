Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distRoot = Join-Path $projectRoot "dist"
$webDistRoot = Join-Path $distRoot "web"
$ngrokDistRoot = Join-Path $distRoot "tools\ngrok"
$iconPath = Join-Path $projectRoot "logoapp.ico"
$compileRoot = Join-Path $projectRoot '.build-tools\sources'
New-Item -ItemType Directory -Path $compileRoot -Force | Out-Null

# Inline support modules in EXEs so Restricted execution policy does not prevent
# dot-sourcing at runtime. Source-script installs still use the shared modules.
foreach ($entryPoint in @('MarcaVecioPlayer.ps1','WebServer.ps1')) {
    $source = [IO.File]::ReadAllText((Join-Path $projectRoot ('src\' + $entryPoint)))
    foreach ($moduleName in @('MediaCatalog.ps1','PlaybackSurface.ps1','PlaybackController.ps1')) {
        $marker = ". (Join-Path `$AppRoot '$moduleName')"
        if ($source.Contains($marker)) {
            $source = $source.Replace($marker, [IO.File]::ReadAllText((Join-Path $projectRoot ('src\' + $moduleName))))
        }
    }
    [IO.File]::WriteAllText((Join-Path $compileRoot $entryPoint), $source, (New-Object Text.UTF8Encoding($true)))
    $parseTokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($source,[ref]$parseTokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ('Sorgente compilata non valida: '+$entryPoint+'. '+($parseErrors.Message -join ' ')) }
}

if (-not (Test-Path -LiteralPath $distRoot)) {
    New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $webDistRoot)) {
    New-Item -ItemType Directory -Path $webDistRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ngrokDistRoot)) {
    New-Item -ItemType Directory -Path $ngrokDistRoot -Force | Out-Null
}

if (Get-Module -ListAvailable ps2exe) {
    Import-Module ps2exe
} else {
    Import-Module (Join-Path $projectRoot '.build-tools\ps2exe\ps2exe.psd1')
}

$meta = @{
    title       = "Marca Vecio Stream"
    description = "Slide e video con priorita, VLC, pannello web, Telegram e ngrok."
    company     = "The Appartment"
    product     = "Marca Vecio Stream"
    copyright   = "The Appartment"
    version     = "1.3.1.0"
}

Invoke-ps2exe -inputFile (Join-Path $compileRoot "MarcaVecioPlayer.ps1") `
    -outputFile (Join-Path $distRoot "MarcaVecioStream.exe") `
    -iconFile $iconPath `
    -noConsole -STA -x64 -DPIAware `
    -title $meta.title -description $meta.description -company $meta.company -product $meta.product -copyright $meta.copyright -version $meta.version

Invoke-ps2exe -inputFile (Join-Path $compileRoot "WebServer.ps1") `
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
foreach ($supportFile in @('MediaCatalog.ps1','PlaybackSurface.ps1','PlaybackController.ps1','launcher.vbs')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot ('src\' + $supportFile)) -Destination (Join-Path $distRoot $supportFile) -Force
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination $distRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\assets') -Destination $distRoot -Recurse -Force
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
