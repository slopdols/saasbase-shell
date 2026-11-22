function Get-PreflightNames {
    param([string]$Type)
    foreach ($stage in @('prod', 'dev')) {
        switch ($Type) {
            'AWS::DynamoDB::Table' { foreach ($table in @('main', 'ledger', 'throttle', 'webmetrics')) { "$($state.AppName)-$table-$stage" } }
            'AWS::ECR::Repository' { "$($state.AppName)-api-$stage" }
            'AWS::SecretsManager::Secret' { "$($state.AppName)-app-secrets-$stage-v4" }
            'AWS::Lambda::Function' { "$($state.AppName)-api-$stage" }
            'AWS::Cognito::UserPool' { "$($state.AppName)-pool-$stage" }
            'AWS::Cognito::UserPoolDomain' { "$($state.AppName)-$($state.AccountId)-$stage" }
            'AWS::ApiGatewayV2::Api' { "$($state.AppName)-api-$stage" }
            'AWS::SNS::Topic' { "$($state.AppName)-alerts-$stage" }
            'AWS::Logs::LogGroup' { "/aws/lambda/$($state.AppName)-api-$stage" }
            'AWS::CloudWatch::Alarm' { foreach ($alarm in @('errors', 'throttles', 'p99-latency')) { "$($state.AppName)-$stage-lambda-$alarm" } }
            'AWS::IAM::Role' { "$($state.AppName)-lambda-$stage" }
        }
    }
    if ($Type -eq 'AWS::S3::Bucket') { "$($state.AppName)-templates-$($state.AccountId)-$($state.Region)" }
    if ($Type -eq 'AWS::IAM::Role') { "$($state.AppName)-github-deploy" }
}

function Assert-PreflightName {
    param([hashtable]$Resource)
    $names = @(Get-PreflightNames $Resource.Type)
    $deploymentRole = $Resource.Type -eq 'AWS::IAM::Role' -and
        $Resource.Name -cmatch "^$([regex]::Escape($state.AppName))-\d+-github-deploy$"
    if ($Resource.Name -cnotin $names -and -not $deploymentRole) {
        throw "Resource name is outside this application's exact naming patterns: $($Resource.Name)."
    }
}

function Assert-PreflightTags {
    param($Tags)
    $stackId = if ($Tags -is [System.Collections.IDictionary]) {
        if ($Tags['aws:cloudformation:stack-id']) { $Tags['aws:cloudformation:stack-id'] }
        elseif ($Tags['Key'] -eq 'aws:cloudformation:stack-id') { $Tags['Value'] }
    } else {
        @($Tags | Where-Object { $_ -and $_.Key -eq 'aws:cloudformation:stack-id' } | ForEach-Object { $_.Value })
    }
    if (-not $stackId) { return }
    $stack = Get-TeardownStack $stackId
    if (-not $stack) { throw 'Cannot verify the CloudFormation owner of a named resource. Inspect it manually before cleanup.' }
    if ($stack['RootId']) { $stack = Get-TeardownStack $stack.RootId }
    if (-not $stack) { throw 'Cannot verify the root stack owning a named resource.' }
    Assert-TeardownStack $stack
    $parameters = @{}
    foreach ($parameter in $stack.Parameters) { $parameters[$parameter.ParameterKey] = $parameter.ParameterValue }
    if ($parameters['AppName'] -ne $state.AppName -or $parameters['Stage'] -notin @('prod', 'dev') -or
        $stack.StackName -ne "$($state.AppName)-$($parameters['Stage'])") {
        throw 'A matching resource name belongs to another CloudFormation application. Refusing deletion.'
    }
}

