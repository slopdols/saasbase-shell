#Requires -Version 7.2
[CmdletBinding()]
param([string]$AWSProfile, [switch]$Plan)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root '.setup/state.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    throw 'Run IAM updates from the original application folder configured by setup; .setup/state.json is required.'
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
Assert-AppName $state['AppName']
if ($state['AccountId'] -notmatch '^\d{12}$' -or
    $state['Region'] -notmatch '^[a-z]{2}-[a-z]+-\d+$' -or $state['Region'] -match '^(cn-|us-gov-)' -or
    $state['Profile'] -notmatch '^[a-zA-Z0-9_-]+$' -or
    $state['Repository'] -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -or
    $state['Repository'].Split('/')[1] -cne $state['AppName']) {
    throw 'Invalid setup identity. Refusing to update IAM.'
}
$env:AWS_PAGER = ''
$env:AWS_CLI_AUTO_PROMPT = 'off'
$startingLocation = Get-Location
Set-Location $root
try {
    if ((Get-SetupOriginRepository) -ne $state.Repository) {
        throw 'Git origin does not match the recorded application repository.'
    }
    Connect-SetupGitHub
    $repo = Get-SetupRepositoryInfo -Repository $state.Repository
    if ($repo['is_template']) { throw 'Cannot update IAM for a template repository.' }
    if ($repo['id'] -notmatch '^[1-9][0-9]*$' -or -not $repo['permissions'] -or -not $repo['permissions']['admin']) {
        throw 'Cannot verify repository identity and administrator access.'
    }
    $profile = if ($AWSProfile) { $AWSProfile } else { Read-SetupValue 'Local AWS profile' $state.Profile }
    if ($profile -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid AWS profile name.' }
    $awsOptions = @('--profile', $profile, '--region', $state.Region, '--no-cli-pager', '--output', 'json')
    $identity = Get-SetupAwsIdentity -Profile $profile -Region $state.Region
    if ($identity.Account -ne $state.AccountId) { throw 'The signed-in AWS account does not match this application.' }
    $roleName = "$($state.AppName)-$($repo['id'])-github-deploy"
    $roleArn = "arn:aws:iam::$($state.AccountId):role/$roleName"
    function Get-VerifiedDeployRole {
        $data = Invoke-Checked aws (@('iam', 'get-role', '--role-name', $roleName) + $awsOptions) |
            ConvertFrom-Json -AsHashtable
        $role = $data['Role']
        if (-not $role -or $role['RoleName'] -ne $roleName -or $role['Arn'] -ne $roleArn -or
            $role['RoleId'] -notmatch '^AROA[A-Z0-9]+$') {
            throw 'Cannot verify deployment role ownership.'
        }
        foreach ($tag in @{ Application = $state.AppName; GitHubRepository = $state.Repository }.GetEnumerator()) {
            $matches = @($role['Tags'] | Where-Object { $_ -and $_['Key'] -eq $tag.Key -and $_['Value'] -eq $tag.Value })
            if ($matches.Count -ne 1) { throw 'Deployment role ownership tags do not match this application.' }
        }
        return $role
    }
    $role = Get-VerifiedDeployRole
    $policy = Get-AppDeployPolicy -Path (Join-Path $root 'aws/iam.json') -AppName $state.AppName -AccountId $state.AccountId -Region $state.Region
    Write-Host "`nApplication: $($state.Repository)`nAWS account: $($state.AccountId), region: $($state.Region)`nRole: $roleName"
    Write-Host "Replaces only '$($state.AppName)-deploy' with this folder's current aws/iam.json, scoped to this app/account/region. Affects dev and Production. Trust, other policies and resources are unchanged."
    if ($Plan) {
        Write-Host ($policy | ConvertTo-Json -Depth 30)
        Write-Host 'Plan only. No IAM permissions changed.'
        return
    }
    if ((Read-Host 'Type UPDATE to apply these permissions') -cne 'UPDATE') {
        Write-Host 'Cancelled. No IAM permissions changed.'
        return
    }
    $currentIdentity = Invoke-Checked aws (@('sts', 'get-caller-identity') + $awsOptions) | ConvertFrom-Json
    if ($currentIdentity.Account -ne $state.AccountId -or $currentIdentity.Arn -ne $identity.Arn) {
        throw 'AWS account or sign-in identity changed during confirmation. Refusing to update IAM.'
    }
    if ((Get-VerifiedDeployRole).RoleId -ne $role.RoleId) {
        throw 'The deployment role was replaced during confirmation. Refusing to update IAM.'
    }
    Set-AppDeployPolicy -RoleName $roleName -AppName $state.AppName -Policy $policy -AWSOptions $awsOptions
    Write-Host 'Permissions updated. No deployment was started.' -ForegroundColor Green
    Write-Host "Rerun the failed workflow: https://github.com/$($state.Repository)/actions/workflows/ci-cd.yml"
} finally { Set-Location $startingLocation }
