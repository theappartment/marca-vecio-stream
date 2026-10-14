param([string]$CompilerPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep the old entry point, using the same complete Inno Setup package.
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $projectRoot 'build-setup.ps1') -CompilerPath $CompilerPath
