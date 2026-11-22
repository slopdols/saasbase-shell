#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [AllowEmptyString()][string]$InputText,
        [switch]$AllowFailure
    )
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = 0
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $lines = $InputText | & $Command @Arguments 2>&1
    } else {
        $lines = & $Command @Arguments 2>&1
    }
    $code = $global:LASTEXITCODE
    $text = ($lines | Out-String).Trim()
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "$Command failed (exit $code). $text"
    }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [AllowEmptyString()][string]$InputText
    )
    $options = @{ Command = $Command; Arguments = $Arguments }
    if ($PSBoundParameters.ContainsKey('InputText')) { $options.InputText = $InputText }
    return (Invoke-External @options).Text
}

function Connect-SetupGitHub {
    $auth = Invoke-External gh -Arguments @('auth', 'status', '--hostname', 'github.com') -AllowFailure
    if ($auth.Code -ne 0) {
        & gh auth login --hostname github.com --git-protocol https --web --scopes 'repo,workflow'
        if ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in failed.' }
    }
}

function Get-SetupAwsIdentity {
    param([string]$Profile, [string]$Region)
    $awsOptions = @('--profile', $Profile, '--region', $Region, '--no-cli-pager')
    $identityResult = Invoke-External aws (@('sts', 'get-caller-identity', '--output', 'json') + $awsOptions) -AllowFailure
    if ($identityResult.Code -ne 0) {
        $profiles = (Invoke-Checked aws -Arguments @('configure', 'list-profiles')) -split '\r?\n'
        $useSso = $false
        if ($Profile -cin $profiles) {
            $sso = Invoke-External aws -Arguments @('configure', 'get', 'sso_session', '--profile', $Profile) -AllowFailure
            $legacySso = Invoke-External aws -Arguments @('configure', 'get', 'sso_start_url', '--profile', $Profile) -AllowFailure
            foreach ($result in @($sso, $legacySso)) {
                if ($result.Code -notin @(0, 1)) { throw "Cannot inspect AWS sign-in configuration: $($result.Text)" }
            }
            $useSso = $sso.Code -eq 0 -or $legacySso.Code -eq 0
        }
        if (-not $useSso) {
            $method = Read-SetupValue 'AWS sign-in method (console/sso)' 'console'
            if ($method -notin @('console', 'sso')) { throw 'Choose console or sso for AWS sign-in.' }
            if ($method -eq 'sso') {
                & aws configure sso --profile $Profile
                if ($LASTEXITCODE -ne 0) { throw 'AWS SSO configuration failed.' }
                $useSso = $true
            }
        }
        Write-Host 'Opening AWS browser sign-in. Use your non-root administrator.'
        if ($useSso) { & aws sso login --profile $Profile }
        else { & aws login --profile $Profile --region $Region }
        if ($LASTEXITCODE -ne 0) { throw 'AWS sign-in failed. Check the browser sign-in and administrator permissions in setup.md.' }
        $identityResult = Invoke-External aws (@('sts', 'get-caller-identity', '--output', 'json') + $awsOptions)
    }
    $identity = $identityResult.Text | ConvertFrom-Json
    if ($identity.Arn -notlike 'arn:aws:*' -or $identity.Arn -like '*:root') {
        throw 'Use a non-root administrator in a standard AWS account.'
    }
    return $identity
}

function Assert-RepositoryAvailable {
    param([string]$Repository)
    $result = Invoke-External gh -Arguments @('api', "repos/$Repository") -AllowFailure
    if ($result.Code -eq 0) { throw "Repository $Repository already exists. Choose another application name." }
    if ($result.Text -notmatch 'HTTP 404') { throw "Cannot check repository availability: $($result.Text)" }
}

function Get-SetupOriginRepository {
    $url = Invoke-Checked git -Arguments @('remote', 'get-url', 'origin')
    if ($url -notmatch '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)/?$') {
        throw 'Setup requires a GitHub origin URL without embedded credentials.'
    }
    return $Matches[2] -replace '\.git$', ''
}

