# One persistent fullscreen surface; photos crossfade and VLC videos share its HWND.
$script:PlaybackMode = 'stopped'
$script:PlaybackCurrent = $null
$script:PlaybackQueue = @()
$script:PlaybackIndex = 0
$script:PlaybackView = $null
$script:PlaybackSignature = ''
$script:PlaybackAppliedSignature = ''
$script:PlaybackFailed = @{}
$script:PlaybackError = ''
$script:PlaybackMessage = 'Pronto.'
$script:PlaybackFolder = ''
$script:PlaybackSelected = ''
$script:PlaybackReady = $false
$script:PlaybackSawPlaying = $false
$script:PlaybackStarted = [datetime]::MinValue
$script:PlaybackControlFailures = 0
$script:PlaybackChangingContent = $false
$script:PlaybackUpdating = $false

function Set-PlaybackNotice([string]$Message, [bool]$IsError = $false) {
    $script:PlaybackMessage = $Message
    if ($IsError) { $script:PlaybackError = $Message; Write-AppLog $Message }
    Update-Status $Message
}

function Update-PlaybackCatalog([string]$Folder) {
    $view = if ([string]::IsNullOrWhiteSpace($Folder) -or -not [IO.Directory]::Exists($Folder)) {
        [pscustomobject]@{ priorityFrequency = 2; items = @() }
    } else { Get-MediaView $Folder }
    $signature = $Folder + ($view | ConvertTo-Json -Depth 8 -Compress)
    if ($signature -ne $script:PlaybackSignature) {
        $script:PlaybackView = $view
        $script:PlaybackFolder = $Folder
        $script:PlaybackSignature = $signature
        $script:PlaybackFailed = @{}
    }
}

function Start-ControlledPlayback([string]$VlcPath, [string]$Folder, [string]$Selected = '', [string[]]$ExtraArguments = @()) {
    Stop-Playback
    $script:PlaybackError = ''
    $script:PlaybackSignature = ''
    Update-PlaybackCatalog $Folder
    $script:PlaybackSelected = $Selected
    $script:PlaybackMode = if ($Selected) { 'selected' } else { 'rotation' }
    $script:PlaybackAppliedSignature = ''
    $script:PlaybackReady = $false
    $script:PlaybackStarted = [datetime]::UtcNow
    $script:PlaybackControlFailures = 0
    try {
        Initialize-EmbeddedVlc $VlcPath $ExtraArguments
        New-PlaybackSurface ($ExtraArguments -contains '--vout=dummy')
        $script:PlaybackReady = $true
        Move-PlaybackNext
    } catch { Stop-Playback; throw }
}

function Stop-ControlledPlayback {
    $script:PlaybackMode = 'stopped'
    $script:PlaybackCurrent = $null
    $script:PlaybackReady = $false
    Close-PlaybackSurface
    $script:PlaybackMessage = 'Playback fermato.'
}

