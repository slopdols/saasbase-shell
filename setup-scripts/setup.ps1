#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$AppName
)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config/setup.env' }
$stateDir = Join-Path $root '.setup'
$statePath = Join-Path $stateDir 'state.json'
$config = Read-SetupConfig $ConfigPath
$state = @{}

foreach ($tool in @('git', 'gh', 'aws')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing $tool. Run the root setup.ps1 or setup.sh launcher to install required tools."
    }
}
$env:AWS_PAGER = ''
$env:AWS_CLI_AUTO_PROMPT = 'off'
$startingLocation = Get-Location
Set-Location $root
$tempFiles = [System.Collections.Generic.List[string]]::new()
try {
    $null = Invoke-Checked git -Arguments @('rev-parse', '--show-toplevel')
    Connect-SetupGitHub
    $sourceRepository = Get-SetupOriginRepository
    $sourceInfo = Get-SetupRepositoryInfo -Repository $sourceRepository
    $defaultApp = if ($AppName) { $AppName } elseif ($config['APP_NAME']) { $config['APP_NAME'] } else { '' }
    $app = if ($AppName) { $AppName } else { Read-SetupValue 'Application name (3-24 lowercase letters, digits or hyphens)' $defaultApp }
    Assert-AppName $app
    $login = Invoke-Checked gh -Arguments @('api', 'user', '--jq', '.login')
    $repository = "$login/$app"
    Assert-RepositoryAvailable $repository
    if (-not $sourceInfo['is_template']) { throw 'Run setup from a clone of the template repository.' }
    $template = $sourceRepository
    if (Invoke-Checked git -Arguments @('status', '--porcelain')) { throw 'Commit or stash local changes before setup.' }
    if ((Invoke-Checked git -Arguments @('branch', '--show-current')) -ne 'main') {
        $null = Invoke-Checked git -Arguments @('switch', 'main')
    }
    Set-SetupGitIdentity
    $region = if ($config['AWS_REGION']) { $config['AWS_REGION'] } elseif ($env:AWS_REGION) { $env:AWS_REGION
    } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION
    } else { 'us-east-2' }
    $region = Read-SetupValue 'AWS region' $region
    if ($region -notmatch '^[a-z]{2}-[a-z]+-\d+$' -or $region -match '^(cn-|us-gov-)') {
        throw 'Use a standard commercial AWS region, for example us-east-2 or eu-west-1.'
    }
    $profile = if ($config['AWS_PROFILE']) { $config['AWS_PROFILE'] } elseif ($env:AWS_PROFILE) { $env:AWS_PROFILE
    } elseif ($env:AWS_DEFAULT_PROFILE) { $env:AWS_DEFAULT_PROFILE
    } else { 'default' }
    $profile = Read-SetupValue 'Local AWS profile' $profile
    if (-not $profile -or $profile -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Use a nonempty AWS profile name with letters, digits, underscores or hyphens.' }
    $awsOptions = @('--profile', $profile, '--region', $region, '--no-cli-pager')
    $identity = Get-SetupAwsIdentity -Profile $profile -Region $region
    $account = [string]$identity.Account
    $token = Get-SetupVercelToken
    if (-not $token) { throw 'A Vercel token is required.' }
    $null = Invoke-VercelApi -Token $token -Path '/v2/user'
    $owner = if ($config['VERCEL_TEAM_ID']) { $config['VERCEL_TEAM_ID'] } elseif ($env:VERCEL_TEAM_ID) { $env:VERCEL_TEAM_ID
    } else { '' }
    $owner = Get-SetupVercelTeam -Token $token -TeamId $owner
    if (@(Get-AppVercelProjects -Token $token -OwnerId $owner -AppName $app).Count -gt 0) {
        throw "Vercel projects already exist for '$app'. Choose another application name. Setup never deletes or reuses them."
    }
    & (Join-Path $PSScriptRoot 'destroy-project.ps1') -Preflight -CollisionCheck -SetupIdentity @{
        AppName = $app; AccountId = $account; Region = $region; Profile = $profile
        Repository = $repository; VercelProjectId = $null; VercelOwnerId = $null
    }

    Write-Host "`nRepository: $repository (private)`nFolder: $root (unchanged)`nAWS: $account ($($identity.Arn)), $region`nVercel team: $owner"
    Write-Host 'Setup initializes an empty GitHub repository without triggering CI, configures AWS and Vercel, then starts main and dev pipelines in parallel and waits for both. Preview upload waits only for the first ready Production website. It switches origin without moving or renaming this folder; your files are preserved. Both AWS environments incur charges.'
    if ((Read-Host 'Type SETUP to continue') -cne 'SETUP') { throw 'Setup cancelled. No infrastructure configuration was changed.' }
    Assert-RepositoryAvailable $repository
    $null = New-Item -ItemType Directory -Path $stateDir -Force
    $null = Invoke-Checked gh -Arguments @('repo', 'create', $repository, '--private')
    $state = @{
        AppName = $app; Region = $region; Profile = $profile; AccountId = $account
        Repository = $repository; TemplateRepository = $template; RepositoryLinked = $false
        VercelOwnerId = $owner
    }
    Write-JsonFile $statePath $state
    Connect-AppRepository -Root $root -State $state
    $null = Invoke-Checked gh -Arguments @('repo', 'edit', $repository, '--default-branch', 'main')
    $repo = Get-SetupRepositoryInfo -Repository $repository
    if ($repo['is_template'] -or $repository -eq $state['TemplateRepository']) {
        throw "Refusing to configure template repository $repository. The application must have its own repository."
    }
    if (-not $repo['permissions']['admin']) { throw "You need administrator access to $repository." }
    if ($repo['default_branch'] -ne 'main') { throw 'The repository default branch must be main.' }
    $stages = @{}
    $projectName = "$app-$($repo['id'])"
    $state.Stages = $stages
    $state.VercelLayout = 'production-preview'
    $state.VercelProjectName = $projectName
    $state.VercelProjectId = $null
    Write-JsonFile $statePath $state

    $project = Invoke-VercelApi -Token $token -OwnerId $owner -Path "/v9/projects/$projectName" -AllowNotFound
    if ($null -ne $project) {
        throw "Vercel project '$projectName' already exists. Choose another application name. The new GitHub repository was already created."
    }

    $providers = Invoke-Checked aws (@('iam', 'list-open-id-connect-providers', '--output', 'json') + $awsOptions) | ConvertFrom-Json
    $providerArn = "arn:aws:iam::${account}:oidc-provider/token.actions.githubusercontent.com"
    if ($providerArn -notin @($providers.OpenIDConnectProviderList | ForEach-Object { $_.Arn })) {
        $null = Invoke-Checked aws (@(
            'iam', 'create-open-id-connect-provider', '--url', 'https://token.actions.githubusercontent.com',
            '--client-id-list', 'sts.amazonaws.com'
        ) + $awsOptions)
    } else {
        $provider = Invoke-Checked aws (@('iam', 'get-open-id-connect-provider', '--open-id-connect-provider-arn', $providerArn, '--output', 'json') + $awsOptions) | ConvertFrom-Json
        if ('sts.amazonaws.com' -notin $provider.ClientIDList) {
            $null = Invoke-Checked aws (@('iam', 'add-client-id-to-open-id-connect-provider', '--open-id-connect-provider-arn', $providerArn, '--client-id', 'sts.amazonaws.com') + $awsOptions)
        }
    }
    $trust = New-TrustPolicy -AccountId $account -Repository $repository -OwnerId $repo['owner']['id'] -RepositoryId $repo['id']
    $policy = Get-AppDeployPolicy -Path (Join-Path $root 'aws/iam.json') -AppName $app -AccountId $account -Region $region
    $trustPath = [IO.Path]::GetTempFileName()
    $tempFiles.Add($trustPath)
    Write-JsonFile $trustPath $trust
    $roleName = "$app-$($repo['id'])-github-deploy"
    $existingRole = Invoke-External aws (@('iam', 'get-role', '--role-name', $roleName, '--output', 'json') + $awsOptions) -AllowFailure
    if ($existingRole.Code -eq 0) {
        throw "AWS role '$roleName' already exists. Choose another application name. Setup never overwrites or reuses it."
    } elseif ($existingRole.Text -match '\(NoSuchEntity\)') {
        $null = Invoke-Checked aws (@(
            'iam', 'create-role', '--role-name', $roleName,
            '--assume-role-policy-document', "file://$trustPath",
            '--tags', "Key=Application,Value=$app", "Key=GitHubRepository,Value=$repository"
        ) + $awsOptions)
    } else { throw "Cannot inspect deployment role: $($existingRole.Text)" }
    Set-AppDeployPolicy -RoleName $roleName -AppName $app -Policy $policy -AWSOptions $awsOptions
    $roleArn = "arn:aws:iam::${account}:role/$roleName"

    $protection = @{ deploymentType = 'prod_deployment_urls_and_all_previews' }
    $project = Invoke-VercelApi -Token $token -OwnerId $owner -Path '/v11/projects' -Method POST -Body @{
        name = $projectName; framework = $null; ssoProtection = $protection
    }
    $state.VercelProjectId = $project.id
    Write-JsonFile $statePath $state
    $projectData = $project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    if ($projectData['link']) { throw "Vercel project $projectName has a Git integration. Disconnect it before using GitHub-orchestrated deployments." }
    if ($project.accountId -ne $owner) { throw 'Vercel project belongs to an unexpected team.' }
    $null = Invoke-VercelApi -Token $token -OwnerId $owner -Path "/v9/projects/$($project.id)" -Method PATCH -Body @{ ssoProtection = $protection }
    $state.VercelProjectId = $project.id
    Write-JsonFile $statePath $state

    foreach ($stage in @('prod', 'dev')) {
        $branch = if ($stage -eq 'prod') { 'main' } else { 'dev' }
        $target = if ($stage -eq 'prod') { 'production' } else { 'preview' }
        $domain = if ($stage -eq 'prod') { "$projectName.vercel.app" } else { "$projectName-dev.vercel.app" }
        $domainBranch = if ($stage -eq 'dev') { 'dev' } else { $null }
        Set-VercelProjectDomain -Token $token -OwnerId $owner -ProjectId $project.id -Domain $domain -Branch $domainBranch
        $website = Get-WebsiteOrigin "https://$domain"
        $stages[$stage] = @{
            ProjectId = $project.id; ProjectName = $projectName; Branch = $branch
            Target = $target; WebsiteUrl = $website
        }
        Write-JsonFile $statePath $state

        $environment = Invoke-External gh -Arguments @('api', "repos/$repository/environments/$stage") -AllowFailure
        $needsBranchPolicy = $false
        if ($environment.Code -ne 0) {
            if ($environment.Text -notmatch 'HTTP 404') { throw "Cannot inspect GitHub environment: $($environment.Text)" }
            $environmentBody = @{
                deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
            } | ConvertTo-Json -Depth 5 -Compress
            $null = Invoke-Checked gh -Arguments @('api', '--method', 'PUT', "repos/$repository/environments/$stage", '--input', '-') -InputText $environmentBody
            $needsBranchPolicy = $true
        } else {
            $environmentData = $environment.Text | ConvertFrom-Json -AsHashtable
            if ($environmentData['deployment_branch_policy']) {
                $needsBranchPolicy = $environmentData['deployment_branch_policy']['custom_branch_policies']
            }
        }
        if ($needsBranchPolicy) {
            $branchNames = Invoke-Checked gh -Arguments @(
                'api', "repos/$repository/environments/$stage/deployment-branch-policies",
                '--paginate', '--jq', '.branch_policies[].name'
            )
            if ($branch -notin ($branchNames -split '\r?\n')) {
                $null = Invoke-Checked gh -Arguments @(
                    'api', '--method', 'POST', "repos/$repository/environments/$stage/deployment-branch-policies",
                    '-f', "name=$branch", '-f', 'type=branch'
                )
            }
        }
        $variables = @{
            APP_NAME = $app; AWS_REGION = $region; AWS_ACCOUNT_ID = $account
            WEBSITE_URL = $website; VERCEL_ORG_ID = $owner; VERCEL_PROJECT_ID = $project.id
        }
        foreach ($entry in $variables.GetEnumerator()) {
            $null = Invoke-Checked gh -Arguments @('variable', 'set', $entry.Key, '--repo', $repository, '--env', $stage, '--body', $entry.Value)
        }
        $null = Invoke-Checked gh -Arguments @('secret', 'set', 'AWS_ROLE_ARN', '--repo', $repository, '--env', $stage) -InputText $roleArn
        $null = Invoke-Checked gh -Arguments @('secret', 'set', 'VERCEL_TOKEN', '--repo', $repository, '--env', $stage) -InputText $token
        if ($stage -eq 'dev') {
            $bypass = if ($template) { $null } else { $env:VERCEL_AUTOMATION_BYPASS_SECRET }
            $existingSecrets = Invoke-Checked gh -Arguments @('secret', 'list', '--repo', $repository, '--env', $stage, '--json', 'name', '--jq', '.[].name')
            if (-not $bypass -and 'VERCEL_AUTOMATION_BYPASS_SECRET' -notin ($existingSecrets -split '\r?\n')) {
                $bypass = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
                $null = Invoke-VercelApi -Token $token -OwnerId $owner -Path "/v1/projects/$($project.id)/protection-bypass" -Method PATCH -Body @{
                    generate = @{ secret = $bypass; note = 'GitHub Actions preview verification' }
                }
                if (-not $bypass) { throw 'An automation bypass secret is required for protected Preview checks.' }
            }
            if ($bypass) {
                $null = Invoke-Checked gh -Arguments @('secret', 'set', 'VERCEL_AUTOMATION_BYPASS_SECRET', '--repo', $repository, '--env', $stage) -InputText $bypass
            }
            $bypass = $null
        }
        Write-Host "Configured $branch -> $stage -> $website" -ForegroundColor Green
    }
    $devRef = Invoke-External gh -Arguments @('api', "repos/$repository/git/ref/heads/dev") -AllowFailure
    if ($devRef.Code -ne 0) {
        if ($devRef.Text -notmatch 'HTTP 404') { throw "Cannot inspect dev branch: $($devRef.Text)" }
        $mainRef = Invoke-Checked gh -Arguments @('api', "repos/$repository/git/ref/heads/main") | ConvertFrom-Json
        $null = Invoke-Checked gh -Arguments @('api', '--method', 'POST', "repos/$repository/git/refs", '-f', 'ref=refs/heads/dev', '-f', "sha=$($mainRef.object.sha)")
    }
    Start-SetupDeployments -Repository $repository -Root $root
    Write-Host "`nSetup complete. Production and development are deployed." -ForegroundColor Green
    Write-Host "Production: $($stages['prod']['WebsiteUrl'])"
    Write-Host "Development: $($stages['dev']['WebsiteUrl']) (sign into Vercel to access protected Preview)"
    Write-SetupNextSteps -Repository $repository -Root $root
} finally {
    $token = $null
    $bypass = $null
    foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force }
    Set-Location $startingLocation
}
