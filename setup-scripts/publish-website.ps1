#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('prod', 'dev')][string]$Stage,
    [Parameter(Mandatory)][string]$ApiUrl,
    [Parameter(Mandatory)][string]$WebsiteUrl
)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
foreach ($name in @('VERCEL_TOKEN', 'VERCEL_ORG_ID', 'VERCEL_PROJECT_ID', 'VUE_APP_COGNITO_ISSUER', 'VUE_APP_COGNITO_CLIENT_ID')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing $name. Run the setup wizard first." }
}
$api = Get-WebsiteOrigin $ApiUrl
$website = Get-WebsiteOrigin $WebsiteUrl
$cognitoOrigin = Get-CognitoOrigin $env:VUE_APP_COGNITO_ISSUER
if ($env:VUE_APP_COGNITO_CLIENT_ID -notmatch '^[a-zA-Z0-9]+$') { throw 'Invalid Cognito app client ID.' }
$target = if ($Stage -eq 'prod') { 'production' } else { 'preview' }
$branch = if ($Stage -eq 'prod') { 'main' } else { 'dev' }
$bypass = $null
if ($Stage -eq 'dev') {
    $bypass = $env:VERCEL_AUTOMATION_BYPASS_SECRET
    if (-not $bypass) { throw 'Missing VERCEL_AUTOMATION_BYPASS_SECRET for protected Preview checks. Configure the dev GitHub environment secret and Vercel protection bypass.' }
    $project = Invoke-VercelApi -Token $env:VERCEL_TOKEN -OwnerId $env:VERCEL_ORG_ID -Path "/v9/projects/$env:VERCEL_PROJECT_ID"
    $projectData = $project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    if (-not $projectData['ssoProtection'] -or
        $projectData['ssoProtection']['deploymentType'] -ne 'prod_deployment_urls_and_all_previews') {
        throw 'Preview authentication protection is not configured as expected. Check the Vercel project deployment protection before deploying dev.'
    }
}
$work = Join-Path ([IO.Path]::GetTempPath()) "shell-vercel-$([guid]::NewGuid().ToString('N'))"
$output = Join-Path $work '.vercel/output'
$static = Join-Path $output 'static'
$null = New-Item -ItemType Directory -Path $static -Force
$oldApi = $env:VUE_APP_API_BASE
try {
    Push-Location (Join-Path $root 'website')
    try {
        $env:VUE_APP_API_BASE = $api
        $null = Invoke-Checked npm -Arguments @('run', 'build')
        Copy-Item -Path (Join-Path $root 'website/dist/*') -Destination $static -Recurse
    } finally {
        Pop-Location
        $env:VUE_APP_API_BASE = $oldApi
    }
    $outputConfig = New-VercelOutputConfig -ApiUrl $api -HeadersPath (Join-Path $root 'website/vercel.json') -CognitoOrigin $cognitoOrigin
    Write-JsonFile (Join-Path $output 'config.json') $outputConfig
    Write-JsonFile (Join-Path $work '.vercel/project.json') @{
        orgId = $env:VERCEL_ORG_ID; projectId = $env:VERCEL_PROJECT_ID
    }
    Push-Location $work
    try {
        if ($Stage -eq 'dev') {
            Wait-VercelProduction -Token $env:VERCEL_TOKEN -OwnerId $env:VERCEL_ORG_ID -ProjectId $env:VERCEL_PROJECT_ID
        }
        # Upload only prebuilt public assets, never the repository or local config.
        $arguments = @(
            '--yes', 'vercel@65.2.0', 'deploy', '--prebuilt', '--yes', '--no-color',
            '--token', $env:VERCEL_TOKEN,
            '--meta', 'githubDeployment=1', '--meta', "githubCommitRef=$branch"
        )
        if ($Stage -eq 'prod') { $arguments += '--prod' } else { $arguments += @('--target', 'preview') }
        $deployment = Invoke-Checked npx -Arguments $arguments
        Write-Host $deployment
        $deploymentUrl = Get-VercelDeploymentUrl $deployment
        $deploymentHost = ([uri]$deploymentUrl).Host
        $info = Invoke-VercelApi -Token $env:VERCEL_TOKEN -OwnerId $env:VERCEL_ORG_ID -Path "/v13/deployments/$deploymentHost"
        if ($info.projectId -ne $env:VERCEL_PROJECT_ID -or $info.readyState -ne 'READY') {
            throw 'Vercel did not return a ready deployment for the configured project.'
        }
        $deploymentData = $info | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        if (($Stage -eq 'prod' -and $deploymentData['target'] -ne 'production') -or
            ($Stage -eq 'dev' -and $deploymentData['target'] -notin @($null, 'preview'))) {
            throw "Vercel returned the wrong deployment environment for $Stage. No Preview alias was changed."
        }
        if ($Stage -eq 'dev') {
            $null = Invoke-Checked npx -Arguments @(
                '--yes', 'vercel@65.2.0', 'alias', 'set', $deploymentUrl, ([uri]$website).Host,
                '--scope', $env:VERCEL_ORG_ID, '--token', $env:VERCEL_TOKEN
            )
        }
    } finally { Pop-Location }
    if ($Stage -eq 'prod') {
        $project = Invoke-VercelApi -Token $env:VERCEL_TOKEN -OwnerId $env:VERCEL_ORG_ID -Path "/v9/projects/$env:VERCEL_PROJECT_ID"
        $projectData = $project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        if ($project.id -ne $env:VERCEL_PROJECT_ID -or $project.accountId -ne $env:VERCEL_ORG_ID) {
            throw 'Vercel project ownership does not match the configured Production deployment.'
        }
        if ($projectData['paused'] -eq $true) {
            $null = Invoke-VercelApi -Token $env:VERCEL_TOKEN -OwnerId $env:VERCEL_ORG_ID -Path "/v1/projects/$env:VERCEL_PROJECT_ID/unpause" -Method POST
            $project = Invoke-VercelApi -Token $env:VERCEL_TOKEN -OwnerId $env:VERCEL_ORG_ID -Path "/v9/projects/$env:VERCEL_PROJECT_ID"
            $projectData = $project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            if ($projectData['paused'] -ne $false) { throw 'Vercel Production is still paused after redeployment.' }
            Write-Host 'Resumed Vercel Production after a ready deployment.'
        }
    }
    Test-LiveDeployment -ApiUrl $api -WebsiteUrl $website -ProtectionBypass $bypass -CognitoOrigin $cognitoOrigin
    if ($env:GITHUB_STEP_SUMMARY) {
        "## $target deployment verified`n`n- Website: $website`n- API: $api`n" |
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
