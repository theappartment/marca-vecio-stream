param([switch]$Compiled,[string]$PreviewVideoPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-server-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'MarcaVecioStream'
$folder = Join-Path $testRoot 'contents'
[IO.Directory]::CreateDirectory($folder) | Out-Null
[IO.Directory]::CreateDirectory($ConfigRoot) | Out-Null
. (Join-Path $project 'src\MediaCatalog.ps1')
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$cfg = @{ videoFolder = $folder; vlcPath = 'C:\Program Files\VideoLAN\VLC\vlc.exe'; webEnabled = $true; webPort = $port; remoteToken = 'test-secret';
    autoStartPlayback = $false; kioskMode = $false; launchOnLogin = $false; telegramEnabled = $false; ngrokEnabled = $false }
Write-MediaJson (Join-Path $ConfigRoot 'config.json') $cfg
$server = $null
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Request([string]$Path, [string]$Method = 'GET', [byte[]]$Bytes = @(), [string]$Token = 'test-secret') {
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port$Path"); $req.Proxy = $null; $req.Method = $Method; $req.Timeout = 10000
    if ($Token) { $req.Headers['X-Auth-Token'] = $Token }
    if ($Method -in @('POST','PATCH')) {
        $req.ContentType = 'application/json'; $req.ContentLength = $Bytes.Length
        $stream = $req.GetRequestStream(); try { $stream.Write($Bytes,0,$Bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $null
    try { $response = $req.GetResponse() } catch [Net.WebException] { if (-not $_.Exception.Response) { throw }; $response = $_.Exception.Response }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return @{ status = [int]$response.StatusCode; body = $body }
    } finally { $response.Dispose() }
}
function JsonBytes($Object) { return [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 5)) }
try {
    $info = New-Object Diagnostics.ProcessStartInfo
    if ($Compiled) { $info.FileName = Join-Path $project 'dist\WebServer.exe' }
    else { $info.FileName = 'powershell.exe'; $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $project 'src\WebServer.ps1') + '"' }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.EnvironmentVariables['APPDATA'] = $testRoot
    $info.EnvironmentVariables.Remove('PSExecutionPolicyPreference')
    $server = [Diagnostics.Process]::Start($info)
    $ready = $false
    for ($i=0; $i -lt 30; $i++) {
        try { $response = Request '/api/status'; if ($response.status -eq 200) { $ready = $true; break } } catch { }
        if ($server.HasExited) { throw 'Web server exited unexpectedly.' }
        Start-Sleep -Milliseconds 100
    }
    Assert $ready 'Server starts'
    $panel = Request '/'
    Assert ($panel.status -eq 200 -and $panel.body.Contains('priorityFrequency')) 'Updated web panel served'
    Assert ((Request '/api/status' 'GET' @() '').status -eq 401) 'Status authentication'
    Assert ((Request '/api/preview?name=Slide.png' 'GET' @() '').status -eq 401) 'Preview authentication'
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap(16,16)
    $buffer = New-Object IO.MemoryStream
    try { $bitmap.Save($buffer,[Drawing.Imaging.ImageFormat]::Png); $bytes = $buffer.ToArray() } finally { $bitmap.Dispose(); $buffer.Dispose() }
    Assert ((Request '/api/upload?filename=Slide.png' 'POST' $bytes).status -eq 200) 'Image upload'
    Assert ((Request '/api/upload?filename=Slide.png' 'POST' $bytes).status -eq 409) 'Duplicate upload rejected'
    Assert ((Request '/api/upload?filename=Broken.png' 'POST' ([Text.Encoding]::UTF8.GetBytes('broken'))).status -eq 400) 'Corrupt upload rejected'
    Assert ((Request '/api/content?name=Slide.png' 'PATCH' (JsonBytes @{ priority = $true; durationSeconds = 3 })).status -eq 200) 'Metadata update'
    Assert ((Request '/api/content?name=Slide.png' 'PATCH' (JsonBytes @{ durationSeconds = 0 })).status -eq 400) 'Duration validation'
    Assert ((Request '/api/rotation' 'POST' (JsonBytes @{ priorityFrequency = 4 })).status -eq 200) 'Global frequency update'
    $status = (Request '/api/status').body | ConvertFrom-Json
    Assert ($status.priorityFrequency -eq 4 -and $status.files[0].priority -and $status.files[0].durationSeconds -eq 3) 'Fresh status metadata'
    Assert ((Request '/api/slide-duration' 'POST' (JsonBytes @{ slideDurationSeconds = 8 })).status -eq 200) 'Global image duration update'
    Assert ((Request '/api/slide-duration' 'POST' (JsonBytes @{ slideDurationSeconds = 0 })).status -eq 400) 'Global image duration validation'
    $status = (Request '/api/status').body | ConvertFrom-Json
    Assert ($status.slideDurationSeconds -eq 8 -and $status.files[0].durationSeconds -eq 8) 'Global image duration reflected in status'
    Assert ((Request '/api/preview?name=Slide.png').status -eq 200) 'Authenticated preview'
    Assert ((Request '/api/order' 'POST' (JsonBytes @{ names = @('Slide.png') })).status -eq 200) 'Reorder endpoint'
    Assert ((Request '/api/order' 'POST' (JsonBytes @{ names = @() })).status -eq 409) 'Stale order rejected'
    Assert ((Request '/api/play-all' 'POST').status -eq 200) 'Existing play endpoint'
    Assert ((Request '/api/stop' 'POST').status -eq 200) 'Existing stop endpoint'
    Assert ((Request '/api/files?name=Slide.png' 'DELETE').status -eq 200) 'Deferred delete endpoint'
    Assert (((Request '/api/status').body | ConvertFrom-Json).files[0].pendingDelete) 'Pending deletion in status'
    Assert ((Request '/api/upload?filename=Promo.png&priority=true' 'POST' $bytes).status -eq 200) 'Promo chosen during upload'
    Assert ((Request '/api/upload?filename=Loop.png&priority=false' 'POST' $bytes).status -eq 200) 'Normal loop chosen during upload'
    Assert ((Request '/api/upload?filename=Invalid.png&priority=wrong' 'POST' $bytes).status -eq 400) 'Invalid upload category rejected'
    Assert ((Request '/api/upload?filename=Video.mp4&priority=true' 'POST' $bytes).status -eq 400) 'Video promo request rejected'
    $files = ((Request '/api/status').body | ConvertFrom-Json).files
    Assert (($files | Where-Object name -eq 'Promo.png').priority) 'Uploaded promo immediately marked priority'
    Assert (-not ($files | Where-Object name -eq 'Loop.png').priority) 'Uploaded normal image remains in base loop'
    Assert ((Request '/api/upload?filename=Reel.mp4&role=reel' 'POST' $bytes).status -eq 200) 'Reel upload classification'
    Assert ((Request '/api/upload?filename=Background.png&role=background' 'POST' $bytes).status -eq 200) 'Background upload classification'
    Assert ((Request '/api/upload?filename=Bad.png&role=reel' 'POST' $bytes).status -eq 400) 'Photo rejected as reel'
    Assert ((Request '/api/upload?filename=Bad.mp4&role=background' 'POST' $bytes).status -eq 400) 'Video rejected as background'
    Assert ((Request '/api/upload?filename=Bad.mp4&role=wrong' 'POST' $bytes).status -eq 400) 'Invalid role rejected'
    Assert ((Request '/api/preview?name=Background.png' 'GET' @() '').status -eq 401) 'Background preview protected'
    Assert ((Request '/api/preview?name=Background.png').status -eq 200) 'Background preview available'
    $files = ((Request '/api/status').body | ConvertFrom-Json).files
    Assert (($files | Where-Object name -eq 'Reel.mp4').kind -eq 'reel') 'Reel status'
    Assert (($files | Where-Object name -eq 'Background.png').kind -eq 'background') 'Background status'
    Assert ((Request '/api/content?name=Reel.mp4' 'PATCH' (JsonBytes @{ role='loop' })).status -eq 200) 'Convert reel to full-length normal video'
    Assert ((Request '/api/content?name=Loop.png' 'PATCH' (JsonBytes @{ role='background' })).status -eq 200) 'Select another background'
    $files = ((Request '/api/status').body | ConvertFrom-Json).files
    Assert (-not ($files | Where-Object name -eq 'Background.png').enabled) 'Previous background deactivated'
    if ($PreviewVideoPath) {
        Assert ((Request '/api/upload?filename=Preview.mp4&role=reel' 'POST' ([IO.File]::ReadAllBytes($PreviewVideoPath))).status -eq 200) 'Upload real reel for preview'
        Assert ((Request '/api/preview?name=Preview.mp4' 'GET' @() '').status -eq 401) 'Video preview authentication'
        Assert ((Request '/api/preview?name=Preview.mp4').status -eq 200) 'Actual video thumbnail served'
        Assert ((Request '/api/preview?name=Preview.mp4').status -eq 200) 'Cached video preview served'
        Assert ((Request '/api/content?name=Preview.mp4' 'PATCH' (JsonBytes @{ role='loop' })).status -eq 200) 'Normal video category'
        Assert ((Request '/api/preview?name=Preview.mp4').status -eq 200) 'Normal video thumbnail served'
    }
    Write-Output "PASS: HTTP authentication, upload, preview, metadata, rotation, reorder, compatibility; compiled=$Compiled"
} finally {
    if ($server -and -not $server.HasExited) { $server.Kill(); $server.WaitForExit(3000) | Out-Null }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project) + '\') -and (Split-Path -Leaf $resolved).StartsWith('.test-server-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