function Get-SetupRepositoryInfo {
    param([string]$Repository)
    if ($Repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') { throw 'Invalid application repository identity.' }
    $repo = Invoke-Checked gh -Arguments @('api', "repos/$Repository") | ConvertFrom-Json -AsHashtable
    if ($repo['full_name'] -ne $Repository -or $repo['is_template'] -isnot [bool]) {
        throw "Cannot verify repository identity and template status for $Repository."
    }
    return $repo
}

function Connect-AppRepository {
    param([string]$Root, [hashtable]$State)
    if ($State['RepositoryLinked']) { return }
    if (Invoke-Checked git -Arguments @('status', '--porcelain')) { throw 'Commit or stash local changes before resuming repository linking.' }
    if ((Invoke-Checked git -Arguments @('branch', '--show-current')) -ne 'main') { throw 'Switch to main before setup.' }
    $url = "https://github.com/$($State.Repository).git"
    $gitAuth = @('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential')
    if (Invoke-Checked git -Arguments ($gitAuth + @('ls-remote', '--', $url))) {
        throw "Repository $($State.Repository) is not empty. Refusing to initialize or overwrite it."
    }
    $message = "Initialize $($State.AppName) from shell [skip ci]`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
    $null = Invoke-Checked git -Arguments @('commit', '--allow-empty', '-m', $message)
    $null = Invoke-Checked git -Arguments @('remote', 'set-url', 'origin', $url)
    $pushUrl = Invoke-External git -Arguments @('config', '--get-all', 'remote.origin.pushurl') -AllowFailure
    if ($pushUrl.Code -eq 0) {
        $null = Invoke-Checked git -Arguments @('config', '--unset-all', 'remote.origin.pushurl')
    } elseif ($pushUrl.Code -ne 1) { throw "Cannot inspect origin push URL: $($pushUrl.Text)" }
    $null = Invoke-Checked git -Arguments ($gitAuth + @('push', $url, 'HEAD:refs/heads/main'))
    $null = Invoke-Checked git -Arguments ($gitAuth + @('fetch', 'origin'))
    $null = Invoke-Checked git -Arguments @('branch', '--set-upstream-to=origin/main', 'main')
    $State.RepositoryLinked = $true
    Write-JsonFile (Join-Path $Root '.setup/state.json') $State
}

function Get-SetupVercelToken {
    if ($env:VERCEL_TOKEN) { return $env:VERCEL_TOKEN }
    if (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement) {
        Import-Module Microsoft.PowerShell.SecretManagement
        $vault = Get-SecretVault | Where-Object Name -EQ 'Saasbase'
        if ($vault) {
            if ($vault.ModuleName -ne 'Microsoft.PowerShell.SecretStore') {
                throw 'The Saasbase vault must use Microsoft.PowerShell.SecretStore.'
            }
            Import-Module Microsoft.PowerShell.SecretStore
            if ((Get-SecretStoreConfiguration).Authentication -ne 'Password') {
                throw 'Enable password authentication for SecretStore before using the saved Vercel token.'
            }
            $info = Get-SecretInfo -Name 'VERCEL_TOKEN' -Vault Saasbase
            if ($info) {
                $secret = Get-Secret -Name 'VERCEL_TOKEN' -Vault Saasbase
                if ($secret -isnot [Security.SecureString]) {
                    throw 'Save VERCEL_TOKEN as a SecureString using save-vercel-token.ps1.'
                }
                try { return [System.Net.NetworkCredential]::new('', $secret).Password }
                finally { $secret.Dispose() }
            }
        }
    }
    Write-Host 'Open https://vercel.com/account/settings/tokens and create a token scoped to your team. Paste it below.'
    $secret = Read-Host 'Vercel token (hidden)' -AsSecureString
    try {
        $token = [System.Net.NetworkCredential]::new('', $secret).Password
        if (-not $token) { throw 'A Vercel token is required.' }
        $null = Invoke-VercelApi -Token $token -Path '/v2/user'
        if ((Read-SetupValue 'Save token in a password-protected local vault for future apps? (Y/n)' 'Y') -match '^(y|yes)$') {
            Save-SetupVercelToken -Secret $secret
        }
        return $token
    }
    finally { $secret.Dispose() }
}

function Save-SetupVercelToken {
    param([Security.SecureString]$Secret)
    foreach ($module in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Need to install $module from Microsoft's PowerShell Gallery (current user only)."
            Install-Module $module -Scope CurrentUser -Repository PSGallery -Force
        }
        Import-Module $module
    }
    $vault = Get-SecretVault | Where-Object Name -EQ 'Saasbase'
    if ($vault -and $vault.ModuleName -ne 'Microsoft.PowerShell.SecretStore') {
        throw 'The Saasbase vault name is already registered to another provider.'
    }
    if (-not $vault) {
        Register-SecretVault -Name Saasbase -ModuleName Microsoft.PowerShell.SecretStore
    }
    if ((Get-SecretStoreConfiguration).Authentication -ne 'Password') {
        throw 'Your existing SecretStore has password protection disabled. Enable it before saving credentials.'
    }
    Write-Host 'Unlock your vault or choose a vault password when prompted. This is not your Vercel token.'
    Set-Secret -Name VERCEL_TOKEN -Secret $Secret -Vault Saasbase
    Write-Host 'Vercel token saved in your encrypted local vault.'
}

