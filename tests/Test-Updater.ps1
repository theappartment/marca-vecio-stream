Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'src\UpdateClient.ps1')
function Assert($Condition,[string]$Message) { if (-not $Condition) {throw "FAIL: $Message"} }
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $threw=$false; try { & $Action } catch {$threw=$true}; Assert $threw $Message
}
$root=Join-Path $project ('.test-updater-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $package=Join-Path $root 'fixture.exe'
    [IO.File]::WriteAllBytes($package,[byte[]]@(77,90,1,2,3,4,5,6))
    $hash=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    $release=[pscustomobject]@{tag_name='v1.4.0';draft=$false;prerelease=$false;body='Changes';assets=@([pscustomobject]@{name='MarcaVecioStream-Setup.exe';state='uploaded';id=123;size=8;digest=('sha256:'+$hash)})}
    $info=ConvertTo-UpdateRelease $release '1.3.0'
    Assert ($info.available -and $info.version -eq '1.4.0' -and $info.sha256 -eq $hash) 'New stable release with complete installer selected'
    Assert (-not (ConvertTo-UpdateRelease $release '1.4.0.0').available) 'Equivalent three/four component versions do not offer repeated updates'
    Assert (-not (ConvertTo-UpdateRelease $release '2.0.0').available) 'Rollback is never offered as an update'
    $old=[pscustomobject]@{tag_name='1.0.0';assets=@()}
    Assert (-not (ConvertTo-UpdateRelease $old).available) 'Original historical release remains compatible'
    $release.prerelease=$true;Assert-Throws {ConvertTo-UpdateRelease $release} 'Prerelease rejected';$release.prerelease=$false
    $release.assets[0].digest='';Assert-Throws {ConvertTo-UpdateRelease $release} 'Missing digest rejected';$release.assets[0].digest='sha256:'+$hash
    $release.assets[0].state='new';Assert-Throws {ConvertTo-UpdateRelease $release} 'Incomplete asset rejected';$release.assets[0].state='uploaded'
    Assert-UpdatePackage $package $info
    [IO.File]::WriteAllBytes($package,[byte[]]@(77,90,1,2,3,4,5,7))
    Assert-Throws {Assert-UpdatePackage $package $info} 'Same-size corrupted package rejected'
    [IO.File]::WriteAllBytes($package,[byte[]]@(77,90,1))
    Assert-Throws {Assert-UpdatePackage $package $info} 'Interrupted package rejected'
    # Mock only the network boundary, exercise real streaming and atomic promotion.
    function Open-UpdateResponse {
        param($Url,$Token,$Binary)
        $response=[pscustomobject]@{bytes=$script:DownloadBytes}
        $response | Add-Member ScriptMethod GetResponseStream {return [IO.MemoryStream]::new([byte[]]$this.bytes)}
        $response | Add-Member ScriptMethod Dispose {}
        return $response
    }
    $script:DownloadBytes=[byte[]]@(77,90,1,2,3,4,5,6)
    $download=Save-UpdatePackage $info (Join-Path $root 'downloads')
    Assert ([IO.File]::Exists($download)) 'Verified completed download promoted to installer'
    $script:DownloadBytes=[byte[]]@(77,90,1,2)
    Assert-Throws {Save-UpdatePackage $info (Join-Path $root 'downloads')} 'Interrupted stream rejected'
    Assert ((Get-FileHash -LiteralPath $download).Hash.ToLowerInvariant() -eq $hash) 'Failed replacement retains previous verified installer'
    Assert (@(Get-ChildItem (Join-Path $root 'downloads') -Filter '*.tmp').Count -eq 0) 'Failed download removes temporary file'
    $dpapiAvailable=$true
    try { Save-UpdateCredential $root 'test-token-for-dpapi' }
    catch [Security.Cryptography.CryptographicException] {
        $dpapiAvailable=$false
        Write-Output 'SKIP: Windows credential protection unavailable for this noninteractive account.'
    }
    if ($dpapiAvailable) {
        Assert ((Get-UpdateCredential $root) -eq 'test-token-for-dpapi') 'Credential decrypts for same Windows account'
        Assert (-not [IO.File]::ReadAllText((Join-Path $root 'github-update.credential')).Contains('test-token-for-dpapi')) 'Credential never persisted as plain text'
        Save-UpdateCredential $root '';Assert ((Get-UpdateCredential $root) -eq '') 'Credential can be removed'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
    $source=[IO.File]::ReadAllText((Join-Path $project 'src\MarcaVecioPlayer.ps1'))
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'Desktop source parses'
    $assignment=$ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '[xml]$xaml'},$false)
    Invoke-Expression $assignment.Extent.Text
    $window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($xaml)))
    . (Join-Path $project 'src\UpdateUi.ps1')
    $ConfigRoot=$root;$AppRoot=Join-Path $project 'src'
    $script:StartedJobs=@()
    function Start-AppUpdateJob([string]$Operation) {$script:StartedJobs+=$Operation}
    Initialize-AppUpdater
    Assert ($script:StartedJobs.Count -eq 0) 'Startup does not check GitHub'
    $script:UpdaterTimer.Stop()
    # The timer only monitors a user-started worker, never starts a request.
    Update-AppUpdateJob;Update-AppUpdateJob
    Assert ($script:StartedJobs.Count -eq 0) 'Idle polling does not check GitHub'
    $click=[Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
    $window.FindName('CheckUpdatesButton').RaiseEvent($click)
    Assert (($script:StartedJobs -join ',') -eq 'Check') 'Only explicit check button starts a search'
    Assert (-not $window.FindName('InstallUpdateButton').IsEnabled) 'No installation without a selected newer release'
    $window.Close()
    Write-Output 'PASS: manual-only checks, versions, stable releases, interrupted/corrupt downloads, atomic replacement, credential protection and desktop controls.'
} finally {
    if ($root.StartsWith($project+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $root).StartsWith('.test-updater-')) {Remove-Item -LiteralPath $root -Recurse -Force}
}
