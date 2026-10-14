Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\MediaCatalog.ps1')
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Entry([string]$Name,[string]$Kind,[bool]$Priority=$false) {
    return [pscustomobject]@{ name=$Name; fullName=$Name; kind=$Kind; priority=$Priority; enabled=$true; pendingDelete=$false }
}
foreach ($baseCount in @(0,1,2,5,8)) {
    foreach ($reelCount in @(1,3,6,15)) {
        $base = @(); $reels = @()
        for ($i=0; $i -lt $baseCount; $i++) { $base += Entry "Base$i" $(if ($i%2) { 'video' } else { 'slide' }) }
        for ($i=0; $i -lt $reelCount; $i++) { $reels += Entry "Reel$i" 'reel' }
        for ($round=0; $round -lt 12; $round++) {
            $result = @(Get-MediaRotation ([pscustomobject]@{ items=($base+$reels); priorityFrequency=2 }))
            $sceneCount = [int][math]::Ceiling($reelCount/3)
            Assert ($result.Count -eq $baseCount+$sceneCount) 'Every base item and reel scene included once'
            Assert ((@($result | Where-Object kind -ne 'reel' | ForEach-Object { $_.name }) -join '|') -eq (@($base | ForEach-Object { $_.name }) -join '|')) 'Photo/video order preserved'
            $positions = @()
            for ($i=0; $i -lt $result.Count; $i++) { if ($result[$i].kind -eq 'reel') { $positions += $i } }
            $gaps = @()
            for ($i=0; $i -lt $positions.Count; $i++) {
                $next = if ($i+1 -lt $positions.Count) { $positions[$i+1] } else { $positions[0]+$result.Count }
                $gaps += $next-$positions[$i]-1
            }
            Assert ((($gaps | Measure-Object -Maximum).Maximum-($gaps | Measure-Object -Minimum).Minimum) -le 1) 'Reel scenes evenly spaced around the cycle'
            if ($sceneCount -le $baseCount) { Assert (@($gaps | Where-Object { $_ -eq 0 }).Count -eq 0) 'No adjacent reel scenes when other content can separate them'
            }
        }
    }
}
$items = @()
for ($i=0; $i -lt 6; $i++) { $items += Entry "Base$i" $(if ($i%2) { 'video' } else { 'slide' }); $items += Entry "Reel$i" 'reel' }
$items += Entry 'Promo' 'slide' $true
foreach ($frequency in @(2,3,4,5)) {
    $result = @(Get-MediaRotation ([pscustomobject]@{ items=$items; priorityFrequency=$frequency }))
    Assert (@($result | Where-Object name -eq 'Promo').Count -eq $frequency) 'Promo frequency retained in mixed rotation'
    Assert (@($result | Where-Object kind -eq 'reel').Count -eq 2) 'Promo insertion preserves reel scenes'
    Assert ((@($result | Where-Object name -like 'Base*').name -join '|') -eq 'Base0|Base1|Base2|Base3|Base4|Base5') 'Mixed rotation retains base photo/video order'
}
Write-Host 'PASS: interleaved reel/photo/video cycles, even spacing, base order, reel-only and single-content cases, promo frequencies 2-5.'
