#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Plan, [switch]$Preflight, [hashtable]$SetupIdentity, [switch]$CollisionCheck, [switch]$Purge, [switch]$Confirmed)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$statePath = Join-Path $root '.setup/state.json'
if (($CollisionCheck -or $Purge) -and -not $Preflight) { throw 'Collision checks and purge require an explicit identity.' }
if ($Confirmed -and -not $Purge) { throw 'Confirmed deletion is only supported by the purge orchestrator.' }
$recordPath = Join-Path $root $(if ($Preflight) { ".setup/purge-aws-$($SetupIdentity['AppName']).json" } else { '.setup/teardown.json' })
if ($Preflight) {
    if (-not $SetupIdentity) { throw 'An explicit setup identity is required for AWS preflight cleanup.' }
    $state = $SetupIdentity
    . (Join-Path $PSScriptRoot 'aws-preflight.ps1')
} else {
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'Setup recovery state is required to identify this application safely.' }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
}
Assert-AppName $state['AppName']
if ($state['AccountId'] -notmatch '^\d{12}$' -or $state['Region'] -notmatch '^[a-z]{2}-[a-z]+-\d+$' -or
    $state['Profile'] -notmatch '^[a-zA-Z0-9_-]+$' -or $state['Repository'] -notmatch '^[\w.-]+/[\w.-]+$') {
    throw 'Invalid setup identity. Refusing teardown.'
}
$env:AWS_PAGER = ''
$env:AWS_CLI_AUTO_PROMPT = 'off'
$awsOptions = @('--profile', $state.Profile, '--region', $state.Region, '--no-cli-pager', '--output', 'json')

function Get-TeardownStack {
    param([string]$Id)
    $result = Invoke-External aws (@('cloudformation', 'describe-stacks', '--stack-name', $Id) + $awsOptions) -AllowFailure
    if ($result.Code -ne 0) {
        if ($result.Text -match '\(ValidationError\).*does not exist') { return $null }
        throw "Cannot inspect CloudFormation stack: $($result.Text)"
    }
    $stacks = ($result.Text | ConvertFrom-Json -AsHashtable).Stacks
    if ($stacks.Count -ne 1) { throw 'Expected exactly one CloudFormation stack.' }
    return $stacks[0]
}

function Assert-TeardownStack {
    param([hashtable]$Stack, [string]$ParentId, [string]$RootId)
    $prefix = "arn:aws:cloudformation:$($state.Region):$($state.AccountId):stack/"
    if (-not $Stack.StackId.StartsWith($prefix) -or
        ($ParentId -and ($Stack['ParentId'] -ne $ParentId -or $Stack['RootId'] -ne $RootId))) {
        throw 'CloudFormation stack ownership does not match the recorded account, region or nesting.'
    }
    if ($Stack.StackStatus -like '*_IN_PROGRESS') { throw "Stack $($Stack.StackId) is busy. Wait for its operation to finish and retry." }
}

function Get-TeardownResources {
    param([string]$StackId)
    $data = Invoke-Checked aws (@('cloudformation', 'list-stack-resources', '--stack-name', $StackId) + $awsOptions) |
        ConvertFrom-Json -AsHashtable
    return @($data.StackResourceSummaries)
}