function Set-SetupGitIdentity {
    foreach ($identity in @('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT')) {
        $result = Invoke-External git -Arguments @('var', $identity) -AllowFailure
        if ($result.Code -eq 0) { continue }
        $user = Invoke-Checked gh -Arguments @('api', 'user') | ConvertFrom-Json -AsHashtable
        $name = if ($user['name']) { $user['name'] } else { $user['login'] }
        $email = if ($user['email']) { $user['email'] } else { "$($user['id'])+$($user['login'])@users.noreply.github.com" }
        $null = Invoke-Checked git -Arguments @('config', '--local', 'user.name', $name)
        $null = Invoke-Checked git -Arguments @('config', '--local', 'user.email', $email)
        Write-Host "Using GitHub identity for local Git commits: $name <$email>."
        $null = Invoke-Checked git -Arguments @('var', $identity)
    }
}

function Assert-AppName {
    param([string]$Name)
    if ($Name -cnotmatch '^[a-z][a-z0-9-]{1,22}[a-z0-9]$') {
        throw 'APP_NAME must be 3-24 lowercase letters, digits or hyphens, start with a letter and end with a letter or digit.'
    }
}

function Get-WebsiteOrigin {
    param([string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or
        $uri.Fragment -or $uri.AbsolutePath -ne '/' -or -not $uri.IsDefaultPort) {
        throw "Expected an HTTPS origin without path, port, credentials, query or fragment: $Url"
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Read-SetupConfig {
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    $allowed = @('APP_NAME', 'AWS_REGION', 'AWS_PROFILE', 'VERCEL_TEAM_ID')
    foreach ($line in Get-Content -LiteralPath $Path) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([A-Z_]+)=(.*)$') { throw 'Invalid setup.env entry. Expected KEY=value; do not put credentials here.' }
        $key, $value = $Matches[1], $Matches[2].Trim()
        if ($key -notin $allowed) { throw "Unsupported setup.env key: $key. Do not put credentials in this file." }
        if ($values.ContainsKey($key)) { throw "Duplicate setup.env key: $key" }
        $values[$key] = $value
    }
    return $values
}

function Read-SetupValue {
    param([string]$Label, [string]$Default)
    $prompt = if ($Default) { "$Label [$Default]" } else { $Label }
    $value = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Write-JsonFile {
    param([string]$Path, [Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function New-TrustPolicy {
    param(
        [string]$AccountId, [string]$Repository, [string]$OwnerId, [string]$RepositoryId
    )
    $owner, $repoName = $Repository.Split('/')
    $subjects = foreach ($stage in @('prod', 'dev')) {
        "repo:${Repository}:environment:$stage"
        "repo:${owner}@${OwnerId}/${repoName}@${RepositoryId}:environment:$stage"
    }
    return @{
        Version = '2012-10-17'
        Statement = @(@{
            Effect = 'Allow'
            Principal = @{ Federated = "arn:aws:iam::${AccountId}:oidc-provider/token.actions.githubusercontent.com" }
            Action = 'sts:AssumeRoleWithWebIdentity'
            Condition = @{
                StringEquals = @{
                    'token.actions.githubusercontent.com:aud' = 'sts.amazonaws.com'
                    'token.actions.githubusercontent.com:sub' = @($subjects)
                }
            }
        })
    }
}

function Get-AppDeployPolicy {
    param([string]$Path, [string]$AppName, [string]$AccountId, [string]$Region)
    Assert-AppName $AppName
    $text = (Get-Content -LiteralPath $Path -Raw).Replace('saasbase', $AppName)
    $text = $text.Replace('arn:aws:iam::*:', "arn:aws:iam::${AccountId}:")
    foreach ($service in @('lambda', 'dynamodb', 'ecr', 'logs', 'sns', 'cloudwatch', 'cognito-idp')) {
        $text = $text.Replace("arn:aws:${service}:*:*:", "arn:aws:${service}:${Region}:${AccountId}:")
    }
    $text = $text.Replace('arn:aws:apigateway:*::', "arn:aws:apigateway:${Region}::")
    return ($text | ConvertFrom-Json -AsHashtable)
}

function Set-AppDeployPolicy {
    param([string]$RoleName, [string]$AppName, [hashtable]$Policy, [string[]]$AWSOptions)
    $policyPath = [IO.Path]::GetTempFileName()
    try {
        Write-JsonFile $policyPath $Policy
        $null = Invoke-Checked aws (@(
            'iam', 'put-role-policy', '--role-name', $RoleName,
            '--policy-name', "$AppName-deploy", '--policy-document', "file://$policyPath"
        ) + $AWSOptions)
    } finally { Remove-Item -LiteralPath $policyPath -Force }
}

function Invoke-VercelApi {
    param(
        [string]$Token, [string]$OwnerId, [string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        $Body, [switch]$AllowNotFound
    )
    if (-not $Path.StartsWith('/')) { throw 'Vercel API path must start with /.' }
    $uri = "https://api.vercel.com$Path"
    if ($OwnerId -like 'team_*') {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $uri += "${separator}teamId=$([uri]::EscapeDataString($OwnerId))"
    }
    $options = @{
        Uri = $uri; Method = $Method
        Headers = @{ Authorization = "Bearer $Token" }
        SkipHttpErrorCheck = $true; StatusCodeVariable = 'status'
    }
    if ($null -ne $Body) {
        $options.ContentType = 'application/json'
        $options.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    $status = 0
    $result = Invoke-RestMethod @options
    if ($status -eq 404 -and $AllowNotFound) { return $null }
    if ($status -lt 200 -or $status -ge 300) {
        throw "Vercel $Method $Path returned HTTP $status. Check token scope, selected team, project permissions and account limits."
    }
    return $result
}

function Get-RequiredExport {
    param([array]$Exports, [string]$Name)
    $matches = @($Exports | Where-Object Name -EQ $Name)
    if ($matches.Count -ne 1 -or -not $matches[0].Value) {
        throw "Missing CloudFormation export '$Name'. Check the backend deployment in GitHub Actions."
    }
    return [string]$matches[0].Value
}

function Get-BackendDeploymentOutputs {
    param([string]$AppName, [ValidateSet('dev', 'prod')][string]$Stage, [string]$Region)
    Assert-AppName $AppName
    $data = Invoke-Checked aws -Arguments @('cloudformation', 'list-exports', '--region', $Region,
        '--output', 'json', '--no-cli-pager') | ConvertFrom-Json
    $prefix = "$AppName-$Stage"
    $api = Get-WebsiteOrigin (Get-RequiredExport -Exports $data.Exports -Name "$prefix-api-endpoint")
    $client = Get-RequiredExport -Exports $data.Exports -Name "$prefix-user-pool-client-id"
    $issuer = Get-RequiredExport -Exports $data.Exports -Name "$prefix-cognito-issuer"
    if ($client -notmatch '^[a-zA-Z0-9]+$') { throw "Invalid Cognito client export '$prefix-user-pool-client-id'." }
    $null = Get-CognitoOrigin $issuer
    return @{ api_url = $api; cognito_client_id = $client; cognito_issuer = $issuer }
}

function Get-CognitoOrigin {
    param([string]$Issuer)
    if ($Issuer -notmatch '^https://cognito-idp\.[a-z0-9-]+\.amazonaws\.com/[a-zA-Z0-9_-]+$') {
        throw 'Expected a standard Cognito user-pool issuer URL.'
    }
    return ([uri]$Issuer).GetLeftPart([UriPartial]::Authority)
}

function Get-CognitoIdToken {
    param([string]$Issuer, [string]$ClientId, [string]$Username, [string]$Password)
    if ($ClientId -notmatch '^[a-zA-Z0-9]+$' -or -not $Username -or -not $Password) {
        throw 'A Cognito client ID and dedicated confirmed test-user credentials are required.'
    }
    $body = @{
        ClientId = $ClientId; AuthFlow = 'USER_PASSWORD_AUTH'
        AuthParameters = @{ USERNAME = $Username; PASSWORD = $Password }
    } | ConvertTo-Json -Depth 5 -Compress
    $status = 0
    $result = Invoke-RestMethod -Uri (Get-CognitoOrigin $Issuer) -Method POST -Headers @{
        'X-Amz-Target' = 'AWSCognitoIdentityProviderService.InitiateAuth'
    } -ContentType 'application/x-amz-json-1.1' -Body $body -SkipHttpErrorCheck -StatusCodeVariable status -TimeoutSec 30
    $data = $result | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    $authentication = $data['AuthenticationResult']
    if ($status -ne 200 -or $data['ChallengeName'] -or -not $authentication -or -not $authentication['IdToken']) {
        throw "Cognito test-user authentication failed (HTTP $status). Use a confirmed, non-MFA, non-admin test user with a permanent password."
    }
    return [string]$data.AuthenticationResult.IdToken
}

function Assert-CspConnectOrigin {
    param([string]$Csp, [string]$Origin)
    $directives = @($Csp -split ';' | Where-Object { $_ -match '^\s*connect-src\s' })
    if ($directives.Count -ne 1 -or $Origin -cnotin ($directives[0].Trim() -split '\s+')) {
        throw "Frontend Content-Security-Policy does not allow $Origin."
    }
}

function Write-SetupNextSteps {
    param([string]$Repository, [string]$Root)
    Write-Host "Both deployments passed. Actions: https://github.com/$Repository/actions/workflows/ci-cd.yml"
    $app = ($Repository -split '/')[-1]
    if ((Split-Path $Root -Leaf) -cne $app) {
        Write-Host "Rename this local folder to '$app' afterward when convenient. Setup left $Root unchanged; keep using your current VS Code window."
    }
    Write-Host "Then open $(Join-Path $Root 'context/onboarding/run-this-prompt-after-setup.md'), replace the app-description placeholder, and paste the prompt into your preferred AI agent."
}

function Get-SetupVercelTeam {
    param([string]$Token, [string]$TeamId)
    if (-not $TeamId) {
        $teams = [System.Collections.Generic.List[object]]::new()
        $path = '/v2/teams?limit=100'
        do {
            $page = Invoke-VercelApi -Token $Token -Path $path
            foreach ($team in $page.teams) { $teams.Add($team) }
            $data = $page | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
            $next = if ($data['pagination']) { $data['pagination']['next'] } else { $null }
            $path = "/v2/teams?limit=100&until=$next"
        } while ($next)
        if ($teams.Count -eq 0) { throw 'No Vercel team is visible. Use a token scoped to the original workspace and rerun.' }
        if ($teams.Count -eq 1) {
            $TeamId = $teams[0].id
        } else {
            for ($i = 0; $i -lt $teams.Count; $i++) { Write-Host "$($i + 1). $($teams[$i].name) ($($teams[$i].id))" }
            $selection = Read-SetupValue 'Vercel team number' '1'
            $number = 0
            if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $teams.Count) {
                throw 'Invalid Vercel team selection.'
            }
            $TeamId = $teams[$number - 1].id
        }
    }
    if ($TeamId -notmatch '^team_[a-zA-Z0-9]+$') { throw 'VERCEL_TEAM_ID must be a Vercel team ID starting with team_.' }
    return $TeamId
}

function Get-AppVercelProjects {
    param([string]$Token, [string]$OwnerId, [string]$AppName)
    $path = '/v9/projects?limit=100'
    do {
        $page = Invoke-VercelApi -Token $Token -OwnerId $OwnerId -Path $path
        foreach ($project in $page.projects) {
            if ($project.name -ceq $AppName -or $project.name -cmatch "^$([regex]::Escape($AppName))-\d+$") {
                if ($project.accountId -ne $OwnerId -or $project.id -notmatch '^prj_[a-zA-Z0-9_-]+$') { throw 'Cannot verify Vercel project ownership.' }
                $project
            }
        }
        $data = $page | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $next = if ($data['pagination']) { $data['pagination']['next'] } else { $null }
        $path = "/v9/projects?limit=100&until=$next"
    } while ($next)
}

function Get-SetupDeploymentRuns {
    param([string]$Repository, [string]$Branch, [string]$Commit)
    $json = Invoke-Checked gh -Arguments @('run', 'list', '--repo', $Repository, '--workflow', 'ci-cd.yml',
        '--branch', $Branch, '--commit', $Commit, '--limit', '100', '--json', 'databaseId,status,headSha,event')
    return @($json | ConvertFrom-Json)
}

function Wait-SetupDeployment {
    param([string]$Repository, [string]$Branch, [string]$Commit, [long]$RunId)
    $link = "https://github.com/$Repository/actions/runs/$RunId"
    Write-Host "Waiting for $Branch deployment: $link"
    for ($attempt = 0; $attempt -lt 360; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 15 }
        $run = Invoke-Checked gh -Arguments @('run', 'view', "$RunId", '--repo', $Repository,
            '--json', 'status,conclusion,headSha,headBranch,jobs') | ConvertFrom-Json
        if ($run.headSha -ne $Commit -or $run.headBranch -ne $Branch) {
            throw "Unexpected commit or branch in $link. Setup cannot verify success; the other pipeline may still be running."
        }
        if ($run.status -ne 'completed') { continue }
        if ($run.conclusion -ne 'success') { throw "$Branch deployment failed ($($run.conclusion)): $link. Setup stopped; inspect the failed Actions run." }
        foreach ($name in @('test-infrastructure', 'test-backend', 'test-website', 'Check changes and overrides', 'deploy', 'Test deployed website and API')) {
            $jobs = @($run.jobs | Where-Object name -EQ $name)
            if ($jobs.Count -ne 1 -or $jobs[0].conclusion -ne 'success') {
                throw "Required job $name did not succeed in $link. The other pipeline may still be running."
            }
        }
        $deploy = @($run.jobs | Where-Object name -EQ 'deploy')[0]
        foreach ($name in @('Bootstrap/update stateful resources without disabling compute', 'Build and push Lambda image',
            'Deploy Lambda and API Gateway', 'Build, deploy and verify frontend')) {
            $steps = @($deploy.steps | Where-Object name -EQ $name)
            if ($steps.Count -ne 1 -or $steps[0].conclusion -ne 'success') {
                throw "Required deployment step '$name' did not succeed in $link. The other pipeline may still be running."
            }
            $live = @($run.jobs | Where-Object name -EQ 'Test deployed website and API')[0]
            $steps = @($live.steps | Where-Object name -EQ 'Verify live API and browser contracts')
            if ($steps.Count -ne 1 -or $steps[0].conclusion -ne 'success') {
                throw "Required live verification step did not succeed in $link. The other pipeline may still be running."
            }
        }
        return
    }
    throw "Timed out waiting for $link (90 minutes). Check both Actions runs; either pipeline may still be running."
}

function Start-SetupDeployments {
    param([string]$Repository, [string]$Root)
    $target = Get-SetupRepositoryInfo -Repository $Repository
    if ($target['is_template']) { throw "Refusing to deploy template repository $Repository. Setup must create a separate application repository." }
    if (Invoke-Checked git -Arguments @('status', '--porcelain')) { throw 'Commit or stash local changes before automatic deployment.' }
    if ((Invoke-Checked git -Arguments @('branch', '--show-current')) -ne 'main') { throw 'Switch to main before automatic setup deployment.' }
    $origin = Invoke-Checked git -Arguments @('remote', 'get-url', '--push', 'origin')
    if ($origin -ne "https://github.com/$Repository.git") { throw 'Origin push URL does not match this application repository.' }
    $overrides = Join-Path $Root 'config/override.env'
    if ((Test-Path -LiteralPath $overrides) -and
        (Select-String -LiteralPath $overrides -Pattern '^\s*SKIP_(ALL|DEPLOY_(BACKEND|WEBSITE)|TEST_(INFRASTRUCTURE|BACKEND|WEBSITE_(UNIT|E2E|AUTH))|POST_DEPLOY_TESTS)\s*=\s*true\s*$')) {
        throw 'Remove enabled deployment skip flags and test skip flags from config/override.env before setup can deploy and verify both environments.'
    }
    $commit = Invoke-Checked git -Arguments @('rev-parse', 'refs/heads/main')
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid main commit.' }
    $gitAuth = @('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential')
    $null = Invoke-Checked git -Arguments ($gitAuth + @('fetch', $origin,
        '+refs/heads/main:refs/remotes/origin/main', '+refs/heads/dev:refs/remotes/origin/dev'))
    $remote = @{}
    foreach ($branch in @('main', 'dev')) {
        $remote[$branch] = Invoke-Checked git -Arguments @('rev-parse', "refs/remotes/origin/$branch")
        $ancestor = Invoke-External git -Arguments @('merge-base', '--is-ancestor', $remote[$branch], $commit) -AllowFailure
        if ($ancestor.Code -eq 1) { throw "Remote $branch has changes outside local main. Refusing to overwrite or synchronize divergent branches." }
        if ($ancestor.Code -ne 0) { throw "Cannot check $branch ancestry: $($ancestor.Text)" }
    }
    $startedRuns = @{}
    foreach ($branch in @('main', 'dev')) {
        $previous = @(Get-SetupDeploymentRuns -Repository $Repository -Branch $branch -Commit $commit)
        $active = @($previous | Where-Object { $_.headSha -eq $commit -and $_.status -ne 'completed' })
        $runId = $null
        if ($remote[$branch] -eq $commit -and $active.Count -gt 0) {
            $runId = $active[0].databaseId
        } else {
            $event = 'workflow_dispatch'
            if ($remote[$branch] -ne $commit) {
                $messages = Invoke-Checked git -Arguments @('log', "$($remote[$branch])..$commit", '--format=%B')
                $skipped = $messages -match '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|skip-checks:\s*true'
                $null = Invoke-Checked git -Arguments ($gitAuth + @('push', $origin, "${commit}:refs/heads/$branch"))
                if (-not $skipped) { $event = 'push' }
            }
            if ($event -eq 'workflow_dispatch') {
                $null = Invoke-Checked gh -Arguments @('workflow', 'run', 'ci-cd.yml', '--repo', $Repository, '--ref', $branch)
            }
            $previousIds = @($previous | ForEach-Object databaseId)
            for ($attempt = 0; $attempt -lt 24; $attempt++) {
                if ($attempt -gt 0) { Start-Sleep -Seconds 5 }
                $runs = @(Get-SetupDeploymentRuns -Repository $Repository -Branch $branch -Commit $commit)
                $new = @($runs | Where-Object { $_.headSha -eq $commit -and $_.event -eq $event -and $_.databaseId -notin $previousIds })
                if ($new.Count -gt 0) { $runId = $new[0].databaseId; break }
            }
            if (-not $runId) { throw "No new $branch CI/CD run appeared. Check https://github.com/$Repository/actions; no further branches were pushed." }
        }
        $startedRuns[$branch] = $runId
        Write-Host "Started $branch pipeline: https://github.com/$Repository/actions/runs/$runId"
    }
    foreach ($branch in @('main', 'dev')) {
        Wait-SetupDeployment -Repository $Repository -Branch $branch -Commit $commit -RunId $startedRuns[$branch]
    }
}

function Wait-VercelProduction {
    param([string]$Token, [string]$OwnerId, [string]$ProjectId, [int]$Attempts = 120)
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 10 }
        $project = Invoke-VercelApi -Token $Token -OwnerId $OwnerId -Path "/v9/projects/$ProjectId"
        $data = $project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        if ($data['id'] -ne $ProjectId -or $data['accountId'] -ne $OwnerId) {
            throw 'Vercel project ownership does not match the configured Preview project.'
        }
        if ($data['targets'] -and $data['targets']['production'] -and
            $data['targets']['production']['readyState'] -eq 'READY') { return }
        if ($attempt -eq 0) {
            Write-Host 'Waiting for the first ready Production website before uploading Preview; both pipelines can otherwise run in parallel.'
        }
    }
    throw 'Timed out waiting for a ready Vercel Production website (20 minutes). Inspect main; no Preview was uploaded.'
}

function Set-VercelProjectDomain {
    param(
        [string]$Token, [string]$OwnerId, [string]$ProjectId,
        [string]$Domain, [AllowNull()][string]$Branch
    )
    $domains = Invoke-VercelApi -Token $Token -OwnerId $OwnerId -Path "/v9/projects/$ProjectId/domains?limit=100"
    $matches = @($domains.domains | Where-Object name -EQ $Domain)
    $body = @{ gitBranch = if ($Branch) { $Branch } else { $null } }
    if ($matches.Count -eq 0) {
        $body.name = $Domain
        $result = Invoke-VercelApi -Token $Token -OwnerId $OwnerId -Path "/v10/projects/$ProjectId/domains" -Method POST -Body $body
    } else {
        $result = $matches[0]
        $data = $result | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        if ($data['redirect']) { throw "Generated website domain $Domain is configured as a redirect. Remove the redirect before rerunning setup." }
        if ([string]$data['gitBranch'] -ne [string]$Branch) {
            $result = Invoke-VercelApi -Token $Token -OwnerId $OwnerId -Path "/v9/projects/$ProjectId/domains/$Domain" -Method PATCH -Body $body
        }
    }
    if (-not $result.verified) { throw "Vercel could not verify website domain $Domain." }
}

function Get-VercelDeploymentUrl {
    param([string]$Output)
    $urls = @([regex]::Matches($Output, '(?m)^https://[a-z0-9.-]+\.vercel\.app/?\r?$') |
        ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    if ($urls.Count -ne 1) { throw 'Vercel CLI did not return one unambiguous deployment URL.' }
    return Get-WebsiteOrigin $urls[0]
}

function New-VercelOutputConfig {
    param([string]$ApiUrl, [string]$HeadersPath, [string]$CognitoOrigin)
    $origin = Get-WebsiteOrigin $ApiUrl
    $connections = if ($CognitoOrigin) { "$origin $(Get-WebsiteOrigin $CognitoOrigin)" } else { $origin }
    $config = Get-Content -LiteralPath $HeadersPath -Raw | ConvertFrom-Json
    $headers = @{}
    foreach ($header in $config.headers[0].headers) {
        $headers[$header.key] = $header.value
    }
    $headers['Content-Security-Policy'] = $headers['Content-Security-Policy'].Replace(
        "connect-src 'self' https://api.saasbase.example.com", "connect-src 'self' $connections"
    )
    Assert-CspConnectOrigin -Csp $headers['Content-Security-Policy'] -Origin $origin
    if ($CognitoOrigin) { Assert-CspConnectOrigin -Csp $headers['Content-Security-Policy'] -Origin $CognitoOrigin }
    return @{
        version = 3
        routes = @(
            @{ src = '/(.*)'; headers = $headers; continue = $true },
            @{ handle = 'filesystem' },
            @{ src = '/(.*)'; dest = '/index.html' }
        )
    }
}

function Test-LiveDeployment {
    param([string]$ApiUrl, [string]$WebsiteUrl, [string]$ProtectionBypass, [string]$CognitoOrigin)
    $api = Get-WebsiteOrigin $ApiUrl
    $website = Get-WebsiteOrigin $WebsiteUrl
    $health = Invoke-RestMethod -Uri "$api/health" -TimeoutSec 30
    if ($health.status -ne 'ok') { throw 'Backend health check did not return status=ok.' }
    $cors = Invoke-WebRequest -Uri "$api/health" -Method Options -Headers @{
        Origin = $website; 'Access-Control-Request-Method' = 'GET'
    } -TimeoutSec 30
    if ($cors.Headers['Access-Control-Allow-Origin'] -notcontains $website) {
        throw "Backend CORS does not allow $website."
    }
    $headers = @{}
    if ($ProtectionBypass) { $headers['x-vercel-protection-bypass'] = $ProtectionBypass }
    $page = Invoke-WebRequest -Uri $website -Headers $headers -MaximumRedirection 0 -TimeoutSec 30
    if ($page.Content -notmatch '<div id="app"') { throw 'The deployed page is not the expected Vue application.' }
    $csp = $page.Headers['Content-Security-Policy'] -join ' '
    Assert-CspConnectOrigin -Csp $csp -Origin $api
    if ($CognitoOrigin) { Assert-CspConnectOrigin -Csp $csp -Origin $CognitoOrigin }
    Write-Host "Verified backend, CORS, frontend and CSP: $website" -ForegroundColor Green
}