function Get-PreflightResource {
    param([hashtable]$Resource)
    Assert-PreflightName $Resource
    $notFound = '\(ResourceNotFoundException\)'
    switch ($Resource.Type) {
        'AWS::DynamoDB::Table' { $arguments = @('dynamodb', 'describe-table', '--table-name', $Resource.Id) }
        'AWS::ECR::Repository' { $arguments = @('ecr', 'describe-repositories', '--repository-names', $Resource.Id); $notFound = '\(RepositoryNotFoundException\)' }
        'AWS::SecretsManager::Secret' { $arguments = @('secretsmanager', 'describe-secret', '--secret-id', $Resource.Id) }
        'AWS::Lambda::Function' { $arguments = @('lambda', 'get-function', '--function-name', $Resource.Id) }
        'AWS::Cognito::UserPool' { $arguments = @('cognito-idp', 'describe-user-pool', '--user-pool-id', $Resource.Id) }
        'AWS::Cognito::UserPoolDomain' { $arguments = @('cognito-idp', 'describe-user-pool-domain', '--domain', $Resource.Id) }
        'AWS::ApiGatewayV2::Api' { $arguments = @('apigatewayv2', 'get-api', '--api-id', $Resource.Id); $notFound = '\(NotFoundException\)' }
        'AWS::SNS::Topic' { $arguments = @('sns', 'get-topic-attributes', '--topic-arn', $Resource.Id); $notFound = '\(NotFound\)' }
        'AWS::IAM::Role' { $arguments = @('iam', 'get-role', '--role-name', $Resource.Id); $notFound = '\(NoSuchEntity\)' }
        'AWS::Logs::LogGroup' { $arguments = @('logs', 'describe-log-groups', '--log-group-name-prefix', $Resource.Id) }
        'AWS::CloudWatch::Alarm' { $arguments = @('cloudwatch', 'describe-alarms', '--alarm-names', $Resource.Id) }
        'AWS::S3::Bucket' {
            if ($Resource.Id -cne $Resource.Name) { throw 'Bucket identity does not match its approved name.' }
            $result = Invoke-External aws (@('s3api', 'head-bucket', '--bucket', $Resource.Id, '--expected-bucket-owner', $state.AccountId) + $awsOptions) -AllowFailure
            if ($result.Code -ne 0) {
                if ($result.Text -match '\(404\)|\(NoSuchBucket\)') { return $null }
                throw "Cannot verify bucket ownership: $($result.Text)"
            }
            $location = Invoke-Checked aws (@('s3api', 'get-bucket-location', '--bucket', $Resource.Id, '--expected-bucket-owner', $state.AccountId) + $awsOptions) | ConvertFrom-Json -AsHashtable
            $region = if (-not $location['LocationConstraint']) { 'us-east-1' } elseif ($location.LocationConstraint -eq 'EU') { 'eu-west-1' } else { $location.LocationConstraint }
            if ($region -ne $state.Region) { throw 'The named templates bucket is in another region. Refusing deletion.' }
            $buckets = Invoke-Checked aws (@('s3api', 'list-buckets') + $awsOptions) | ConvertFrom-Json -AsHashtable
            $bucket = @($buckets.Buckets | Where-Object Name -CEQ $Resource.Name)
            if ($bucket.Count -ne 1 -or -not $bucket[0]['CreationDate']) { throw 'Cannot verify the templates bucket creation identity.' }
            $tags = Invoke-External aws (@('s3api', 'get-bucket-tagging', '--bucket', $Resource.Id, '--expected-bucket-owner', $state.AccountId) + $awsOptions) -AllowFailure
            if ($tags.Code -eq 0) { Assert-PreflightTags ($tags.Text | ConvertFrom-Json -AsHashtable).TagSet }
            elseif ($tags.Text -notmatch '\(NoSuchTagSet\)') { throw "Cannot inspect bucket tags: $($tags.Text)" }
            return @{ Id = $Resource.Id; Identity = "$($state.AccountId)|$($bucket[0].CreationDate)" }
        }
        default { throw "Unsupported preflight resource type: $($Resource.Type)" }
    }
    $result = Invoke-External aws ($arguments + $awsOptions) -AllowFailure
    if ($result.Code -ne 0) {
        if ($result.Text -match $notFound) { return $null }
        throw "Cannot inspect $($Resource.Name): $($result.Text)"
    }
    $data = $result.Text | ConvertFrom-Json -AsHashtable
    $tags = $null
    $tagArguments = $null
    $arn = $null
    switch ($Resource.Type) {
        'AWS::DynamoDB::Table' {
            $item = $data.Table; $name = $item.TableName; $id = $name; $identity = $item.TableId; $arn = $item.TableArn
            $tagArguments = @('dynamodb', 'list-tags-of-resource', '--resource-arn', $arn)
        }
        'AWS::ECR::Repository' {
            if ($data.repositories.Count -ne 1) { throw 'Expected exactly one ECR repository.' }
            $item = $data.repositories[0]; $name = $item.repositoryName; $id = $name; $arn = $item.repositoryArn
            $identity = "$arn|$($item.createdAt)"
            $tagArguments = @('ecr', 'list-tags-for-resource', '--resource-arn', $arn)
        }
        'AWS::SecretsManager::Secret' { $name = $data.Name; $id = $data.ARN; $arn = $id; $identity = $id; $tags = $data['Tags'] }
        'AWS::Lambda::Function' { $name = $data.Configuration.FunctionName; $id = $name; $arn = $data.Configuration.FunctionArn; $identity = $data.Configuration.RevisionId; $tags = $data['Tags'] }
        'AWS::Cognito::UserPool' { $name = $data.UserPool.Name; $id = $data.UserPool.Id; $arn = $data.UserPool.Arn; $identity = "$id|$($data.UserPool.CreationDate)"; $tags = $data.UserPool['UserPoolTags'] }
        'AWS::Cognito::UserPoolDomain' {
            $domain = $data['DomainDescription']
            if (-not $domain -or -not $domain['UserPoolId']) { return $null }
            if ($domain.AWSAccountId -ne $state.AccountId -or $domain.UserPoolId -notlike "$($state.Region)_*") { throw 'Cognito domain belongs to another account or region.' }
            $name = $domain.Domain; $id = $name; $identity = "$($domain.UserPoolId)|$($domain['CloudFrontDistribution'])"
            $pool = Invoke-Checked aws (@('cognito-idp', 'describe-user-pool', '--user-pool-id', $domain.UserPoolId) + $awsOptions) | ConvertFrom-Json -AsHashtable
            $tags = $pool.UserPool['UserPoolTags']
        }
        'AWS::ApiGatewayV2::Api' { $name = $data.Name; $id = $data.ApiId; $identity = "$id|$($data.CreatedDate)"; $tags = $data['Tags'] }
        'AWS::SNS::Topic' {
            $id = $data.Attributes.TopicArn; $arn = $id; $name = ($id -split ':')[-1]; $identity = $id
            if ($data.Attributes.Owner -ne $state.AccountId) { throw 'SNS topic belongs to another account.' }
            $tagArguments = @('sns', 'list-tags-for-resource', '--resource-arn', $id)
        }
        'AWS::IAM::Role' {
            $name = $data.Role.RoleName; $id = $name; $roleIdentity = $data.Role.RoleId; $arn = $data.Role.Arn; $tags = $data.Role['Tags']
            $callerArn = $script:identity.Arn
            if ($callerArn -eq $arn -or $callerArn -match "^arn:aws:sts::$($state.AccountId):assumed-role/$([regex]::Escape($name))/") {
                throw 'A matching role is providing the current bootstrap credentials. Sign in with a separate administrator before cleanup.'
            }
            $identity = $roleIdentity
        }
        'AWS::Logs::LogGroup' {
            $items = @($data.logGroups | Where-Object logGroupName -CEQ $Resource.Name)
            if ($items.Count -eq 0) { return $null }
            if ($items.Count -ne 1) { throw 'Ambiguous log group identity.' }
            $name = $items[0].logGroupName; $id = $name; $identity = "$name|$($items[0].creationTime)"; $arn = $items[0].arn
            $tagArguments = @('logs', 'list-tags-log-group', '--log-group-name', $name)
        }
        'AWS::CloudWatch::Alarm' {
            $items = @(@($data['MetricAlarms']) + @($data['CompositeAlarms']) | Where-Object { $_ -and $_.AlarmName -ceq $Resource.Name })
            if ($items.Count -eq 0) { return $null }
            if ($items.Count -ne 1) { throw 'Ambiguous alarm identity.' }
            $name = $items[0].AlarmName; $id = $name; $arn = $items[0].AlarmArn; $identity = "$arn|$($items[0].AlarmConfigurationUpdatedTimestamp)"
            $tagArguments = @('cloudwatch', 'list-tags-for-resource', '--resource-arn', $arn)
        }
    }
    if ($name -cne $Resource.Name -or -not $identity -or -not $id) { throw 'Resource metadata does not match the approved application name and identity.' }
    if ($arn) {
        $prefix = if ($Resource.Type -eq 'AWS::IAM::Role') { "arn:aws:iam::$($state.AccountId):" }
            else { "^arn:aws:[^:]+:$([regex]::Escape($state.Region)):$($state.AccountId):" }
        if (($Resource.Type -eq 'AWS::IAM::Role' -and -not $arn.StartsWith($prefix)) -or
            ($Resource.Type -ne 'AWS::IAM::Role' -and $arn -notmatch $prefix)) { throw 'Resource ARN belongs to another account or region.' }
    }
    if ($tagArguments) {
        $tagData = Invoke-Checked aws ($tagArguments + $awsOptions) | ConvertFrom-Json -AsHashtable
        $tags = if ($Resource.Type -eq 'AWS::ECR::Repository' -or $Resource.Type -eq 'AWS::Logs::LogGroup') { $tagData['tags'] } else { $tagData['Tags'] }
    }
    Assert-PreflightTags $tags
    return @{ Id = $id; Identity = $identity; Data = $data }
}

