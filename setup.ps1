[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$AppName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setup-scripts\bootstrap.ps1')
if ($env:OS -eq 'Windows_NT') {
    Install-WindowsSetupTools
} else {
    & bash (Join-Path $PSScriptRoot 'setup-scripts/install-tools.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Tool installation failed.' }
    $env:Path = "/opt/homebrew/bin:/usr/local/bin:$env:Path"
}
$options = @{}
if ($ConfigPath) { $options.ConfigPath = $ConfigPath }
if ($AppName) { $options.AppName = $AppName }
if ($PSVersionTable.PSVersion -lt [version]'7.2') {
    $arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'setup.ps1'))
    foreach ($key in $options.Keys) { $arguments += @("-$key", $options[$key]) }
    & pwsh @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Setup failed in PowerShell 7.' }
} else {
    & (Join-Path $PSScriptRoot 'setup-scripts/setup.ps1') @options
}
