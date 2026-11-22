#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApiUrl,
    [ValidateSet('prod', 'dev')][string]$Stage = 'dev',
    [switch]$Authenticated
)

. (Join-Path $PSScriptRoot 'common.ps1')
$api = Get-WebsiteOrigin $ApiUrl
$token = $null
$createdId = $null

function Invoke-ShellRequest {
    param([string]$Path, [string]$Method = 'GET', $Body, [int]$ExpectedStatus = 200, [switch]$WithAuth)
    $options = @{
        Uri = "$api$Path"; Method = $Method; SkipHttpErrorCheck = $true
        TimeoutSec = 30; Headers = @{}
    }
    if ($WithAuth) { $options.Headers.Authorization = "Bearer $token" }
    if ($null -ne $Body) { $options.ContentType = 'application/json'; $options.Body = $Body | ConvertTo-Json -Compress }
    $response = Invoke-WebRequest @options
    if ($response.StatusCode -ne $ExpectedStatus) { throw "Shell API $Method $Path returned HTTP $($response.StatusCode), expected $ExpectedStatus." }
    $result = $response.Content | ConvertFrom-Json
    $document = [System.Text.Json.JsonDocument]::Parse($response.Content)
    try {
        if ($document.RootElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            foreach ($field in @('created_at', 'updated_at')) {
                $value = [System.Text.Json.JsonElement]::new()
                if ($document.RootElement.TryGetProperty($field, [ref]$value) -and
                    $value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                    # PowerShell converts +00:00 dates to local DateTime; validate the wire strings.
                    $result.$field = $value.GetString()
                }
            }
        }
    } finally { $document.Dispose() }
    return $result
}

function Assert-ShellResult {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Shell smoke check failed: $Message" }
}

function Assert-ShellItem {
    param($Item, [string]$Owner, [string]$Id, [string]$Name, [int]$Version)
    Assert-ShellResult ($Item.id -eq $Id -and $Item.owner_sub -eq $Owner -and $Item.name -eq $Name -and
        $Item.status -eq 'active' -and $Item.version -is [long] -and $Item.version -eq $Version) 'item response shape, ownership or version'
    foreach ($field in @('created_at', 'updated_at')) {
        $value = $Item.$field
        $date = [DateTimeOffset]::MinValue
        Assert-ShellResult ($value -is [string] -and $value -match '^\d{4}-\d{2}-\d{2}T.+(Z|\+00:00)$' -and
            [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$date) -and $date.Offset -eq [TimeSpan]::Zero) 'item UTC timestamp'
    }
}

try {
    $health = Invoke-ShellRequest '/health'
    Assert-ShellResult ($health.status -eq 'ok' -and $health.environment -eq $Stage) 'health/environment'
    $info = Invoke-ShellRequest '/'
    Assert-ShellResult ($info.status -eq 'ok' -and $info.service -eq 'saasbase-api') 'service response'
    $anonymous = Invoke-ShellRequest '/v1/auth/whoami'
    Assert-ShellResult ($anonymous.authenticated -eq $false) 'anonymous identity'
    $denied = Invoke-ShellRequest '/v1/auth/me' -ExpectedStatus 401
    Assert-ShellResult ($denied.error.code -eq 'unauthorized') 'unauthenticated error envelope'
    Write-Host "Verified public shell API contracts for $Stage."
    if (-not $Authenticated) { return }

    $token = Get-CognitoIdToken -Issuer $env:VUE_APP_COGNITO_ISSUER -ClientId $env:VUE_APP_COGNITO_CLIENT_ID `
        -Username $env:SMOKE_TEST_USERNAME -Password $env:SMOKE_TEST_PASSWORD
    $me = Invoke-ShellRequest '/v1/auth/me' -WithAuth
    Assert-ShellResult ($me.sub -and $me.email -eq $env:SMOKE_TEST_USERNAME -and $me.is_admin -eq $false) 'dedicated non-admin test user'
    $who = Invoke-ShellRequest '/v1/auth/whoami' -WithAuth
    Assert-ShellResult ($who.authenticated -eq $true -and $who.sub -eq $me.sub) 'authenticated identity'
    $admin = Invoke-ShellRequest '/v1/auth/admin/status' -WithAuth -ExpectedStatus 403
    Assert-ShellResult ($admin.error.code -eq 'forbidden') 'admin authorization'
    $invalid = Invoke-ShellRequest '/v1/items' -Method POST -Body @{ name = '' } -WithAuth -ExpectedStatus 422
    Assert-ShellResult ($invalid.error.code -eq 'validation_error') 'request validation'
    $items = @(Invoke-ShellRequest '/v1/items?limit=1' -WithAuth)
    Assert-ShellResult (@($items | Where-Object { $_.owner_sub -ne $me.sub -or $_.status -eq 'deleted' }).Count -eq 0) 'list ownership/filtering'
    $name = "shell-smoke-$([guid]::NewGuid().ToString('N'))"
    $created = Invoke-ShellRequest '/v1/items' -Method POST -Body @{ name = $name } -WithAuth -ExpectedStatus 201
    Assert-ShellResult ($created.id -cmatch '^[a-f0-9]{32}$' -and $created.owner_sub -eq $me.sub) 'safe test-item identity'
    $createdId = $created.id
    Assert-ShellItem -Item $created -Owner $me.sub -Id $createdId -Name $name -Version 0
    $read = Invoke-ShellRequest "/v1/items/$createdId" -WithAuth
    Assert-ShellItem -Item $read -Owner $me.sub -Id $createdId -Name $name -Version 0
    $updated = Invoke-ShellRequest "/v1/items/$createdId" -Method PUT -Body @{ name = "$name-updated"; version = 0 } -WithAuth
    Assert-ShellItem -Item $updated -Owner $me.sub -Id $createdId -Name "$name-updated" -Version 1
    $conflict = Invoke-ShellRequest "/v1/items/$createdId" -Method PUT -Body @{ name = 'stale'; version = 0 } -WithAuth -ExpectedStatus 409
    Assert-ShellResult ($conflict.error.code -eq 'conflict') 'optimistic locking'
} finally {
    if ($createdId) {
        $deleted = Invoke-ShellRequest "/v1/items/$createdId" -Method DELETE -WithAuth
        Assert-ShellResult ($deleted.id -eq $createdId -and $deleted.status -eq 'deleted') 'test-item cleanup'
        $missing = Invoke-ShellRequest "/v1/items/$createdId" -WithAuth -ExpectedStatus 404
        Assert-ShellResult ($missing.error.code -eq 'not_found') 'deleted item visibility'
    }
    $token = $null
}
Write-Host "Verified Cognito login and authenticated shell API contracts for $Stage."
