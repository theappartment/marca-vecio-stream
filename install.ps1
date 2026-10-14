Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$appName = "Marca Vecio Stream"
$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\MarcaVecioStream"
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "$appName.lnk"
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$startMenuShortcutPath = Join-Path $startMenuDir "$appName.lnk"
$iconPath = "C:\Windows\System32\shell32.dll,1"

function Copy-IfExists([string]$SourcePath, [string]$DestinationPath) {
    if (Test-Path -LiteralPath $SourcePath) {
        $destDir = Split-Path -Parent $DestinationPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }
}

if (Test-Path -LiteralPath (Join-Path $sourceRoot "logoapp.ico")) {
    $iconPath = Join-Path $installRoot "logoapp.ico"
}

foreach ($candidate in @("C:\Program Files\VideoLAN\VLC\vlc.exe", "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe")) {
    if ($iconPath -eq "C:\Windows\System32\shell32.dll,1" -and (Test-Path -LiteralPath $candidate)) {
        $iconPath = "$candidate,0"
        break
    }
}

if (-not (Test-Path -LiteralPath $installRoot)) {
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
}

Copy-IfExists -SourcePath (Join-Path $sourceRoot "src\MarcaVecioPlayer.ps1") -DestinationPath (Join-Path $installRoot "MarcaVecioPlayer.ps1")
Copy-IfExists -SourcePath (Join-Path $sourceRoot "src\WebServer.ps1") -DestinationPath (Join-Path $installRoot "WebServer.ps1")
Copy-IfExists -SourcePath (Join-Path $sourceRoot "src\TelegramWorker.ps1") -DestinationPath (Join-Path $installRoot "TelegramWorker.ps1")
Copy-IfExists -SourcePath (Join-Path $sourceRoot "src\launcher.vbs") -DestinationPath (Join-Path $installRoot "launcher.vbs")
foreach ($supportFile in @('MediaCatalog.ps1','PlaybackSurface.ps1','PlaybackController.ps1','launcher.vbs')) {
    Copy-IfExists -SourcePath (Join-Path $sourceRoot ('src\' + $supportFile)) -DestinationPath (Join-Path $installRoot $supportFile)
    Copy-IfExists -SourcePath (Join-Path $sourceRoot ('dist\' + $supportFile)) -DestinationPath (Join-Path $installRoot $supportFile)
}
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'dist\docs')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'dist\docs') -Destination $installRoot -Recurse -Force
}
Copy-IfExists -SourcePath (Join-Path $sourceRoot "README.md") -DestinationPath (Join-Path $installRoot "README.md")
foreach ($assetSource in @('src\assets','dist\assets')) {
    if (Test-Path -LiteralPath (Join-Path $sourceRoot $assetSource)) { Copy-Item -LiteralPath (Join-Path $sourceRoot $assetSource) -Destination $installRoot -Recurse -Force }
}
Copy-IfExists -SourcePath (Join-Path $sourceRoot "uninstall.ps1") -DestinationPath (Join-Path $installRoot "uninstall.ps1")
Copy-IfExists -SourcePath (Join-Path $sourceRoot "logoapp.png.jpg") -DestinationPath (Join-Path $installRoot "logoapp.png.jpg")
Copy-IfExists -SourcePath (Join-Path $sourceRoot "logoapp.ico") -DestinationPath (Join-Path $installRoot "logoapp.ico")
foreach ($binary in @("MarcaVecioStream.exe", "WebServer.exe", "TelegramWorker.exe")) {
    $binarySource = Join-Path $sourceRoot ("dist\" + $binary)
    Copy-IfExists -SourcePath $binarySource -DestinationPath (Join-Path $installRoot $binary)
}
Copy-IfExists -SourcePath (Join-Path $sourceRoot "src\tools\ngrok\ngrok.exe") -DestinationPath (Join-Path $installRoot "tools\ngrok\ngrok.exe")
Copy-IfExists -SourcePath (Join-Path $sourceRoot "dist\tools\ngrok\ngrok.exe") -DestinationPath (Join-Path $installRoot "tools\ngrok\ngrok.exe")

$webInstallRoot = Join-Path $installRoot "web"
if (-not (Test-Path -LiteralPath $webInstallRoot)) {
    New-Item -ItemType Directory -Path $webInstallRoot -Force | Out-Null
}
$webSource = Join-Path $sourceRoot "src\web\index.html"
if (Test-Path -LiteralPath (Join-Path $sourceRoot "dist\web\index.html")) {
    $webSource = Join-Path $sourceRoot "dist\web\index.html"
}
Copy-IfExists -SourcePath $webSource -DestinationPath (Join-Path $webInstallRoot "index.html")

$shell = New-Object -ComObject WScript.Shell
$shortcutTarget = Join-Path $installRoot "launcher.vbs"
if (Test-Path -LiteralPath (Join-Path $installRoot "MarcaVecioStream.exe")) {
    $shortcutTarget = Join-Path $installRoot "MarcaVecioStream.exe"
}

foreach ($shortcutPath in @($desktopShortcutPath, $startMenuShortcutPath)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $shortcutTarget
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.IconLocation = $iconPath
    $shortcut.Save()
}

Write-Host ""
Write-Host "$appName installata in:"
Write-Host $installRoot
Write-Host ""
Write-Host "Shortcut creati:"
Write-Host $desktopShortcutPath
Write-Host $startMenuShortcutPath