function Move-PlaybackNext {
    if ($script:PlaybackChangingContent) { return }
    $script:PlaybackChangingContent = $true
    $operationSurface = $script:PlaybackSurface
    try {
    $previous = if ($script:PlaybackCurrent) { $script:PlaybackCurrent.name } else { '' }
    if ($script:PlaybackCurrent) {
        Hold-PlaybackVisual
        # Release VLC's file before completing a deferred video deletion.
        if ($script:PlaybackCurrent.kind -eq 'video') { Stop-NativePlayer $script:EmbeddedVlc }
        if ($script:PlaybackCurrent.kind -eq 'reel') { Stop-PlaybackReels }
        if ($script:PlaybackMode -eq 'stopped' -or -not [object]::ReferenceEquals($operationSurface,$script:PlaybackSurface)) { return }
        Complete-MediaDeletes $script:PlaybackCurrent.folder
    }
    $script:PlaybackCurrent = $null
    Update-PlaybackCatalog $script:PlaybackFolder
    if ($script:PlaybackAppliedSignature -ne $script:PlaybackSignature -or $script:PlaybackIndex -ge $script:PlaybackQueue.Count) {
        $view = $script:PlaybackView
        $candidates = @($view.items | Where-Object { $_.enabled -and -not $_.pendingDelete -and -not $script:PlaybackFailed.ContainsKey($_.name) })
        if ($script:PlaybackMode -eq 'selected') { $candidates = @($candidates | Where-Object { $_.name -eq $script:PlaybackSelected }) }
        $script:PlaybackQueue = @(Get-MediaRotation ([pscustomobject]@{ items = $candidates; priorityFrequency = $view.priorityFrequency }))
        # Preserve order, rotate the cycle origin to avoid the same slide across a boundary.
        if ($script:PlaybackQueue.Count -gt 1 -and $script:PlaybackQueue[0].name -eq $previous) {
            $offset = 1
            while ($offset -lt $script:PlaybackQueue.Count -and $script:PlaybackQueue[$offset].name -eq $previous) { $offset++ }
            if ($offset -lt $script:PlaybackQueue.Count) {
                $script:PlaybackQueue = @($script:PlaybackQueue[$offset..($script:PlaybackQueue.Count-1)]) + @($script:PlaybackQueue[0..($offset-1)])
            }
        }
        $script:PlaybackIndex = 0
        $script:PlaybackAppliedSignature = $script:PlaybackSignature
    }
    while ($script:PlaybackIndex -lt $script:PlaybackQueue.Count) {
        $item = $script:PlaybackQueue[$script:PlaybackIndex]
        $script:PlaybackIndex++
        if ($script:PlaybackFailed.ContainsKey($item.name)) { continue }
        try {
            if (-not [IO.File]::Exists($item.fullName)) { throw 'File non trovato.' }
            if ($item.kind -eq 'slide') { Test-MediaImage $item.fullName }
        } catch {
            $script:PlaybackFailed[$item.name] = $true
            Set-PlaybackNotice ("Saltato $($item.name): " + $_.Exception.Message) $true
            continue
        }
        try {
            if ($item.kind -eq 'reel') {
                $background = @($script:PlaybackView.items | Where-Object { $_.kind -eq 'background' -and $_.enabled -and -not $_.pendingDelete }) | Select-Object -Last 1
                $backgroundPath = if ($background) { $background.fullName } else {
                    $root = Get-Variable AppRoot -ValueOnly -ErrorAction SilentlyContinue
                    if ($root) { Join-Path $root 'assets\reel-background.jpg' } else { '' }
                }
                Show-PlaybackReels $item.members $backgroundPath
            }
            elseif ($item.kind -eq 'slide') { Show-PlaybackSlide $item.fullName }
            else { Show-PlaybackVideo $item.fullName }
        } catch {
            if ($item.kind -eq 'reel') { Stop-PlaybackReels }
            $script:PlaybackFailed[$item.name] = $true
            Set-PlaybackNotice ("Saltato $($item.name): " + $_.Exception.Message) $true
            continue
        }
        if ($script:PlaybackMode -eq 'stopped' -or -not [object]::ReferenceEquals($operationSurface,$script:PlaybackSurface)) { return }
        $names = if ($item.kind -eq 'reel') { @($item.members.name) } else { @($item.name) }
        $script:PlaybackCurrent = [pscustomobject]@{ name = $item.name; names = $names; kind = $item.kind; durationSeconds = $item.durationSeconds; folder = $script:PlaybackFolder }
        $script:PlaybackStarted = [datetime]::UtcNow
        $script:PlaybackSawPlaying = ($item.kind -eq 'slide')
        $label = if ($item.kind -eq 'reel') { 'Reel (30 s): ' + ($names -join ' / ') } else { $item.name }
        Set-PlaybackNotice ("In riproduzione: $label")
        return
    }
    if ($script:PlaybackFailed.Count -gt 0) {
        # Rebuild once to skip failed items in the next cycle; stop when all have failed.
        $remaining = @($script:PlaybackView.items | Where-Object { $_.enabled -and -not $_.pendingDelete -and -not $script:PlaybackFailed.ContainsKey($_.name) -and
            $_.kind -ne 'background' -and ($script:PlaybackMode -ne 'selected' -or $_.name -eq $script:PlaybackSelected) })
        if ($remaining.Count -gt 0) { $script:PlaybackAppliedSignature = ''; $script:PlaybackChangingContent = $false; Move-PlaybackNext; return }
    }
    $message = if ($script:PlaybackFailed.Count -gt 0) { 'Rotazione fermata: nessun contenuto riproducibile.' } else { 'Rotazione fermata: nessun contenuto attivo.' }
    Stop-Playback
    Set-PlaybackNotice $message ($script:PlaybackFailed.Count -gt 0)
    } finally { $script:PlaybackChangingContent = $false }
}

