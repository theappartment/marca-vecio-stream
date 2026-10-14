param([ValidateSet('Check','Download')][string]$Operation='Check',[string]$Root,[string]$ResultPath,[string]$ExpectedVersion='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$AppRoot=if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
. (Join-Path $AppRoot 'UpdateClient.ps1')
$result=$null
try {
    $token=Get-UpdateCredential $Root
    $release=Get-LatestUpdate $token
    $package=''
    if ($Operation -eq 'Download') {
        if (-not $release.available -or $release.version -ne $ExpectedVersion) { throw 'La release e cambiata. Cerca nuovamente gli aggiornamenti.' }
        $package=Save-UpdatePackage $release (Join-Path $Root 'updates') $token
    }
    $result=[ordered]@{ok=$true;release=$release;package=$package}
} catch { $result=[ordered]@{ok=$false;message=$_.Exception.Message} }
finally { $token=$null }
$temporary=$ResultPath + '.tmp'
[IO.File]::WriteAllText($temporary,($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
[IO.File]::Move($temporary,$ResultPath)
