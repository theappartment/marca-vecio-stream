param([string]$FixtureVideoPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-escape-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'
$folder = Join-Path $testRoot 'contents'
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $project 'src\MediaCatalog.ps1')
. (Join-Path $project 'src\PlaybackSurface.ps1')
. (Join-Path $project 'src\PlaybackController.ps1')
function Update-Status([string]$Message) { }
function Write-AppLog([string]$Message) { }
function Stop-Playback { Stop-ControlledPlayback }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Send-WpfKey($Window, [Windows.Input.Key]$Key) {
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($Window)).EnsureHandle()
    $source = [Windows.Interop.HwndSource]::FromHwnd($hwnd)
    $event = New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice,$source,[Environment]::TickCount,$Key)
    $event.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
    $Window.RaiseEvent($event)
    return $event
}
function Assert-Stopped($Surface) {
    Assert ($script:PlaybackMode -eq 'stopped') 'Escape stops playback immediately'
    Assert (-not $script:PlaybackSurface -and -not $script:EmbeddedVlc) 'Escape releases fullscreen and native player'
    Assert (-not $Surface.escapeTimer.IsEnabled) 'Escape listener released with playback'
    Assert (-not (Get-Process -Id $PID).HasExited) 'Host application remains alive'
}
$vlc = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
try {
    Add-Type -AssemblyName System.Drawing
    $image = New-Object Drawing.Bitmap(160,90)
    try { $image.Save((Join-Path $folder 'Slide.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
    Update-MediaItem $folder 'Slide.png' ([pscustomobject]@{ durationSeconds = 300 })
    Start-ControlledPlayback $vlc $folder '' @('--vout=dummy','--aout=dummy')
    $surface = $script:PlaybackSurface
    Send-WpfKey $surface.window ([Windows.Input.Key]::A) | Out-Null
    Assert ($script:PlaybackMode -ne 'stopped') 'Other keys do not stop photo playback'
    $event = Send-WpfKey $surface.window ([Windows.Input.Key]::Escape)
    Assert $event.Handled 'WPF Escape is consumed'
    Assert-Stopped $surface

    # Exercise the native video host, without sending keys to the user's desktop.
    if ($FixtureVideoPath) { Copy-Item -LiteralPath $FixtureVideoPath -Destination (Join-Path $folder 'Video.mp4') }
    else {
    $inputUri = ([uri](Join-Path $folder 'Slide.png')).AbsoluteUri
    $encoder = Start-Process -FilePath $vlc -WorkingDirectory $folder -WindowStyle Hidden -PassThru -ArgumentList @(
        '--intf=dummy','--no-one-instance','--vout=dummy','--aout=dummy','--image-duration=2',
        '--sout=#transcode{vcodec=mp4v,vb=500,fps=25}:std{access=file,mux=mp4,dst=Video.mp4}','--play-and-exit',$inputUri)
    if (-not $encoder.WaitForExit(10000)) { $encoder.Kill(); throw 'Video fixture generation timed out.' }
    }
    Start-ControlledPlayback $vlc $folder 'Video.mp4' @('--vout=dummy','--aout=dummy')
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while ($script:EmbeddedVlc.State -ne 3 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert ($script:EmbeddedVlc.State -eq 3) 'Video playing before keyboard test'
    $surface = $script:PlaybackSurface
    $method = $surface.videoPanel.GetType().GetMethod('OnKeyDown',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
    $event = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Escape)
    $parameters = New-Object object[] 1
    $parameters[0] = $event.PSObject.BaseObject
    $method.Invoke($surface.videoPanel.PSObject.BaseObject, $parameters) | Out-Null
    Assert ($event.Handled -and $event.SuppressKeyPress) 'Embedded video Escape is consumed'
    Assert-Stopped $surface

    # Native VLC children may bypass both managed key handlers. Test the timer's
    # fallback against a controlled key-state probe rather than injecting OS keys.
    Start-ControlledPlayback $vlc $folder 'Slide.png' @('--vout=dummy','--aout=dummy')
    $surface = $script:PlaybackSurface
    function Test-PlaybackEscapePressed { return $false }
    Update-PlaybackKeyboard
    Assert ($script:PlaybackMode -ne 'stopped') 'Inactive key-state probe does not stop playback'
    function Test-PlaybackEscapePressed { return $true }
    Update-PlaybackKeyboard
    Assert-Stopped $surface
    Update-PlaybackKeyboard
    Write-Output 'PASS: photo Escape, embedded-video Escape, native-focus fallback, other keys ignored, timer cleanup, host remains open.'
} finally {
    Stop-Playback
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project) + '\') -and (Split-Path -Leaf $resolved).StartsWith('.test-escape-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