function Get-TeardownResourceDetails {
    param([hashtable]$Resource)
    switch ($Resource.Type) {
        'AWS::DynamoDB::Table' { $arguments = @('dynamodb', 'describe-table', '--table-name', $Resource.Id); $notFound = '\(ResourceNotFoundException\)' }
        'AWS::ECR::Repository' { $arguments = @('ecr', 'describe-repositories', '--repository-names', $Resource.Id); $notFound = '\(RepositoryNotFoundException\)' }
        'AWS::SecretsManager::Secret' { $arguments = @('secretsmanager', 'describe-secret', '--secret-id', $Resource.Id); $notFound = '\(ResourceNotFoundException\)' }
        'AWS::Cognito::UserPool' { $arguments = @('cognito-idp', 'describe-user-pool', '--user-pool-id', $Resource.Id); $notFound = '\(ResourceNotFoundException\)' }
        'AWS::S3::Bucket' { $arguments = @('s3api', 'get-bucket-tagging', '--bucket', $Resource.Id, '--expected-bucket-owner', $state.AccountId); $notFound = '\(NoSuchBucket\)' }
        default { return $null }
    }
    $result = Invoke-External aws ($arguments + $awsOptions) -AllowFailure
    if ($result.Code -ne 0) {
        if ($result.Text -match $notFound) { return $null }
        throw "Cannot inspect $($Resource.Type) $($Resource.Id): $($result.Text)"
    }
    $data = $result.Text | ConvertFrom-Json -AsHashtable
    switch ($Resource.Type) {
        'AWS::DynamoDB::Table' {
            if (-not $data.Table['TableId']) { throw 'DynamoDB TableId is required for safe teardown.' }
            return @{ Identity = $data.Table.TableId; Protected = $data.Table['DeletionProtectionEnabled']; Status = $data.Table.TableStatus }
        }
        'AWS::ECR::Repository' {
            if ($data.repositories.Count -ne 1) { throw 'Expected exactly one ECR repository.' }
            return @{ Identity = "$($data.repositories[0].repositoryArn)|$($data.repositories[0].createdAt)" }
        }
        'AWS::SecretsManager::Secret' { return @{ Identity = $data.ARN; Pending = $null -ne $data['DeletedDate'] } }
        'AWS::Cognito::UserPool' {
            if ($data.UserPool.Id -ne $Resource.Id -or -not $data.UserPool['CreationDate']) { throw 'Cannot verify Cognito pool identity.' }
            return @{ Identity = "$($data.UserPool.Id)|$($data.UserPool.CreationDate)"; Protected = $data.UserPool['DeletionProtection'] -eq 'ACTIVE' }
        }
        'AWS::S3::Bucket' {
            $tag = @($data.TagSet | Where-Object { $_.Key -eq 'aws:cloudformation:stack-id' -and $_.Value -eq $Resource.StackId })
            if ($tag.Count -ne 1) { throw "Bucket $($Resource.Id) is not tagged for its recorded CloudFormation stack. Refusing to empty it." }
            return @{ Identity = $Resource.StackId }
        }
    }
}

function Add-TeardownInventory {
    param([hashtable]$Stack, [System.Collections.Generic.List[object]]$Resources, [string]$RootId)
    foreach ($item in Get-TeardownResources $Stack.StackId) {
        if (-not $item['PhysicalResourceId']) { continue }
        if ($item.ResourceType -eq 'AWS::CloudFormation::Stack') {
            $child = Get-TeardownStack $item.PhysicalResourceId
            if (-not $child) { throw 'A nested stack disappeared during inventory. Retry before deleting anything.' }
            Assert-TeardownStack -Stack $child -ParentId $Stack.StackId -RootId $RootId
            Add-TeardownInventory -Stack $child -Resources $Resources -RootId $RootId
        } else {
            $resource = @{
                StackId = $Stack.StackId; LogicalId = $item.LogicalResourceId
                Type = $item.ResourceType; Id = $item.PhysicalResourceId
            }
            $details = Get-TeardownResourceDetails $resource
            if ($details) { $resource.Identity = $details.Identity }
            $Resources.Add($resource)
        }
    }
}

function Assert-RecordedResource {
    param([hashtable]$Resource)
    $matches = @(Get-TeardownResources $Resource.StackId | Where-Object {
        $_.LogicalResourceId -eq $Resource.LogicalId -and $_.PhysicalResourceId -eq $Resource.Id -and $_.ResourceType -eq $Resource.Type
    })
    if ($matches.Count -ne 1) { throw "Resource $($Resource.Id) is not in its recorded CloudFormation inventory. Refusing deletion." }
    return $matches[0]
}

function Get-RecordedStackTree {
    param([string[]]$RootIds)
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($id in $RootIds) { $pending.Enqueue($id) }
    $prefix = "arn:aws:cloudformation:$($state.Region):$($state.AccountId):stack/"
    while ($pending.Count -gt 0) {
        $id = $pending.Dequeue()
        if (-not $visited.Add($id)) { continue }
        if (-not $id.StartsWith($prefix)) { throw "Recorded stack ancestry crosses another account or region: $id" }
        foreach ($child in Get-TeardownResources $id | Where-Object ResourceType -EQ 'AWS::CloudFormation::Stack') {
            if ($child['PhysicalResourceId']) { $pending.Enqueue($child.PhysicalResourceId) }
        }
    }
    return @($visited)
}

