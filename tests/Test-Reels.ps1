param([switch]$Packaged)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-reels-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'
$folder = Join-Path $testRoot 'contents'
$AppRoot = Join-Path $project $(if ($Packaged) { 'dist' } else { 'src' })
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $AppRoot 'MediaCatalog.ps1')
. (Join-Path $AppRoot 'PlaybackSurface.ps1')
. (Join-Path $AppRoot 'PlaybackController.ps1')
function Update-Status([string]$Message) { }
function Write-AppLog([string]$Message) { Write-Host $Message }
function Stop-Playback { Stop-ControlledPlayback }
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Wait-Reels([scriptblock]$Condition,[double]$Seconds=12) {
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        Update-ControlledPlayback
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 80
    } while ([datetime]::UtcNow -lt $deadline)
    throw ('Timeout: ' + $script:PlaybackMessage + ' ' + $script:PlaybackError)
}
$vlc = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
try {
    Add-Type -AssemblyName System.Drawing
    $image = New-Object Drawing.Bitmap(90,160)
    try { $image.Save((Join-Path $folder 'Input.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
    $uri = ([uri](Join-Path $folder 'Input.png')).AbsoluteUri
    foreach ($fixture in @(@('Short.mp4',2),@('Long.mp4',35))) {
        $encoder = Start-Process $vlc -WorkingDirectory $folder -WindowStyle Hidden -PassThru -ArgumentList @(
            '--ignore-config','--intf=dummy','--no-one-instance','--vout=dummy','--aout=dummy',('--image-duration='+$fixture[1]),
            ('--sout=#transcode{vcodec=mp4v,vb=100,fps=10}:std{access=file,mux=mp4,dst='+$fixture[0]+'}'),'--play-and-exit',$uri)
        if (-not $encoder.WaitForExit(50000)) { $encoder.Kill(); throw 'Fixture encoding timed out.' }
        Assert ((Get-Item (Join-Path $folder $fixture[0])).Length -gt 100) 'Encoded real portrait MP4'
    }
    Copy-Item -LiteralPath (Join-Path $folder 'Short.mp4') -Destination (Join-Path $folder 'Reel con spazi.mp4')
    Copy-Item -LiteralPath (Join-Path $folder 'Short.mp4') -Destination (Join-Path $folder 'Reel caffè.mp4')
    Update-MediaItem $folder 'Input.png' ([pscustomobject]@{ role='background' })
    foreach ($name in @('Short.mp4','Long.mp4','Reel con spazi.mp4','Reel caffè.mp4')) {
        Update-MediaItem $folder $name ([pscustomobject]@{ role='reel' })
    }
    $view = Get-MediaView $folder
    $seenOrders = @{}
    for ($i=0; $i -lt 20; $i++) {
        $rotation = @(Get-MediaRotation $view)
        Assert ($rotation.Count -eq 2) 'Four reels form two scenes'
        Assert (@($rotation | Where-Object { $_.kind -eq 'background' }).Count -eq 0) 'Background excluded from loop'
        $members = @($rotation | ForEach-Object { $_.members.name })
        Assert (@($members | Select-Object -Unique).Count -eq 4) 'Every active reel represented'
        foreach ($group in $rotation) {
            Assert ($group.members.Count -eq 3 -and @($group.members.name | Select-Object -Unique).Count -eq 3) 'Distinct three videos when available'
            Assert ($group.durationSeconds -eq 30) 'Scene capped at thirty seconds'
        }
        $seenOrders[($members -join '|')] = $true
    }
    Assert ($seenOrders.Count -gt 1) 'Random groups and positions'
    $two = @($view.items | Where-Object kind -eq 'reel' | Select-Object -First 2)
    $pair = @(Get-MediaRotation ([pscustomobject]@{ items=$two; priorityFrequency=2 }))
    Assert ($pair.Count -eq 1 -and $pair[0].members.Count -eq 3 -and @($pair[0].members.name | Select-Object -Unique).Count -eq 2) 'Two reels fill three positions with both included'
    foreach ($name in @('Input.png','Long.mp4','Reel con spazi.mp4','Reel caffè.mp4')) { Update-MediaItem $folder $name ([pscustomobject]@{ enabled=$false }) }
    Start-ControlledPlayback $vlc $folder '' @('--vout=dummy','--aout=dummy')
    Assert ($script:PlaybackCurrent.kind -eq 'reel' -and $script:PlaybackCurrent.names.Count -eq 3) 'One reel fills all three positions'
    Assert ($script:ReelPlayers.Count -eq 3) 'Three native VLC players'
    Assert (@($script:PlaybackSurface.reelHosts | Where-Object { $_.Visibility -eq [Windows.Visibility]::Hidden }).Count -eq 3) 'No black hosts exposed before decoding'
    Assert ($script:PlaybackSurface.reelBackground.Source.PixelWidth -eq 1920) 'Provided default background loaded'
    Assert ([math]::Abs($script:PlaybackSurface.reelHosts[1].Width/$script:PlaybackSurface.reelHosts[1].Height-9/16) -lt 0.001) 'Center keeps portrait ratio'
    Assert ($script:PlaybackSurface.reelHosts[1].Height -gt $script:PlaybackSurface.reelHosts[0].Height) 'Center larger than side panels'
    $window = $script:PlaybackSurface.window
    $badBackground = Join-Path $folder 'Broken background.jpg'
    [IO.File]::WriteAllText($badBackground,'invalid image')
    Show-PlaybackReels $script:PlaybackQueue[0].members $badBackground
    Assert ($script:PlaybackSurface.reelBackground.Source.PixelWidth -eq 1920) 'Unreadable custom background falls back without losing reels'
    [IO.File]::Delete($badBackground)
    Wait-Reels { @($script:ReelSlots | Where-Object { $_.loops -ge 1 }).Count -eq 3 }
    Assert (@($script:ReelSlots | Where-Object { $_.frameReady }).Count -eq 3) 'Frames decoded before revealing hosts'
    Assert (@($script:PlaybackSurface.reelHosts | Where-Object { $_.Visibility -eq [Windows.Visibility]::Visible }).Count -eq 3) 'Three prepared reel hosts revealed together'
    Assert ([object]::ReferenceEquals($window,$script:PlaybackSurface.window)) 'Short reels loop in same window'
    Request-MediaDelete $folder 'Short.mp4'
    Complete-MediaDeletes $folder $script:PlaybackCurrent.names
    Assert ([IO.File]::Exists((Join-Path $folder 'Short.mp4'))) 'All three current filenames protected from deletion'
    Update-MediaItem $folder 'Long.mp4' ([pscustomobject]@{ enabled=$true })
    Update-PlaybackCatalog $folder
    Assert ($script:PlaybackCurrent.name -eq 'Short.mp4') 'Changes preserve current thirty-second scene'
    $script:PlaybackStarted = [datetime]::UtcNow.AddSeconds(-30)
    Update-ControlledPlayback
    Assert ($script:PlaybackCurrent.name -eq 'Long.mp4') 'New catalog applied at scene end'
    Assert (-not [IO.File]::Exists((Join-Path $folder 'Short.mp4'))) 'Deletion after releasing every reel player'
    Wait-Reels { @($script:ReelSlots | Where-Object { $_.sawPlaying }).Count -eq 3 }
    Assert ($script:ReelPlayers[0].Length -gt 30000) 'Real source longer than thirty seconds'
    $firstSlots = $script:ReelSlots
    $script:PlaybackStarted = [datetime]::UtcNow.AddSeconds(-30)
    Update-ControlledPlayback
    Assert (-not [object]::ReferenceEquals($firstSlots,$script:ReelSlots)) 'Long reel scene advances at thirty seconds'
    Assert ([object]::ReferenceEquals($window,$script:PlaybackSurface.window)) 'Same window across scenes'
    Update-MediaItem $folder 'Long.mp4' ([pscustomobject]@{ enabled=$false })
    $script:PlaybackStarted = [datetime]::UtcNow.AddSeconds(-30)
    Update-ControlledPlayback
    Assert ($script:PlaybackMode -eq 'stopped' -and $script:ReelPlayers.Count -eq 0) 'Empty rotation stops and releases three VLC players'
    [IO.File]::WriteAllText((Join-Path $folder 'Broken.mp4'),'invalid')
    Update-MediaItem $folder 'Broken.mp4' ([pscustomobject]@{ role='reel' })
    Start-ControlledPlayback $vlc $folder '' @('--vout=dummy','--aout=dummy')
    Wait-Reels { $script:PlaybackMode -eq 'stopped' }
    Assert ($script:PlaybackError -match 'nessun contenuto riproducibile') 'Corrupt-only reels stop with clear error'
    Write-Host 'PASS: random reel groups, native triple playback, looping short videos, 30-second limit, supplied background, layout, live updates, deletion, corrupt files and cleanup.'
} finally {
    Stop-Playback
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($project+'\') -and [IO.Path]::GetFileName($resolved).StartsWith('.test-reels-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
