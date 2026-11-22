#Requires -Version 7.2
[CmdletBinding()]
param([string]$AppName, [string]$GitHubOwner, [string]$AWSProfile, [string]$AWSRegion, [string]$VercelTeamId, [switch]$Plan)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$config = Read-SetupConfig (Join-Path $root 'config/setup.env')
$app = if ($AppName) { $AppName } else { Read-SetupValue 'Application name to permanently purge' }
Assert-AppName $app
$login = Invoke-Checked gh -Arguments @('api', 'user', '--jq', '.login')
$owner = if ($GitHubOwner) { $GitHubOwner } else { Read-SetupValue 'GitHub owner' $login }
if ($owner -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') { throw 'Invalid GitHub owner.' }
$repository = "$owner/$app"
$profile = if ($AWSProfile) { $AWSProfile } else { Read-SetupValue 'Local AWS profile' $(if ($config['AWS_PROFILE']) { $config['AWS_PROFILE'] } else { 'default' }) }
$region = if ($AWSRegion) { $AWSRegion } else { Read-SetupValue 'AWS region' $(if ($config['AWS_REGION']) { $config['AWS_REGION'] } else { 'us-east-2' }) }
if ($profile -notmatch '^[a-zA-Z0-9_-]+$' -or $region -notmatch '^[a-z]{2}-[a-z]+-\d+$' -or $region -match '^(cn-|us-gov-)') { throw 'Invalid AWS profile or commercial region.' }
$awsIdentity = Invoke-Checked aws -Arguments @('sts', 'get-caller-identity', '--profile', $profile, '--region', $region, '--no-cli-pager', '--output', 'json') | ConvertFrom-Json
if ($awsIdentity.Account -notmatch '^\d{12}$' -or $awsIdentity.Arn -notlike 'arn:aws:*' -or $awsIdentity.Arn -like '*:root') { throw 'Use a non-root administrator in a standard AWS account.' }
$recordPath = Join-Path $root ".setup/purge-$owner-$app.json"
$saved = if (Test-Path -LiteralPath $recordPath) { Get-Content $recordPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
$statePath = Join-Path $root '.setup/state.json'
$state = if (Test-Path -LiteralPath $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
$team = if ($VercelTeamId) { $VercelTeamId
} elseif ($saved -and -not $saved.Complete) { $saved.TeamId
} elseif ($state -and $state.VercelOwnerId -and $state.AppName -ceq $app -and $state.Repository -ceq $repository -and
    $state.AccountId -eq $awsIdentity.Account -and $state.Region -eq $region) { $state.VercelOwnerId
} elseif ($config['VERCEL_TEAM_ID']) { $config['VERCEL_TEAM_ID']
} elseif ($env:VERCEL_TEAM_ID) { $env:VERCEL_TEAM_ID
} else { '' }
function Get-PurgeRepository {
    $result = Invoke-External gh -Arguments @('api', "repos/$repository") -AllowFailure
    if ($result.Code -ne 0) {
        if ($result.Text -match 'HTTP 404') { return $null }
        throw "Cannot inspect purge repository: $($result.Text)"
    }
    $repo = $result.Text | ConvertFrom-Json -AsHashtable
    if ($repo.full_name -ne $repository -or $repo.is_template -ne $false -or -not $repo.permissions.admin -or -not $repo.id) {
        throw 'Purge requires administrator access to a non-template application repository.'
    }
    return $repo
}
$token = $null
try {
    $repo = Get-PurgeRepository
    if ($repo) {
        $headers = Invoke-Checked gh -Arguments @('api', '--include', 'user', '--jq', '.login')
        if ($headers -match '(?im)^x-oauth-scopes:[ \t]*([^\r\n]*)') {
            $scopes = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() })
            if ('delete_repo' -notin $scopes) {
                throw 'GitHub token lacks delete_repo. Run: gh auth refresh -h github.com -s delete_repo, then rerun purge. Environment-supplied tokens must be replaced with one authorized to delete this repository.'
            }
        } else {
            Write-Host 'GitHub token does not report OAuth scopes; deletion permission cannot be preverified. GitHub will enforce it during repository deletion.'
        }
    }
    $token = Get-SetupVercelToken
    if (-not $token) { throw 'A Vercel token is required.' }
    $team = Get-SetupVercelTeam -Token $token -TeamId $team
    $projects = @(Get-AppVercelProjects -Token $token -OwnerId $team -AppName $app)
    $identity = @{
        AppName = $app; AccountId = [string]$awsIdentity.Account; Region = $region; Profile = $profile
        Repository = $repository; VercelProjectId = $null; VercelOwnerId = $null
    }
    if ($saved -and -not $saved.Complete) {
        foreach ($key in @('AppName', 'AccountId', 'Region', 'Profile', 'Repository')) {
            if ($saved.Identity[$key] -ne $identity[$key]) { throw 'Pending purge belongs to another identity. Refusing deletion.' }
        }
        if ($saved.TeamId -ne $team -or ($repo -and $repo.id -ne $saved.RepositoryId)) { throw 'Repository or team changed since purge began. Refusing deletion.' }
        foreach ($project in $projects) {
            if ($project.id -notin @($saved.Projects | ForEach-Object id)) { throw 'A new Vercel project appeared since purge began. Refusing deletion.' }
        }
        $record = $saved
    } else {
        $record = @{ Identity = $identity; TeamId = $team; RepositoryId = $(if ($repo) { $repo.id } else { $null }); Projects = @($projects | ForEach-Object { @{ id = $_.id; name = $_.name } }); Complete = $false }
    }
    $awsPlanError = $null
    try { & (Join-Path $PSScriptRoot 'destroy-project.ps1') -Preflight -Purge -Plan -SetupIdentity $identity }
    catch {
        $awsPlanError = $_.Exception.Message
        Write-Warning "AWS inventory could not be verified; AWS deletion will be skipped. Other verified providers can still be purged. $awsPlanError"
    }
    Write-Host "`nPERMANENT PURGE: $repository | AWS $($identity.AccountId) ($region) | Vercel $team"
    if ($repo) { Write-Host "Delete GitHub repository: $repository (including remote code, issues, settings and secrets)" }
    foreach ($project in $projects) { Write-Host "Delete Vercel project: $($project.name) ($($project.id)), all deployments and configuration" }
    Write-Host 'NO GOING BACK: app data, users, secrets, files and cloud resources are permanently deleted. No backups are made. Local files, shared infrastructure and unrelated names are not deleted.'
    Write-Host 'AWS scope is the selected region (IAM roles are account-global). Resources in other accounts/regions and backups are not purged.'
    if ($Plan) {
        if ($awsPlanError) { throw "Purge plan incomplete: AWS: $awsPlanError" }
        return
    }
    if ((Read-Host "Type PURGE $app $($identity.AccountId) $repository to confirm irreversible deletion") -cne "PURGE $app $($identity.AccountId) $repository") { throw 'Purge cancelled. No resources were changed.' }
    $null = New-Item -ItemType Directory -Path (Split-Path $recordPath -Parent) -Force
    $record.Errors = @()
    Write-JsonFile $recordPath $record
    $current = Get-PurgeRepository
    if ($current -and $current.id -ne $record.RepositoryId) { throw 'Repository identity changed. Refusing deletion.' }
    if ($current) {
        $workflows = Invoke-Checked gh -Arguments @('api', "repos/$repository/actions/workflows?per_page=100", '--paginate', '--jq', '.workflows[] | [.id, .state] | @tsv')
        foreach ($line in $workflows -split '\r?\n' | Where-Object { $_ }) {
            $fields = $line -split "`t"
            if ($fields.Count -ne 2 -or $fields[0] -notmatch '^\d+$') { throw 'Invalid workflow identity or state.' }
            $id, $workflowState = $fields
            if ($workflowState -match '^disabled_' -or $workflowState -eq 'deleted') { continue }
            if ($workflowState -ne 'active') { throw "Unknown workflow state for $id`: $workflowState" }
            $disabled = Invoke-External gh -Arguments @('workflow', 'disable', $id, '--repo', $repository) -AllowFailure
            if ($disabled.Code -ne 0) {
                if ($disabled.Text -match 'Unable to disable a workflow that is not active') {
                    $workflowState = Invoke-Checked gh -Arguments @('api', "repos/$repository/actions/workflows/$id", '--jq', '.state')
                    if ($workflowState -match '^disabled_' -or $workflowState -eq 'deleted') { continue }
                }
                throw "Cannot disable workflow $id; cloud deletion has not started. $($disabled.Text)"
            }
        }
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $active = @(
                foreach ($status in @('queued', 'in_progress', 'waiting', 'pending', 'requested')) {
                    $runs = Invoke-Checked gh -Arguments @('api', "repos/$repository/actions/runs?status=$status&per_page=100", '--paginate', '--jq', '.workflow_runs[].id')
                    foreach ($id in $runs -split '\r?\n' | Where-Object { $_ }) {
                        if ($id -notmatch '^\d+$') { throw 'Invalid workflow run ID.' }
                        $id
                    }
                }
            )
            if ($active.Count -eq 0) { break }
            if ($attempt -eq 0) { foreach ($id in $active | Select-Object -Unique) { $null = Invoke-Checked gh -Arguments @('run', 'cancel', $id, '--repo', $repository) } }
            Start-Sleep -Seconds 5
        }
        if ($active.Count -gt 0) { throw 'Workflow runs are still active. Purge stopped before cloud deletion.' }
    }
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($awsPlanError) { $failures.Add("AWS skipped (unverified inventory): $awsPlanError") }
    else {
        try { & (Join-Path $PSScriptRoot 'destroy-project.ps1') -Preflight -Purge -Confirmed -SetupIdentity $identity }
        catch {
            $failures.Add("AWS: $($_.Exception.Message)")
        }
    }
    foreach ($project in $record.Projects) {
        try {
            $current = Invoke-VercelApi -Token $token -OwnerId $team -Path "/v9/projects/$($project.id)" -AllowNotFound
            if (-not $current) { continue }
            if ($current.id -ne $project.id -or $current.name -cne $project.name -or $current.accountId -ne $team) { throw 'Vercel project identity changed. Refusing deletion.' }
            $null = Invoke-VercelApi -Token $token -OwnerId $team -Path "/v9/projects/$($project.id)" -Method DELETE
            if (Invoke-VercelApi -Token $token -OwnerId $team -Path "/v9/projects/$($project.id)" -AllowNotFound) { throw 'Vercel project deletion was not confirmed.' }
        } catch {
            $failures.Add("Vercel project $($project.name) ($($project.id)): $($_.Exception.Message)")
        }
    }
    try {
        $remaining = @(Get-AppVercelProjects -Token $token -OwnerId $team -AppName $app)
        if ($remaining.Count -gt 0) { throw "Matching Vercel projects remain: $($remaining.name -join ', ')." }
    } catch { $failures.Add("Vercel verification: $($_.Exception.Message)") }
    try {
        $current = Get-PurgeRepository
        if ($current) {
            if ($current.id -ne $record.RepositoryId) { throw 'Repository was replaced. Refusing deletion.' }
            $deletion = Invoke-External gh -Arguments @('api', '--method', 'DELETE', "repos/$repository") -AllowFailure
            if ($deletion.Code -ne 0) {
                if ($deletion.Text -match 'HTTP 403') {
                    throw "Repository deletion was denied for $repository. For GitHub CLI sign-in, run: gh auth refresh -h github.com -s delete_repo. Update environment tokens separately: classic tokens need delete_repo, fine-grained tokens need repository Administration write access. Also check account admin rights and organization deletion restrictions. $($deletion.Text)"
                }
                throw "GitHub repository deletion failed (exit $($deletion.Code)). $($deletion.Text)"
            }
            if (Get-PurgeRepository) { throw 'GitHub repository deletion was not confirmed.' }
        }
    } catch {
        $failures.Add("GitHub repository $repository`: $($_.Exception.Message)")
    }
    $record.Errors = @($failures.ToArray())
    $record.Complete = $failures.Count -eq 0
    Write-JsonFile $recordPath $record
    if (-not $record.Complete) {
        throw "Purge incomplete. Failed or unverified resources:`n - $($failures -join "`n - ")`nKeep the purge records and retry the same command after resolving these errors. Successful deletions are not undone."
    }
    Write-Host 'Purge complete. Inventoried AWS resources, Vercel projects and GitHub repository were permanently deleted. Local files remain.' -ForegroundColor Green
} finally { $token = $null }
