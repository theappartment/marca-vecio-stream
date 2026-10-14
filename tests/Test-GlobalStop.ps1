param([string]$FixtureVideoPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-global-stop-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'; $folder = Join-Path $testRoot 'contents'
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $project 'src\MediaCatalog.ps1')
. (Join-Path $project 'src\PlaybackSurface.ps1')
. (Join-Path $project 'src\PlaybackController.ps1')
function Update-Status([string]$Message) { }
function Write-AppLog([string]$Message) { }
function Stop-Playback { Stop-ControlledPlayback }
$script:ReturnedToApp = 0
function Show-ConfigurationWindow {
    if ($script:PlaybackSurface -or $script:EmbeddedVlc -or $script:PlaybackMode -ne 'stopped') { throw 'Configuration opened before stopping player.' }
    $script:ReturnedToApp++
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StopShortcutTest {
    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessage(IntPtr window, uint message, IntPtr parameter, IntPtr extra);
}
'@
function Pump-Ui([int]$Milliseconds) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Send-GlobalStop($Surface) {
    # Post the actual native hotkey message to an inactive, hidden window. No keys
    # are injected into the user's desktop and no foreground focus is required.
    Assert (-not $Surface.window.IsActive) 'Fullscreen window is not focused'
    Assert ([StopShortcutTest]::PostMessage($Surface.hotkeyHandle,0x0312,[IntPtr]$Surface.hotkeyId,[IntPtr]0x00530003)) 'Native hotkey message queued'
    Pump-Ui 100
    Assert ($script:PlaybackMode -eq 'stopped' -and -not $script:PlaybackSurface -and -not $script:EmbeddedVlc) 'Global shortcut closes fullscreen and stops playback'
    Assert (-not $Surface.hotkeyRegistered -and -not $Surface.escapeTimer.IsEnabled) 'Shortcut registration and listeners released'
}
$vlc = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
try {
    Add-Type -AssemblyName System.Drawing
    $image = New-Object Drawing.Bitmap(160,90)
    try { $image.Save((Join-Path $folder 'Slide.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
    Update-MediaItem $folder 'Slide.png' ([pscustomobject]@{ durationSeconds=300 })
    Start-ControlledPlayback $vlc $folder 'Slide.png' @('--vout=dummy','--aout=dummy')
    $interactiveRegistration = $true
    try { Register-PlaybackStopShortcut }
    catch {
        if ($_.Exception.InnerException -is [ComponentModel.Win32Exception] -and $_.Exception.InnerException.NativeErrorCode -eq 1459) {
            $interactiveRegistration = $false
            Write-Output 'SKIP: physical OS hotkey registration requires an interactive Windows desktop (1459). Testing the actual HWND message hook instead.'
        } else { throw }
    }
    $surface = $script:PlaybackSurface
    Assert ($surface.hotkeySource -and $surface.hotkeyHook) 'Native window message hook installed'
    # A second window cannot steal the same combination while playback is active.
    $other = New-Object Windows.Window
    $otherHandle = (New-Object Windows.Interop.WindowInteropHelper($other)).EnsureHandle()
    if ($interactiveRegistration) {
        $conflict = $false
        try { [MarcaVecio.PlaybackKeyboard]::RegisterStop($otherHandle,77) } catch { $conflict = $true }
        Assert $conflict 'Combination conflict is detected'
    }
    Send-GlobalStop $surface
    Assert ($script:ReturnedToApp -eq 1) 'Photo shortcut returns to configuration'
    # Registration is genuinely released, not just cleared in our state object.
    if ($interactiveRegistration) {
        [MarcaVecio.PlaybackKeyboard]::RegisterStop($otherHandle,77)
        [MarcaVecio.PlaybackKeyboard]::UnregisterStop($otherHandle,77)
    }
    $other.Close()

    if ($FixtureVideoPath) { Copy-Item -LiteralPath $FixtureVideoPath -Destination (Join-Path $folder 'Video.mp4') }
    else {
    $inputUri = ([uri](Join-Path $folder 'Slide.png')).AbsoluteUri
    $encoder = Start-Process -FilePath $vlc -WorkingDirectory $folder -WindowStyle Hidden -PassThru -ArgumentList @(
        '--intf=dummy','--no-one-instance','--vout=dummy','--aout=dummy','--image-duration=2',
        '--sout=#transcode{vcodec=mp4v,vb=500,fps=25}:std{access=file,mux=mp4,dst=Video.mp4}','--play-and-exit',$inputUri)
    if (-not $encoder.WaitForExit(10000)) { $encoder.Kill(); throw 'Video fixture generation timed out.' }
    }
    Start-ControlledPlayback $vlc $folder 'Video.mp4' @('--vout=dummy','--aout=dummy')
    $deadline=[datetime]::UtcNow.AddSeconds(5)
    while ($script:EmbeddedVlc.State -ne 3 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert ($script:EmbeddedVlc.State -eq 3) 'Video playing before shortcut'
    try { Register-PlaybackStopShortcut }
    catch {
        if ($interactiveRegistration -or $_.Exception.InnerException.NativeErrorCode -ne 1459) { throw }
    }
    Send-GlobalStop $script:PlaybackSurface
    Assert ($script:ReturnedToApp -eq 2) 'Video shortcut returns to configuration'
    Write-Output 'PASS: actual native hotkey message hook, inactive player window, photo/video stop, return to app, listener cleanup.'
} finally {
    Stop-Playback
    if (Get-Variable other -ErrorAction SilentlyContinue) { [MarcaVecio.PlaybackKeyboard]::UnregisterStop($otherHandle,77); $other.Close() }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project)+'\') -and (Split-Path -Leaf $resolved).StartsWith('.test-global-stop-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
