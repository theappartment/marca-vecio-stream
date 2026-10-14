Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PlaybackSurface.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PlaybackController.ps1')
function Update-Status([string]$Message){}
function Write-AppLog([string]$Message){}
function Stop-Playback {Stop-ControlledPlayback}
function Move-PlaybackNext {$script:TestMovedNext=$true}
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"}}
Initialize-PlaybackKeyboard
$fade=New-Object MarcaVecio.NativeTransitionFade
try {
    $fade.Start([IntPtr]::Zero,100)
    # Deliberately do not pump WPF: the fade must finish independently.
    Start-Sleep -Milliseconds 250
    Assert ($fade.Finished -and $fade.Opacity -eq 0) 'Fade finishes while UI dispatcher is idle'
    $fade.Start([IntPtr]::Zero,100)
    $fade.Stop()
    $fade.Start([IntPtr]::Zero,800)
    Start-Sleep -Milliseconds 200
    Assert (-not $fade.Finished -and $fade.Opacity -gt 0) 'Stale timer cannot finish the replacement transition'
    $fade.Start([IntPtr]1,800)
    Start-Sleep -Milliseconds 100
    Assert ($fade.Finished -and $fade.Faulted) 'Native alpha failure ends the fade worker instead of retaining an opaque cover'
    New-PlaybackSurface $true
    $surface=$script:PlaybackSurface
    Assert ($surface.transitionWindow -is [Windows.Forms.Form]) 'Native static-bitmap overlay replaces transparent WPF window'
    $surface.transitionWindow.SetFrame((New-Object byte[] (16*12*4)),16,12)
    Assert ($surface.transitionWindow.BackgroundImage.Width -eq 16 -and $surface.transitionWindow.BackgroundImage.Height -eq 12) 'Native frame uploaded once with correct dimensions'
    $surface.transitionWindow.ReleaseFrame()
    Assert (-not $surface.transitionWindow.BackgroundImage) 'Native snapshot bitmap released after transition'
    $surface.transitionCover.Visibility=[Windows.Visibility]::Visible
    Start-PlaybackDissolve
    $surface.transitionStarted=[datetime]::UtcNow.AddSeconds(-2)
    Update-PlaybackTransition
    Assert (-not $surface.transitionFading -and $surface.transitionCover.Visibility -eq [Windows.Visibility]::Collapsed) 'Watchdog removes stuck cover without a completion callback'
    Assert ($surface.transitionFade.Finished) 'Watchdog cancels native fade worker'
    $script:EmbeddedVlc=[pscustomobject]@{State=3;Length=300000;Time=1000}
    $script:EmbeddedVlc | Add-Member ScriptMethod FrameReady {param($Headless) return $false}
    $script:EmbeddedVlc | Add-Member ScriptMethod Dispose {}
    $script:PlaybackMode='rotation'
    $script:PlaybackCurrent=[pscustomobject]@{name='Hung.mp4';kind='video'}
    $script:PlaybackStarted=[datetime]::UtcNow.AddSeconds(-9)
    $script:TestMovedNext=$false
    Update-ControlledPlayback
    Assert ($script:TestMovedNext -and $script:PlaybackFailed.ContainsKey('Hung.mp4')) 'Unready long video skipped after bounded wait'
    $script:EmbeddedVlc.State=6
    $script:PlaybackCurrent=[pscustomobject]@{name='No frames.mp4';kind='video'}
    $script:PlaybackStarted=[datetime]::UtcNow
    $script:TestMovedNext=$false
    Update-ControlledPlayback
    Assert ($script:TestMovedNext -and $script:PlaybackFailed.ContainsKey('No frames.mp4')) 'Short video without frames cannot repeat indefinitely'
    $oldSurface=$script:PlaybackSurface
    $slowPlayer=[pscustomobject]@{stopTask=[Threading.Tasks.Task]::Delay(400);deferred=$false}
    $slowPlayer | Add-Member ScriptMethod BeginStop {return $this.stopTask}
    $slowPlayer | Add-Member ScriptMethod DisposeAfterStop {$this.deferred=$true}
    $slowPlayer | Add-Member ScriptMethod Dispose {}
    $script:EmbeddedVlc=$slowPlayer
    $stopWatch=[Diagnostics.Stopwatch]::StartNew()
    Stop-ControlledPlayback
    Assert ($stopWatch.ElapsedMilliseconds -lt 250 -and -not $script:PlaybackSurface -and $slowPlayer.deferred) 'Stop returns before delayed decoder teardown'
    New-PlaybackSurface $true
    $newSurface=$script:PlaybackSurface
    $script:PlaybackMode='rotation'
    $uiFrame=New-Object Windows.Threading.DispatcherFrame
    $uiTimer=New-Object Windows.Threading.DispatcherTimer
    $uiTimer.Interval=[TimeSpan]::FromMilliseconds(650)
    $uiTimer.Add_Tick({$uiTimer.Stop();$uiFrame.Continue=$false})
    $uiTimer.Start();[Windows.Threading.Dispatcher]::PushFrame($uiFrame)
    Assert ($oldSurface.closed -and [object]::ReferenceEquals($newSurface,$script:PlaybackSurface) -and $script:PlaybackMode -eq 'rotation') 'Deferred close of old player does not stop replacement playback'
    $delayed=[pscustomobject]@{stopTask=[Threading.Tasks.Task]::Delay(200)}
    $delayed | Add-Member ScriptMethod BeginStop {return $this.stopTask}
    $script:InjectedStopFailure=$null
    try {Stop-NativePlayer $delayed 20} catch {$script:InjectedStopFailure=$_.Exception}
    Assert ($script:InjectedStopFailure -and $script:InjectedStopFailure.Data.Contains('PlaybackStopTimeout')) 'Decoder teardown has a bounded timeout'
    function Move-PlaybackNext {throw $script:InjectedStopFailure}
    $script:EmbeddedVlc=[pscustomobject]@{State=6;Length=1}
    $script:EmbeddedVlc | Add-Member ScriptMethod Dispose {}
    $script:PlaybackCurrent=[pscustomobject]@{name='Stuck decoder.mp4';kind='video'}
    $script:PlaybackReady=$true;$script:PlaybackControlFailures=0
    Update-ControlledPlayback
    Assert ($script:PlaybackMode -eq 'stopped' -and $script:PlaybackControlFailures -eq 1) 'Stuck decoder closes playback on first timeout rather than retrying indefinitely'
    Write-Host 'PASS: independent fade timing, stale callback protection, deadline recovery and worker cleanup.'
} finally {$fade.Dispose();Close-PlaybackSurface}
