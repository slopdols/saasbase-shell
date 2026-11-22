#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) "shell-smoke-tests-$([guid]::NewGuid().ToString('N'))"
$fixture = Join-Path $temp 'app'
$null = New-Item -ItemType Directory -Path (Join-Path $fixture 'setup-scripts'), (Join-Path $fixture '.setup') -Force
Copy-Item (Join-Path $scripts 'common.ps1'), (Join-Path $scripts 'configure-smoke-tests.ps1') -Destination (Join-Path $fixture 'setup-scripts')
. (Join-Path $scripts 'common.ps1')
Write-JsonFile (Join-Path $fixture '.setup/state.json') @{
    AppName = 'app'; AccountId = '123456789012'; Region = 'us-east-2'; Profile = 'test'; Repository = 'owner/app'
}
$saved = @{}
foreach ($name in @('VUE_APP_COGNITO_ISSUER', 'VUE_APP_COGNITO_CLIENT_ID', 'SMOKE_TEST_USERNAME', 'SMOKE_TEST_PASSWORD')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$passed = 0

function Assert-SmokeTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-SmokeCase {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-SmokeFailure {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        Assert-SmokeTest (-not $_.Exception.Message.Contains('Fake-only!123')) 'Password leaked in failure output.'
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected smoke failure containing $Message"
}
function Reset-SmokeFixture {
    $global:ShellSmokeMock = @{
        Calls = [System.Collections.Generic.List[string]]::new(); Item = $null; Deleted = $false; Deletes = 0
        BadHealth = $false; Admin = $false; Challenge = $false; BadVersion = $false; Confirm = ''
        Timestamp = '2026-01-01T00:00:00.123456+00:00'
    }
    $env:VUE_APP_COGNITO_ISSUER = 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test'
    $env:VUE_APP_COGNITO_CLIENT_ID = 'client123'
    $env:SMOKE_TEST_USERNAME = 'smoke@example.com'
    $env:SMOKE_TEST_PASSWORD = 'Fake-only!123'
}
function Read-Host {
    param($Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { return (ConvertTo-SecureString 'Fake-only!123' -AsPlainText -Force) }
    if ($Prompt -like '*PRODUCTION*') { return $global:ShellSmokeMock.Confirm }
    return 'smoke@example.com'
}
function aws {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $global:ShellSmokeMock.Calls.Add("aws $($Arguments -join ' ')")
    if ($Arguments[0] -eq 'sts') { return '{"Account":"123456789012"}' }
    return (@{ Exports = @(
        @{ Name = 'app-dev-cognito-issuer'; Value = $env:VUE_APP_COGNITO_ISSUER },
        @{ Name = 'app-dev-user-pool-client-id'; Value = $env:VUE_APP_COGNITO_CLIENT_ID },
        @{ Name = 'app-dev-api-endpoint'; Value = 'https://api.example.com' }
    ) } | ConvertTo-Json -Depth 5)
}
function gh {
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments, [Parameter(ValueFromPipeline)][string]$InputText)
    $global:LASTEXITCODE = 0
    $text = $Arguments -join ' '
    Assert-SmokeTest (-not $text.Contains('Fake-only!123')) 'Password was put in process arguments.'
    if ($Arguments[0] -eq 'secret') {
        $value = $InputText.Trim()
        $expected = if ($Arguments[2] -eq 'SMOKE_TEST_PASSWORD') { 'Fake-only!123' } else { 'smoke@example.com' }
        Assert-SmokeTest ($value -eq $expected) 'Secret was not transferred on stdin.'
    }
    $global:ShellSmokeMock.Calls.Add("gh $text")
}
function Invoke-SmokeHttpResponse {
    param($Uri, $Method = 'GET', $Headers = @{}, $Body, $ContentType, $TimeoutSec, [switch]$SkipHttpErrorCheck, $StatusCodeVariable)
    $mock = $global:ShellSmokeMock
    $path = ([uri]$Uri).AbsolutePath
    $mock.Calls.Add("$Method $Uri")
    $status = 200
    $response = $null
    if ($Uri -eq 'https://cognito-idp.us-east-2.amazonaws.com') {
        $credentials = $Body | ConvertFrom-Json
        Assert-SmokeTest ($credentials.AuthParameters.PASSWORD -eq 'Fake-only!123') 'Wrong test password.'
        $response = if ($mock.Challenge) { @{ ChallengeName = 'SMS_MFA' } } else { @{ AuthenticationResult = @{ IdToken = 'fake-id-token' } } }
    } elseif ($path -eq '/health') {
        $response = @{ status = $(if ($mock.BadHealth) { 'broken' } else { 'ok' }); environment = 'dev' }
    } elseif ($path -eq '/') {
        $response = @{ status = 'ok'; service = 'saasbase-api' }
    } elseif ($path -eq '/v1/auth/whoami') {
        $response = @{ authenticated = $Headers.ContainsKey('Authorization'); sub = 'test-user' }
    } elseif ($path -eq '/v1/auth/me') {
        if ($Headers.ContainsKey('Authorization')) { $response = @{ sub = 'test-user'; email = 'smoke@example.com'; is_admin = $mock.Admin } }
        else { $status = 401; $response = @{ error = @{ code = 'unauthorized' } } }
    } elseif ($path -eq '/v1/auth/admin/status') {
        $status = 403; $response = @{ error = @{ code = 'forbidden' } }
    } elseif ($path -eq '/v1/items' -and $Method -eq 'GET') {
        $response = @()
    } elseif ($path -eq '/v1/items' -and $Method -eq 'POST') {
        $data = $Body | ConvertFrom-Json
        if ($data.name -eq '') { $status = 422; $response = @{ error = @{ code = 'validation_error' } } }
        else {
            $status = 201
            $mock.Item = @{
                id = 'a' * 32; name = $data.name; status = 'active'; owner_sub = 'test-user'
                version = $(if ($mock.BadVersion) { '0' } else { 0 })
                created_at = $mock.Timestamp; updated_at = $mock.Timestamp
            }
            $response = $mock.Item
        }
    } elseif ($mock.Item -and $path -eq "/v1/items/$($mock.Item.id)") {
        if ($Method -eq 'DELETE') { $mock.Deletes++; $mock.Deleted = $true; $response = @{ id = $mock.Item.id; status = 'deleted' } }
        elseif ($mock.Deleted) { $status = 404; $response = @{ error = @{ code = 'not_found' } } }
        elseif ($Method -eq 'PUT') {
            $data = $Body | ConvertFrom-Json
            if ($mock.Item.version -ne $data.version) { $status = 409; $response = @{ error = @{ code = 'conflict' } } }
            else { $mock.Item.name = $data.name; $mock.Item.version++; $response = $mock.Item }
        } else { $response = $mock.Item }
    } else { throw "Unmocked smoke HTTP call: $Method $Uri" }
    return @{ StatusCode = $status; Content = (ConvertTo-Json -InputObject $response -Depth 10) }
}
function Invoke-RestMethod {
    param($Uri, $Method = 'GET', $Headers = @{}, $Body, $ContentType, $TimeoutSec, [switch]$SkipHttpErrorCheck, $StatusCodeVariable)
    $response = Invoke-SmokeHttpResponse @PSBoundParameters
    if ($StatusCodeVariable) { Set-Variable $StatusCodeVariable $response.StatusCode -Scope 1 }
    return ($response.Content | ConvertFrom-Json)
}
function Invoke-WebRequest {
    param($Uri, $Method = 'GET', $Headers = @{}, $Body, $ContentType, $TimeoutSec, [switch]$SkipHttpErrorCheck, $StatusCodeVariable)
    $response = Invoke-SmokeHttpResponse @PSBoundParameters
    if ($StatusCodeVariable) { Set-Variable $StatusCodeVariable $response.StatusCode -Scope 1 }
    return $response
}

try {
    Test-SmokeCase 'Public smoke verifies contracts without signing in or writing data' {
        Reset-SmokeFixture
        & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' 6>$null
        Assert-SmokeTest ($global:ShellSmokeMock.Calls.Count -eq 4 -and -not $global:ShellSmokeMock.Item) 'Public smoke made extra calls.'
    }
    Test-SmokeCase 'Authenticated smoke checks identity, validation, locking and cleans up only its created item' {
        Reset-SmokeFixture
        & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null
        Assert-SmokeTest ($global:ShellSmokeMock.Deletes -eq 1 -and $global:ShellSmokeMock.Deleted) 'Test item was not cleaned up.'
        Assert-SmokeTest (@($global:ShellSmokeMock.Calls | Where-Object { $_ -like 'PUT *' }).Count -eq 2) 'Optimistic locking was not tested.'
    }
    Test-SmokeCase 'Smoke accepts wire UTC timestamps with Z or an explicit zero offset' {
        foreach ($timestamp in @('2026-01-01T00:00:00Z', '2026-01-01T00:00:00.123456+00:00')) {
            Reset-SmokeFixture
            $global:ShellSmokeMock.Timestamp = $timestamp
            & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null
            Assert-SmokeTest ($global:ShellSmokeMock.Deletes -eq 1) 'UTC-format check left its item active.'
        }
    }
    Test-SmokeCase 'Smoke rejects non-UTC or invalid wire timestamps and still cleans up its item' {
        foreach ($timestamp in @('2026-01-01T02:00:00+02:00', '2026-01-01T00:00:00',
            '2026-02-30T00:00:00Z', 123)) {
            Reset-SmokeFixture
            $global:ShellSmokeMock.Timestamp = $timestamp
            Assert-SmokeFailure { & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null } 'item UTC timestamp'
            Assert-SmokeTest ($global:ShellSmokeMock.Deletes -eq 1) 'Invalid timestamp check left its item active.'
            Assert-SmokeTest (@($global:ShellSmokeMock.Calls | Where-Object { $_ -like 'PUT *' }).Count -eq 0) 'Invalid timestamps reached an item update.'
        }
    }
    Test-SmokeCase 'UTC wire checks do not depend on the machine calendar or culture' {
        $culture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ar-SA')
            Reset-SmokeFixture
            & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null
            Assert-SmokeTest ($global:ShellSmokeMock.Deletes -eq 1) 'Culture-independent timestamp check left its item active.'
        } finally { [Globalization.CultureInfo]::CurrentCulture = $culture }
    }
    Test-SmokeCase 'Incorrect public response shape fails before authenticated work' {
        Reset-SmokeFixture
        $global:ShellSmokeMock.BadHealth = $true
        Assert-SmokeFailure { & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null } 'health/environment'
        Assert-SmokeTest ($global:ShellSmokeMock.Calls.Count -eq 1) 'Smoke continued after bad health.'
    }
    Test-SmokeCase 'Enabled smoke with missing credentials fails explicitly' {
        Reset-SmokeFixture
        $env:SMOKE_TEST_PASSWORD = $null
        Assert-SmokeFailure { & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null } 'credentials are required'
    }
    Test-SmokeCase 'Cognito challenges fail without creating API test data' {
        Reset-SmokeFixture
        $global:ShellSmokeMock.Challenge = $true
        Assert-SmokeFailure { & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null } 'authentication failed'
        Assert-SmokeTest (-not $global:ShellSmokeMock.Item) 'Challenge led to test writes.'
    }
    Test-SmokeCase 'Failed item assertion still deletes only the created test item' {
        Reset-SmokeFixture
        $global:ShellSmokeMock.BadVersion = $true
        Assert-SmokeFailure { & (Join-Path $scripts 'test-shell.ps1') -ApiUrl 'https://api.example.com' -Authenticated 6>$null } 'item response shape'
        Assert-SmokeTest ($global:ShellSmokeMock.Deletes -eq 1) 'Failure left test data active.'
    }
    Test-SmokeCase 'Test credential configuration defaults to dev and enables only after saving secrets on stdin' {
        Reset-SmokeFixture
        & (Join-Path $fixture 'setup-scripts/configure-smoke-tests.ps1') 6>$null
        $calls = @($global:ShellSmokeMock.Calls | Where-Object { $_ -like 'gh *' })
        Assert-SmokeTest ($calls.Count -eq 4 -and $calls[0].EndsWith('--body false') -and $calls[3].EndsWith('--body true')) 'Unsafe enable order.'
        Assert-SmokeTest (@($calls | Where-Object { $_ -notlike '*--env dev*' }).Count -eq 0) 'Default configuration touched Production.'
        Assert-SmokeTest (-not (Get-Content (Join-Path $fixture '.setup/state.json') -Raw).Contains('Fake-only!123')) 'Password saved locally.'
    }
    Test-SmokeCase 'Production credential configuration requires explicit acknowledgement' {
        Reset-SmokeFixture
        Assert-SmokeFailure { & (Join-Path $fixture 'setup-scripts/configure-smoke-tests.ps1') -Stage prod 6>$null } 'not enabled'
        Assert-SmokeTest ($global:ShellSmokeMock.Calls.Count -eq 0) 'Declined Production opt-in changed configuration.'
    }
    Write-Host "All $passed smoke tests passed (no real credentials or API calls)."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Variable -Name ShellSmokeMock -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