function Update-ControlledPlayback {
    if ($script:PlaybackMode -eq 'stopped' -or $script:PlaybackChangingContent -or $script:PlaybackUpdating) { return }
    $script:PlaybackUpdating = $true
    try {
        Update-PlaybackTransition
        if (-not $script:PlaybackSurface -or -not $script:EmbeddedVlc) { throw 'Schermo di riproduzione non disponibile.' }
        if (-not $script:PlaybackCurrent) { Move-PlaybackNext; $script:PlaybackControlFailures = 0; return }
        $elapsed = ([datetime]::UtcNow - $script:PlaybackStarted).TotalSeconds
        if ($script:PlaybackCurrent.kind -eq 'reel') {
            if ($elapsed -ge 30) { Move-PlaybackNext; return }
            for ($i=0; $i -lt $script:ReelSlots.Count; $i++) {
                $slot = $script:ReelSlots[$i]
                if ($slot.failed) { continue }
                $player = $script:ReelPlayers[$i]; $state = $player.State
                if ($state -eq 3) {
                    $slot.sawPlaying = $true
                    if ($player.FrameReady($script:PlaybackSurface.headless)) { $slot.frameReady = $true }
                    $time = $player.Time
                    if ($time -lt ($slot.lastTime-500)) { $slot.loops++ }
                    $slot.lastTime = $time
                }
                $age = ([datetime]::UtcNow - $slot.started).TotalSeconds
                if ($state -eq 7 -or ($state -in @(5,6) -and -not $slot.sawPlaying -and $age -ge 3) -or ($state -in @(0,1,2) -and $age -ge 10) -or ($state -eq 3 -and -not $slot.frameReady -and $age -ge 10)) {
                    $slot.failed = $true; $script:PlaybackFailed[$slot.item.name] = $true
                    Stop-NativePlayer $player
                    if (-not $script:PlaybackSurface -or $script:PlaybackMode -eq 'stopped') { return }
                    $script:PlaybackSurface.reelHosts[$i].Visibility = [Windows.Visibility]::Hidden
                    Set-PlaybackNotice ("Reel saltato: $($slot.item.name), file non leggibile.") $true
                } elseif ($state -eq 6 -and $slot.sawPlaying) {
                    $script:PlaybackSurface.reelHosts[$i].Visibility = [Windows.Visibility]::Hidden
                    $slot.frameReady = $false
                    Stop-NativePlayer $player
                    if (-not $script:PlaybackSurface -or $script:PlaybackMode -eq 'stopped') { return }
                    $player.PlayLooped($slot.item.fullName,$script:PlaybackSurface.reelPanels[$i].Handle)
                    $player.SetMuted($true)
                    $slot.loops++; $slot.sawPlaying = $false; $slot.started = [datetime]::UtcNow
                }
            }
            $activeSlots = @($script:ReelSlots | Where-Object { -not $_.failed })
            if ($activeSlots.Count -gt 0 -and @($activeSlots | Where-Object { -not $_.frameReady }).Count -eq 0) {
                Present-PlaybackReels
            }
            if (@($script:ReelSlots | Where-Object { -not $_.failed }).Count -eq 0) { Move-PlaybackNext }
            $script:PlaybackControlFailures = 0
            return
        }
        if ($script:PlaybackCurrent.kind -eq 'slide') {
            if ($elapsed -ge $script:PlaybackCurrent.durationSeconds) { Move-PlaybackNext }
            $script:PlaybackControlFailures = 0
            return
        }
        $state = $script:EmbeddedVlc.State
        if (-not $script:PlaybackSurface.videoPresented -and $elapsed -ge 8 -and $state -in @(0,1,2,3)) {
            $script:PlaybackFailed[$script:PlaybackCurrent.name] = $true
            Set-PlaybackNotice ("Video saltato: $($script:PlaybackCurrent.name), nessun fotogramma disponibile entro 8 secondi.") $true
            Move-PlaybackNext; return
        }
        if ($state -eq 3) {
            $script:PlaybackSawPlaying = $true
            if ($script:EmbeddedVlc.FrameReady($script:PlaybackSurface.headless)) { Present-PlaybackVideo }
            if ($script:PlaybackSurface.videoPresented -and -not $script:PlaybackSurface.videoEndingFrame -and
                $script:EmbeddedVlc.Length -gt 0 -and $script:EmbeddedVlc.Time -ge ($script:EmbeddedVlc.Length-750)) {
                $script:PlaybackSurface.videoEndingFrame = Hold-PlaybackVisual $true
            }
            $script:PlaybackControlFailures = 0; return
        }
        if ($state -eq 4) { $script:PlaybackControlFailures = 0; return }
        if ($state -eq 7 -or $state -eq 6 -or ($state -eq 5 -and ($script:PlaybackSawPlaying -or $elapsed -ge 3))) {
            if ($state -eq 7 -or -not $script:PlaybackSurface.videoPresented) {
                $script:PlaybackFailed[$script:PlaybackCurrent.name] = $true
                Set-PlaybackNotice ("Saltato $($script:PlaybackCurrent.name): VLC non riesce a leggerlo.") $true
            }
            Move-PlaybackNext
        }
        $script:PlaybackControlFailures = 0
    } catch {
        $script:PlaybackControlFailures++
        $failure=$_.Exception; $stopTimedOut=$false
        while ($failure) { if ($failure.Data.Contains('PlaybackStopTimeout')) { $stopTimedOut=$true; break }; $failure=$failure.InnerException }
        if ($stopTimedOut -or (-not $script:PlaybackReady -and ([datetime]::UtcNow - $script:PlaybackStarted).TotalSeconds -gt 10) -or
            ($script:PlaybackReady -and $script:PlaybackControlFailures -ge 5)) {
            $message = 'Riproduzione fermata: player non disponibile. ' + $_.Exception.Message
            Stop-Playback
            Set-PlaybackNotice $message $true
            if ($stopTimedOut -and (Get-Command Show-ConfigurationWindow -ErrorAction SilentlyContinue)) { Show-ConfigurationWindow }
        }
    } finally { $script:PlaybackUpdating = $false }
}
