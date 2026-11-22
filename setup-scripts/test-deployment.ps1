#Requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('prod', 'dev')][string]$Stage = 'prod')

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root '.setup/state.json'
if (-not (Test-Path -LiteralPath $statePath)) { throw 'Run setup-scripts/setup.ps1 first in this clone.' }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
if (-not $state.Stages.ContainsKey($Stage) -or -not $state.Stages[$Stage]['WebsiteUrl']) {
    throw "Setup is incomplete for $Stage. Rerun setup-scripts/setup.ps1 first."
}
$options = @('--profile', $state.Profile, '--region', $state.Region, '--no-cli-pager', '--output', 'json')
$identity = Invoke-Checked aws (@('sts', 'get-caller-identity') + $options) | ConvertFrom-Json
if ($identity.Account -ne $state.AccountId) { throw 'AWS profile is signed into a different account. Sign into the setup account before checking deployments.' }
$exports = Invoke-Checked aws (@('cloudformation', 'list-exports') + $options) | ConvertFrom-Json
$api = Get-RequiredExport -Exports $exports.Exports -Name "$($state.AppName)-$Stage-api-endpoint"
$bypass = $null
if ($Stage -eq 'dev') {
    $bypass = $env:VERCEL_AUTOMATION_BYPASS_SECRET
    if (-not $bypass) {
        $secret = Read-Host 'Automation bypass secret for the protected Preview (hidden)' -AsSecureString
        $bypass = [System.Net.NetworkCredential]::new('', $secret).Password
        $secret.Dispose()
    }
    if (-not $bypass) { throw 'An automation bypass secret is required to verify the protected Preview.' }
}
try {
    Test-LiveDeployment -ApiUrl $api -WebsiteUrl $state.Stages[$Stage].WebsiteUrl -ProtectionBypass $bypass
} finally { $bypass = $null }
