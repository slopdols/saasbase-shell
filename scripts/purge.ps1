[CmdletBinding()]
param([string]$AppName, [string]$GitHubOwner, [string]$AWSProfile, [string]$AWSRegion, [string]$VercelTeamId, [switch]$Plan)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'setup-scripts\bootstrap.ps1')
if ($env:OS -eq 'Windows_NT') { Install-WindowsSetupTools }
else {
    & bash (Join-Path $root 'setup-scripts/install-tools.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Tool installation failed.' }
    $env:Path = "/opt/homebrew/bin:/usr/local/bin:$env:Path"
}
if ($PSVersionTable.PSVersion -lt [version]'7.2') {
    $arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'purge.ps1'))
    foreach ($key in @('AppName', 'GitHubOwner', 'AWSProfile', 'AWSRegion', 'VercelTeamId')) {
        if ($PSBoundParameters[$key]) { $arguments += @("-$key", $PSBoundParameters[$key]) }
    }
    if ($Plan) { $arguments += '-Plan' }
    & pwsh @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Purge failed in PowerShell 7.' }
} else { & (Join-Path $root 'setup-scripts\purge-project.ps1') @PSBoundParameters }