function Assert-TeardownRecord {
    param([hashtable]$Record)
    if ($Record.WorkflowId -ne [string]$workflow.id) { throw 'The recorded deployment workflow identity changed.' }
    foreach ($entry in $Record.Stacks) {
        if ($entry.Name -notin @("$($state.AppName)-prod", "$($state.AppName)-dev")) { throw 'Recorded root stack name does not match this application.' }
        $stack = Get-TeardownStack $entry.Id
        if (-not $stack) { throw 'Recorded stack history is unavailable. Refusing to guess resource ownership.' }
        Assert-TeardownStack $stack
        $parameters = @{}
        foreach ($parameter in $stack.Parameters) { $parameters[$parameter.ParameterKey] = $parameter.ParameterValue }
        if ($stack.StackId -ne $entry.Id -or $stack.StackName -ne $entry.Name -or $stack['ParentId'] -or
            $parameters['AppName'] -ne $state.AppName -or "$($state.AppName)-$($parameters['Stage'])" -ne $entry.Name) {
            throw 'Recorded root stack ownership does not match this application.'
        }
        $current = Get-TeardownStack $entry.Name
        if ($current -and $current.StackId -ne $entry.Id -and $current.StackStatus -ne 'DELETE_COMPLETE') {
            throw 'A new stack was deployed after teardown began. Refusing to delete resources from an older installation.'
        }
    }
    $rootIds = @($Record.Stacks | ForEach-Object { $_.Id })
    $historicalStackIds = $null
    foreach ($resource in $Record.Resources) {
        $stack = Get-TeardownStack $resource.StackId
        $owned = $stack -and ($stack.StackId -in $rootIds -or $stack['RootId'] -in $rootIds)
        if ($stack -and -not $owned -and -not $stack['RootId'] -and $stack.StackStatus -eq 'DELETE_COMPLETE') {
            if ($null -eq $historicalStackIds) { $historicalStackIds = @(Get-RecordedStackTree -RootIds $rootIds) }
            $owned = $stack.StackId -in $historicalStackIds
        }
        if (-not $owned) {
            throw "Recorded resource $($resource.Type) $($resource.Id) belongs to an unavailable stack or a stack outside this application: $($resource.StackId). Refusing deletion."
        }
        $null = Assert-RecordedResource $resource
        if ($resource.Type -in @('AWS::DynamoDB::Table', 'AWS::ECR::Repository', 'AWS::SecretsManager::Secret', 'AWS::S3::Bucket', 'AWS::Cognito::UserPool')) {
            $null = Assert-ResourceIdentity $resource
        }
    }
    if ($Preflight) {
        foreach ($resource in $Record.Orphans) { $null = Assert-PreflightResourceIdentity $resource }
    }
}

function Assert-ResourceIdentity {
    param([hashtable]$Resource)
    $details = Get-TeardownResourceDetails $Resource
    if ($details -and (-not $Resource['Identity'] -or $details.Identity -ne $Resource.Identity)) {
        throw "Resource $($Resource.Id) has been replaced since teardown started. Refusing deletion."
    }
    return $details
}

