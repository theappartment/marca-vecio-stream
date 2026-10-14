param([switch]$Packaged,[switch]$NoStats)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $project ('.test-dissolves-'+[guid]::NewGuid().ToString('N'))
$ConfigRoot=Join-Path $testRoot 'data'
$folder=Join-Path $testRoot 'contents'
$AppRoot=Join-Path $project $(if($Packaged){'dist'}else{'src'})
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $AppRoot 'MediaCatalog.ps1')
. (Join-Path $AppRoot 'PlaybackSurface.ps1')
. (Join-Path $AppRoot 'PlaybackController.ps1')
function Stop-Playback { Stop-ControlledPlayback }
function Update-Status([string]$Message) { }
function Write-AppLog([string]$Message) { Write-Host $Message }
function Assert($Condition,[string]$Message) { if(-not $Condition){throw "FAIL: $Message"} }
function Pump([int]$Milliseconds) {
    $frame=New-Object Windows.Threading.DispatcherFrame
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick({$timer.Stop();$frame.Continue=$false})
    $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
    Update-PlaybackTransition
}
try {
    foreach($name in @('Photo A.jpg','Photo B.jpg')) { Copy-Item -LiteralPath (Join-Path $AppRoot 'assets\reel-background.jpg') -Destination (Join-Path $folder $name) }
    foreach($name in @('Video A.mp4','Video B.mp4','Reel A.mp4','Reel B.mp4')) {
        Copy-Item -LiteralPath 'C:\Users\Niccolo\Desktop\Diapo\snapgram.io_ybcxsfzzbqxq.mp4' -Destination (Join-Path $folder $name)
        if($name.StartsWith('Reel')) { Update-MediaItem $folder $name ([pscustomobject]@{role='reel'}) }
    }
    $options=@('--vout=dummy','--aout=dummy')
    if($NoStats){$options+='--no-stats'}
    Start-ControlledPlayback 'C:\Program Files\VideoLAN\VLC\vlc.exe' $folder 'Photo A.jpg' $options
    $window=$script:PlaybackSurface.window
    $pairs=@{}
    foreach($name in @('Photo B.jpg','Video A.mp4','Video B.mp4','Photo A.jpg','Reel A.mp4','Photo B.jpg','Reel A.mp4','Video A.mp4','Reel B.mp4','Reel A.mp4')) {
        $previous=$script:PlaybackCurrent.kind
        $count=$script:PlaybackSurface.transitionCount
        $script:PlaybackSelected=$name;$script:PlaybackMode='selected';$script:PlaybackAppliedSignature=''
        Move-PlaybackNext
        $pairs[$previous+'->'+$script:PlaybackCurrent.kind]=$true
        Assert ($script:PlaybackSurface.transitionCover.Source -and $script:PlaybackSurface.transitionCover.Visibility -eq [Windows.Visibility]::Visible) 'Previous frame remains above incoming media'
        $deadline=[datetime]::UtcNow.AddSeconds(8)
        while(-not $script:PlaybackSurface.transitionFading -and [datetime]::UtcNow -lt $deadline){ Update-ControlledPlayback;Pump 30 }
        Assert ($script:PlaybackSurface.transitionFading) 'Fade begins when incoming content is ready'
        Pump 180
        $opacity=$script:PlaybackSurface.transitionFade.Opacity
        Assert ($opacity -gt 0 -and $opacity -lt 1) 'Intermediate alpha blends old frame and new content'
        Pump 400
        Assert (-not $script:PlaybackSurface.transitionFading -and -not $script:PlaybackSurface.transitionCover.Source) 'Fade completes and releases snapshot'
        Assert ($script:PlaybackSurface.transitionCount -eq $count+1) 'One dissolve per boundary'
        Assert ([object]::ReferenceEquals($window,$script:PlaybackSurface.window)) 'Fullscreen player remains the same'
    }
    Assert ($pairs.Count -eq 9) 'All nine slide/video/reel boundary combinations exercised'
    $script:PlaybackSelected='Photo B.jpg';$script:PlaybackAppliedSignature='';Move-PlaybackNext
    Assert ($script:PlaybackSurface.transitionFading) 'Final boundary animating'
    Stop-Playback
    Pump 600
    Assert (-not $script:PlaybackSurface -and $script:ReelPlayers.Count -eq 0) 'Stop cancels overlay animation and releases player'
    Write-Host 'PASS: all nine media boundaries, prepared-content gate, intermediate opacity, completed dissolve, stable player, immediate stop during fade.'
} finally {
    Stop-Playback
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith($project+'\') -and [IO.Path]::GetFileName($resolved).StartsWith('.test-dissolves-')){ Remove-Item -LiteralPath $resolved -Recurse -Force }
}
