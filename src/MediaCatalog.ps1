# Shared by the Windows player and the HTTP server. Keep compatible with PowerShell 5.1.
$script:MediaExtensions = @('.mp4','.mkv','.avi','.mov','.wmv','.m4v','.webm','.jpg','.jpeg','.png')

function Throw-MediaError([string]$Message, [int]$Status = 400) {
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['HttpStatus'] = $Status
    throw $exception
}

function Get-MediaName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -ne [IO.Path]::GetFileName($Name) -or
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Name.EndsWith('.') -or $Name.EndsWith(' ') -or
        [IO.Path]::GetFileNameWithoutExtension($Name) -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or
        $script:MediaExtensions -notcontains [IO.Path]::GetExtension($Name).ToLowerInvariant()) {
        Throw-MediaError 'Nome file o formato non valido.'
    }
    return $Name
}

function Get-MediaFiles([string]$Folder) {
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not [IO.Directory]::Exists($Folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $Folder -File | Where-Object {
        $script:MediaExtensions -contains $_.Extension.ToLowerInvariant() -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | Sort-Object Name)
}

function Get-MediaCatalogIdentity([string]$Folder) {
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not [IO.Directory]::Exists($Folder)) { Throw-MediaError 'Seleziona una cartella contenuti valida.' }
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full)))).Replace('-','') } finally { $sha.Dispose() }
    $root = Join-Path $ConfigRoot 'catalogs'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    return @{ path = (Join-Path $root "$key.json"); mutex = "Local\MarcaVecioMedia$key"; folder = $full }
}

