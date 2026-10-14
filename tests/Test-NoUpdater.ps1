Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$source=[IO.File]::ReadAllText((Join-Path $project 'src\MarcaVecioPlayer.ps1'))
if($source -match 'UpdateClient|UpdateUi|UpdateWorker|Initialize-AppUpdater|UpdaterTimer|CheckUpdatesButton|InstallUpdateButton'){throw 'Updater still included in player'}
$build=[IO.File]::ReadAllText((Join-Path $project 'build-exe.ps1'))
if($build -match 'UpdateClient|UpdateUi|UpdateWorker'){throw 'Updater still included in build'}
$installer=[IO.File]::ReadAllText((Join-Path $project 'installer.iss'))
if($installer -match 'Source: "dist\\Update'){throw 'Updater still included in installer'}
foreach($name in @('UpdateWorker.exe','UpdateWorker.ps1','UpdateClient.ps1','UpdateUi.ps1')){
    if(-not $installer.Contains('Name: "{app}\'+$name+'"')){throw ('Missing legacy cleanup: '+$name)}
}
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){throw 'Player parse errors'}
Write-Output 'PASS: updater absent from player/build/installer and exact legacy file cleanup retained.'