function Assert-PreflightResourceIdentity {
    param([hashtable]$Resource)
    $details = Get-PreflightResource $Resource
    if ($details -and ($details.Id -cne $Resource.Id -or $details.Identity -ne $Resource.Identity)) {
        throw "Named resource $($Resource.Name) changed since inventory. Refusing deletion."
    }
    return $details
}

function Get-PreflightOrphans {
    param([object[]]$Tracked)
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($type in @('AWS::DynamoDB::Table', 'AWS::ECR::Repository', 'AWS::SecretsManager::Secret', 'AWS::Lambda::Function', 'AWS::Logs::LogGroup', 'AWS::CloudWatch::Alarm', 'AWS::Cognito::UserPoolDomain', 'AWS::S3::Bucket')) {
        foreach ($name in Get-PreflightNames $type) { $candidates.Add(@{ Type = $type; Name = $name; Id = $name }) }
    }
    $roles = Invoke-Checked aws (@('iam', 'list-roles') + $awsOptions) | ConvertFrom-Json -AsHashtable
    foreach ($role in $roles.Roles) {
        if ($role.RoleName -cin @(Get-PreflightNames 'AWS::IAM::Role') -or $role.RoleName -cmatch "^$([regex]::Escape($state.AppName))-\d+-github-deploy$") {
            $candidates.Add(@{ Type = 'AWS::IAM::Role'; Name = $role.RoleName; Id = $role.RoleName })
        }
    }
    $pools = Invoke-Checked aws (@('cognito-idp', 'list-user-pools', '--max-results', '60') + $awsOptions) | ConvertFrom-Json -AsHashtable
    foreach ($pool in $pools.UserPools) {
        if ($pool.Name -cin @(Get-PreflightNames 'AWS::Cognito::UserPool')) { $candidates.Add(@{ Type = 'AWS::Cognito::UserPool'; Name = $pool.Name; Id = $pool.Id }) }
    }
    $apis = Invoke-Checked aws (@('apigatewayv2', 'get-apis') + $awsOptions) | ConvertFrom-Json -AsHashtable
    foreach ($api in $apis.Items) {
        if ($api.Name -cin @(Get-PreflightNames 'AWS::ApiGatewayV2::Api')) { $candidates.Add(@{ Type = 'AWS::ApiGatewayV2::Api'; Name = $api.Name; Id = $api.ApiId }) }
    }
    $topics = Invoke-Checked aws (@('sns', 'list-topics') + $awsOptions) | ConvertFrom-Json -AsHashtable
    foreach ($topic in $topics.Topics) {
        $name = ($topic.TopicArn -split ':')[-1]
        if ($name -cin @(Get-PreflightNames 'AWS::SNS::Topic') -and $topic.TopicArn -ceq "arn:aws:sns:$($state.Region):$($state.AccountId):$name") {
            $candidates.Add(@{ Type = 'AWS::SNS::Topic'; Name = $name; Id = $topic.TopicArn })
        }
    }
    foreach ($resource in $candidates) {
        if (@($Tracked | Where-Object { $_.Type -eq $resource.Type -and $_.Id -ceq $resource.Id }).Count -gt 0) { continue }
        $details = Get-PreflightResource $resource
        if (-not $details) { continue }
        if (@($Tracked | Where-Object { $_.Type -eq $resource.Type -and $_.Id -ceq $details.Id }).Count -gt 0) { continue }
        $resource.Id = $details.Id
        $resource.Identity = $details.Identity
        $resource
    }
}