function Empty-TeardownBucket {
    param([hashtable]$Resource, [switch]$Untracked)
    if ($Untracked) {
        if (-not $Preflight) { throw 'Untracked buckets can only be cleaned in confirmed setup preflight.' }
        $details = Assert-PreflightResourceIdentity $Resource
    } else {
        $null = Assert-RecordedResource $Resource
        $details = Assert-ResourceIdentity $Resource
    }
    if (-not $details) { return }
    $bucketOptions = @('--expected-bucket-owner', $state.AccountId) + $awsOptions
    $file = [IO.Path]::GetTempFileName()
    try {
        do {
            $page = Invoke-Checked aws (@('s3api', 'list-object-versions', '--bucket', $Resource.Id, '--max-keys', '1000', '--no-paginate') + $bucketOptions) |
                ConvertFrom-Json -AsHashtable
            $objects = @(
                foreach ($item in (@($page['Versions']) + @($page['DeleteMarkers']))) {
                    if ($null -ne $item) { @{ Key = $item.Key; VersionId = $item.VersionId } }
                }
            )
            if ($objects.Count -gt 0) {
                Write-JsonFile $file @{ Objects = $objects; Quiet = $true }
                $deleted = Invoke-Checked aws (@('s3api', 'delete-objects', '--bucket', $Resource.Id, '--delete', "file://$file") + $bucketOptions) |
                    ConvertFrom-Json -AsHashtable
                if ($deleted['Errors']) { throw "S3 could not delete objects from $($Resource.Id); check object locks and permissions." }
            }
        } while ($objects.Count -gt 0)
        do {
            $page = Invoke-Checked aws (@('s3api', 'list-multipart-uploads', '--bucket', $Resource.Id, '--max-uploads', '1000', '--no-paginate') + $bucketOptions) |
                ConvertFrom-Json -AsHashtable
            $uploads = @($page['Uploads'] | Where-Object { $null -ne $_ })
            foreach ($upload in $uploads) {
                $null = Invoke-Checked aws (@('s3api', 'abort-multipart-upload', '--bucket', $Resource.Id, '--key', $upload.Key, '--upload-id', $upload.UploadId) + $bucketOptions)
            }
        } while ($uploads.Count -gt 0)
    } finally { Remove-Item -LiteralPath $file -Force }
}

function Disable-TeardownTableProtection {
    param([hashtable]$Resource)
    $details = Assert-ResourceIdentity $Resource
    if ($details -and $details.Protected) {
        $null = Invoke-Checked aws (@('dynamodb', 'update-table', '--table-name', $Resource.Id, '--no-deletion-protection-enabled') + $awsOptions)
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $details = Assert-ResourceIdentity $Resource
            if ($details -and -not $details.Protected -and $details.Status -eq 'ACTIVE') { break }
            Start-Sleep -Seconds 3
        }
        if ($details -and ($details.Protected -or $details.Status -ne 'ACTIVE')) { throw 'DynamoDB deletion protection change is still pending. Retry cleanup.' }
    }
}

function Remove-RetainedResource {
    param([hashtable]$Resource)
    $item = Assert-RecordedResource $Resource
    if ($item.ResourceStatus -eq 'DELETE_COMPLETE') { return }
    if ($item.ResourceStatus -ne 'DELETE_SKIPPED') { throw "CloudFormation did not finish deleting $($Resource.Id): $($item.ResourceStatus)." }
    $supported = @('AWS::DynamoDB::Table', 'AWS::ECR::Repository', 'AWS::SecretsManager::Secret', 'AWS::S3::Bucket')
    if ($Resource.Type -notin $supported) { throw "Retained resource type $($Resource.Type) requires manual cleanup; nothing will be guessed." }
    $details = Assert-ResourceIdentity $Resource
    if (-not $details) { return }
    switch ($Resource.Type) {
        'AWS::DynamoDB::Table' { $arguments = @('dynamodb', 'delete-table', '--table-name', $Resource.Id) }
        'AWS::ECR::Repository' { $arguments = @('ecr', 'delete-repository', '--repository-name', $Resource.Id, '--force') }
        'AWS::SecretsManager::Secret' { $arguments = @('secretsmanager', 'delete-secret', '--secret-id', $Resource.Id, '--force-delete-without-recovery') }
        'AWS::S3::Bucket' { Empty-TeardownBucket $Resource; $arguments = @('s3api', 'delete-bucket', '--bucket', $Resource.Id, '--expected-bucket-owner', $state.AccountId) }
    }
    $pending = ($Resource.Type -eq 'AWS::SecretsManager::Secret' -and $details.Pending) -or
        ($Resource.Type -eq 'AWS::DynamoDB::Table' -and $details.Status -eq 'DELETING')
    if (-not $pending) { $null = Invoke-Checked aws ($arguments + $awsOptions) }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if (-not (Assert-ResourceIdentity $Resource)) { Write-Host "Deleted retained resource: $($Resource.Id)"; return }
        Start-Sleep -Seconds 3
    }
    throw "Deletion of $($Resource.Id) is still pending. Retry teardown before redeploying."
}

