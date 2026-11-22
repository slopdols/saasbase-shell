#Requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('prod', 'dev')][string]$Stage = 'dev')

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$path = Join-Path $root '.setup/state.json'
if (-not (Test-Path -LiteralPath $path)) { throw 'Setup state is required in this app folder.' }
$state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
if ($Stage -eq 'prod' -and (Read-Host 'These tests create and soft-delete test items in Production. Type PRODUCTION to opt in') -cne 'PRODUCTION') {
    throw 'Production smoke tests were not enabled.'
}
$options = @('--profile', $state.Profile, '--region', $state.Region, '--no-cli-pager', '--output', 'json')
$identity = Invoke-Checked aws (@('sts', 'get-caller-identity') + $options) | ConvertFrom-Json
if ($identity.Account -ne $state.AccountId) { throw 'AWS profile does not match this installation.' }
$exports = Invoke-Checked aws (@('cloudformation', 'list-exports') + $options) | ConvertFrom-Json
$issuer = Get-RequiredExport -Exports $exports.Exports -Name "$($state.AppName)-$Stage-cognito-issuer"
$client = Get-RequiredExport -Exports $exports.Exports -Name "$($state.AppName)-$Stage-user-pool-client-id"
$api = Get-WebsiteOrigin (Get-RequiredExport -Exports $exports.Exports -Name "$($state.AppName)-$Stage-api-endpoint")
Write-Host 'Register and verify a dedicated non-admin test account in this environment first. Do not use a customer account.'
Write-Host 'This helper configures credentials for manual API checks. CI uses temporary users automatically; RUN_AUTH_SMOKE_TESTS opts Production in but never disables dev CI tests.'
$username = Read-SetupValue 'Test-user email' ''
$secret = Read-Host 'Test-user password (hidden)' -AsSecureString
$password = $null
$token = $null
try {
    $password = [System.Net.NetworkCredential]::new('', $secret).Password
    $token = Get-CognitoIdToken -Issuer $issuer -ClientId $client -Username $username -Password $password
    $me = Invoke-RestMethod -Uri "$api/v1/auth/me" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 30
    if ($me.email -ne $username -or $me.is_admin -ne $false) { throw 'Use a dedicated confirmed non-admin test account.' }
    $null = Invoke-Checked gh -Arguments @('variable', 'set', 'RUN_AUTH_SMOKE_TESTS', '--repo', $state.Repository, '--env', $Stage, '--body', 'false')
    $null = Invoke-Checked gh -Arguments @('secret', 'set', 'SMOKE_TEST_USERNAME', '--repo', $state.Repository, '--env', $Stage) -InputText $username
    $null = Invoke-Checked gh -Arguments @('secret', 'set', 'SMOKE_TEST_PASSWORD', '--repo', $state.Repository, '--env', $Stage) -InputText $password
    $null = Invoke-Checked gh -Arguments @('variable', 'set', 'RUN_AUTH_SMOKE_TESTS', '--repo', $state.Repository, '--env', $Stage, '--body', 'true')
    Write-Host "Authenticated smoke tests enabled for $Stage. Credentials were saved only in GitHub environment secrets."
} finally {
    $password = $null
    $token = $null
    $secret.Dispose()
}