function Remove-PreflightResource {
    param([hashtable]$Resource)
    $details = Assert-PreflightResourceIdentity $Resource
    if (-not $details) { return }
    switch ($Resource.Type) {
        'AWS::S3::Bucket' { Empty-TeardownBucket -Resource $Resource -Untracked; $arguments = @('s3api', 'delete-bucket', '--bucket', $Resource.Id, '--expected-bucket-owner', $state.AccountId) }
        'AWS::DynamoDB::Table' {
            $table = @{ Id = $Resource.Id; Type = $Resource.Type; Identity = $Resource.Identity }
            Disable-TeardownTableProtection $table
            $arguments = @('dynamodb', 'delete-table', '--table-name', $Resource.Id)
        }
        'AWS::ECR::Repository' { $arguments = @('ecr', 'delete-repository', '--repository-name', $Resource.Id, '--force') }
        'AWS::SecretsManager::Secret' { $arguments = @('secretsmanager', 'delete-secret', '--secret-id', $Resource.Id, '--force-delete-without-recovery') }
        'AWS::Lambda::Function' { $arguments = @('lambda', 'delete-function', '--function-name', $Resource.Id) }
        'AWS::ApiGatewayV2::Api' { $arguments = @('apigatewayv2', 'delete-api', '--api-id', $Resource.Id) }
        'AWS::SNS::Topic' { $arguments = @('sns', 'delete-topic', '--topic-arn', $Resource.Id) }
        'AWS::Logs::LogGroup' { $arguments = @('logs', 'delete-log-group', '--log-group-name', $Resource.Id) }
        'AWS::CloudWatch::Alarm' { $arguments = @('cloudwatch', 'delete-alarms', '--alarm-names', $Resource.Id) }
        'AWS::Cognito::UserPoolDomain' { $arguments = @('cognito-idp', 'delete-user-pool-domain', '--domain', $Resource.Id, '--user-pool-id', $details.Data.DomainDescription.UserPoolId) }
        'AWS::Cognito::UserPool' {
            foreach ($domain in @($details.Data.UserPool['Domain'], $details.Data.UserPool['CustomDomain']) | Where-Object { $_ }) {
                $description = Invoke-Checked aws (@('cognito-idp', 'describe-user-pool-domain', '--domain', $domain) + $awsOptions) | ConvertFrom-Json -AsHashtable
                if (-not $description['DomainDescription'] -or -not $description.DomainDescription['UserPoolId']) { continue }
                if ($description.DomainDescription.UserPoolId -ne $Resource.Id) { throw 'Cognito domain belongs to another pool.' }
                $null = Invoke-Checked aws (@('cognito-idp', 'delete-user-pool-domain', '--domain', $domain, '--user-pool-id', $Resource.Id) + $awsOptions)
                for ($attempt = 0; $attempt -lt 40; $attempt++) {
                    $description = Invoke-Checked aws (@('cognito-idp', 'describe-user-pool-domain', '--domain', $domain) + $awsOptions) | ConvertFrom-Json -AsHashtable
                    $domainDetails = $description['DomainDescription']
                    if (-not $domainDetails -or -not $domainDetails['UserPoolId']) { break }
                    Start-Sleep -Seconds 3
                }
                if ($domainDetails -and $domainDetails['UserPoolId']) { throw 'Cognito domain deletion is still pending. Retry cleanup.' }
            }
            if ($details.Data.UserPool['DeletionProtection'] -eq 'ACTIVE') {
                $null = Invoke-Checked aws (@('cognito-idp', 'update-user-pool', '--user-pool-id', $Resource.Id, '--deletion-protection', 'INACTIVE') + $awsOptions)
            }
            $arguments = @('cognito-idp', 'delete-user-pool', '--user-pool-id', $Resource.Id)
        }
        'AWS::IAM::Role' {
            $profiles = Invoke-Checked aws (@('iam', 'list-instance-profiles-for-role', '--role-name', $Resource.Id) + $awsOptions) | ConvertFrom-Json -AsHashtable
            if ($profiles.InstanceProfiles.Count -gt 0) { throw 'An app-named role has instance-profile dependencies. Remove these manually before cleanup.' }
            $inline = Invoke-Checked aws (@('iam', 'list-role-policies', '--role-name', $Resource.Id) + $awsOptions) | ConvertFrom-Json -AsHashtable
            $attached = Invoke-Checked aws (@('iam', 'list-attached-role-policies', '--role-name', $Resource.Id) + $awsOptions) | ConvertFrom-Json -AsHashtable
            foreach ($name in $inline.PolicyNames) { $null = Invoke-Checked aws (@('iam', 'delete-role-policy', '--role-name', $Resource.Id, '--policy-name', $name) + $awsOptions) }
            foreach ($policy in $attached.AttachedPolicies) { $null = Invoke-Checked aws (@('iam', 'detach-role-policy', '--role-name', $Resource.Id, '--policy-arn', $policy.PolicyArn) + $awsOptions) }
            $arguments = @('iam', 'delete-role', '--role-name', $Resource.Id)
        }
    }
    $details = Assert-PreflightResourceIdentity $Resource
    if (-not $details) { return }
    if ($Resource.Type -ne 'AWS::DynamoDB::Table' -or $details.Data.Table.TableStatus -ne 'DELETING') {
        $null = Invoke-Checked aws ($arguments + $awsOptions)
    }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if (-not (Assert-PreflightResourceIdentity $Resource)) { Write-Host "Deleted named resource: $($Resource.Name)"; return }
        Start-Sleep -Seconds 3
    }
    throw "Deletion of $($Resource.Name) is still pending. Retry cleanup before creating a repository."
}