function Get-ActiveDeploymentRuns {
    param([string]$WorkflowId)
    $ids = @(
        foreach ($status in @('queued', 'in_progress', 'waiting', 'pending', 'requested')) {
            $text = Invoke-Checked gh -Arguments @('api', "repos/$($state.Repository)/actions/workflows/$WorkflowId/runs?status=$status&per_page=100", '--paginate', '--jq', '.workflow_runs[].id')
            foreach ($id in ($text -split '\r?\n')) {
                if ($id) {
                    if ($id -notmatch '^\d+$') { throw 'Invalid GitHub workflow run ID.' }
                    $id
                }
            }
        }
    )
    return @($ids | Select-Object -Unique)
}

function Invoke-TeardownStep {
    param([string]$Target, [scriptblock]$Action)
    try { & $Action }
    catch {
        if (-not ($Purge -and $Confirmed)) { throw }
        $cleanupFailures.Add("$Target`: $($_.Exception.Message)")
    }
}

$identity = Invoke-Checked aws (@('sts', 'get-caller-identity') + $awsOptions) | ConvertFrom-Json
if ($identity.Account -ne $state.AccountId) { throw 'AWS profile is signed into another account. No resources were changed.' }
if ($Preflight) {
    if (-not $Purge) { Assert-RepositoryAvailable $state.Repository }
    $workflow = @{ id = 'preflight'; state = 'disabled' }
} else {
    Push-Location $root
    try { $repository = Invoke-Checked gh -Arguments @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner') }
    finally { Pop-Location }
    if ($repository -ne $state.Repository) { throw 'The local repository does not match setup state. No resources were changed.' }
    $workflow = Invoke-Checked gh -Arguments @('api', "repos/$($state.Repository)/actions/workflows/ci-cd.yml") | ConvertFrom-Json -AsHashtable
}
$record = if (-not $CollisionCheck -and (Test-Path -LiteralPath $recordPath)) { Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
if ($record -and -not $record['Complete']) {
    foreach ($key in @('AppName', 'AccountId', 'Region', 'Repository', 'VercelProjectId', 'VercelOwnerId')) {
        if ($record[$key] -ne $state[$key]) { throw 'Pending teardown belongs to another installation. Refusing to continue.' }
    }
} else {
    $resources = [System.Collections.Generic.List[object]]::new()
    $stacks = @(
        foreach ($stage in @('prod', 'dev')) {
            $stack = Get-TeardownStack "$($state.AppName)-$stage"
            if (-not $stack -or $stack.StackStatus -eq 'DELETE_COMPLETE') { continue }
            Assert-TeardownStack $stack
            $parameters = @{}
            foreach ($parameter in $stack.Parameters) { $parameters[$parameter.ParameterKey] = $parameter.ParameterValue }
            if ($parameters['AppName'] -ne $state.AppName -or $parameters['Stage'] -ne $stage -or $stack['ParentId']) {
                throw 'Root stack parameters do not identify this application and stage. Refusing deletion.'
            }
            Add-TeardownInventory -Stack $stack -Resources $resources -RootId $stack.StackId
            @{ Id = $stack.StackId; Name = "$($state.AppName)-$stage" }
        }
    )
    $record = @{
        AppName = $state.AppName; AccountId = $state.AccountId; Region = $state.Region; Repository = $state.Repository
        VercelProjectId = $state['VercelProjectId']; VercelOwnerId = $state['VercelOwnerId']
        WorkflowId = [string]$workflow.id; WorkflowWasActive = $workflow.state -eq 'active'
        Stacks = $stacks; Resources = @($resources.ToArray()); Complete = $false
    }
    if ($Preflight) { $record.Orphans = @(Get-PreflightOrphans -Tracked $record.Resources) }
}
Assert-TeardownRecord $record
if ($CollisionCheck) {
    if ($record.Stacks.Count -gt 0 -or $record.Orphans.Count -gt 0) {
        throw "AWS resources already exist for '$($state.AppName)'. Choose another application name. Setup never deletes or reuses them."
    }
    return
}
if ($Preflight -and $record.Stacks.Count -eq 0 -and $record.Orphans.Count -eq 0) {
    Write-Host 'No existing application resources found in AWS.'
    return
}
Write-Host "`nApplication: $($state.AppName)`nRepository: $($state.Repository)`nAWS: $($state.AccountId), $($state.Region)"
foreach ($entry in $record.Stacks) { Write-Host "Delete stack: $($entry.Id)" }
foreach ($resource in $record.Resources) { Write-Host "  $($resource.Type): $($resource.Id)" }
if ($Preflight) { foreach ($resource in $record.Orphans) { Write-Host "Delete named resource: $($resource.Type): $($resource.Name) ($($resource.Id))" } }
Write-Host 'PERMANENT DATA LOSS: DynamoDB data, Cognito users, stack-owned S3 files/versions, container images, logs and runtime secrets will be deleted. No backups are made.'
if ($Preflight) {
    Write-Host 'AWS preflight deletes both app stacks, their retained data, and inventoried exact-name orphan resources, including the templates bucket and app roles. IAM roles are account-global.'
    Write-Host 'No backups are made. Stop older deployments before continuing. Shared OIDC providers, unrelated resources, backups and Vercel projects are not deleted.'
    Write-Host 'This is permanent purge cleanup. Deleted data, users and secrets cannot be restored by deploying again.'
} else {
    Write-Host 'A push recreates EMPTY infrastructure, not your data, users or secret values. Do not push or run setup during teardown.'
    Write-Host 'Only recorded CloudFormation resources are targeted. The external templates bucket, deployment role, shared OIDC provider and GitHub secrets remain; residual charges may remain.'
    Write-Host 'Vercel Production will be paused, not deleted. Protected Previews are not guaranteed to be paused.'
}
if ($Plan) { Write-Host 'Plan only. No changes made.'; return }
$confirmation = if ($Preflight) { "DELETE $($state.AppName) $($state.AccountId)" } else { "DELETE $($state.AppName)" }
if (-not $Confirmed -and (Read-Host "Type $confirmation to permanently delete both environments") -cne $confirmation) {
    throw 'Teardown cancelled. No resources were changed.'
}
$token = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
try {
    if ($Preflight) {
        if (-not $Purge) { Assert-RepositoryAvailable $state.Repository }
    } else {
        $token = Get-SetupVercelToken
        $project = Invoke-VercelApi -Token $token -OwnerId $state.VercelOwnerId -Path "/v9/projects/$($state.VercelProjectId)"
        if ($project.id -ne $state.VercelProjectId -or $project.accountId -ne $state.VercelOwnerId) { throw 'Vercel project ownership does not match setup state.' }
        Write-JsonFile $recordPath $record
        $null = Invoke-Checked gh -Arguments @('workflow', 'disable', $record.WorkflowId, '--repo', $state.Repository)
        foreach ($id in Get-ActiveDeploymentRuns $record.WorkflowId) {
            $null = Invoke-Checked gh -Arguments @('run', 'cancel', $id, '--repo', $state.Repository)
        }
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if (@(Get-ActiveDeploymentRuns $record.WorkflowId).Count -eq 0) { break }
            Start-Sleep -Seconds 5
        }
        if (@(Get-ActiveDeploymentRuns $record.WorkflowId).Count -gt 0) { throw 'Deployment runs are still active. CI/CD remains disabled; retry when they stop.' }
        Assert-TeardownRecord $record
        $null = Invoke-VercelApi -Token $token -OwnerId $state.VercelOwnerId -Path "/v1/projects/$($state.VercelProjectId)/pause" -Method POST
        $project = Invoke-VercelApi -Token $token -OwnerId $state.VercelOwnerId -Path "/v9/projects/$($state.VercelProjectId)"
        $projectData = $project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        if ($projectData['paused'] -ne $true) { throw 'Vercel did not confirm that Production is paused.' }
    }
    if ($Preflight) {
        $null = New-Item -ItemType Directory -Path (Split-Path $recordPath -Parent) -Force
        $record.Errors = @()
        Write-JsonFile $recordPath $record
    }
    Assert-TeardownRecord $record
    foreach ($resource in $record.Resources) {
        Invoke-TeardownStep -Target "$($resource.Type) $($resource.Id) preparation" -Action {
            $null = Assert-RecordedResource $resource
            if ($resource.Type -eq 'AWS::S3::Bucket') { Empty-TeardownBucket $resource }
            if ($resource.Type -eq 'AWS::DynamoDB::Table') {
                Disable-TeardownTableProtection $resource
            }
            if ($Preflight -and $resource.Type -eq 'AWS::Cognito::UserPool') {
                $details = Assert-ResourceIdentity $resource
                if ($details -and $details.Protected) {
                    $null = Invoke-Checked aws (@('cognito-idp', 'update-user-pool', '--user-pool-id', $resource.Id, '--deletion-protection', 'INACTIVE') + $awsOptions)
                    for ($attempt = 0; $attempt -lt 40; $attempt++) {
                        $details = Assert-ResourceIdentity $resource
                        if (-not $details -or -not $details.Protected) { break }
                        Start-Sleep -Seconds 3
                    }
                    if ($details -and $details.Protected) { throw 'Cognito deletion protection change is still pending. Retry cleanup.' }
                }
            }
        }
    }
    foreach ($entry in $record.Stacks) {
        Invoke-TeardownStep -Target "CloudFormation stack $($entry.Id)" -Action {
            $stack = Get-TeardownStack $entry.Id
            if (-not $stack -or $stack.StackStatus -eq 'DELETE_COMPLETE') { return }
            Assert-TeardownStack $stack
            if ($stack['EnableTerminationProtection']) {
                $null = Invoke-Checked aws (@('cloudformation', 'update-termination-protection', '--stack-name', $entry.Id, '--no-enable-termination-protection') + $awsOptions)
            }
            $null = Invoke-Checked aws (@('cloudformation', 'delete-stack', '--stack-name', $entry.Id) + $awsOptions)
            $null = Invoke-Checked aws (@('cloudformation', 'wait', 'stack-delete-complete', '--stack-name', $entry.Id) + $awsOptions)
        }
    }
    foreach ($resource in $record.Resources) {
        Invoke-TeardownStep -Target "$($resource.Type) $($resource.Id)" -Action { Remove-RetainedResource $resource }
    }
    if ($Preflight) {
        foreach ($resource in @($record.Orphans | Sort-Object { if ($_.Type -eq 'AWS::IAM::Role') { 1 } else { 0 } })) {
            Invoke-TeardownStep -Target "$($resource.Type) $($resource.Name) ($($resource.Id))" -Action { Remove-PreflightResource $resource }
        }
        foreach ($stage in @('prod', 'dev')) {
            Invoke-TeardownStep -Target "Stack verification $($state.AppName)-$stage" -Action {
                $stack = Get-TeardownStack "$($state.AppName)-$stage"
                if ($stack -and $stack.StackStatus -ne 'DELETE_COMPLETE') { throw "Application stack $($stack.StackId) still exists." }
            }
        }
        Invoke-TeardownStep -Target 'AWS remaining-resource verification' -Action {
            $remaining = @(Get-PreflightOrphans -Tracked @())
            if ($remaining.Count -gt 0) { throw "Application resources remain or appeared during cleanup: $($remaining.Id -join ', ')." }
        }
        if (-not $Purge) { Assert-RepositoryAvailable $state.Repository }
    }
    if ($cleanupFailures.Count -gt 0) {
        $record.Errors = @($cleanupFailures.ToArray())
        Write-JsonFile $recordPath $record
        throw "Failed AWS resources:`n - $($cleanupFailures -join "`n - ")"
    }
    if ($record.WorkflowWasActive) {
        $null = Invoke-Checked gh -Arguments @('workflow', 'enable', $record.WorkflowId, '--repo', $state.Repository)
    }
    $record.Complete = $true
    Write-JsonFile $recordPath $record
    if ($Preflight) { Write-Host 'AWS purge cleanup complete.' -ForegroundColor Green; return }
    Write-Host 'Teardown complete. Stack resources were deleted and Vercel Production is paused.' -ForegroundColor Green
    Write-Host 'To rebuild: push main with backend and website deployment enabled, then deploy dev. Data/users/secrets are not restored.'
    if (-not $record.WorkflowWasActive) { Write-Host 'CI/CD was already disabled and remains disabled. Enable it manually before redeploying.' }
} catch {
    if ($Preflight) { throw "AWS purge cleanup failed; some resources may already be permanently deleted. Retry purge using the same identity. $($_.Exception.Message)" }
    throw "Teardown failed; some changes may already have completed. Retry this command using the saved .setup state. CI/CD may remain disabled. $($_.Exception.Message)"
} finally { $token = $null }