function Write-MediaJson([string]$Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            $backup = "$Path.bak"
            [IO.File]::Replace($temp, $Path, $backup)
            [IO.File]::Delete($backup)
        } else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Invoke-MediaCatalog([string]$Folder, [scriptblock]$Action) {
    $identity = Get-MediaCatalogIdentity $Folder
    $mutex = New-Object Threading.Mutex($false, $identity.mutex)
    $held = $false
    try {
        try { $held = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { Throw-MediaError 'Catalogo occupato, riprova.' 409 }
        if ([IO.File]::Exists($identity.path)) {
            $catalog = [IO.File]::ReadAllText($identity.path) | ConvertFrom-Json
            if ($catalog.version -ne 1 -or $catalog.folder -ne $identity.folder -or $catalog.priorityFrequency -lt 2 -or $catalog.priorityFrequency -gt 5) {
                Throw-MediaError 'Catalogo non valido. Il file originale e stato conservato.' 500
            }
        } else {
            $catalog = [pscustomobject]@{ version = 1; folder = $identity.folder; priorityFrequency = 2; slideDurationSeconds = 10; items = @() }
        }
        $before = $catalog | ConvertTo-Json -Depth 10 -Compress
        if (-not $catalog.PSObject.Properties['slideDurationSeconds']) {
            $catalog | Add-Member -NotePropertyName slideDurationSeconds -NotePropertyValue 10
        }
        if ($catalog.slideDurationSeconds -is [bool] -or $catalog.slideDurationSeconds -lt 1 -or $catalog.slideDurationSeconds -gt 300 -or
            [math]::Floor($catalog.slideDurationSeconds) -ne $catalog.slideDurationSeconds) { Throw-MediaError 'Durata globale del catalogo non valida.' 500 }
        $files = @(Get-MediaFiles $Folder)
        $byName = @{}
        foreach ($file in $files) { $byName[$file.Name] = $file }
        $items = New-Object 'Collections.Generic.List[object]'
        $seen = @{}
        foreach ($item in @($catalog.items)) {
            if ($byName.ContainsKey($item.name) -and -not $seen.ContainsKey($item.name)) {
                $items.Add($item); $seen[$item.name] = $true
            }
        }
        foreach ($file in $files) {
            if (-not $seen.ContainsKey($file.Name)) {
                $duration = if ($file.Extension -match '^\.(jpg|jpeg|png)$') { $catalog.slideDurationSeconds } else { 10 }
                $items.Add([pscustomobject]@{ name = $file.Name; enabled = $true; priority = $false; durationSeconds = $duration; pendingDelete = $false })
            }
        }
        $catalog.items = @($items.ToArray())
        foreach ($item in $catalog.items) {
            if (-not $item.PSObject.Properties['role']) { $item | Add-Member role 'loop' }
        }
        $result = & $Action $catalog
        $after = $catalog | ConvertTo-Json -Depth 10 -Compress
        if ($before -ne $after -or -not [IO.File]::Exists($identity.path)) { Write-MediaJson $identity.path $catalog }
        return $result
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Get-MediaCatalog([string]$Folder) {
    return Invoke-MediaCatalog $Folder { param($catalog) $catalog }
}

function Get-MediaView([string]$Folder) {
    $catalog = Get-MediaCatalog $Folder
    $files = @{}
    foreach ($file in @(Get-MediaFiles $Folder)) { $files[$file.Name] = $file }
    $index = 0
    $view = @($catalog.items | ForEach-Object {
        $file = $files[$_.name]
        if ($file) {
            [pscustomobject]@{ name = $_.name; role = $_.role; kind = $(if ($_.role -eq 'background') { 'background' } elseif ($_.role -eq 'reel') { 'reel' } elseif ($file.Extension -match '^\.(jpg|jpeg|png)$') { 'slide' } else { 'video' });
                enabled = $_.enabled; priority = $_.priority; durationSeconds = $_.durationSeconds; pendingDelete = $_.pendingDelete;
                order = $index; size = $file.Length; modifiedAt = $file.LastWriteTime.ToString('s'); modifiedTicks = $file.LastWriteTimeUtc.Ticks;
                fullName = $file.FullName }
            $index++
        }
    })
    return [pscustomobject]@{ priorityFrequency = $catalog.priorityFrequency; slideDurationSeconds = $catalog.slideDurationSeconds; items = $view }
}

function Update-MediaItem([string]$Folder, [string]$Name, $Changes) {
    $Name = Get-MediaName $Name
    Invoke-MediaCatalog $Folder {
        param($catalog)
        $item = @($catalog.items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
        if (-not $item -or $item.pendingDelete) { Throw-MediaError 'Contenuto non trovato.' 404 }
        foreach ($property in $Changes.PSObject.Properties) {
            switch ($property.Name) {
                'enabled' { if ($property.Value -isnot [bool]) { Throw-MediaError 'Attivo deve essere un booleano.' }; $item.enabled = $property.Value }
                'role' {
                    Test-MediaRole $Name $property.Value
                    $item.role = $property.Value
                    if ($item.role -ne 'loop') { $item.priority = $false }
                }
                'priority' {
                    if ($property.Value -isnot [bool] -or [IO.Path]::GetExtension($Name) -notmatch '^\.(jpg|jpeg|png)$') { Throw-MediaError 'Priorita disponibile solo per le slide.' }
                    $item.priority = $property.Value
                }
                'durationSeconds' {
                    if ([IO.Path]::GetExtension($Name) -notmatch '^\.(jpg|jpeg|png)$' -or $property.Value -isnot [valuetype] -or
                        $property.Value -is [bool] -or $property.Value -lt 1 -or $property.Value -gt 300 -or [math]::Floor($property.Value) -ne $property.Value) { Throw-MediaError 'Durata slide: numero intero da 1 a 300 secondi.' }
                    $item.durationSeconds = [int]$property.Value
                }
                default { Throw-MediaError 'Campo contenuto non valido.' }
            }
        }
        if ($item.role -ne 'loop') { $item.priority = $false }
        if ($item.role -eq 'background' -and $item.enabled) {
            foreach ($other in $catalog.items) { if ($other.name -ne $item.name -and $other.role -eq 'background') { $other.enabled = $false } }
        }
    } | Out-Null
}

function Set-MediaOrder([string]$Folder, [string[]]$Names) {
    Invoke-MediaCatalog $Folder {
        param($catalog)
        if ($Names.Count -ne @($catalog.items).Count -or @($Names | Select-Object -Unique).Count -ne $Names.Count) { Throw-MediaError 'Elenco ordine incompleto o duplicato.' 409 }
        $map = @{}
        foreach ($item in $catalog.items) { $map[$item.name] = $item }
        foreach ($name in $Names) { if (-not $map.ContainsKey($name)) { Throw-MediaError 'Il catalogo e cambiato: aggiorna prima di riordinare.' 409 } }
        $catalog.items = @($Names | ForEach-Object { $map[$_] })
    } | Out-Null
}

function Set-MediaFrequency([string]$Folder, $Frequency) {
    if ($Frequency -isnot [valuetype] -or $Frequency -is [bool] -or $Frequency -lt 2 -or $Frequency -gt 5 -or [math]::Floor($Frequency) -ne $Frequency) { Throw-MediaError 'Frequenza prioritarie: numero intero da 2 a 5.' }
    Invoke-MediaCatalog $Folder { param($catalog) $catalog.priorityFrequency = [int]$Frequency } | Out-Null
}

function Set-MediaSlideDuration([string]$Folder, $Seconds) {
    if ($Seconds -isnot [valuetype] -or $Seconds -is [bool] -or $Seconds -lt 1 -or $Seconds -gt 300 -or [math]::Floor($Seconds) -ne $Seconds) {
        Throw-MediaError 'Durata delle immagini: numero intero da 1 a 300 secondi.'
    }
    Invoke-MediaCatalog $Folder {
        param($catalog)
        $catalog.slideDurationSeconds = [int]$Seconds
        foreach ($item in $catalog.items) {
            if ([IO.Path]::GetExtension($item.name) -match '^\.(jpg|jpeg|png)$') { $item.durationSeconds = [int]$Seconds }
        }
    } | Out-Null
}

function Request-MediaDelete([string]$Folder, [string]$Name) {
    $Name = Get-MediaName $Name
    Invoke-MediaCatalog $Folder {
        param($catalog)
        $item = $catalog.items | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if (-not $item) { Throw-MediaError 'Contenuto non trovato.' 404 }
        $item.pendingDelete = $true; $item.enabled = $false
    } | Out-Null
}

function Complete-MediaDeletes([string]$Folder, [string[]]$CurrentName = @()) {
    Invoke-MediaCatalog $Folder {
        param($catalog)
        foreach ($item in @($catalog.items)) {
            if ($item.pendingDelete -and $CurrentName -notcontains $item.name) {
                try { [IO.File]::Delete((Join-Path $Folder (Get-MediaName $item.name))) } catch { continue }
            }
        }
        $catalog.items = @($catalog.items | Where-Object { [IO.File]::Exists((Join-Path $Folder $_.name)) })
    } | Out-Null
}

function Test-MediaImage([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $image = $null
    try { $image = [Drawing.Image]::FromFile($Path); if ($image.Width -lt 1 -or $image.Height -lt 1) { throw 'Immagine vuota.' } }
    catch { Throw-MediaError 'Immagine non leggibile.' }
    finally { if ($image) { $image.Dispose() } }
}

function Test-MediaRole([string]$Name, $Role) {
    if ($Role -notin @('loop','reel','background') -or
        ($Role -eq 'reel' -and [IO.Path]::GetExtension($Name) -match '^\.(jpg|jpeg|png)$') -or
        ($Role -eq 'background' -and [IO.Path]::GetExtension($Name) -notmatch '^\.(jpg|jpeg|png)$')) { Throw-MediaError 'Destinazione non valida: reel solo video, sfondo solo JPG/PNG.' }
}

function Save-MediaStream([string]$Folder, [string]$Name, [IO.Stream]$Stream, [long]$ExpectedLength = -1, [bool]$Priority = $false, [string]$Role = 'loop') {
    $Name = Get-MediaName $Name
    Test-MediaRole $Name $Role
    if ($Priority -and $Role -ne 'loop') { Throw-MediaError 'Promo disponibile solo nel loop immagini.' }
    if ($Priority -and [IO.Path]::GetExtension($Name) -notmatch '^\.(jpg|jpeg|png)$') { Throw-MediaError 'La scelta Promo / evento e disponibile per le immagini.' }
    Get-MediaCatalogIdentity $Folder | Out-Null
    $destination = Join-Path $Folder $Name
    if ([IO.File]::Exists($destination)) { Throw-MediaError 'Esiste gia un file con questo nome.' 409 }
    $temp = Join-Path $Folder ('.upload-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $output = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Stream.CopyTo($output); $length = $output.Length } finally { $output.Dispose() }
        if ($length -eq 0 -or ($ExpectedLength -ge 0 -and $length -ne $ExpectedLength)) { Throw-MediaError 'Caricamento incompleto o file vuoto.' }
        if ([IO.Path]::GetExtension($Name) -match '^\.(jpg|jpeg|png)$') { Test-MediaImage $temp }
        Invoke-MediaCatalog $Folder {
            param($catalog)
            if ([IO.File]::Exists($destination)) { Throw-MediaError 'Esiste gia un file con questo nome.' 409 }
            [IO.File]::Move($temp, $destination)
            $duration = if ([IO.Path]::GetExtension($Name) -match '^\.(jpg|jpeg|png)$') { $catalog.slideDurationSeconds } else { 10 }
            if ($Role -eq 'background') { foreach ($other in $catalog.items) { if ($other.role -eq 'background') { $other.enabled = $false } } }
            $catalog.items = @($catalog.items) + @([pscustomobject]@{ name = $Name; role = $Role; enabled = $true; priority = $Priority; durationSeconds = $duration; pendingDelete = $false })
        } | Out-Null
        return $destination
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Get-ShuffledMediaEntries([object[]]$Entries) {
    $result = @($Entries).Clone()
    for ($i = $result.Count - 1; $i -gt 0; $i--) {
        $index = Get-Random -Minimum 0 -Maximum ($i + 1)
        $swap = $result[$i]; $result[$i] = $result[$index]; $result[$index] = $swap
    }
    return $result
}

function Get-MediaPreview([string]$Path,[string]$VlcPath) {
    if (-not ('MarcaVecio.MediaThumbnail' -as [type])) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
namespace MarcaVecio {
    [StructLayout(LayoutKind.Sequential)] public struct ThumbnailSize { public int cx, cy; }
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(ThumbnailSize size, uint flags, out IntPtr bitmap); }
    public static class MediaThumbnail {
        [DllImport("shell32.dll",CharSet=CharSet.Unicode,PreserveSig=true)] static extern int SHCreateItemFromParsingName(string path,IntPtr context,ref Guid iid,out IShellItemImageFactory item);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);
        public static bool Save(string path,string output) {
            IShellItemImageFactory item = null; IntPtr handle = IntPtr.Zero;
            try {
                Guid iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
                if (SHCreateItemFromParsingName(path,IntPtr.Zero,ref iid,out item) < 0) return false;
                if (item.GetImage(new ThumbnailSize { cx=320,cy=320 },8,out handle) < 0 || handle==IntPtr.Zero) return false;
                using (Bitmap bitmap = Image.FromHbitmap(handle)) { bitmap.Save(output,ImageFormat.Png); }
                return true;
            } catch { return false; }
            finally { if(handle!=IntPtr.Zero) DeleteObject(handle); if(item!=null) Marshal.ReleaseComObject(item); }
        }
    }
}
'@
    }
    if ([IO.Path]::GetExtension($Path) -match '^\.(jpg|jpeg|png)$') { return $Path }
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($file.FullName+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks)))).Replace('-','') } finally { $sha.Dispose() }
    $cache = Join-Path $ConfigRoot 'previews'
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $target = Join-Path $cache ($key+'.png')
    $failure = Join-Path $cache ($key+'.failed')
    if ([IO.File]::Exists($target)) { return $target }
    if ([IO.File]::Exists($failure)) { Throw-MediaError 'Anteprima video non disponibile: file non leggibile.' 422 }
    $mutex = New-Object Threading.Mutex($false,('Local\MarcaVecioPreview'+$key))
    $held = $false; $process = $null; $temporary = $null
    try {
        try { $held = $mutex.WaitOne(8000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { Throw-MediaError 'Anteprima in preparazione, riprova.' 503 }
        if ([IO.File]::Exists($target)) { return $target }
        $shellTemporary = Join-Path $cache ($key+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
        try {
            if ([MarcaVecio.MediaThumbnail]::Save($file.FullName,$shellTemporary)) {
                [IO.File]::Move($shellTemporary,$target)
                return $target
            }
        } finally { if ([IO.File]::Exists($shellTemporary)) { [IO.File]::Delete($shellTemporary) } }
        if (-not [IO.File]::Exists($VlcPath)) { Throw-MediaError 'VLC non disponibile per generare la miniatura.' 503 }
        $temporary = Join-Path $cache ('.preview-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($temporary) | Out-Null
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $VlcPath
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $info.Arguments = '--intf=dummy --no-one-instance --no-audio --vout=dummy --video-filter=scene --scene-format=png --scene-width=320 --scene-ratio=1 --scene-prefix=frame --scene-path="'+$temporary+'" --stop-time=1 --play-and-exit "'+([uri]$file.FullName).AbsoluteUri+'"'
        $process = [Diagnostics.Process]::Start($info)
        if (-not $process.WaitForExit(6000)) { $process.Kill(); $process.WaitForExit() }
        $frame = Get-ChildItem -LiteralPath $temporary -Filter '*.png' -File | Sort-Object Name | Select-Object -Last 1
        if (-not $frame) { [IO.File]::WriteAllText($failure,'unreadable'); Throw-MediaError 'Anteprima video non disponibile: file non leggibile.' 422 }
        Test-MediaImage $frame.FullName
        [IO.File]::Move($frame.FullName,$target)
        return $target
    } finally {
        if ($process) { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        if ($temporary -and [IO.Directory]::Exists($temporary) -and [IO.Path]::GetFullPath($temporary).StartsWith([IO.Path]::GetFullPath($cache)+'\')) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
}

function Get-MediaRotation($View) {
    $active = @($View.items | Where-Object { $_.enabled -and -not $_.pendingDelete -and $_.kind -ne 'background' })
    $reels = @(Get-ShuffledMediaEntries @($active | Where-Object { $_.kind -eq 'reel' }))
    $groups = @()
    for ($i=0; $i -lt $reels.Count; $i+=3) {
        $members = @($reels[$i..([math]::Min($i+2,$reels.Count-1))])
        foreach ($candidate in @(Get-ShuffledMediaEntries $reels)) {
            if ($members.Count -ge 3) { break }
            if ($members.name -notcontains $candidate.name) { $members += $candidate }
        }
        while ($members.Count -lt 3) { $members += $reels[$members.Count % $reels.Count] }
        $groups += [pscustomobject]@{ name = $members[0].name; kind = 'reel'; enabled = $true; priority = $false; pendingDelete = $false; durationSeconds = 30; fullName = $members[0].fullName; members = @(Get-ShuffledMediaEntries $members) }
    }
    $promos = @($active | Where-Object { $_.kind -eq 'slide' -and $_.priority })
    $normal = @($active | Where-Object { $_.kind -ne 'reel' -and ($_.kind -ne 'slide' -or -not $_.priority) })
    if ($groups.Count -gt 0) {
        # Spread reel scenes evenly through the base loop, with a new phase each
        # round. Photo/video order is preserved; scenes never form a separate block.
        $total = $normal.Count + $groups.Count
        $phase = Get-Random -Minimum 0 -Maximum $total
        $mixed = New-Object 'Collections.Generic.List[object]'
        $baseIndex = 0; $sceneIndex = 0
        for ($position=0; $position -lt $total; $position++) {
            $before = [math]::Floor(($position*$groups.Count+$phase)/$total)
            $after = [math]::Floor((($position+1)*$groups.Count+$phase)/$total)
            if ($after -gt $before) { $mixed.Add($groups[$sceneIndex]); $sceneIndex++ }
            else { $mixed.Add($normal[$baseIndex]); $baseIndex++ }
        }
        $normal = @($mixed.ToArray())
    }
    if ($promos.Count -eq 0) { return $normal }
    $frequency = [int]$View.priorityFrequency
    $promos = @(Get-ShuffledMediaEntries $promos)
    # A randomly chosen anchor separates each group. Every promo occurs exactly
    # once in each group; base content remains in its original relative order.
    $counts = @(0..($frequency-1) | ForEach-Object { [int][math]::Floor($normal.Count / $frequency) })
    $extraBuckets = @(Get-ShuffledMediaEntries @(0..($frequency-1)))
    for ($i=0; $i -lt ($normal.Count % $frequency); $i++) { $counts[$extraBuckets[$i]]++ }
    $normalIndex = 0
    $sequence = New-Object 'Collections.Generic.List[object]'
    for ($bucket=0; $bucket -lt $frequency; $bucket++) {
        $sequence.Add($promos[0])
        $groupNormal = @()
        for ($i=0; $i -lt $counts[$bucket]; $i++) { $groupNormal += $normal[$normalIndex]; $normalIndex++ }
        $rest = @()
        for ($i=1; $i -lt $promos.Count; $i++) { $rest += $promos[$i] }
        $rest += $groupNormal
        $rest = @(Get-ShuffledMediaEntries $rest)
        $groupIndex = 0
        foreach ($item in $rest) {
            if ($item.kind -ne 'slide' -or -not $item.priority) {
                $sequence.Add($groupNormal[$groupIndex]); $groupIndex++
            } else { $sequence.Add($item) }
        }
    }
    return $sequence.ToArray()
}
