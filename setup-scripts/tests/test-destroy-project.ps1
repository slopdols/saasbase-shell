#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path $PSScriptRoot -Parent
. (Join-Path $scripts 'common.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) "shell-destroy-tests-$([guid]::NewGuid().ToString('N'))"
$fixture = Join-Path $temp 'app'
$null = New-Item -ItemType Directory -Path (Join-Path $fixture 'setup-scripts'), (Join-Path $fixture '.setup') -Force
Copy-Item (Join-Path $scripts 'common.ps1'), (Join-Path $scripts 'destroy-project.ps1'), (Join-Path $scripts 'aws-preflight.ps1'), (Join-Path $scripts 'purge-project.ps1') -Destination (Join-Path $fixture 'setup-scripts')
$savedToken = $env:VERCEL_TOKEN
$savedTeam = $env:VERCEL_TEAM_ID
$env:VERCEL_TOKEN = 'fake-teardown-token'
$env:VERCEL_TEAM_ID = $null
$passed = 0

function Assert-TeardownTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-TeardownCase {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-TeardownFailure {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected teardown failure containing $Message"
}
function New-TeardownFixture {
    Remove-Item -LiteralPath (Join-Path $fixture '.setup/teardown.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $fixture '.setup/purge-aws-app.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $fixture '.setup/purge-owner-app.json') -Force -ErrorAction SilentlyContinue
    $global:ShellTeardownMock = @{
        Account = '123456789012'; Repository = 'owner/app'; Confirm = 'DELETE app'; WorkflowActive = $true
        Runs = @('100'); KeepRuns = $false; Paused = $false; FailWait = $false; FailSecret = $false; Replaced = $false; FailObjects = $false
        Calls = [System.Collections.Generic.List[string]]::new(); Mutations = [System.Collections.Generic.List[string]]::new()
        Stacks = @{}; Resources = @{}; Live = @{}; ObjectDeletes = @(); UploadsAborted = 0
        Preflight = $false; Orphans = @{}; RepoExists = $false; ForeignBucket = $false; ReplaceOnConfirm = $false
        BootstrapArn = 'arn:aws:iam::123456789012:user/test'
        RepositoryId = 456; Template = $false; Projects = @{}; FailProjectDelete = $false
        Teams = @(@{ id = 'team_test'; name = 'Test workspace' }); TeamDenied = $false
        GitHubScopes = 'repo, workflow, delete_repo'; FailRepositoryDelete = $false
        WorkflowDisableRace = $false; RejectDisabledWorkflow = $false; FailedProjectIds = @()
    }
    $mock = $global:ShellTeardownMock
    Write-JsonFile (Join-Path $fixture '.setup/state.json') @{
        AppName = 'app'; AccountId = '123456789012'; Region = 'us-east-2'; Profile = 'test'
        Repository = 'owner/app'; VercelProjectId = 'prj_app'; VercelOwnerId = 'team_test'
    }
    foreach ($stage in @('prod', 'dev')) {
        $id = "arn:aws:cloudformation:us-east-2:123456789012:stack/app-$stage/root-$stage"
        $childId = "arn:aws:cloudformation:us-east-2:123456789012:stack/app-$stage-data/child-$stage"
        $mock.Stacks[$id] = @{
            StackId = $id; StackName = "app-$stage"; StackStatus = 'CREATE_COMPLETE'; EnableTerminationProtection = $true
            Parameters = @(@{ ParameterKey = 'AppName'; ParameterValue = 'app' }, @{ ParameterKey = 'Stage'; ParameterValue = $stage })
        }
        $mock.Stacks[$childId] = @{
            StackId = $childId; StackName = "app-$stage-data"; StackStatus = 'CREATE_COMPLETE'; ParentId = $id; RootId = $id
            Parameters = @()
        }
        $mock.Resources[$id] = @(@{ LogicalResourceId = 'Data'; PhysicalResourceId = $childId; ResourceType = 'AWS::CloudFormation::Stack'; ResourceStatus = 'CREATE_COMPLETE' })
        $types = @{
            Table = 'AWS::DynamoDB::Table'; Images = 'AWS::ECR::Repository'
            Secret = 'AWS::SecretsManager::Secret'; Bucket = 'AWS::S3::Bucket'; Function = 'AWS::Lambda::Function'
        }
        $mock.Resources[$childId] = @(
            foreach ($key in $types.Keys) {
                $resourceId = "app-$stage-$key"
                if ($key -eq 'Secret') { $resourceId = "arn:aws:secretsmanager:us-east-2:123456789012:secret:app-$stage-secret-AbCdEf" }
                $mock.Live[$resourceId] = @{
                    Type = $types[$key]; Exists = $true; TableId = "table-$stage"; Protected = $true; StackId = $childId
                    Pending = $false; Versions = @(@{ Key = 'data'; VersionId = 'v1' }); Markers = @(@{ Key = 'data'; VersionId = 'marker1' })
                    Uploads = @(@{ Key = 'unfinished'; UploadId = 'upload1' })
                }
                @{ LogicalResourceId = $key; PhysicalResourceId = $resourceId; ResourceType = $types[$key]; ResourceStatus = 'CREATE_COMPLETE' }
            }
        )
    }
}

function Start-Sleep { param($Seconds) }
function Read-Host {
    param($Prompt, [switch]$AsSecureString)
    if ($global:ShellTeardownMock.ReplaceOnConfirm) {
        ($global:ShellTeardownMock.Orphans.Values | Where-Object Name -EQ 'app-main-prod').Identity = 'replacement'
    }
    return $global:ShellTeardownMock.Confirm
}
function gh {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $mock = $global:ShellTeardownMock
    $text = $Arguments -join ' '
    $mock.Calls.Add("gh $text")
    $global:LASTEXITCODE = 0
    if ($text -eq 'api user --jq .login') { return 'owner' }
    if ($text -eq 'api --include user --jq .login') {
        if ($null -eq $mock.GitHubScopes) { return "HTTP/2.0 200 OK`r`n`r`nowner" }
        return "HTTP/2.0 200 OK`r`nX-OAuth-Scopes: $($mock.GitHubScopes)`r`n`r`nowner"
    }
    if ($text -eq 'api repos/owner/app') {
        if ($mock.RepoExists) { return (@{ full_name = 'owner/app'; id = $mock.RepositoryId; is_template = $mock.Template; permissions = @{ admin = $true } } | ConvertTo-Json -Depth 5) }
        $global:LASTEXITCODE = 1; return 'HTTP 404'
    }
    if ($text -eq 'api --method DELETE repos/owner/app') {
        if ($mock.FailRepositoryDelete) { $global:LASTEXITCODE = 1; return 'gh: Must have admin rights to Repository. (HTTP 403)' }
        $mock.RepoExists = $false; $mock.Mutations.Add("gh $text"); return
    }
    if ($text.StartsWith('api repos/owner/app/actions/workflows?')) { return "42`t$(if ($mock.WorkflowActive) { 'active' } else { 'disabled_manually' })" }
    if ($text -eq 'api repos/owner/app/actions/workflows/42 --jq .state') { return $(if ($mock.WorkflowActive) { 'active' } else { 'disabled_manually' }) }
    if ($text.StartsWith('api repos/owner/app/actions/runs?')) {
        if ($text -like '*status=in_progress*') { return ($mock.Runs -join "`n") }
        return ''
    }
    if ($text -like 'repo view*') { return $mock.Repository }
    if ($text -eq 'api repos/owner/app/actions/workflows/ci-cd.yml') {
        return (@{ id = 42; state = $(if ($mock.WorkflowActive) { 'active' } else { 'disabled_manually' }) } | ConvertTo-Json)
    }
    if ($text -like 'api repos/owner/app/actions/workflows/42/runs*') {
        if ($text -like '*status=in_progress*') { return ($mock.Runs -join "`n") }
        return ''
    }
    if ($text -eq 'workflow disable 42 --repo owner/app') {
        if ($mock.WorkflowDisableRace -or ($mock.RejectDisabledWorkflow -and -not $mock.WorkflowActive)) {
            $mock.WorkflowActive = $false; $global:LASTEXITCODE = 1
            return 'HTTP 403: Unable to disable a workflow that is not active.'
        }
        $mock.WorkflowActive = $false; $mock.Mutations.Add("gh $text"); return
    }
    if ($text -eq 'workflow enable 42 --repo owner/app') { $mock.WorkflowActive = $true; $mock.Mutations.Add("gh $text"); return }
    if ($text -like 'run cancel * --repo owner/app') {
        $mock.Mutations.Add("gh $text")
        if (-not $mock.KeepRuns) { $mock.Runs = @() }
        return
    }
    throw "Unexpected teardown gh command: $text"
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, [switch]$SkipHttpErrorCheck, $StatusCodeVariable, $ContentType, $Body)
    $mock = $global:ShellTeardownMock
    $mock.Calls.Add("vercel $Method $Uri")
    Set-Variable $StatusCodeVariable 200 -Scope 1
    $path = ([uri]$Uri).AbsolutePath
    if ($path -eq '/v2/teams') {
        if ($mock.TeamDenied) { Set-Variable $StatusCodeVariable 403 -Scope 1; return @{} }
        return @{ teams = $mock.Teams; pagination = @{} }
    }
    if ($path -eq '/v9/projects') { return @{ projects = @($mock.Projects.Values); pagination = @{} } }
    if ($path -match '^/v9/projects/(prj_purge|prj_other|prj_second)$') {
        $id = $Matches[1]
        if (-not $mock.Projects.ContainsKey($id)) { Set-Variable $StatusCodeVariable 404 -Scope 1; return @{} }
        if ($Method -eq 'DELETE') {
            if ($mock.FailProjectDelete -or $id -in $mock.FailedProjectIds) { Set-Variable $StatusCodeVariable 403 -Scope 1; return @{} }
            $mock.Projects.Remove($id); $mock.Mutations.Add("vercel DELETE $path"); return @{}
        }
        return $mock.Projects[$id]
    }
    if ($path -eq '/v9/projects/prj_app') { return @{ id = 'prj_app'; accountId = 'team_test'; paused = $mock.Paused } }
    if ($path -eq '/v1/projects/prj_app/pause' -and $Method -eq 'POST') {
        $mock.Paused = $true
        $mock.Mutations.Add("vercel $Method $path")
        return @{}
    }
    throw "Unexpected teardown Vercel request: $Method $Uri"
}
function aws {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $mock = $global:ShellTeardownMock
    $text = $Arguments -join ' '
    $mock.Calls.Add("aws $text")
    $global:LASTEXITCODE = 0
    $service = $Arguments[0]; $action = $Arguments[1]
    if ($service -eq 'sts') { return (@{ Account = $mock.Account; Arn = $mock.BootstrapArn } | ConvertTo-Json) }
    if ($service -eq 'cloudformation') {
        $id = $Arguments[[array]::IndexOf($Arguments, '--stack-name') + 1]
        if ($action -eq 'describe-stacks') {
            if (-not $id.StartsWith('arn:')) {
                $found = @($mock.Stacks.Values | Where-Object { $_.StackName -eq $id -and $_.StackStatus -ne 'DELETE_COMPLETE' })
                if ($mock.Replaced -and $id -eq 'app-prod') {
                    $replacement = $mock.Stacks.Values | Where-Object StackName -EQ 'app-prod' | Select-Object -First 1
                    $replacement = $replacement.Clone()
                    $replacement.StackId += '-new'
                    $replacement.StackStatus = 'CREATE_COMPLETE'
                    $found = @($replacement)
                }
            } else { $found = @($mock.Stacks[$id] | Where-Object { $_ }) }
            if ($found.Count -eq 0) { $global:LASTEXITCODE = 1; return '(ValidationError) Stack does not exist' }
            return (@{ Stacks = $found } | ConvertTo-Json -Depth 10)
        }
        if ($action -eq 'list-stack-resources') { return (@{ StackResourceSummaries = $mock.Resources[$id] } | ConvertTo-Json -Depth 10) }
        if ($action -eq 'wait') {
            if ($mock.FailWait) { $global:LASTEXITCODE = 17; return 'mock stack deletion failure' }
            return
        }
        $mock.Mutations.Add("aws $text")
        if ($action -eq 'update-termination-protection') { $mock.Stacks[$id].EnableTerminationProtection = $false; return '{}' }
        if ($action -eq 'delete-stack') {
            $mock.Stacks[$id].StackStatus = 'DELETE_COMPLETE'
            foreach ($child in @($mock.Stacks.Values | Where-Object { $_['RootId'] -eq $id })) {
                $child.StackStatus = 'DELETE_COMPLETE'
                foreach ($resource in $mock.Resources[$child.StackId]) {
                    if ($resource.ResourceType -eq 'AWS::Cognito::UserPool') {
                        $resource.ResourceStatus = 'DELETE_COMPLETE'
                        $pool = $mock.Orphans.Values | Where-Object Id -EQ $resource.PhysicalResourceId
                        Assert-TeardownTest (-not $pool.Protected) 'CloudFormation pool deletion protection was not disabled.'
                        $pool.Exists = $false; $pool.DomainExists = $false
                    } elseif ($resource.ResourceType -eq 'AWS::Lambda::Function') {
                        $resource.ResourceStatus = 'DELETE_COMPLETE'
                        $mock.Live[$resource.PhysicalResourceId].Exists = $false
                    } else { $resource.ResourceStatus = 'DELETE_SKIPPED' }
                }
            }
            return
        }
        throw "Unexpected CloudFormation action: $action"
    }
    if ($mock.Preflight) {
        $flag = switch ($service) { dynamodb { '--table-name' }; ecr { if ($action -eq 'describe-repositories') { '--repository-names' } else { '--repository-name' } }; secretsmanager { '--secret-id' }; s3api { '--bucket' } }
        $index = if ($flag) { [array]::IndexOf($Arguments, $flag) } else { -1 }
        if ($index -lt 0 -or -not $mock.Live.ContainsKey($Arguments[$index + 1])) {
            return Invoke-PreflightMockAws -Arguments $Arguments
        }
    }
    $flag = switch ($service) { dynamodb { '--table-name' }; ecr { if ($action -eq 'describe-repositories') { '--repository-names' } else { '--repository-name' } }; secretsmanager { '--secret-id' }; s3api { '--bucket' } }
    if (-not $flag) { throw "Unexpected AWS service: $service" }
    $id = $Arguments[[array]::IndexOf($Arguments, $flag) + 1]
    if (-not $mock.Live.ContainsKey($id)) { throw "Attempt to access a resource outside the fixture: $id" }
    $live = $mock.Live[$id]
    if (-not $live.Exists) {
        $global:LASTEXITCODE = 1
        return $(switch ($service) { dynamodb { '(ResourceNotFoundException)' }; ecr { '(RepositoryNotFoundException)' }; secretsmanager { '(ResourceNotFoundException)' }; s3api { '(NoSuchBucket)' } })
    }
    switch ("$service $action") {
        'dynamodb describe-table' { return (@{ Table = @{ TableId = $live.TableId; DeletionProtectionEnabled = $live.Protected; TableStatus = 'ACTIVE' } } | ConvertTo-Json) }
        'ecr describe-repositories' { return (@{ repositories = @(@{ repositoryArn = "arn:aws:ecr:us-east-2:123456789012:repository/$id"; createdAt = '2026-01-01' }) } | ConvertTo-Json) }
        'secretsmanager describe-secret' {
            $secret = @{ ARN = $id }
            if ($live.Pending) { $secret.DeletedDate = '2026-01-01' }
            return ($secret | ConvertTo-Json)
        }
        's3api get-bucket-tagging' { return (@{ TagSet = @(@{ Key = 'aws:cloudformation:stack-id'; Value = $live.StackId }) } | ConvertTo-Json) }
        's3api list-object-versions' { return (@{ Versions = $live.Versions; DeleteMarkers = $live.Markers } | ConvertTo-Json -Depth 5) }
        's3api list-multipart-uploads' { return (@{ Uploads = $live.Uploads } | ConvertTo-Json -Depth 5) }
    }
    $mock.Mutations.Add("aws $text")
    switch ("$service $action") {
        'dynamodb update-table' { Assert-TeardownTest ($Arguments -contains '--no-deletion-protection-enabled') 'Protection was not disabled.'; $live.Protected = $false }
        'dynamodb delete-table' { Assert-TeardownTest (-not $live.Protected) 'Protected table deletion attempted.'; $live.Exists = $false }
        'ecr delete-repository' { Assert-TeardownTest ($Arguments -contains '--force') 'Retained images were not removed.'; $live.Exists = $false }
        'secretsmanager delete-secret' {
            Assert-TeardownTest ($Arguments -contains '--force-delete-without-recovery') 'Secret would remain scheduled for deletion.'
            if ($mock.FailSecret) { $live.Pending = $true } else { $live.Exists = $false }
        }
        's3api delete-objects' {
            if ($mock.FailObjects) { return '{"Errors":[{"Code":"AccessDenied","Key":"data"}]}' }
            $file = $Arguments[[array]::IndexOf($Arguments, '--delete') + 1]
            $data = Get-Content -LiteralPath $file.Substring(7) -Raw | ConvertFrom-Json -AsHashtable
            $mock.ObjectDeletes += @($data.Objects)
            $live.Versions = @(); $live.Markers = @()
        }
        's3api abort-multipart-upload' { $live.Uploads = @(); $mock.UploadsAborted++ }
        's3api delete-bucket' {
            Assert-TeardownTest ($live.Versions.Count -eq 0 -and $live.Markers.Count -eq 0 -and $live.Uploads.Count -eq 0) 'Bucket was not fully emptied.'
            $live.Exists = $false
        }
        default { throw "Unexpected resource deletion: $text" }
    }
    return '{}'
}

function New-PreflightFixture {
    param([switch]$WithoutStacks)
    New-TeardownFixture
    $mock = $global:ShellTeardownMock
    $mock.Preflight = $true
    $mock.Confirm = 'DELETE app 123456789012'
    if ($WithoutStacks) { $mock.Stacks.Clear(); $mock.Resources.Clear(); $mock.Live.Clear() }
    $names = @{
        dynamodb = 'app-main-prod'; ecr = 'app-api-prod'; secretsmanager = 'app-app-secrets-prod-v4'
        lambda = 'app-api-prod'; 'cognito-idp' = 'app-pool-prod'; apigatewayv2 = 'app-api-prod'
        sns = 'app-alerts-prod'; logs = '/aws/lambda/app-api-prod'; cloudwatch = 'app-prod-lambda-errors'
        s3api = 'app-templates-123456789012-us-east-2'; iam = 'app-github-deploy'
    }
    foreach ($service in $names.Keys) {
        $name = $names[$service]
        $id = switch ($service) {
            secretsmanager { "arn:aws:secretsmanager:us-east-2:123456789012:secret:$name-AbCdEf" }
            'cognito-idp' { 'us-east-2_pool' }
            apigatewayv2 { 'api123' }
            sns { "arn:aws:sns:us-east-2:123456789012:$name" }
            default { $name }
        }
        $arn = switch ($service) {
            dynamodb { "arn:aws:dynamodb:us-east-2:123456789012:table/$name" }
            ecr { "arn:aws:ecr:us-east-2:123456789012:repository/$name" }
            lambda { "arn:aws:lambda:us-east-2:123456789012:function:$name" }
            'cognito-idp' { "arn:aws:cognito-idp:us-east-2:123456789012:userpool/$id" }
            logs { "arn:aws:logs:us-east-2:123456789012:log-group:$name" }
            cloudwatch { "arn:aws:cloudwatch:us-east-2:123456789012:alarm:$name" }
            iam { "arn:aws:iam::123456789012:role/$name" }
            default { $id }
        }
        $mock.Orphans["$service|$id"] = @{
            Service = $service; Name = $name; Id = $id; Arn = $arn; Exists = $true; Target = $true
            Identity = "identity-$service"; Tags = @{}; Protected = $true; Pending = $false
            Domain = 'app-123456789012-prod'; DomainExists = $true
            Versions = @(@{ Key = 'data'; VersionId = 'v1' }); Markers = @(@{ Key = 'data'; VersionId = 'marker' })
            Uploads = @(@{ Key = 'unfinished'; UploadId = 'upload' })
        }
    }
    $old = $mock.Orphans['iam|app-github-deploy'].Clone()
    $old.Name = 'app-456-github-deploy'; $old.Id = $old.Name; $old.Arn = "arn:aws:iam::123456789012:role/$($old.Name)"
    $mock.Orphans["iam|$($old.Id)"] = $old
    $other = $old.Clone(); $other.Name = 'app-extra-github-deploy'; $other.Id = $other.Name
    $other.Target = $false; $other.Arn = "arn:aws:iam::123456789012:role/$($other.Name)"
    $mock.Orphans["iam|$($other.Id)"] = $other
}

function Invoke-PreflightMockAws {
    param([string[]]$Arguments)
    $mock = $global:ShellTeardownMock
    $service = $Arguments[0]; $action = $Arguments[1]
    $text = $Arguments -join ' '
    $items = @($mock.Orphans.Values | Where-Object { $_.Service -eq $service -and $_.Exists })
    switch ("$service $action") {
        'iam list-roles' { return (@{ Roles = @($items | ForEach-Object { @{ RoleName = $_.Name } }) } | ConvertTo-Json -Depth 5) }
        'cognito-idp list-user-pools' { return (@{ UserPools = @($items | ForEach-Object { @{ Id = $_.Id; Name = $_.Name } }) } | ConvertTo-Json -Depth 5) }
        'apigatewayv2 get-apis' { return (@{ Items = @($items | ForEach-Object { @{ ApiId = $_.Id; Name = $_.Name } }) } | ConvertTo-Json -Depth 5) }
        'sns list-topics' { return (@{ Topics = @($items | ForEach-Object { @{ TopicArn = $_.Arn } }) } | ConvertTo-Json -Depth 5) }
        's3api list-buckets' { return (@{ Buckets = @($items | ForEach-Object { @{ Name = $_.Name; CreationDate = '2026-01-01' } }) } | ConvertTo-Json -Depth 5) }
    }
    if ($action -like '*user-pool-domain') {
        $domain = $Arguments[[array]::IndexOf($Arguments, '--domain') + 1]
        $pools = @($items | Where-Object { $_.Domain -eq $domain -and $_.DomainExists })
        if ($action -eq 'describe-user-pool-domain') {
            return (@{ DomainDescription = $(if ($pools.Count -eq 1) {
                @{ UserPoolId = $pools[0].Id; Domain = $domain; AWSAccountId = '123456789012'; CloudFrontDistribution = 'distribution' }
            } else { @{} }) } | ConvertTo-Json -Depth 5)
        }
        Assert-TeardownTest ($pools.Count -eq 1) 'Deleted an unknown Cognito domain.'
        $pool = $pools[0]
        $mock.Mutations.Add("aws $text"); $pool.DomainExists = $false
        return '{}'
    }
    $flag = switch ($service) {
        dynamodb { if ($action -eq 'list-tags-of-resource') { '--resource-arn' } else { '--table-name' } }
        ecr { if ($action -eq 'describe-repositories') { '--repository-names' } elseif ($action -eq 'list-tags-for-resource') { '--resource-arn' } else { '--repository-name' } }
        secretsmanager { '--secret-id' }; lambda { '--function-name' }; 'cognito-idp' { '--user-pool-id' }
        apigatewayv2 { '--api-id' }; sns { if ($action -eq 'list-tags-for-resource') { '--resource-arn' } else { '--topic-arn' } }
        iam { '--role-name' }; logs { if ($action -eq 'describe-log-groups') { '--log-group-name-prefix' } else { '--log-group-name' } }
        cloudwatch { if ($action -eq 'list-tags-for-resource') { '--resource-arn' } else { '--alarm-names' } }
        s3api { '--bucket' }
    }
    if (-not $flag) { throw "Unexpected preflight service: $service" }
    $id = $Arguments[[array]::IndexOf($Arguments, $flag) + 1]
    $found = @($items | Where-Object { $_.Id -eq $id -or $_.Name -eq $id -or $_.Arn -eq $id })
    if ($found.Count -eq 0) {
        if ($service -eq 'logs') { return '{"logGroups":[]}' }
        if ($service -eq 'cloudwatch') { return '{"MetricAlarms":[],"CompositeAlarms":[]}' }
        $global:LASTEXITCODE = 1
        return $(switch ($service) { ecr { '(RepositoryNotFoundException)' }; iam { '(NoSuchEntity)' }; sns { '(NotFound)' }; apigatewayv2 { '(NotFoundException)' }; s3api { '(NoSuchBucket)' }; default { '(ResourceNotFoundException)' } })
    }
    Assert-TeardownTest ($found.Count -eq 1) 'Ambiguous mock resource.'
    $item = $found[0]
    if ($action -like 'list-tags*') {
        if ($service -eq 'logs') { return (@{ tags = $item.Tags } | ConvertTo-Json -Depth 5) }
        $tags = @(foreach ($key in $item.Tags.Keys) { @{ Key = $key; Value = $item.Tags[$key] } })
        return (@{ Tags = $tags } | ConvertTo-Json -Depth 5)
    }
    switch ("$service $action") {
        'dynamodb describe-table' { return (@{ Table = @{ TableName = $item.Name; TableId = $item.Identity; TableArn = $item.Arn; DeletionProtectionEnabled = $item.Protected; TableStatus = 'ACTIVE' } } | ConvertTo-Json -Depth 5) }
        'ecr describe-repositories' { return (@{ repositories = @(@{ repositoryName = $item.Name; repositoryArn = $item.Arn; createdAt = '2026-01-01' }) } | ConvertTo-Json -Depth 5) }
        'secretsmanager describe-secret' { return (@{ Name = $item.Name; ARN = $item.Arn; Tags = @() } | ConvertTo-Json -Depth 5) }
        'lambda get-function' { return (@{ Configuration = @{ FunctionName = $item.Name; FunctionArn = $item.Arn; RevisionId = $item.Identity }; Tags = $item.Tags } | ConvertTo-Json -Depth 5) }
        'cognito-idp describe-user-pool' { return (@{ UserPool = @{ Id = $item.Id; Name = $item.Name; Arn = $item.Arn; CreationDate = '2026-01-01'; Domain = $(if ($item.DomainExists) { $item.Domain } else { '' }); DeletionProtection = $(if ($item.Protected) { 'ACTIVE' } else { 'INACTIVE' }); UserPoolTags = $item.Tags } } | ConvertTo-Json -Depth 5) }
        'apigatewayv2 get-api' { return (@{ ApiId = $item.Id; Name = $item.Name; CreatedDate = '2026-01-01'; Tags = $item.Tags } | ConvertTo-Json -Depth 5) }
        'sns get-topic-attributes' { return (@{ Attributes = @{ TopicArn = $item.Arn; Owner = '123456789012' } } | ConvertTo-Json -Depth 5) }
        'iam get-role' { return (@{ Role = @{ RoleName = $item.Name; RoleId = $item.Identity; Arn = $item.Arn; Tags = @() } } | ConvertTo-Json -Depth 5) }
        'iam list-instance-profiles-for-role' { return '{"InstanceProfiles":[]}' }
        'iam list-role-policies' { return '{"PolicyNames":["app-deploy"]}' }
        'iam list-attached-role-policies' { return '{"AttachedPolicies":[{"PolicyArn":"arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"}]}' }
        'logs describe-log-groups' { return (@{ logGroups = @(@{ logGroupName = $item.Name; creationTime = 1; arn = $item.Arn }) } | ConvertTo-Json -Depth 5) }
        'cloudwatch describe-alarms' { return (@{ MetricAlarms = @(@{ AlarmName = $item.Name; AlarmArn = $item.Arn; AlarmConfigurationUpdatedTimestamp = '2026-01-01' }); CompositeAlarms = @() } | ConvertTo-Json -Depth 5) }
        's3api head-bucket' {
            Assert-TeardownTest ($Arguments -contains '--expected-bucket-owner') 'Bucket owner was not checked.'
            if ($mock.ForeignBucket) { $global:LASTEXITCODE = 1; return '(403) Forbidden' }
            return '{}'
        }
        's3api get-bucket-location' { return '{"LocationConstraint":"us-east-2"}' }
        's3api get-bucket-tagging' { $global:LASTEXITCODE = 1; return '(NoSuchTagSet)' }
        's3api list-object-versions' { return (@{ Versions = $item.Versions; DeleteMarkers = $item.Markers } | ConvertTo-Json -Depth 5) }
        's3api list-multipart-uploads' { return (@{ Uploads = $item.Uploads } | ConvertTo-Json -Depth 5) }
    }
    $mock.Mutations.Add("aws $text")
    if ($action -eq 'delete-objects') {
        if ($mock.FailObjects) { return '{"Errors":[{"Code":"AccessDenied"}]}' }
        $item.Versions = @(); $item.Markers = @(); return '{}'
    }
    if ($action -eq 'abort-multipart-upload') { $item.Uploads = @(); return '{}' }
    if ($action -in @('update-table', 'update-user-pool')) { $item.Protected = $false; return '{}' }
    if ($action -in @('delete-role-policy', 'detach-role-policy')) { return '{}' }
    if ($action -like 'delete-*') {
        if ($service -eq 's3api') { Assert-TeardownTest ($item.Versions.Count -eq 0 -and $item.Markers.Count -eq 0 -and $item.Uploads.Count -eq 0) 'Templates bucket was not emptied.' }
        if ($service -eq 'dynamodb') { Assert-TeardownTest (-not $item.Protected) 'Protected orphan table was deleted.' }
        if ($service -eq 'cognito-idp') { Assert-TeardownTest (-not $item.Protected -and -not $item.DomainExists) 'Pool protection/domain was not removed.' }
        if ($service -eq 'secretsmanager' -and $mock.FailSecret) { $item.Pending = $true } else { $item.Exists = $false }
        return '{}'
    }
    throw "Unexpected preflight command: $text"
}

$command = Join-Path $fixture 'setup-scripts/destroy-project.ps1'
$preflightIdentity = @{
    AppName = 'app'; AccountId = '123456789012'; Region = 'us-east-2'; Profile = 'test'
    Repository = 'owner/app'; VercelProjectId = $null; VercelOwnerId = $null
}
try {
    New-TeardownFixture
    Test-TeardownCase 'Destruction plan and cancellation make no cloud changes' {
        & $command -Plan 6>$null
        Assert-TeardownTest ($global:ShellTeardownMock.Mutations.Count -eq 0) 'Plan changed resources.'
        Assert-TeardownTest (-not (Test-Path (Join-Path $fixture '.setup/teardown.json'))) 'Plan wrote recovery state.'
        $global:ShellTeardownMock.Confirm = ''
        Assert-TeardownFailure { & $command 6>$null } 'cancelled'
        Assert-TeardownTest ($global:ShellTeardownMock.Mutations.Count -eq 0) 'Cancellation changed resources.'
    }
    New-TeardownFixture
    Test-TeardownCase 'Wrong account or stack application fails before destructive operations' {
        $mock = $global:ShellTeardownMock
        $mock.Account = '999999999999'
        Assert-TeardownFailure { & $command 6>$null } 'another account'
        $mock.Account = '123456789012'
        $stack = $mock.Stacks.Values | Where-Object StackName -EQ 'app-prod'
        $stack.Parameters[0].ParameterValue = 'another-app'
        Assert-TeardownFailure { & $command 6>$null } 'Root stack parameters'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Invalid scope changed resources.'
    }
    New-TeardownFixture
    Test-TeardownCase 'Active deployment runs must stop before AWS deletion' {
        $mock = $global:ShellTeardownMock
        $mock.KeepRuns = $true
        Assert-TeardownFailure { & $command 6>$null } 'still active'
        Assert-TeardownTest (-not $mock.WorkflowActive) 'Workflow was not disabled.'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -like 'aws *' }).Count -eq 0) 'AWS was changed while deployment was active.'
    }
    New-TeardownFixture
    Test-TeardownCase 'Teardown deletes only stack inventory, including retained data and versioned bucket contents' {
        $mock = $global:ShellTeardownMock
        & $command 6>$null
        Assert-TeardownTest ($mock.WorkflowActive -and $mock.Paused) 'Workflow was not restored or Vercel not paused.'
        Assert-TeardownTest (@($mock.Live.Values | Where-Object Exists).Count -eq 0) 'Stack resources remain.'
        Assert-TeardownTest ($mock.ObjectDeletes.Count -eq 4 -and $mock.UploadsAborted -eq 2) 'Object versions, delete markers or uploads were left behind.'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -match 'templates-|oidc|github-deploy|delete-secret.*VERCEL' }).Count -eq 0) 'External bootstrap resources were targeted.'
        $saved = Get-Content (Join-Path $fixture '.setup/teardown.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TeardownTest ($saved.Complete -and -not ($saved | ConvertTo-Json -Depth 20).Contains($env:VERCEL_TOKEN)) 'Completion/state safety failed.'
        $disable = @($mock.Mutations).IndexOf('gh workflow disable 42 --repo owner/app')
        $firstDelete = @($mock.Mutations | Where-Object { $_ -like 'aws *delete-stack*' })[0]
        Assert-TeardownTest ($disable -ge 0 -and $disable -lt @($mock.Mutations).IndexOf($firstDelete)) 'AWS deletion started before workflow disabling.'
    }
    New-TeardownFixture
    Test-TeardownCase 'Failed stack deletion keeps CI disabled and can resume from recorded stack IDs' {
        $mock = $global:ShellTeardownMock
        $mock.FailWait = $true
        Assert-TeardownFailure { & $command 6>$null } 'mock stack deletion failure'
        Assert-TeardownTest (-not $mock.WorkflowActive) 'Failure re-enabled CI.'
        $mock.FailWait = $false
        & $command 6>$null
        Assert-TeardownTest ($mock.WorkflowActive -and @($mock.Live.Values | Where-Object Exists).Count -eq 0) 'Retry did not complete cleanup.'
    }
    New-TeardownFixture
    Test-TeardownCase 'A newly deployed stack or replaced table cannot be deleted by an old teardown record' {
        $mock = $global:ShellTeardownMock
        $mock.FailWait = $true
        Assert-TeardownFailure { & $command 6>$null } 'mock stack deletion failure'
        $mock.FailWait = $false
        $mock.Replaced = $true
        $before = $mock.Mutations.Count
        Assert-TeardownFailure { & $command 6>$null } 'new stack'
        Assert-TeardownTest ($mock.Mutations.Count -eq $before) 'Old record changed a newly deployed application.'
        $mock.Replaced = $false
        $mock.Live['app-prod-Table'].TableId = 'replacement-table'
        Assert-TeardownFailure { & $command 6>$null } 'has been replaced'
        Assert-TeardownTest ($mock.Mutations.Count -eq $before) 'Replacement table was changed.'
    }
    New-TeardownFixture
    Test-TeardownCase 'An edited recovery record cannot target a resource in another CloudFormation stack' {
        $mock = $global:ShellTeardownMock
        $mock.FailWait = $true
        Assert-TeardownFailure { & $command 6>$null } 'mock stack deletion failure'
        $mock.FailWait = $false
        $outside = 'arn:aws:cloudformation:us-east-2:123456789012:stack/another-app-prod/outside'
        $mock.Stacks[$outside] = @{ StackId = $outside; StackName = 'another-app-prod'; StackStatus = 'CREATE_COMPLETE'; Parameters = @() }
        $mock.Resources[$outside] = @(@{ LogicalResourceId = 'Outside'; PhysicalResourceId = 'outside-table'; ResourceType = 'AWS::DynamoDB::Table'; ResourceStatus = 'CREATE_COMPLETE' })
        $path = Join-Path $fixture '.setup/teardown.json'
        $saved = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $saved.Resources[0] = @{ StackId = $outside; LogicalId = 'Outside'; Id = 'outside-table'; Type = 'AWS::DynamoDB::Table' }
        Write-JsonFile $path $saved
        $before = $mock.Mutations.Count
        Assert-TeardownFailure { & $command 6>$null } 'outside this application'
        Assert-TeardownTest ($mock.Mutations.Count -eq $before) 'Edited recovery state caused destructive changes.'
    }
    New-TeardownFixture
    Test-TeardownCase 'S3 object deletion errors prevent stack deletion and keep the recovery record' {
        $mock = $global:ShellTeardownMock
        $mock.FailObjects = $true
        Assert-TeardownFailure { & $command 6>$null } 'S3 could not delete'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -like '*delete-stack*' }).Count -eq 0) 'Stack deletion continued after S3 errors.'
        Assert-TeardownTest (-not $mock.WorkflowActive -and (Test-Path (Join-Path $fixture '.setup/teardown.json'))) 'Recovery state or workflow safety was lost.'
    }
    New-TeardownFixture
    Test-TeardownCase 'Pending secret deletion is verified and never reported as finished' {
        $mock = $global:ShellTeardownMock
        $mock.FailSecret = $true
        Assert-TeardownFailure { & $command 6>$null } 'still pending'
        Assert-TeardownTest (-not $mock.WorkflowActive) 'Pending cleanup re-enabled deployment.'
        foreach ($live in $mock.Live.Values) {
            if ($live.Pending) { $live.Exists = $false }
        }
        $mock.FailSecret = $false
        & $command 6>$null
        Assert-TeardownTest $mock.WorkflowActive 'Completed retry did not restore workflow.'
    }
    New-TeardownFixture
    Test-TeardownCase 'Previously disabled workflows remain disabled after successful deletion' {
        $mock = $global:ShellTeardownMock
        $mock.WorkflowActive = $false
        & $command 6>$null
        Assert-TeardownTest (-not $mock.WorkflowActive) 'Previously disabled workflow was enabled.'
    }
    New-PreflightFixture
    Test-TeardownCase 'AWS preflight inventory and cancellation do not mutate AWS, GitHub or Vercel' {
        $mock = $global:ShellTeardownMock
        & $command -Preflight -SetupIdentity $preflightIdentity -Plan 6>$null
        $mock.Confirm = ''
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'cancelled'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0 -and -not (Test-Path (Join-Path $fixture '.setup/purge-aws-app.json'))) 'Planning or cancellation changed resources/state.'
    }
    New-PreflightFixture
    Test-TeardownCase 'Confirmed AWS preflight deletes stack data and exact-name orphans, but not similar names or shared resources' {
        $mock = $global:ShellTeardownMock
        & $command -Preflight -SetupIdentity $preflightIdentity 6>$null
        Assert-TeardownTest (@($mock.Live.Values | Where-Object Exists).Count -eq 0) 'Tracked stack data remains.'
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists }).Count -eq 0) 'Named app resources remain.'
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { -not $_.Target -and $_.Exists }).Count -eq 1) 'Similar but unrelated role was deleted.'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -match '^gh |^vercel |oidc|delete-policy |app-extra-' }).Count -eq 0) 'Shared infrastructure, another app, or Vercel/GitHub was changed.'
        $saved = Get-Content (Join-Path $fixture '.setup/purge-aws-app.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TeardownTest $saved.Complete 'Cleanup completed without recording verified success.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'AWS preflight rejects foreign buckets and foreign CloudFormation owners before deleting anything' {
        $mock = $global:ShellTeardownMock
        $mock.ForeignBucket = $true
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'bucket ownership'
        $mock.ForeignBucket = $false
        $id = 'arn:aws:cloudformation:us-east-2:123456789012:stack/other-prod/root'
        $mock.Stacks[$id] = @{ StackId = $id; StackName = 'other-prod'; StackStatus = 'CREATE_COMPLETE'
            Parameters = @(@{ ParameterKey = 'AppName'; ParameterValue = 'other' }, @{ ParameterKey = 'Stage'; ParameterValue = 'prod' }) }
        ($mock.Orphans.Values | Where-Object Name -EQ 'app-main-prod').Tags['aws:cloudformation:stack-id'] = $id
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'another CloudFormation application'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Foreign ownership caused deletion.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Resource replacement during confirmation prevents AWS preflight deletion' {
        $mock = $global:ShellTeardownMock
        $mock.ReplaceOnConfirm = $true
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'changed since inventory'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Replacement resource was changed.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Failed S3 cleanup stays incomplete and retry verifies removal before success' {
        $mock = $global:ShellTeardownMock
        $mock.FailObjects = $true
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'S3 could not delete'
        $saved = Get-Content (Join-Path $fixture '.setup/purge-aws-app.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TeardownTest (-not $saved.Complete) 'Failed cleanup was reported complete.'
        $mock.FailObjects = $false
        & $command -Preflight -SetupIdentity $preflightIdentity 6>$null
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists }).Count -eq 0) 'Retry left app resources.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Existing GitHub repository prevents even AWS preflight inventory' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'already exists'
        Assert-TeardownTest (@($mock.Calls | Where-Object { $_ -like 'aws *' -and $_ -notlike 'aws sts *' }).Count -eq 0) 'Existing repo allowed AWS cleanup inventory.'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Existing repo allowed deletion.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Pending orphan secret deletion cannot complete AWS preflight' {
        $mock = $global:ShellTeardownMock
        $mock.FailSecret = $true
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'still pending'
        $saved = Get-Content (Join-Path $fixture '.setup/purge-aws-app.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TeardownTest (-not $saved.Complete) 'Pending secret deletion was reported complete.'
    }
    New-PreflightFixture
    Test-TeardownCase 'Preflight disables tracked Cognito deletion protection before CloudFormation deletion' {
        $mock = $global:ShellTeardownMock
        $child = $mock.Stacks.Values | Where-Object StackName -EQ 'app-prod-data'
        $mock.Resources[$child.StackId] += @{ LogicalResourceId = 'Pool'; PhysicalResourceId = 'us-east-2_pool'; ResourceType = 'AWS::Cognito::UserPool'; ResourceStatus = 'CREATE_COMPLETE' }
        & $command -Preflight -SetupIdentity $preflightIdentity 6>$null
        Assert-TeardownTest (-not $mock.Orphans['cognito-idp|us-east-2_pool'].Exists) 'Tracked pool survived cleanup.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Preflight never deletes the role supplying current bootstrap credentials' {
        $mock = $global:ShellTeardownMock
        $mock.BootstrapArn = 'arn:aws:sts::123456789012:assumed-role/app-github-deploy/session'
        Assert-TeardownFailure { & $command -Preflight -SetupIdentity $preflightIdentity 6>$null } 'current bootstrap credentials'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Bootstrap role was changed.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Exact app Cognito domain is cleaned without deleting a differently named pool' {
        $mock = $global:ShellTeardownMock
        $pool = $mock.Orphans['cognito-idp|us-east-2_pool']
        $pool.Name = 'different-pool'; $pool.Target = $false
        & $command -Preflight -SetupIdentity $preflightIdentity 6>$null
        Assert-TeardownTest ($pool.Exists -and -not $pool.DomainExists) 'Domain cleanup deleted the differently named pool.'
    }
    New-PreflightFixture
    Test-TeardownCase 'Deleted nested stacks with missing RootId use historical parent inventory, not guessed ownership' {
        $mock = $global:ShellTeardownMock
        $mock.FailSecret = $true
        Assert-TeardownFailure { & $command -Preflight -Purge -Confirmed -SetupIdentity $preflightIdentity 6>$null } 'still pending'
        foreach ($child in @($mock.Stacks.Values | Where-Object { $_['ParentId'] })) {
            $child.Remove('RootId')
        }
        $before = $mock.Mutations.Count
        & $command -Preflight -Purge -Plan -SetupIdentity $preflightIdentity 6>$null
        Assert-TeardownTest ($mock.Mutations.Count -eq $before) 'Ancestry validation plan changed resources.'
        $recordPath = Join-Path $fixture '.setup/purge-aws-app.json'
        $record = Get-Content $recordPath -Raw | ConvertFrom-Json -AsHashtable
        $foreignId = 'arn:aws:cloudformation:us-east-2:123456789012:stack/unrelated/history'
        $mock.Stacks[$foreignId] = @{ StackId = $foreignId; StackName = 'unrelated'; StackStatus = 'DELETE_COMPLETE'; Parameters = @() }
        $record.Resources[0].StackId = $foreignId
        Write-JsonFile $recordPath $record
        Assert-TeardownFailure { & $command -Preflight -Purge -Plan -SetupIdentity $preflightIdentity 6>$null } 'outside this application'
        Assert-TeardownTest ($mock.Mutations.Count -eq $before) 'RootId fallback accepted a foreign stack.'
    }
    $purgeCommand = Join-Path $fixture 'setup-scripts/purge-project.ps1'
    $purgeArguments = @{ AppName = 'app'; GitHubOwner = 'owner'; AWSProfile = 'test'; AWSRegion = 'us-east-2'; VercelTeamId = 'team_test' }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Purge retries skip disabled workflows and verify concurrent shutdown' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.WorkflowActive = $false; $mock.RejectDisabledWorkflow = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        & $purgeCommand @purgeArguments 6>$null
        Assert-TeardownTest (-not $mock.RepoExists) 'Disabled workflow prevented purge.'
        Assert-TeardownTest (@($mock.Calls | Where-Object { $_ -eq 'gh workflow disable 42 --repo owner/app' }).Count -eq 0) 'Already-disabled workflow was disabled again.'
        New-PreflightFixture -WithoutStacks
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.WorkflowDisableRace = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        & $purgeCommand @purgeArguments 6>$null
        Assert-TeardownTest (-not $mock.RepoExists) 'Verified concurrent workflow shutdown prevented purge.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Missing repository deletion scope stops purge before cloud changes' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.GitHubScopes = 'repo, workflow'
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'gh auth refresh -h github.com -s delete_repo'
        Assert-TeardownTest ($mock.RepoExists -and $mock.Mutations.Count -eq 0) 'Missing delete_repo allowed destructive changes.'
        $mock.GitHubScopes = ''
        Assert-TeardownFailure { & $purgeCommand @purgeArguments -Plan 6>$null } 'delete_repo'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Repository deletion denial stays incomplete and can resume with corrected authorization' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.GitHubScopes = $null; $mock.FailRepositoryDelete = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'Repository deletion was denied'
        $record = Get-Content (Join-Path $fixture '.setup/purge-owner-app.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TeardownTest ($mock.RepoExists -and -not $record.Complete) 'Denied repository deletion was reported complete.'
        $mock.FailRepositoryDelete = $false
        & $purgeCommand @purgeArguments 6>$null
        Assert-TeardownTest (-not $mock.RepoExists) 'Corrected authorization did not finish the pending purge.'
    }
    Test-TeardownCase 'Shared workspace discovery paginates and requires valid selection or visible teams' {
        & {
            $requests = [System.Collections.Generic.List[string]]::new()
            $answer = '2'
            $empty = $false
            function Read-Host { param($Prompt) return $answer }
            function Invoke-VercelApi {
                param($Token, $Path)
                $requests.Add($Path)
                if ($empty) { return @{ teams = @(); pagination = @{} } }
                if ($Path -eq '/v2/teams?limit=100') {
                    return @{ teams = @(@{ id = 'team_first'; name = 'First' }); pagination = @{ next = 123 } }
                }
                if ($Path -eq '/v2/teams?limit=100&until=123') {
                    return @{ teams = @(@{ id = 'team_second'; name = 'Second' }); pagination = @{} }
                }
                throw "Unexpected discovery path: $Path"
            }
            $selected = Get-SetupVercelTeam -Token fake 6>$null
            Assert-TeardownTest ($selected -eq 'team_second' -and $requests.Count -eq 2) 'Paginated team selection chose the wrong workspace.'
            $answer = '3'
            Assert-TeardownFailure { Get-SetupVercelTeam -Token fake 6>$null } 'Invalid Vercel team selection'
            $empty = $true
            Assert-TeardownFailure { Get-SetupVercelTeam -Token fake 6>$null } 'No Vercel team is visible'
        }
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Purge reuses setup workspace and token when repository and Vercel project are already absent' {
        $mock = $global:ShellTeardownMock
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        & $purgeCommand -AppName app -GitHubOwner owner -AWSProfile test -AWSRegion us-east-2 6>$null
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists }).Count -eq 0) 'Absent-project purge left AWS resources.'
        Assert-TeardownTest (@($mock.Calls | Where-Object { $_ -like 'vercel */v2/teams*' }).Count -eq 0) 'Saved workspace triggered unnecessary discovery.'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -like 'gh *' -or $_ -like 'vercel *' }).Count -eq 0) 'Absent remote resources caused mutations.'
        Assert-TeardownTest (@($mock.Calls | Where-Object { $_ -eq 'gh api --include user --jq .login' }).Count -eq 0) 'Absent repository required unnecessary deletion permissions.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Purge discovers a single workspace from the reused token without local setup state' {
        $mock = $global:ShellTeardownMock
        Remove-Item -LiteralPath (Join-Path $fixture '.setup/state.json')
        & $purgeCommand -AppName app -GitHubOwner owner -AWSProfile test -AWSRegion us-east-2 -Plan 6>$null
        Assert-TeardownTest (@($mock.Calls | Where-Object { $_ -like 'vercel */v2/teams*' }).Count -eq 1) 'Workspace was not discovered using the token.'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Discovery plan changed resources.'
        $mock.TeamDenied = $true
        Assert-TeardownFailure { & $purgeCommand -AppName app -GitHubOwner owner -AWSProfile test -AWSRegion us-east-2 -Plan 6>$null } 'HTTP 403'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Failed discovery changed resources.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Purge plan and cancellation preserve repository, projects and AWS resources' {
        $mock = $global:ShellTeardownMock; $mock.RepoExists = $true
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app-456'; accountId = 'team_test' }
        & $purgeCommand @purgeArguments -Plan 6>$null
        $mock.Confirm = ''
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'Purge cancelled'
        Assert-TeardownTest ($mock.RepoExists -and $mock.Projects.Count -eq 1 -and $mock.Mutations.Count -eq 0) 'Purge plan/cancel made changes.'
    }
    New-PreflightFixture
    Test-TeardownCase 'Confirmed purge drains CI then deletes AWS, matching Vercel projects and repository, preserving unrelated projects' {
        $mock = $global:ShellTeardownMock; $mock.RepoExists = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app-456'; accountId = 'team_test' }
        $mock.Projects['prj_other'] = @{ id = 'prj_other'; name = 'app-other'; accountId = 'team_test' }
        & $purgeCommand @purgeArguments 6>$null
        Assert-TeardownTest (-not $mock.RepoExists -and -not $mock.Projects.ContainsKey('prj_purge') -and $mock.Projects.ContainsKey('prj_other')) 'Purge missed targets or deleted unrelated project.'
        $mutations = @($mock.Mutations)
        $firstAws = @($mutations | Where-Object { $_ -like 'aws *' })[0]
        Assert-TeardownTest ($mutations.IndexOf('gh workflow disable 42 --repo owner/app') -lt $mutations.IndexOf($firstAws)) 'Cloud deletion started before CI stopped.'
        Assert-TeardownTest ($mutations[-1] -eq 'gh api --method DELETE repos/owner/app') 'Repository was not deleted last.'
        Assert-TeardownTest (Test-Path $fixture) 'Purge deleted local files.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Failed Vercel deletion still deletes other projects and repository; retry rejects a replacement repository' {
        $mock = $global:ShellTeardownMock; $mock.RepoExists = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app'; accountId = 'team_test' }
        $mock.Projects['prj_second'] = @{ id = 'prj_second'; name = 'app-456'; accountId = 'team_test' }
        $mock.FailedProjectIds = @('prj_purge')
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'HTTP 403'
        Assert-TeardownTest (-not $mock.RepoExists -and -not $mock.Projects.ContainsKey('prj_second') -and $mock.Projects.ContainsKey('prj_purge')) 'Vercel failure prevented independent deletions.'
        $mock.RepoExists = $true; $mock.RepositoryId = 789
        $before = $mock.Mutations.Count
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'changed since purge began'
        Assert-TeardownTest ($mock.Mutations.Count -eq $before) 'Retry changed replacement repository.'
        $mock.RepoExists = $false; $mock.RepositoryId = 456; $mock.FailedProjectIds = @()
        Remove-Item -LiteralPath (Join-Path $fixture '.setup/state.json')
        $env:VERCEL_TEAM_ID = 'team_other'
        try { & $purgeCommand -AppName app -GitHubOwner owner -AWSProfile test -AWSRegion us-east-2 6>$null }
        finally { $env:VERCEL_TEAM_ID = $null }
        Assert-TeardownTest (-not $mock.RepoExists) 'Purge retry did not complete.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Purge rejects template repositories and active CI before cloud deletion' {
        $mock = $global:ShellTeardownMock; $mock.RepoExists = $true; $mock.Template = $true
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'non-template'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Template repository was changed.'
        $mock.Template = $false; $mock.KeepRuns = $true; $mock.Confirm = 'PURGE app 123456789012 owner/app'
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'still active'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -like 'aws *' -or $_ -like 'vercel *' -or $_ -like '*--method DELETE*' }).Count -eq 0) 'Active CI allowed destructive cloud changes.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Purge works for AWS and Vercel orphans when the GitHub repository is already absent' {
        $mock = $global:ShellTeardownMock
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app-123'; accountId = 'team_test' }
        & $purgeCommand @purgeArguments 6>$null
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists }).Count -eq 0 -and $mock.Projects.Count -eq 0) 'Orphan-only purge did not finish.'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -like 'gh *' }).Count -eq 0) 'Absent repository caused GitHub mutations.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Incomplete AWS deletion continues independent AWS, Vercel and repository cleanup' {
        $mock = $global:ShellTeardownMock; $mock.RepoExists = $true; $mock.FailSecret = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app-456'; accountId = 'team_test' }
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'still pending'
        Assert-TeardownTest (-not $mock.RepoExists -and $mock.Projects.Count -eq 0) 'Incomplete AWS purge prevented independent provider deletion.'
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists -and $_.Service -ne 'secretsmanager' }).Count -eq 0) 'One AWS error prevented other AWS deletions.'
        $record = Get-Content (Join-Path $fixture '.setup/purge-owner-app.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-TeardownTest (-not $record.Complete) 'Partial purge was reported complete.'
        $mock.FailSecret = $false
        & $purgeCommand @purgeArguments 6>$null
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists }).Count -eq 0) 'Partial purge could not resume after remote deletion.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Templates-bucket errors identify the bucket and do not block other confirmed deletions' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.FailObjects = $true
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'app-templates-123456789012-us-east-2'
        Assert-TeardownTest (-not $mock.RepoExists) 'Templates bucket failure blocked repository deletion.'
        Assert-TeardownTest (@($mock.Orphans.Values | Where-Object { $_.Target -and $_.Exists -and $_.Service -ne 's3api' }).Count -eq 0) 'Templates bucket failure blocked independent AWS deletion.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Unsafe AWS inventory stays untouched while separately verified providers can be purged' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.ForeignBucket = $true
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app'; accountId = 'team_test' }
        Assert-TeardownFailure { & $purgeCommand @purgeArguments -Plan 6>$null 3>$null } 'bucket ownership'
        Assert-TeardownTest ($mock.Mutations.Count -eq 0) 'Failed inventory plan changed resources.'
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null 3>$null } 'AWS skipped (unverified inventory)'
        Assert-TeardownTest (-not $mock.RepoExists -and $mock.Projects.Count -eq 0) 'Blocked AWS ownership prevented independent provider deletion.'
        Assert-TeardownTest (@($mock.Mutations | Where-Object { $_ -like 'aws *' }).Count -eq 0) 'AWS ownership failure was bypassed.'
    }
    New-PreflightFixture -WithoutStacks
    Test-TeardownCase 'Final purge report and recovery record retain failures from every provider' {
        $mock = $global:ShellTeardownMock
        $mock.RepoExists = $true; $mock.FailObjects = $true; $mock.FailSecret = $true
        $mock.FailProjectDelete = $true; $mock.FailRepositoryDelete = $true
        $mock.Projects['prj_purge'] = @{ id = 'prj_purge'; name = 'app'; accountId = 'team_test' }
        $mock.Confirm = 'PURGE app 123456789012 owner/app'
        Assert-TeardownFailure { & $purgeCommand @purgeArguments 6>$null } 'Purge incomplete'
        $record = Get-Content (Join-Path $fixture '.setup/purge-owner-app.json') -Raw | ConvertFrom-Json -AsHashtable
        $report = $record.Errors -join "`n"
        Assert-TeardownTest (-not $record.Complete -and $report.Contains('app-templates-123456789012-us-east-2') -and
            $report.Contains('app-app-secrets-prod-v4') -and $report.Contains('prj_purge') -and
            $report.Contains('Repository deletion was denied')) 'Final report omitted a provider or failed resource.'
    }
    Write-Host "$passed teardown/preflight/purge tests passed." -ForegroundColor Green
} finally {
    $env:VERCEL_TOKEN = $savedToken
    $env:VERCEL_TEAM_ID = $savedTeam
    Remove-Variable ShellTeardownMock -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
