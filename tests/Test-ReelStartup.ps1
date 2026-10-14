param([switch]$Packaged)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-startup-'+[guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'
$folder = Join-Path $testRoot 'contents'
$AppRoot = Join-Path $project $(if ($Packaged) { 'dist' } else { 'src' })
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $AppRoot 'MediaCatalog.ps1')
. (Join-Path $AppRoot 'PlaybackSurface.ps1')
. (Join-Path $AppRoot 'PlaybackController.ps1')
function Stop-Playback { Stop-ControlledPlayback }
function Update-Status([string]$Message) { }
function Write-AppLog([string]$Message) { Write-Host $Message }
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
try {
    $names = @('snapgram.io_ybcxsfzzbqxq.mp4','snapgram.io_jxi8nhx1rri8.mp4','snapgram.io_3c6l3xx4m25f.mp4')
    foreach ($name in $names) {
        Copy-Item -LiteralPath (Join-Path 'C:\Users\Niccolo\Desktop\Diapo' $name) -Destination (Join-Path $folder $name)
        Update-MediaItem $folder $name ([pscustomobject]@{ role='reel' })
    }
    # The test stops each input at two seconds to exercise several complete
    # internal VLC repeats quickly, using the actual uploaded MP4s.
    Start-ControlledPlayback 'C:\Program Files\VideoLAN\VLC\vlc.exe' $folder '' @('--vout=dummy','--aout=dummy','--stop-time=2')
    Assert (@($script:PlaybackSurface.reelHosts | Where-Object { $_.Visibility -eq [Windows.Visibility]::Hidden }).Count -eq 3) 'Native black hosts hidden initially'
    Assert ($script:PlaybackSurface.reelCanvas.Visibility -eq [Windows.Visibility]::Hidden) 'Background hidden during preparation'
    $handles = @($script:ReelPlayers | ForEach-Object { $_.PlayerHandle })
    $window = $script:PlaybackSurface.window
    $deadline = [datetime]::UtcNow.AddSeconds(12)
    do {
        Update-ControlledPlayback
        $visible = @($script:PlaybackSurface.reelHosts | Where-Object { $_.Visibility -eq [Windows.Visibility]::Visible }).Count
        Assert ($visible -in @(0,3)) 'All three reel hosts revealed together'
        if ($visible -eq 0) { Assert ($script:PlaybackSurface.reelCanvas.Visibility -ne [Windows.Visibility]::Visible) 'No background-only startup frame' }
        if ($visible -eq 3) { Assert (@($script:ReelSlots | Where-Object { $_.frameReady }).Count -eq 3) 'Decoded frames required before reveal' }
        if (@($script:ReelSlots | Where-Object { $_.loops -ge 2 }).Count -eq 3) { break }
        Start-Sleep -Milliseconds 80
    } while ([datetime]::UtcNow -lt $deadline)
    Assert (@($script:ReelSlots | Where-Object { $_.loops -ge 2 }).Count -eq 3) 'Real MP4s loop internally without reopening'
    Assert ((@($script:ReelPlayers | ForEach-Object { $_.PlayerHandle }) -join '|') -eq ($handles -join '|')) 'Native players survive repeats'
    Assert ([object]::ReferenceEquals($window,$script:PlaybackSurface.window)) 'Window survives repeats'
    Assert ($script:PlaybackCurrent.durationSeconds -eq 30) 'Scene retains thirty-second cap'
    $photoName = 'Previous photo.jpg'
    Copy-Item -LiteralPath (Join-Path $AppRoot 'assets\reel-background.jpg') -Destination (Join-Path $folder $photoName)
    Update-MediaItem $folder $photoName ([pscustomobject]@{ durationSeconds=1 })
    Start-ControlledPlayback 'C:\Program Files\VideoLAN\VLC\vlc.exe' $folder $photoName @('--vout=dummy','--aout=dummy','--stop-time=2')
    $previousPhoto = $script:PlaybackSurface.layers[$script:PlaybackSurface.front].Source
    $script:PlaybackMode = 'rotation'; $script:PlaybackAppliedSignature = ''
    $script:PlaybackStarted = [datetime]::UtcNow.AddSeconds(-2)
    Update-ControlledPlayback
    Assert ($script:PlaybackCurrent.kind -eq 'reel') 'Controller advances from photo to reel scene'
    $preparedAt = [datetime]::UtcNow
    Assert ($script:PlaybackSurface.transitionCover.Visibility -eq [Windows.Visibility]::Visible) 'Previous photo held while loading reels'
    Assert ([object]::ReferenceEquals($previousPhoto,$script:PlaybackSurface.transitionCover.Source)) 'Held image is the previous content'
    Assert ($script:PlaybackSurface.reelCanvas.Visibility -eq [Windows.Visibility]::Hidden) 'Whole new scene hidden behind previous content'
    $deadline = [datetime]::UtcNow.AddSeconds(6)
    do { Update-ControlledPlayback; Start-Sleep -Milliseconds 80 } while (-not $script:PlaybackSurface.reelPresented -and [datetime]::UtcNow -lt $deadline)
    Assert ($script:PlaybackSurface.reelPresented) 'New scene presented'
    Assert ($script:PlaybackSurface.reelCanvas.Visibility -eq [Windows.Visibility]::Visible) 'Background and reel scene shown together'
    Assert ($script:PlaybackSurface.transitionFading) 'Complete reel scene starts the dissolve'
    $fadeFrame = New-Object Windows.Threading.DispatcherFrame
    $fadeTimer = New-Object Windows.Threading.DispatcherTimer
    $fadeTimer.Interval = [TimeSpan]::FromMilliseconds(650)
    $fadeTimer.Add_Tick({ $fadeTimer.Stop(); $fadeFrame.Continue=$false })
    $fadeTimer.Start(); [Windows.Threading.Dispatcher]::PushFrame($fadeFrame)
    Update-PlaybackTransition
    Assert ($script:PlaybackSurface.transitionCover.Visibility -eq [Windows.Visibility]::Collapsed -and -not $script:PlaybackSurface.transitionCover.Source) 'Previous frame released after dissolve'
    Assert ($script:PlaybackStarted -ge $preparedAt) 'Thirty-second timer begins when scene is presented'
    Stop-Playback
    Assert ($script:ReelPlayers.Count -eq 0 -and -not $script:PlaybackSurface) 'Stop releases all players immediately'
    Write-Host 'PASS: actual three reels, coordinated decoded-frame reveal, internal VLC repeats, stable players/window and stop.'
} finally {
    Stop-Playback
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($project+'\') -and [IO.Path]::GetFileName($resolved).StartsWith('.test-startup-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
