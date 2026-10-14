Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$root = Join-Path $project 'test-install'
. (Join-Path $project 'src\StopForUpdate.ps1') -InstallRoot $root -FunctionsOnly
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
Assert (Test-UpdateProcessPath (Join-Path $root 'WebServer.exe') $root) 'Installed helper matches'
Assert (Test-UpdateProcessPath (Join-Path $root 'tools\ngrok\ngrok.exe') $root) 'Bundled tunnel matches'
Assert (-not (Test-UpdateProcessPath (Join-Path ($root + '-other') 'WebServer.exe') $root)) 'Different installation is excluded'
Assert (-not (Test-UpdateProcessPath (Join-Path $root 'other\WebServer.exe') $root)) 'Unrelated executable under root is excluded'
Assert (-not (Test-UpdateProcessPath '' $root)) 'Unknown path is excluded'
$script:StoppedIds = @()
$script:Candidates = @(
    [pscustomobject]@{ Name='WebServer.exe';ProcessId=101;ExecutablePath=(Join-Path $root 'WebServer.exe') },
    [pscustomobject]@{ Name='MarcaVecioStream.exe';ProcessId=102;ExecutablePath=(Join-Path $root 'MarcaVecioStream.exe') },
    [pscustomobject]@{ Name='TelegramWorker.exe';ProcessId=103;ExecutablePath=(Join-Path $root 'TelegramWorker.exe') },
    [pscustomobject]@{ Name='WebServer.exe';ProcessId=104;ExecutablePath='C:\other\WebServer.exe' }
)
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) return $script:Candidates }
function Get-Process {
    param($Id,$ErrorAction)
    $item = $script:Candidates | Where-Object ProcessId -eq $Id | Select-Object -First 1
    if (-not $item) { return $null }
    $proc = [pscustomobject]@{ Id=$item.ProcessId;Path=$item.ExecutablePath }
    $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
    return $proc
}
function Stop-Process {
    param($Id,[switch]$Force,$ErrorAction)
    $script:StoppedIds += $Id
    $script:Candidates = @($script:Candidates | Where-Object ProcessId -ne $Id)
}
Stop-ProcessesForUpdate $root
Assert ($script:StoppedIds[0] -eq 102 -and (($script:StoppedIds | Sort-Object) -join ',') -eq '101,102,103') 'Main app stopped before helpers'
Assert ($script:Candidates.Count -eq 1 -and $script:Candidates[0].ProcessId -eq 104) 'Other web server left running'

# Verify a reused helper is claimed so normal app exit closes it as well.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'src\MarcaVecioPlayer.ps1'),[ref]$tokens,[ref]$errors)
foreach ($name in @('Start-WebServerProcess','Start-TelegramWorkerProcess','Start-NgrokProcess')) {
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $function.Extent.Text
}
$AppRoot=$root; $WebServerPidPath='web.pid'; $TelegramPidPath='telegram.pid'; $NgrokPidPath='ngrok.pid'
function Get-CurrentConfigFromUi { return @{ webEnabled=$true;telegramEnabled=$true;telegramBotToken='test';ngrokEnabled=$true;ngrokAuthtoken='test';ngrokPath=(Join-Path $root 'tools\ngrok\ngrok.exe') } }
function Read-PidFile { return 200 }
function Test-HelperProcess { return $true }
function Test-Path { return $true }
function Get-Process { return [pscustomobject]@{ Id=200;HasExited=$false } }
$script:WebServerOwnedPid=$null; $script:TelegramWorkerOwnedPid=$null; $script:NgrokOwnedPid=$null
Start-WebServerProcess; Start-TelegramWorkerProcess; Start-NgrokProcess
Assert ($script:WebServerOwnedPid -eq 200 -and $script:TelegramWorkerOwnedPid -eq 200 -and $script:NgrokOwnedPid -eq 200) 'Reused helpers tracked for cleanup'
Write-Output 'PASS: exact installation paths, main-before-helper shutdown, unrelated processes excluded, reused helpers tracked for app exit.'
