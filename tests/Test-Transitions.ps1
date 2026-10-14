Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-transition-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
. (Join-Path $project 'src\PlaybackSurface.ps1')
function Stop-Playback { Close-PlaybackSurface }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Pump-Ui([int]$Milliseconds) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Sample-Center {
    $grid = $script:PlaybackSurface.grid
    $grid.Measure((New-Object Windows.Size(320,180)))
    $grid.Arrange((New-Object Windows.Rect(0,0,320,180)))
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(320,180,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($grid)
    $pixel = New-Object byte[] 4
    $bitmap.CopyPixels((New-Object Windows.Int32Rect(160,90,1,1)), $pixel, 4, 0)
    return $pixel
}
try {
    Add-Type -AssemblyName System.Drawing
    foreach ($color in @('Red','Blue')) {
        $image = New-Object Drawing.Bitmap(320,180)
        $graphics = [Drawing.Graphics]::FromImage($image)
        try { $graphics.Clear([Drawing.Color]::FromName($color)); $image.Save((Join-Path $testRoot "$color.png"),[Drawing.Imaging.ImageFormat]::Png) }
        finally { $graphics.Dispose(); $image.Dispose() }
    }
    New-PlaybackSurface $true
    $window = $script:PlaybackSurface.window
    # Detach only in this offscreen pixel test: an unshown Window suppresses its
    # children's rendering. Production keeps this grid in the visible Window.
    $window.Content = $null
    Show-PlaybackSlide (Join-Path $testRoot 'Red.png')
    $red = Sample-Center
    Assert ($red[2] -gt 245 -and $red[0] -lt 10) 'First photo renders without a VLC window'
    Show-PlaybackSlide (Join-Path $testRoot 'Blue.png')
    Assert ($script:PlaybackSurface.layers[$script:PlaybackSurface.front].HasAnimatedProperties) 'Second photo starts opacity animation'
    Pump-Ui 210
    $middle = Sample-Center
    Assert ($middle[0] -gt 15 -and $middle[2] -gt 15 -and $middle[3] -eq 255) 'Crossfade renders both photos with an opaque background'
    Pump-Ui 400
    $blue = Sample-Center
    Assert ($blue[0] -gt 245 -and $blue[2] -lt 10) 'Crossfade finishes on next photo'
    Assert ([object]::ReferenceEquals($window,$script:PlaybackSurface.window)) 'Same window throughout transition'
    [IO.File]::Delete((Join-Path $testRoot 'Red.png'))
    [IO.File]::Delete((Join-Path $testRoot 'Blue.png'))
    Assert (@(Get-ChildItem $testRoot -File).Count -eq 0) 'Rendered images do not lock their originals'
    Write-Output 'PASS: rendered red / blended / blue frames, 450ms crossfade, opaque surface, same window, no image locks.'
} finally {
    Close-PlaybackSurface
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project) + '\') -and (Split-Path -Leaf $resolved).StartsWith('.test-transition-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
