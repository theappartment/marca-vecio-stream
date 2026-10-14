Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-playback-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'
$folder = Join-Path $testRoot 'contents'
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $project 'src\MediaCatalog.ps1')
. (Join-Path $project 'src\PlaybackSurface.ps1')
. (Join-Path $project 'src\PlaybackController.ps1')
$script:CurrentVlcProcess = $null
function Update-Status([string]$Message) { }
function Write-AppLog([string]$Message) { Write-Output "LOG: $Message" }
function Stop-Playback { Stop-ControlledPlayback }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Wait-Playback([scriptblock]$Condition, [double]$Seconds = 12) {
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        Update-ControlledPlayback
        if (& $Condition) { return }
        if ($script:PlaybackMode -eq 'stopped') { throw ('Playback stopped: ' + $script:PlaybackError) }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw ('Playback timeout: ' + $script:PlaybackMessage + ' ' + $script:PlaybackError)
}
$vlc = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
try {
    Add-Type -AssemblyName System.Drawing
    foreach ($name in @('Slide A.png','Slide B.png')) {
        $image = New-Object Drawing.Bitmap(160,90)
        $graphics = [Drawing.Graphics]::FromImage($image)
        try { $graphics.Clear([Drawing.Color]::DarkBlue); $image.Save((Join-Path $folder $name), [Drawing.Imaging.ImageFormat]::Png) }
        finally { $graphics.Dispose(); $image.Dispose() }
    }
    Update-MediaItem $folder 'Slide A.png' ([pscustomobject]@{ durationSeconds = 2 })
    Update-MediaItem $folder 'Slide B.png' ([pscustomobject]@{ durationSeconds = 1 })
    Start-ControlledPlayback $vlc $folder '' @('--vout=dummy','--aout=dummy')
    Wait-Playback { $script:PlaybackCurrent -and $script:PlaybackCurrent.name -eq 'Slide A.png' -and $script:PlaybackSawPlaying }
    $originalWindow = $script:PlaybackSurface.window
    $originalHwnd = (New-Object Windows.Interop.WindowInteropHelper($originalWindow)).EnsureHandle()
    $originalPlayer = $script:EmbeddedVlc.PlayerHandle
    $firstStarted = $script:PlaybackStarted
    Set-MediaSlideDuration $folder 1
    Update-PlaybackCatalog $folder
    Assert ($script:PlaybackCurrent.durationSeconds -eq 2) 'Global update does not shorten current photo'
    Assert ($script:PlaybackCurrent.durationSeconds -eq 2) 'Configured photo duration'
    Assert ($script:PlaybackSurface.layers[$script:PlaybackSurface.front].Source -ne $null) 'Photo is rendered in permanent window'
    Update-MediaItem $folder 'Slide A.png' ([pscustomobject]@{ enabled = $false })
    Update-PlaybackCatalog $folder
    Assert ($script:PlaybackCurrent.name -eq 'Slide A.png') 'Current content retained during catalog update'
    Assert ($script:PlaybackAppliedSignature -ne $script:PlaybackSignature) 'Pending changes tracked'
    Wait-Playback { $script:PlaybackCurrent -and $script:PlaybackCurrent.name -eq 'Slide B.png' -and $script:PlaybackSawPlaying }
    Assert (([datetime]::UtcNow - $firstStarted).TotalSeconds -ge 1.7) 'Slide completes before update'
    Assert ([object]::ReferenceEquals($script:PlaybackSurface.window,$originalWindow)) 'Same WPF window at photo boundary'
    Assert ((New-Object Windows.Interop.WindowInteropHelper($script:PlaybackSurface.window)).Handle -eq $originalHwnd) 'Actual window HWND survives photo change'
    Assert ($script:EmbeddedVlc.PlayerHandle -eq $originalPlayer) 'Same native VLC player'
    Assert ($script:PlaybackSurface.transitionCount -eq 1) 'Photo boundary uses a crossfade'
    Request-MediaDelete $folder 'Slide B.png'
    Complete-MediaDeletes $folder 'Slide B.png'
    Assert ([IO.File]::Exists((Join-Path $folder 'Slide B.png'))) 'Playing file retained'
    Update-PlaybackCatalog $folder
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while ($script:PlaybackMode -ne 'stopped' -and [datetime]::UtcNow -lt $deadline) { Update-ControlledPlayback; Start-Sleep -Milliseconds 100 }
    Assert ($script:PlaybackMode -eq 'stopped') 'Stop when all contents disabled or deleted'
    Assert (-not [IO.File]::Exists((Join-Path $folder 'Slide B.png'))) 'Deletion after completion'
    # A corrupt video must not leave the app spinning forever.
    [IO.File]::WriteAllText((Join-Path $folder 'Corrupt.mp4'), 'not-a-video')
    Start-ControlledPlayback $vlc $folder '' @('--vout=dummy','--aout=dummy')
    $deadline = [datetime]::UtcNow.AddSeconds(12)
    while ($script:PlaybackMode -ne 'stopped' -and [datetime]::UtcNow -lt $deadline) { Update-ControlledPlayback; Start-Sleep -Milliseconds 100 }
    if ($script:PlaybackMode -ne 'stopped' -or $script:PlaybackError -notmatch 'nessun contenuto riproducibile') {
        Write-Output ("DEBUG mode=$($script:PlaybackMode) error=$($script:PlaybackError) message=$($script:PlaybackMessage) sawPlaying=$($script:PlaybackSawPlaying)")
    }
    Assert ($script:PlaybackMode -eq 'stopped' -and $script:PlaybackError -match 'nessun contenuto riproducibile') 'Corrupt-only rotation stops with error'
    # Generate a real MPEG-4 MP4 with the installed VLC, then exercise video and mixed playback.
    $inputUri = ([uri](Join-Path $folder 'Slide A.png')).AbsoluteUri
    $encoder = Start-Process -FilePath $vlc -WorkingDirectory $folder -WindowStyle Hidden -PassThru -ArgumentList @(
        '--ignore-config','--intf=dummy','--no-one-instance','--vout=dummy','--aout=dummy','--image-duration=2',
        '--sout=#transcode{vcodec=mp4v,vb=500,fps=25}:std{access=file,mux=mp4,dst=Generated.mp4}', '--play-and-exit', $inputUri)
    if (-not $encoder.WaitForExit(15000)) { $encoder.Kill(); throw 'Video fixture generation timed out.' }
    Assert ([IO.File]::Exists((Join-Path $folder 'Generated.mp4'))) 'Real MP4 fixture generated'
    Assert ((Get-Item (Join-Path $folder 'Generated.mp4')).Length -gt 100) 'MP4 contains encoded frames'
    Update-MediaItem $folder 'Corrupt.mp4' ([pscustomobject]@{ enabled = $false })
    Start-ControlledPlayback $vlc $folder 'Generated.mp4' @('--vout=dummy','--aout=dummy')
    Wait-Playback { $script:PlaybackCurrent -and $script:PlaybackCurrent.name -eq 'Generated.mp4' -and $script:PlaybackSawPlaying }
    Assert ($script:EmbeddedVlc.Length -ge 1000) 'MP4 duration detected'
    Stop-Playback
    Update-MediaItem $folder 'Slide A.png' ([pscustomobject]@{ enabled = $true; durationSeconds = 1 })
    Set-MediaOrder $folder @('Slide A.png','Generated.mp4','Corrupt.mp4')
    Start-ControlledPlayback $vlc $folder '' @('--vout=dummy','--aout=dummy')
    Wait-Playback { $script:PlaybackCurrent -and $script:PlaybackCurrent.name -eq 'Slide A.png' -and $script:PlaybackSawPlaying }
    $mixedWindow = $script:PlaybackSurface.window
    $mixedHwnd = (New-Object Windows.Interop.WindowInteropHelper($mixedWindow)).EnsureHandle()
    $mixedPlayer = $script:EmbeddedVlc.PlayerHandle
    Wait-Playback { $script:PlaybackCurrent -and $script:PlaybackCurrent.name -eq 'Generated.mp4' -and $script:PlaybackSawPlaying }
    $videoStarted = $script:PlaybackStarted
    Set-MediaSlideDuration $folder 1
    Update-PlaybackCatalog $folder
    Request-MediaDelete $folder 'Generated.mp4'
    Complete-MediaDeletes $folder 'Generated.mp4'
    Assert ([IO.File]::Exists((Join-Path $folder 'Generated.mp4'))) 'Playing video retained until completion'
    Update-PlaybackCatalog $folder
    Assert ($script:PlaybackCurrent.name -eq 'Generated.mp4') 'Video not cut by update'
    Wait-Playback { $script:PlaybackCurrent -and $script:PlaybackCurrent.name -eq 'Slide A.png' -and $script:PlaybackSawPlaying }
    Assert (([datetime]::UtcNow - $videoStarted).TotalSeconds -ge 1.5) 'Video completes before update'
    Assert ([object]::ReferenceEquals($script:PlaybackSurface.window,$mixedWindow)) 'Same fullscreen window for mixed content'
    Assert ((New-Object Windows.Interop.WindowInteropHelper($script:PlaybackSurface.window)).Handle -eq $mixedHwnd) 'Actual window HWND survives video-to-photo change'
    Assert (-not [IO.File]::Exists((Join-Path $folder 'Generated.mp4'))) 'Video file unlocked and deleted after completion'
    Assert ($script:EmbeddedVlc.PlayerHandle -eq $mixedPlayer) 'Same embedded player for mixed content'
    Stop-Playback
    Assert ($script:PlaybackMode -eq 'stopped' -and -not $script:PlaybackSurface -and -not $script:EmbeddedVlc) 'Immediate stop releases window and player'
    Write-Output 'PASS: photo duration, crossfade, persistent window, embedded VLC, real MP4, mixed playback, updates, deletion, corrupt files, stop.'
} finally {
    Stop-Playback
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project) + '\') -and (Split-Path -Leaf $resolved).StartsWith('.test-playback-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
