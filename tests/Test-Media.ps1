Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project ('.test-media-' + [guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $testRoot 'data'
$folder = Join-Path $testRoot 'contents'
[IO.Directory]::CreateDirectory($folder) | Out-Null
. (Join-Path $project 'src\MediaCatalog.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Expect-Error([scriptblock]$Action, [int]$Status = 400) {
    $failed = $false
    try { & $Action } catch { $failed = $true; Assert ($_.Exception.Data['HttpStatus'] -eq $Status) ('HTTP status: ' + $_.Exception.Message) }
    Assert $failed 'Expected an error'
}
try {
    Add-Type -AssemblyName System.Drawing
    $image = New-Object Drawing.Bitmap(32,20)
    $eventName = 'Evento ' + [char]0x00e8 + ' importante.png'
    try { $image.Save((Join-Path $folder $eventName), [Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
    [IO.File]::WriteAllText((Join-Path $folder 'video montato.mp4'), 'test-video')
    [IO.File]::WriteAllText((Join-Path $folder 'A normale.jpg'), 'placeholder')
    $view = Get-MediaView $folder
    Assert ($view.items.Count -eq 3) 'Import existing files'
    Assert ($view.priorityFrequency -eq 2) 'Default frequency'
    Assert (($view.items.name -join '|') -eq "A normale.jpg|$eventName|video montato.mp4") 'Existing alphabetical order'
    Assert ((@(Get-MediaRotation $view).name -join '|') -eq ($view.items.name -join '|')) 'Normal content respects user order'
    Update-MediaItem $folder $eventName ([pscustomobject]@{ priority = $true; durationSeconds = 2 })
    for ($frequency = 2; $frequency -le 5; $frequency++) {
        Set-MediaFrequency $folder $frequency
        $rotation = @(Get-MediaRotation (Get-MediaView $folder))
        Assert (@($rotation | Where-Object name -eq $eventName).Count -eq $frequency) 'Priority occurrences'
        Assert (@($rotation | Where-Object name -eq 'video montato.mp4').Count -eq 1) 'Video occurs once'
    }
    Set-MediaOrder $folder @('video montato.mp4',$eventName,'A normale.jpg')
    $reloaded = Get-MediaView $folder
    Assert ($reloaded.items[0].name -eq 'video montato.mp4') 'Persisted user order'
    Assert ($reloaded.items[1].durationSeconds -eq 2 -and $reloaded.items[1].priority) 'Persisted metadata'
    $oldCatalog = Get-MediaCatalog $folder
    $oldCatalog.PSObject.Properties.Remove('slideDurationSeconds')
    Write-MediaJson (Get-MediaCatalogIdentity $folder).path $oldCatalog
    $migrated = Get-MediaView $folder
    Assert ($migrated.slideDurationSeconds -eq 10 -and $migrated.items[1].durationSeconds -eq 2) 'Old catalog migration preserves individual durations'
    Set-MediaSlideDuration $folder 7
    $globalView = Get-MediaView $folder
    Assert ($globalView.slideDurationSeconds -eq 7) 'Global duration persisted'
    Assert (@($globalView.items | Where-Object { $_.kind -eq 'slide' -and $_.durationSeconds -ne 7 }).Count -eq 0) 'All images updated together'
    Assert (($globalView.items | Where-Object kind -eq 'video').durationSeconds -eq 10) 'Video metadata untouched'
    Expect-Error { Set-MediaSlideDuration $folder 0 }
    Expect-Error { Set-MediaSlideDuration $folder 301 }
    Expect-Error { Set-MediaSlideDuration $folder 1.5 }
    Expect-Error { Set-MediaSlideDuration $folder $true }
    Expect-Error { Set-MediaFrequency $folder 1 }
    Expect-Error { Set-MediaFrequency $folder 2.5 }
    Expect-Error { Update-MediaItem $folder $eventName ([pscustomobject]@{ durationSeconds = 301 }) }
    Expect-Error { Update-MediaItem $folder 'video montato.mp4' ([pscustomobject]@{ priority = $true }) }
    Expect-Error { Update-MediaItem $folder 'video montato.mp4' ([pscustomobject]@{ enabled = 'false' }) }
    Expect-Error { Set-MediaOrder $folder @('video montato.mp4') } 409
    Expect-Error { Get-MediaName '..\secret.png' }
    Expect-Error { Get-MediaName 'CON.png' }
    $stream = [IO.File]::OpenRead((Join-Path $folder $eventName))
    try {
        Save-MediaStream $folder 'Nuova slide.png' $stream $stream.Length | Out-Null
        Assert (((Get-MediaView $folder).items | Where-Object name -eq 'Nuova slide.png').durationSeconds -eq 7) 'New uploads inherit global duration'
        Assert (-not ((Get-MediaView $folder).items | Where-Object name -eq 'Nuova slide.png').priority) 'Default upload goes into normal loop'
        $stream.Position = 0
        Save-MediaStream $folder 'Promo caricata.png' $stream $stream.Length $true | Out-Null
        $uploadedPromo = (Get-MediaView $folder).items | Where-Object name -eq 'Promo caricata.png'
        Assert ($uploadedPromo.priority -and $uploadedPromo.enabled -and $uploadedPromo.durationSeconds -eq 7) 'Promo category saved together with upload'
        $stream.Position = 0
        Expect-Error { Save-MediaStream $folder 'Video promo.mp4' $stream $stream.Length $true }
        $stream.Position = 0
        Expect-Error { Save-MediaStream $folder 'Nuova slide.png' $stream $stream.Length } 409
        $stream.Position = 0
        Expect-Error { Save-MediaStream $folder 'Interrotta.png' $stream ($stream.Length + 1) }
    } finally { $stream.Dispose() }
    Assert (-not [IO.File]::Exists((Join-Path $folder 'Interrotta.png'))) 'Partial upload invisible'
    Assert (@(Get-ChildItem $folder -Filter '.upload-*').Count -eq 0) 'Upload temporary cleanup'
    $badStream = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes('corrupt'))
    try { Expect-Error { Save-MediaStream $folder 'Corrotta.jpg' $badStream } } finally { $badStream.Dispose() }
    Request-MediaDelete $folder $eventName
    Complete-MediaDeletes $folder $eventName
    Assert ([IO.File]::Exists((Join-Path $folder $eventName))) 'Playing file deletion deferred'
    Assert (@(Get-MediaRotation (Get-MediaView $folder) | Where-Object name -eq $eventName).Count -eq 0) 'Pending deletion excluded'
    Complete-MediaDeletes $folder
    Assert (-not [IO.File]::Exists((Join-Path $folder $eventName))) 'Deletion completed at boundary'
    foreach ($item in (Get-MediaView $folder).items) { Update-MediaItem $folder $item.name ([pscustomobject]@{ enabled = $false }) }
    Assert (@(Get-MediaRotation (Get-MediaView $folder)).Count -eq 0) 'No enabled content'
    $otherFolder = Join-Path $testRoot 'other'; [IO.Directory]::CreateDirectory($otherFolder) | Out-Null
    Assert ((Get-MediaCatalogIdentity $folder).path -ne (Get-MediaCatalogIdentity $otherFolder).path) 'Separate catalogs per folder'
    for ($frequency = 2; $frequency -le 5; $frequency++) {
        $virtual = [pscustomobject]@{ priorityFrequency = $frequency; items = @(
            [pscustomobject]@{ name = 'P1'; kind = 'slide'; enabled = $true; priority = $true; pendingDelete = $false },
            [pscustomobject]@{ name = 'P2'; kind = 'slide'; enabled = $true; priority = $true; pendingDelete = $false },
            [pscustomobject]@{ name = 'N1'; kind = 'video'; enabled = $true; priority = $false; pendingDelete = $false },
            [pscustomobject]@{ name = 'N2'; kind = 'slide'; enabled = $true; priority = $false; pendingDelete = $false }
        ) }
        $sequence = @(Get-MediaRotation $virtual)
        Assert ($sequence.Count -eq ($frequency * 2 + 2)) 'Mixed weights total'
        for ($i=0; $i -lt $sequence.Count; $i++) { Assert ($sequence[$i].name -ne $sequence[($i+1) % $sequence.Count].name) 'No adjacent duplicates including cycle boundary' }
        $virtual.items = @($virtual.items[0])
        Assert (@(Get-MediaRotation $virtual).Count -eq $frequency) 'One active priority slide'
    }
    Write-Output 'PASS: migration, metadata, frequency 2-5, order, upload, validation, deletion, persistence.'
    $signatures = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($frequency in @(2,3,4,5)) {
        for ($seed=1; $seed -le 12; $seed++) {
            Get-Random -SetSeed $seed | Out-Null
            $randomView = [pscustomobject]@{ priorityFrequency=$frequency; items=@() }
            foreach ($name in @('P1','P2','P3')) { $randomView.items += [pscustomobject]@{name=$name;kind='slide';priority=$true;enabled=$true;pendingDelete=$false} }
            foreach ($number in @(1..7)) { $randomView.items += [pscustomobject]@{name="N$number";kind='video';priority=$false;enabled=$true;pendingDelete=$false} }
            $rotation = @(Get-MediaRotation $randomView)
            foreach ($name in @('P1','P2','P3')) { Assert (@($rotation | Where-Object name -eq $name).Count -eq $frequency) 'Each random promo retains exact frequency' }
            Assert ((@($rotation | Where-Object { -not $_.priority }).name -join ',') -eq 'N1,N2,N3,N4,N5,N6,N7') 'Base content order preserved between random promos'
            for ($i=0; $i -lt $rotation.Count; $i++) { Assert ($rotation[$i].name -ne $rotation[($i+1)%$rotation.Count].name) 'Random promos do not repeat consecutively' }
            $signatures.Add(($rotation.name -join ',')) | Out-Null
        }
    }
    Assert ($signatures.Count -gt 4) 'Different rounds produce different random sequences'
    Write-Output 'PASS: randomized promos, exact weights 2-5, ordered base loop, no adjacent duplicates, varied rounds across 48 seeded scenarios.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($project) + '\') -and (Split-Path -Leaf $resolved).StartsWith('.test-media-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
