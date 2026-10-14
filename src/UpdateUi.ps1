$script:UpdateJob=$null
$script:AvailableUpdate=$null

function Set-UpdateUiMessage([string]$Message) {
    $window.FindName('UpdateStatusText').Text=$Message
}

function Start-AppUpdateJob([string]$Operation) {
    if ($script:UpdateJob) { return }
    [IO.Directory]::CreateDirectory($ConfigRoot) | Out-Null
    $resultPath=Join-Path $ConfigRoot ('update-result-' + [guid]::NewGuid().ToString('N') + '.json')
    $arguments=@('-Operation',$Operation,'-Root',('"'+$ConfigRoot+'"'),'-ResultPath',('"'+$resultPath+'"'))
    if ($Operation -eq 'Download') { $arguments += @('-ExpectedVersion',$script:AvailableUpdate.version) }
    $executable=Join-Path $AppRoot 'UpdateWorker.exe'
    if (-not [IO.File]::Exists($executable)) {
        $executable=Join-Path $PSHOME 'powershell.exe'
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $AppRoot 'UpdateWorker.ps1')+'"')) + $arguments
    }
    try {
        $process=Start-Process -FilePath $executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $script:UpdateJob=[pscustomobject]@{process=$process;resultPath=$resultPath;operation=$Operation;started=[datetime]::UtcNow}
        $window.FindName('CheckUpdatesButton').IsEnabled=$false
        $window.FindName('InstallUpdateButton').IsEnabled=$false
        Set-UpdateUiMessage $(if ($Operation -eq 'Check') {'Ricerca aggiornamenti su GitHub...'} else {'Download e verifica del nuovo installer... Puoi continuare a usare l''app.'})
    } catch { Set-UpdateUiMessage 'Impossibile avviare il controllo aggiornamenti. Riprova.' }
}

function Stop-AppUpdateJob {
    if (-not $script:UpdateJob) { return }
    $job=$script:UpdateJob; $script:UpdateJob=$null
    try { if (-not $job.process.HasExited) { $job.process.Kill(); [void]$job.process.WaitForExit(2000) } } catch { }
    foreach ($path in @($job.resultPath,($job.resultPath+'.tmp'))) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    $job.process.Dispose()
}

function Install-AppUpdate([string]$Path,$Release) {
    # Recheck the final file immediately before invoking UAC. A cancelled UAC
    # leaves the running app, helpers and playback untouched.
    Assert-UpdatePackage $Path $Release
    [void](Start-Process -FilePath $Path -ArgumentList @('/DIR="'+$AppRoot+'"') -Verb RunAs -PassThru)
    Set-UpdateUiMessage 'Installer avviato. Completa l''aggiornamento e riapri l''app.'
    $window.Close()
}

function Update-AppUpdateJob {
    if (-not $script:UpdateJob) { return }
    $job=$script:UpdateJob
    $limit=if ($job.operation -eq 'Download') {1200} else {90}
    if (-not $job.process.HasExited -and -not [IO.File]::Exists($job.resultPath) -and ([datetime]::UtcNow-$job.started).TotalSeconds -lt $limit) { return }
    $script:UpdateJob=$null
    $window.FindName('CheckUpdatesButton').IsEnabled=$true
    try {
        if (-not [IO.File]::Exists($job.resultPath)) { throw 'Controllo o download non completato. Riprova.' }
        $result=[IO.File]::ReadAllText($job.resultPath) | ConvertFrom-Json
        if (-not $result.ok) { throw [string]$result.message }
        $script:AvailableUpdate=$result.release
        if ($job.operation -eq 'Download') { Install-AppUpdate $result.package $result.release; return }
        if ($result.release.available) {
            Set-UpdateUiMessage ('Disponibile la versione '+$result.release.version+'. Scarica e installa quando vuoi aggiornare.')
        } else { Set-UpdateUiMessage ('La versione '+$script:AppVersion+' e aggiornata.') }
    } catch {
        # Do not log HTTP exceptions, authorization headers or token values.
        Set-UpdateUiMessage $_.Exception.Message
    } finally {
        try { if (-not $job.process.HasExited) { $job.process.Kill() } } catch { }
        $job.process.Dispose()
        foreach ($path in @($job.resultPath,($job.resultPath+'.tmp'))) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
        $window.FindName('InstallUpdateButton').IsEnabled=($script:AvailableUpdate -and $script:AvailableUpdate.available)
    }
}

function Initialize-AppUpdater {
    $window.FindName('AppVersionText').Text='Versione installata: '+$script:AppVersion
    $credentialExists=[IO.File]::Exists((Join-Path $ConfigRoot 'github-update.credential'))
    Set-UpdateUiMessage $(if ($credentialExists) {'Accesso GitHub salvato su questo PC.'} else {'Repository privato: salva un token GitHub con accesso in lettura a marca-vecio-stream.'})
    $window.FindName('CheckUpdatesButton').Add_Click({Start-AppUpdateJob 'Check'})
    $window.FindName('InstallUpdateButton').Add_Click({if ($script:AvailableUpdate -and $script:AvailableUpdate.available) {Start-AppUpdateJob 'Download'}})
    $window.FindName('SaveGithubTokenButton').Add_Click({
        try {
            $input=$window.FindName('GithubTokenPasswordBox')
            $hasToken=-not [string]::IsNullOrWhiteSpace($input.Password)
            Save-UpdateCredential $ConfigRoot $input.Password
            $input.Clear(); $script:AvailableUpdate=$null
            $window.FindName('InstallUpdateButton').IsEnabled=$false
            Set-UpdateUiMessage $(if ($hasToken) {'Accesso salvato e protetto per questo account Windows.'} else {'Accesso GitHub rimosso da questo PC.'})
        } catch { Set-UpdateUiMessage 'Impossibile salvare l''accesso GitHub.' }
    })
    $window.FindName('OpenReleasesButton').Add_Click({Start-Process ('https://github.com/'+$script:UpdateRepository+'/releases')})
    $script:UpdaterTimer=New-Object Windows.Threading.DispatcherTimer
    $script:UpdaterTimer.Interval=[timespan]::FromMilliseconds(250)
    $script:UpdaterTimer.Add_Tick({Update-AppUpdateJob})
    $script:UpdaterTimer.Start()
}
