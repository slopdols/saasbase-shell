#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path $PSScriptRoot -Parent
$root = Split-Path $scripts -Parent
. (Join-Path $scripts 'common.ps1')
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $thrown = $false
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $thrown = $true
    }
    Assert-True $thrown "Expected failure containing: $Message"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host "PASS: $Name"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) "shell-setup-tests-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $temp
$oldToken = $env:VERCEL_TOKEN
$oldBypass = $env:VERCEL_AUTOMATION_BYPASS_SECRET
$oldIssuer = $env:VUE_APP_COGNITO_ISSUER
$oldClient = $env:VUE_APP_COGNITO_CLIENT_ID
$oldSummary = $env:GITHUB_STEP_SUMMARY
$originalLocation = (Get-Location).Path
$gitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
try {
    $env:GITHUB_STEP_SUMMARY = Join-Path $temp 'step-summary.md'
    Test-Case 'All PowerShell scripts parse' {
        $files = @(Get-ChildItem $scripts -Filter *.ps1 -Recurse) + @(Get-ChildItem (Join-Path $root 'scripts') -Filter *.ps1 -Recurse) + @(Get-Item (Join-Path $root 'setup.ps1'))
        foreach ($file in $files) {
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            Assert-True ($parseErrors.Count -eq 0) "Parse errors in $($file.FullName): $parseErrors"
        }
    }
    Test-Case 'Application names validate at the boundary' {
        Assert-AppName 'my-app'
        foreach ($name in @('', 'ab', 'Uppercase', '../other', '-app', 'app-', ('x' * 25))) {
            Assert-Throws { Assert-AppName $name } 'APP_NAME'
        }
    }
    Test-Case 'Configuration is data, not executable code or a credentials store' {
        $path = Join-Path $temp 'setup.env'
        Set-Content $path "# comment`nAPP_NAME=my-app`nAWS_REGION=us-east-2"
        $config = Read-SetupConfig $path
        Assert-True ($config.APP_NAME -eq 'my-app') 'App name was not read.'
        Set-Content $path 'AWS_SECRET_ACCESS_KEY=do-not-store-here'
        Assert-Throws { Read-SetupConfig $path } 'Unsupported setup.env key'
        Set-Content $path "APP_NAME=one`nAPP_NAME=two"
        Assert-Throws { Read-SetupConfig $path } 'Duplicate'
        Set-Content $path 'APP_NAME=$(throw "must-not-execute")'
        Assert-True ((Read-SetupConfig $path).APP_NAME.StartsWith('$(')) 'Config was executed.'
    }
    Test-Case 'OIDC trust binds both supported subject formats to this repo and stage' {
        $policy = New-TrustPolicy -AccountId 123456789012 -Repository 'owner/app' -OwnerId 123 -RepositoryId 456
        $subjects = $policy.Statement[0].Condition.StringEquals['token.actions.githubusercontent.com:sub']
        Assert-True ($subjects.Count -eq 4) 'Expected two formats for each of two stages.'
        Assert-True ($subjects -contains 'repo:owner/app:environment:prod') 'Missing standard subject.'
        Assert-True ($subjects -contains 'repo:owner@123/app@456:environment:dev') 'Missing ID-based subject.'
        Assert-True (($subjects -join '') -notmatch '\*') 'Trust must not contain wildcard subjects.'
    }
    Test-Case 'Deploy policy is app/account/region specific where supported' {
        $policy = Get-AppDeployPolicy -Path (Join-Path $root 'aws/iam.json') -AppName 'my-app' -AccountId 123456789012 -Region eu-west-1
        $json = $policy | ConvertTo-Json -Depth 20
        Assert-True (-not $json.Contains('saasbase')) 'Policy kept a hardcoded application name.'
        Assert-True ($json.Contains('arn:aws:lambda:eu-west-1:123456789012:function:my-app-api-*')) 'Lambda ARN was not scoped.'
        Assert-True ($json.Contains('arn:aws:iam::123456789012:role/my-app-lambda-*')) 'PassRole was not scoped.'
    }
    Test-Case 'Rendered deploy policy allows HTTP stage tag-on-create only in the selected region' {
        $policy = Get-AppDeployPolicy -Path (Join-Path $root 'aws/iam.json') -AppName 'my-app' -AccountId 123456789012 -Region eu-west-1
        $statements = @($policy.Statement | Where-Object { $_.Effect -eq 'Allow' -and @($_.Action) -contains 'apigateway:TagResource' })
        Assert-True ($statements.Count -eq 1) 'Missing HTTP stage tag-on-create grant.'
        $resources = @($statements[0].Resource)
        $target = 'arn:aws:apigateway:eu-west-1::/apis/test-api/stages'
        Assert-True (@($resources | Where-Object { $target -like $_ }).Count -eq 1) 'Stage creation tagging was not authorized.'
        foreach ($denied in @('arn:aws:apigateway:us-east-2::/apis/test-api/stages',
            'arn:aws:apigateway:eu-west-1::/apis/test-api',
            'arn:aws:apigateway:eu-west-1::/apis/test-api/stages/prod')) {
            Assert-True (@($resources | Where-Object { $denied -like $_ }).Count -eq 0) 'Tag-on-create grant exceeded its regional stage-collection scope.'
        }
    }
    & {
        $repairRoot = Join-Path $temp 'iam-update'
        $null = New-Item -ItemType Directory -Path (Join-Path $repairRoot 'setup-scripts'), (Join-Path $repairRoot 'aws'), (Join-Path $repairRoot '.setup') -Force
        Copy-Item (Join-Path $scripts 'common.ps1'), (Join-Path $scripts 'update-iam.ps1') -Destination (Join-Path $repairRoot 'setup-scripts')
        Copy-Item (Join-Path $root 'aws/iam.json') -Destination (Join-Path $repairRoot 'aws/iam.json')
        $repairState = @{
            AppName = 'test-app'; Repository = 'owner/test-app'; AccountId = '123456789012'
            Region = 'us-east-2'; Profile = 'test-profile'
        }
        Write-JsonFile (Join-Path $repairRoot '.setup/state.json') $repairState
        function New-IamUpdateMock {
            return @{
                Origin = 'owner/test-app'; Template = $false; Account = '123456789012'
                ForeignTags = $false; ForeignArn = $false; ReplaceRole = $false; RoleReads = 0
                Confirmation = 'UPDATE'; Writes = 0; FailWrite = $false; PolicyFile = ''; Policy = $null
                Calls = [System.Collections.Generic.List[string]]::new()
            }
        }
        function git {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            if (($Arguments -join ' ') -eq 'remote get-url origin') {
                return "https://github.com/$($global:ShellIamUpdateTestState.Origin).git"
            }
            throw 'IAM repair must not change Git.'
        }
        function gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $command = $Arguments -join ' '
            if ($command -like 'auth status*') { return }
            if ($command -eq 'api repos/owner/test-app') {
                return (@{ id = 456; full_name = 'owner/test-app'; is_template = $global:ShellIamUpdateTestState.Template; permissions = @{ admin = $true } } | ConvertTo-Json -Depth 5)
            }
            throw 'IAM repair must not configure GitHub or start workflows.'
        }
        function Read-Host {
            param([string]$Prompt)
            if ($Prompt -eq 'Type UPDATE to apply these permissions') { return $global:ShellIamUpdateTestState.Confirmation }
            if ($Prompt -like 'Local AWS profile*') { return '' }
            throw "Unexpected repair prompt: $Prompt"
        }
        function aws {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $mock = $global:ShellIamUpdateTestState
            $command = $Arguments -join ' '
            $mock.Calls.Add($command)
            Assert-True ($Arguments -contains 'test-profile' -and $Arguments -contains 'us-east-2') 'Repair lost the selected profile or recorded region.'
            if ($command -like 'sts get-caller-identity*') {
                return (@{ Account = $mock.Account; Arn = "arn:aws:iam::$($mock.Account):user/Admin" } | ConvertTo-Json)
            }
            if ($command -like 'iam get-role --role-name test-app-456-github-deploy*') {
                $mock.RoleReads++
                $id = if ($mock.ReplaceRole -and $mock.RoleReads -gt 1) { 'AROAREPLACEMENT' } else { 'AROAORIGINAL' }
                $account = if ($mock.ForeignArn) { '999999999999' } else { '123456789012' }
                $repository = if ($mock.ForeignTags) { 'other/test-app' } else { 'owner/test-app' }
                return (@{ Role = @{
                    RoleName = 'test-app-456-github-deploy'; RoleId = $id
                    Arn = "arn:aws:iam::${account}:role/test-app-456-github-deploy"
                    Tags = @(@{ Key = 'Application'; Value = 'test-app' }, @{ Key = 'GitHubRepository'; Value = $repository })
                } } | ConvertTo-Json -Depth 6)
            }
            if ($command -like 'iam put-role-policy --role-name test-app-456-github-deploy --policy-name test-app-deploy*') {
                $mock.Writes++
                $mock.PolicyFile = $Arguments[[array]::IndexOf($Arguments, '--policy-document') + 1].Substring(7)
                $mock.Policy = Get-Content -LiteralPath $mock.PolicyFile -Raw | ConvertFrom-Json -AsHashtable
                if ($mock.FailWrite) { $global:LASTEXITCODE = 7; return 'AccessDenied: cannot update role policy' }
                return
            }
            throw "IAM repair made an unexpected AWS request: $command"
        }
        try {
            Test-Case 'IAM repair renders current permissions for the verified application role' {
                $global:ShellIamUpdateTestState = New-IamUpdateMock
                $output = & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>&1 | Out-String
                $mock = $global:ShellIamUpdateTestState
                Assert-True ($mock.Writes -eq 1) 'Repair did not update exactly one app policy.'
                $policy = $mock.Policy | ConvertTo-Json -Depth 30
                Assert-True ($policy.Contains('test-app-api-*') -and $policy.Contains('arn:aws:lambda:us-east-2:123456789012:')) 'Repair applied an unrendered or wrongly scoped policy.'
                Assert-True ($policy.Contains('apigateway:TagResource')) 'Repair did not apply the current IAM fix.'
                Assert-True (-not (Test-Path -LiteralPath $mock.PolicyFile)) 'Repair left its temporary policy file behind.'
                Assert-True ($output.Contains('Permissions updated') -and $output.Contains('No deployment was started')) 'Repair misreported deployment status.'
            }
            Test-Case 'IAM repair plan and cancellation do not write permissions' {
                $global:ShellIamUpdateTestState = New-IamUpdateMock
                & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') -Plan 6>$null
                $global:ShellIamUpdateTestState.Confirmation = 'CANCEL'
                & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>$null
                Assert-True ($global:ShellIamUpdateTestState.Writes -eq 0) 'Plan or cancellation changed AWS.'
            }
            Test-Case 'IAM repair rejects mismatched origin, template, account and role ownership' {
                foreach ($case in @(
                    @{ Field = 'Origin'; Value = 'owner/other-app'; Error = 'does not match' },
                    @{ Field = 'Template'; Value = $true; Error = 'template repository' },
                    @{ Field = 'Account'; Value = '999999999999'; Error = 'AWS account' },
                    @{ Field = 'ForeignTags'; Value = $true; Error = 'ownership' },
                    @{ Field = 'ForeignArn'; Value = $true; Error = 'ownership' }
                )) {
                    $global:ShellIamUpdateTestState = New-IamUpdateMock
                    $global:ShellIamUpdateTestState[$case.Field] = $case.Value
                    Assert-Throws { & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>$null } $case.Error
                    Assert-True ($global:ShellIamUpdateTestState.Writes -eq 0) 'Unverified identity reached a policy update.'
                }
            }
            Test-Case 'IAM repair detects role replacement during confirmation' {
                $global:ShellIamUpdateTestState = New-IamUpdateMock
                $global:ShellIamUpdateTestState.ReplaceRole = $true
                Assert-Throws { & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>$null } 'replaced'
                Assert-True ($global:ShellIamUpdateTestState.Writes -eq 0) 'Repair updated a replacement role.'
            }
            Test-Case 'IAM repair propagates AWS write errors and removes its temporary policy' {
                $global:ShellIamUpdateTestState = New-IamUpdateMock
                $global:ShellIamUpdateTestState.FailWrite = $true
                Assert-Throws { & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>$null } 'exit 7'
                Assert-True (-not (Test-Path -LiteralPath $global:ShellIamUpdateTestState.PolicyFile)) 'Failed repair left its policy file behind.'
            }
            Test-Case 'IAM repair requires valid recorded setup identity' {
                $global:ShellIamUpdateTestState = New-IamUpdateMock
                $invalidState = $repairState.Clone()
                $invalidState.AccountId = 'not-an-account'
                Write-JsonFile (Join-Path $repairRoot '.setup/state.json') $invalidState
                Assert-Throws { & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>$null } 'Invalid setup identity'
                Remove-Item -LiteralPath (Join-Path $repairRoot '.setup/state.json')
                Assert-Throws { & (Join-Path $repairRoot 'setup-scripts/update-iam.ps1') 6>$null } 'original application folder'
                Assert-True ($global:ShellIamUpdateTestState.Calls.Count -eq 0) 'Missing or invalid state reached AWS.'
            }
        } finally { Remove-Variable -Name ShellIamUpdateTestState -Scope Global }
    }
    Test-Case 'HTTPS origin validation rejects injected policy and URL components' {
        Assert-True ((Get-WebsiteOrigin 'https://example.com/') -eq 'https://example.com') 'Origin normalization failed.'
        foreach ($url in @('http://example.com', 'https://example.com/path', 'https://user@example.com',
            'https://example.com?x=1', 'https://example.com#fragment', 'https://example.com:8080',
            "https://example.com; script-src *")) {
            Assert-Throws { Get-WebsiteOrigin $url } 'Expected an HTTPS origin'
        }
    }
    Test-Case 'Prebuilt output preserves security headers, SPA routing and exact API CSP' {
        $config = New-VercelOutputConfig -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -HeadersPath (Join-Path $root 'website/vercel.json')
        $csp = $config.routes[0].headers['Content-Security-Policy']
        Assert-True ($config.version -eq 3) 'Wrong Build Output API version.'
        Assert-True ($csp.Contains("connect-src 'self' https://abc.execute-api.us-east-2.amazonaws.com;")) 'Missing API origin.'
        Assert-True (-not $csp.Contains('example.com')) 'Placeholder origin leaked into the deployment.'
        Assert-True ($config.routes[0].headers['X-Content-Type-Options'] -eq 'nosniff') 'Security headers were dropped.'
        Assert-True ($config.routes[1].handle -eq 'filesystem') 'Assets must resolve before SPA fallback.'
        Assert-True ($config.routes[2].dest -eq '/index.html') 'Missing SPA fallback.'
    }
    Test-Case 'Missing backend exports fail instead of returning an empty URL' {
        Assert-Throws { Get-RequiredExport -Exports @() -Name 'my-app-prod-api-endpoint' } 'Missing CloudFormation export'
        $value = Get-RequiredExport -Exports @(@{ Name = 'endpoint'; Value = 'https://example.com' }) -Name endpoint
        Assert-True ($value -eq 'https://example.com') 'Wrong export value.'
    }
    Test-Case 'Backend deployment outputs resolve from combined JSON exports, not per-page text results' {
        & {
            $data = @{ Exports = @(
                @{ Name = 'other-prod-api-endpoint'; Value = 'https://other.example.com' },
                @{ Name = 'my-app-dev-api-endpoint'; Value = 'https://api.example.com/' },
                @{ Name = 'my-app-dev-user-pool-client-id'; Value = 'client123' },
                @{ Name = 'my-app-dev-cognito-issuer'; Value = 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_pool' }
            ) }
            $calls = [System.Collections.Generic.List[string]]::new()
            function aws {
                param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                $calls.Add($Arguments -join ' ')
                if (($Arguments -join ' ') -ne 'cloudformation list-exports --region us-east-2 --output json --no-cli-pager') {
                    throw 'Export lookup must combine all pages as JSON without a text query.'
                }
                return ($data | ConvertTo-Json -Depth 10)
            }
            $outputs = Get-BackendDeploymentOutputs -AppName my-app -Stage dev -Region us-east-2
            Assert-True ($outputs.api_url -eq 'https://api.example.com' -and $outputs.cognito_client_id -eq 'client123') 'Wrong or unnormalized deployment outputs.'
            Assert-True ($calls.Count -eq 1) 'Deployment exports were not resolved from one combined listing.'
            $data.Exports = @($data.Exports | Where-Object Name -NE 'my-app-dev-api-endpoint')
            Assert-Throws { Get-BackendDeploymentOutputs -AppName my-app -Stage dev -Region us-east-2 } "Missing CloudFormation export 'my-app-dev-api-endpoint'"
            $data.Exports += @{ Name = 'my-app-dev-api-endpoint'; Value = "None`nhttps://api.example.com" }
            Assert-Throws { Get-BackendDeploymentOutputs -AppName my-app -Stage dev -Region us-east-2 } 'Expected an HTTPS origin'
            function aws {
                param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                $global:LASTEXITCODE = 7
                return 'AccessDenied'
            }
            Assert-Throws { Get-BackendDeploymentOutputs -AppName my-app -Stage dev -Region us-east-2 } 'exit 7'
        }
    }
    Test-Case 'Public auth CSP allows only the exact API and Cognito origins' {
        $cognito = Get-CognitoOrigin 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test'
        $config = New-VercelOutputConfig -ApiUrl 'https://api.example.com' -HeadersPath (Join-Path $root 'website/vercel.json') -CognitoOrigin $cognito
        $csp = $config.routes[0].headers['Content-Security-Policy']
        Assert-CspConnectOrigin -Csp $csp -Origin 'https://api.example.com'
        Assert-CspConnectOrigin -Csp $csp -Origin $cognito
        Assert-Throws { Assert-CspConnectOrigin -Csp $csp -Origin 'https://other.example.com' } 'does not allow'
        Assert-Throws { Get-CognitoOrigin 'https://attacker.example.com/pool' } 'Cognito'
    }
    Test-Case 'Setup handoff points to this repo main workflow and this folder prompt' {
        $output = Write-SetupNextSteps -Repository 'new-owner/new-app' -Root $temp 6>&1 | Out-String
        Assert-True ($output.Contains('https://github.com/new-owner/new-app/actions/workflows/ci-cd.yml')) 'Wrong Actions link.'
        Assert-True ($output.Contains((Join-Path $temp 'context/onboarding/run-this-prompt-after-setup.md'))) 'Wrong prompt path.'
        Assert-True ($output.Contains('Both deployments passed')) 'Missing verified completion message.'
        Assert-True ($output.Contains("Rename this local folder to 'new-app' afterward")) 'Missing manual folder rename reminder.'
    }
    Test-Case 'Deployment URLs are parsed without confusing CLI logs or aliases' {
        $url = Get-VercelDeploymentUrl "Inspect: https://vercel.com/team/project`nhttps://deployment-123.vercel.app`nReady"
        Assert-True ($url -eq 'https://deployment-123.vercel.app') 'Wrong deployment URL.'
        Assert-Throws { Get-VercelDeploymentUrl 'No URL returned' } 'unambiguous'
        Assert-Throws { Get-VercelDeploymentUrl "https://one.vercel.app`nhttps://two.vercel.app" } 'unambiguous'
    }
    Test-Case 'Native process failures propagate and do not expose command arguments' {
        $pwsh = (Get-Process -Id $PID).Path
        Assert-Throws { Invoke-Checked $pwsh -Arguments @('-NoProfile', '-Command', 'exit 7') } 'exit 7'
        $result = Invoke-External $pwsh -Arguments @('-NoProfile', '-Command', 'exit 3') -AllowFailure
        Assert-True ($result.Code -eq 3) 'Exit code was lost.'
    }
    Test-Case 'Windows bootstrap installs only missing tools and verifies the result' {
        & {
            . (Join-Path $scripts 'bootstrap.ps1')
            $installer = @{ Missing = @('git', 'aws'); Calls = @(); Fail = $false }
            function Update-SetupPath {}
            function Get-MissingSetupTools { return $installer.Missing }
            function Invoke-BootstrapCommand {
                param($Command, [string[]]$Arguments)
                Assert-True ($Command -eq 'winget') 'Unexpected package manager.'
                $installer.Calls += ,$Arguments
                if (-not $installer.Fail) {
                    if ($Arguments -contains 'Git.Git') { $installer.Missing = @($installer.Missing | Where-Object { $_ -ne 'git' }) }
                    if ($Arguments -contains 'Amazon.AWSCLI') { $installer.Missing = @($installer.Missing | Where-Object { $_ -ne 'aws' }) }
                }
            }
            function Get-Command { param($Name, $ErrorAction) return @{ Name = $Name } }
            Install-WindowsSetupTools 6>$null
            Assert-True ($installer.Calls.Count -eq 2) 'Expected two package installs.'
            foreach ($arguments in $installer.Calls) {
                Assert-True ($arguments -contains '--exact' -and $arguments -contains 'winget') 'Installer did not select an exact trusted package source.'
            }
            Install-WindowsSetupTools 6>$null
            Assert-True ($installer.Calls.Count -eq 2) 'Prepared machine was reinstalled.'
            $installer.Missing = @('aws')
            $installer.Fail = $true
            Assert-Throws { Install-WindowsSetupTools 6>$null } 'still unavailable or outdated'
        }
    }
    Test-Case 'Windows bootstrap recognizes unsupported PowerShell and AWS versions' {
        & {
            . (Join-Path $scripts 'bootstrap.ps1')
            $versions = @{ PowerShell = '7.1.0'; Aws = 'aws-cli/1.40.0'; Absent = 'gh' }
            function Get-Command { param($Name, $ErrorAction) if ($Name -ne $versions.Absent) { return @{ Name = $Name } } }
            function pwsh { param([Parameter(ValueFromRemainingArguments)]$Arguments) $global:LASTEXITCODE = 0; return $versions.PowerShell }
            function aws { param([Parameter(ValueFromRemainingArguments)]$Arguments) $global:LASTEXITCODE = 0; return $versions.Aws }
            $missing = @(Get-MissingSetupTools)
            Assert-True (($missing -join ',') -eq 'pwsh,gh,aws') 'Old or absent tools were not detected.'
            $versions.PowerShell = '7.2.0'
            $versions.Aws = 'aws-cli/2.32.0'
            $versions.Absent = ''
            Assert-True (@(Get-MissingSetupTools).Count -eq 0) 'Supported versions triggered installation.'
        }
    }
    Test-Case 'Root PowerShell launcher bootstraps and forwards wizard arguments' {
        $launchRoot = Join-Path $temp 'launcher'
        $null = New-Item -ItemType Directory -Path (Join-Path $launchRoot 'setup-scripts') -Force
        Copy-Item (Join-Path $root 'setup.ps1') -Destination (Join-Path $launchRoot 'setup.ps1')
        Set-Content (Join-Path $launchRoot 'setup-scripts/bootstrap.ps1') 'function Install-WindowsSetupTools { Write-Output "bootstrap-called" }'
        Set-Content (Join-Path $launchRoot 'setup-scripts/install-tools.sh') "echo bootstrap-called"
        Set-Content (Join-Path $launchRoot 'setup-scripts/setup.ps1') 'param($AppName, $ConfigPath); Write-Output "wizard-app=$AppName;config=$ConfigPath"'
        $pwsh = (Get-Process -Id $PID).Path
        $output = Invoke-Checked $pwsh -Arguments @('-NoProfile', '-File', (Join-Path $launchRoot 'setup.ps1'), '-AppName', 'launcher-test', '-ConfigPath', 'choices.env')
        Assert-True ($output.Contains('bootstrap-called') -and $output.Contains('wizard-app=launcher-test;config=choices.env')) 'Launcher omitted bootstrap or lost arguments.'
    }
    Test-Case 'Relocated operation launchers resolve the repository and forward plan arguments' {
        $launchRoot = Join-Path $temp 'operations-launcher'
        $null = New-Item -ItemType Directory -Path (Join-Path $launchRoot 'setup-scripts'), (Join-Path $launchRoot 'scripts') -Force
        Set-Content (Join-Path $launchRoot 'setup-scripts/bootstrap.ps1') 'function Install-WindowsSetupTools { Write-Output "bootstrap-called" }'
        Set-Content (Join-Path $launchRoot 'setup-scripts/install-tools.sh') 'echo bootstrap-called'
        Set-Content (Join-Path $launchRoot 'setup-scripts/destroy-project.ps1') 'param([switch]$Plan); Write-Output "destroy-plan=$Plan"'
        Set-Content (Join-Path $launchRoot 'setup-scripts/purge-project.ps1') 'param($AppName, [switch]$Plan); Write-Output "purge-app=$AppName;plan=$Plan"'
        Set-Content (Join-Path $launchRoot 'setup-scripts/update-iam.ps1') 'param($AWSProfile, [switch]$Plan); Write-Output "iam-profile=$AWSProfile;plan=$Plan"'
        $pwsh = (Get-Process -Id $PID).Path
        foreach ($name in @('destroy', 'purge', 'update-iam')) {
            $launcher = Join-Path $launchRoot "scripts/$name.ps1"
            Copy-Item (Join-Path $root "scripts/$name.ps1") -Destination $launcher
            $arguments = @('-NoProfile', '-File', $launcher, '-Plan')
            if ($name -eq 'purge') { $arguments += @('-AppName', 'launcher-test') }
            if ($name -eq 'update-iam') { $arguments += @('-AWSProfile', 'launcher-profile') }
            $output = Invoke-Checked $pwsh -Arguments $arguments
            Assert-True ($output.Contains('bootstrap-called')) 'Operation launcher omitted bootstrap.'
            $expected = switch ($name) {
                'purge' { 'purge-app=launcher-test;plan=True' }
                'update-iam' { 'iam-profile=launcher-profile;plan=True' }
                default { 'destroy-plan=True' }
            }
            Assert-True ($output.Contains($expected)) 'Operation launcher resolved the wrong target or lost arguments.'
        }
    }
    Test-Case 'Vercel token retrieval prefers the process environment and reads the encrypted vault' {
        & {
            $env:VERCEL_TOKEN = 'process-token'
            function Get-Module { param([switch]$ListAvailable, $Name) return $true }
            function Import-Module { param($Name) }
            function Get-SecretVault { return @{ Name = 'Saasbase'; ModuleName = 'Microsoft.PowerShell.SecretStore' } }
            function Get-SecretStoreConfiguration { return @{ Authentication = 'Password' } }
            function Get-SecretInfo { param($Name, $Vault) return @{ Name = 'VERCEL_TOKEN' } }
            function Get-Secret {
                param($Name, $Vault)
                Assert-True ($Name -eq 'VERCEL_TOKEN' -and $Vault -eq 'Saasbase') 'Wrong vault secret requested.'
                return ConvertTo-SecureString 'vault-token' -AsPlainText -Force
            }
            Assert-True ((Get-SetupVercelToken) -eq 'process-token') 'Environment did not take precedence.'
            $env:VERCEL_TOKEN = $null
            Assert-True ((Get-SetupVercelToken) -eq 'vault-token') 'Encrypted vault token was not read.'
            function Get-Secret { param($Name, $Vault) throw 'vault access denied' }
            Assert-Throws { Get-SetupVercelToken } 'vault access denied'
            function Get-SecretStoreConfiguration { return @{ Authentication = 'None' } }
            Assert-Throws { Get-SetupVercelToken } 'password authentication'
            function Get-Module { param([switch]$ListAvailable, $Name) }
            function Read-Host {
                param($Prompt, [switch]$AsSecureString)
                if ($AsSecureString) { return ConvertTo-SecureString 'prompt-token' -AsPlainText -Force }
                return 'n'
            }
            function Invoke-RestMethod {
                param($Uri, $Method, $Headers, [switch]$SkipHttpErrorCheck, $StatusCodeVariable)
                Set-Variable $StatusCodeVariable 200 -Scope 1
                return @{}
            }
            Assert-True ((Get-SetupVercelToken) -eq 'prompt-token') 'Missing optional vault did not use hidden input.'
        }
        $env:VERCEL_TOKEN = $oldToken
    }
    Test-Case 'Saving a Vercel token validates it and requires password-protected storage' {
        & {
            $vaultTest = @{ Saved = $false; Deny = $false; Authentication = 'Password'; Installed = @() }
            function Get-Module { param([switch]$ListAvailable, $Name) return ($Name -in $vaultTest.Installed) }
            function Install-Module {
                param($Name, $Scope, $Repository, [switch]$Force)
                Assert-True ($Scope -eq 'CurrentUser' -and $Repository -eq 'PSGallery') 'Vault modules must install only for this user from PSGallery.'
                $vaultTest.Installed += $Name
            }
            function Import-Module { param($Name) }
            function Get-SecretVault { return @{ Name = 'Saasbase'; ModuleName = 'Microsoft.PowerShell.SecretStore' } }
            function Get-SecretStoreConfiguration { return @{ Authentication = $vaultTest.Authentication } }
            function Read-Host {
                param($Prompt, [switch]$AsSecureString)
                Assert-True $AsSecureString 'Saved token input must be hidden.'
                return ConvertTo-SecureString 'save-test-token' -AsPlainText -Force
            }
            function Invoke-RestMethod {
                param($Uri, $Method, $Headers, [switch]$SkipHttpErrorCheck, $StatusCodeVariable)
                Assert-True ($Uri -eq 'https://api.vercel.com/v2/user') 'Token was not validated.'
                Set-Variable $StatusCodeVariable $(if ($vaultTest.Deny) { 403 } else { 200 }) -Scope 1
                return @{}
            }
            function Set-Secret {
                param($Name, $Secret, $Vault)
                Assert-True ($Name -eq 'VERCEL_TOKEN' -and $Vault -eq 'Saasbase') 'Wrong storage target.'
                Assert-True ($Secret -is [Security.SecureString]) 'Token must be stored as a SecureString.'
                $vaultTest.Saved = $true
            }
            $saveScript = Join-Path $scripts 'save-vercel-token.ps1'
            & $saveScript 6>$null
            Assert-True $vaultTest.Saved 'Validated token was not saved.'
            Assert-True ($vaultTest.Installed.Count -eq 2) 'Missing vault modules were not installed.'
            $vaultTest.Saved = $false
            $vaultTest.Deny = $true
            Assert-Throws { & $saveScript 6>$null } 'HTTP 403'
            Assert-True (-not $vaultTest.Saved) 'Invalid token was saved.'
            $vaultTest.Deny = $false
            $vaultTest.Authentication = 'None'
            Assert-Throws { & $saveScript 6>$null } 'password protection'
            Assert-True (-not $vaultTest.Saved) 'Unprotected vault was used.'
        }
    }

    # Full wizard runs against in-memory GitHub/AWS/Vercel implementations only.
    $fixture = Join-Path $temp 'test-shell'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'setup-scripts') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'aws') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'config') -Force
    Copy-Item (Join-Path $scripts 'common.ps1'), (Join-Path $scripts 'setup.ps1'), (Join-Path $scripts 'publish-website.ps1'), (Join-Path $scripts 'destroy-project.ps1'), (Join-Path $scripts 'aws-preflight.ps1') -Destination (Join-Path $fixture 'setup-scripts')
    Copy-Item (Join-Path $root 'aws/iam.json') -Destination (Join-Path $fixture 'aws/iam.json')
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'website') -Force
    Copy-Item (Join-Path $root 'website/vercel.json') -Destination (Join-Path $fixture 'website/vercel.json')
    Set-Content (Join-Path $fixture 'config/setup.env') "APP_NAME=test-shell`nAWS_REGION=us-east-2`nAWS_PROFILE=test-profile"
    $script:mock = @{
        Account = '123456789012'; Provider = $false; Role = $false; DevBranch = $false
        Projects = @{}; Domains = @{}; Environments = @{}; Variables = @{}; Secrets = @{}
        RoleCreates = 0; Calls = [System.Collections.Generic.List[string]]::new()
        ForeignRoleName = $null
        PreflightStack = $false; PreflightReadDenied = $false
        BranchPolicies = @{}; Fixture = $fixture; UploadPath = ''; FailDeploy = $false; VercelDeny = $false
        AliasCalls = [System.Collections.Generic.List[string]]::new()
        ActualTarget = 'production'; ReturnedTarget = 'auto'; Uploads = 0
        ReturnedProjectId = $null; NewApp = $false; GeneratedBypasses = @()
        RepoExists = $false; FailRepoCheck = $false; FailLink = $false; Linked = $false
        DeleteVercelProject = $false; VercelDeletePrompts = 0
        Repository = 'owner/test-shell'
        ExpiredIdentity = $false; SsoMode = 'console'
        MissingProfile = $false; FailProfileInspection = $false
        Unpauses = 0; DenyUnpause = $false
        Commit = ('a' * 40); Remote = @{ main = ('b' * 40); dev = ('b' * 40) }
        Runs = @{ main = @(); dev = @() }; RunCounter = 100
        FailProduction = $false; SkipFrontend = $false; Divergent = $false; SkipCi = $false
        SkipLiveJob = $false; SkipLiveStep = $false
        RemoteInitialized = $false
    }
    $global:ShellSetupTestState = $script:mock
    $env:VERCEL_TOKEN = 'test-token-not-a-real-credential'
    $env:VERCEL_AUTOMATION_BYPASS_SECRET = 'test-bypass-not-a-real-credential'
    $env:VUE_APP_COGNITO_ISSUER = 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test'
    $env:VUE_APP_COGNITO_CLIENT_ID = 'client123'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture '.setup')
    Write-JsonFile (Join-Path $fixture '.setup/state.json') @{
        Repository = 'owner/app'; AppName = 'test-shell'; AccountId = '123456789012'
        Region = 'us-east-2'; Profile = 'test-profile'; VercelOwnerId = 'team_test'
    }

    function git {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        $global:ShellSetupTestState.Calls.Add("git $($Arguments -join ' ')")
        $text = $Arguments -join ' '
        if ($text -eq 'status --porcelain') { return '' }
        if ($text -eq 'branch --show-current') { return 'main' }
        if ($text -eq 'remote get-url origin') {
            if (-not $global:ShellSetupTestState.Linked) { return 'https://github.com/owner/shell.git' }
            return "https://github.com/$($global:ShellSetupTestState.Repository).git"
        }
        if ($text -eq 'remote get-url --push origin') { return "https://github.com/$($global:ShellSetupTestState.Repository).git" }
        if ($text -eq 'rev-parse refs/heads/main') { return $global:ShellSetupTestState.Commit }
        if ($text -match '^rev-parse refs/remotes/origin/(main|dev)$') { return $global:ShellSetupTestState.Remote[$Matches[1]] }
        if ($text -like 'merge-base --is-ancestor*') {
            if ($global:ShellSetupTestState.Divergent) { $global:LASTEXITCODE = 1 }
            return
        }
        if ($Arguments -contains 'push') {
            $branch = ($Arguments[-1] -split 'refs/heads/')[1]
            $global:ShellSetupTestState.Remote[$branch] = $global:ShellSetupTestState.Commit
            if ($global:ShellSetupTestState.SkipCi) { return }
            $global:ShellSetupTestState.RunCounter++
            $global:ShellSetupTestState.Runs[$branch] += @{
                databaseId = $global:ShellSetupTestState.RunCounter; status = 'completed'
                headSha = $global:ShellSetupTestState.Commit; event = 'push'
            }
            return
        }
        if ($text -like 'log * --format=%B') {
            if ($global:ShellSetupTestState.SkipCi) { return 'shell commit [skip ci]' }
            return 'shell commit'
        }
        if ($text -like 'var GIT_*_IDENT') { return 'Test User <test@example.com>' }
        if ($Arguments -contains 'ls-remote') {
            if ($global:ShellSetupTestState.FailLink) { throw 'mock linking failure' }
            if ($global:ShellSetupTestState.RemoteInitialized) { return "existing refs/heads/main" }
            return
        }
        if ($Arguments -contains 'fetch' -or $Arguments -contains 'commit') {
            if ($global:ShellSetupTestState.FailLink) { throw 'mock linking failure' }
            if ($Arguments -contains 'commit') {
                $message = $Arguments[[array]::IndexOf($Arguments, '-m') + 1]
                $global:ShellSetupTestState.SkipCi = $message.Contains('[skip ci]')
            }
            return
        }
        if ($text -like 'remote set-url origin *') { $global:ShellSetupTestState.Linked = $true; return }
        if ($text -eq 'config --get-all remote.origin.pushurl') { Set-Variable LASTEXITCODE 1 -Scope Global; return }
        if ($text -eq 'branch --set-upstream-to=origin/main main') { return }
        if ($text -ne 'rev-parse --show-toplevel') { throw "Unexpected git command: $text" }
        return $fixture
    }
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($Prompt -eq 'Type SETUP to continue') { return 'SETUP' }
        if ($Prompt -eq 'Press Enter after deleting it, or type CANCEL to stop') {
            $global:ShellSetupTestState.VercelDeletePrompts++
            if ($global:ShellSetupTestState.DeleteVercelProject) {
                $global:ShellSetupTestState.Projects.Remove('app-456')
            } elseif ($global:ShellSetupTestState.VercelDeletePrompts -gt 1) { return 'CANCEL' }
            return ''
        }
        if ($Prompt -like 'AWS sign-in method*' -and $global:ShellSetupTestState.SsoMode -in @('new-sso', 'missing-sso')) { return 'sso' }
        return ''
    }
    function gh {
        [CmdletBinding(PositionalBinding = $false)]
        param(
            [Parameter(ValueFromRemainingArguments)][string[]]$Arguments,
            [Parameter(ValueFromPipeline)][string]$InputText
        )
        $text = $Arguments -join ' '
        $global:ShellSetupTestState.Calls.Add("gh $text")
        $text = $text.Replace('owner/test-shell', 'owner/app')
        if ($text -like 'auth status*') { return }
        if ($text -eq 'api user --jq .login') { return 'owner' }
        if ($text -like 'repo create * --private') {
            $global:ShellSetupTestState.RepoExists = $true
            $global:ShellSetupTestState.Repository = $Arguments[2]
            $global:ShellSetupTestState.RemoteInitialized = $false
            $global:ShellSetupTestState.DevBranch = $false
            return
        }
        if ($text -like 'repo edit * --default-branch main') { return }
        if ($text -match '^workflow run ci-cd.yml --repo owner/app --ref (main|dev)$') {
            $branch = $Matches[1]
            $global:ShellSetupTestState.RunCounter++
            $global:ShellSetupTestState.Runs[$branch] += @{
                databaseId = $global:ShellSetupTestState.RunCounter; status = 'completed'
                headSha = $global:ShellSetupTestState.Commit; event = 'workflow_dispatch'
            }
            return
        }
        if ($Arguments[0] -eq 'run' -and $Arguments[1] -eq 'list') {
            $branch = $Arguments[[array]::IndexOf($Arguments, '--branch') + 1]
            return (ConvertTo-Json -InputObject @($global:ShellSetupTestState.Runs[$branch]) -Depth 5 -Compress)
        }
        if ($Arguments[0] -eq 'run' -and $Arguments[1] -eq 'view') {
            $id = [long]$Arguments[2]
            $branch = if (@($global:ShellSetupTestState.Runs.main | Where-Object databaseId -EQ $id).Count) { 'main' } else { 'dev' }
            $steps = @(foreach ($name in @('Bootstrap/update stateful resources without disabling compute', 'Build and push Lambda image',
                'Deploy Lambda and API Gateway', 'Build, deploy and verify frontend')) {
                @{ name = $name; conclusion = $(if ($global:ShellSetupTestState.SkipFrontend -and $name -eq 'Build, deploy and verify frontend') { 'skipped' } else { 'success' }) }
            })
            $jobs = @(foreach ($name in @('test-infrastructure', 'test-backend', 'test-website', 'Check changes and overrides', 'deploy')) {
                @{ name = $name; conclusion = 'success'; steps = $(if ($name -eq 'deploy') { $steps } else { @() }) }
            })
            $jobs += @{
                name = 'Test deployed website and API'
                conclusion = $(if ($global:ShellSetupTestState.SkipLiveJob) { 'skipped' } else { 'success' })
                steps = @(@{ name = 'Verify live API and browser contracts'; conclusion = $(if ($global:ShellSetupTestState.SkipLiveStep) { 'skipped' } else { 'success' }) })
            }
            return (@{
                status = 'completed'; conclusion = $(if ($global:ShellSetupTestState.FailProduction -and $branch -eq 'main') { 'failure' } else { 'success' })
                headSha = $global:ShellSetupTestState.Commit; headBranch = $branch; jobs = $jobs
            } | ConvertTo-Json -Depth 10 -Compress)
        }
        if ($text -like 'repo view*') {
            if ($env:GH_REPO) { return $env:GH_REPO }
            if ($global:ShellSetupTestState.NewApp -and -not $global:ShellSetupTestState.Linked) { return 'owner/shell' }
            return 'owner/app'
        }
        if ($text -eq 'api repos/owner/app') {
            if (-not $global:ShellSetupTestState.RepoExists) {
                Set-Variable LASTEXITCODE 1 -Scope Global
                if ($global:ShellSetupTestState.FailRepoCheck) { return 'HTTP 403' }
                return 'HTTP 404'
            }
            $data = @{ id = 456; full_name = $global:ShellSetupTestState.Repository; is_template = $false; owner = @{ id = 123 }; default_branch = 'main'; permissions = @{ admin = $true } }
            return ($data | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($text -eq 'api repos/owner/shell') {
            return '{"id":123,"full_name":"owner/shell","is_template":true,"owner":{"id":123},"default_branch":"main","permissions":{"admin":true}}'
        }
        if ($text -match '^api repos/owner/app/environments/(prod|dev)$') {
            if (-not $global:ShellSetupTestState.Environments.ContainsKey($Matches[1])) {
                Set-Variable LASTEXITCODE 1 -Scope Global
                return 'HTTP 404'
            }
            return '{"deployment_branch_policy":{"custom_branch_policies":true}}'
        }
        if ($text -match '^api --method PUT repos/owner/app/environments/(prod|dev)') {
            $global:ShellSetupTestState.Environments[$Matches[1]] = $true
            return '{}'
        }
        if ($text -match '^api repos/owner/app/environments/(prod|dev)/deployment-branch-policies') {
            $stage = $Matches[1]
            if ($global:ShellSetupTestState.BranchPolicies.ContainsKey($stage)) {
                return $global:ShellSetupTestState.BranchPolicies[$stage]
            }
            return ''
        }
        if ($text -match '^api --method POST repos/owner/app/environments/(prod|dev)/deployment-branch-policies') {
            $stage = $Matches[1]
            $name = $Arguments | Where-Object { $_ -like 'name=*' }
            $global:ShellSetupTestState.BranchPolicies[$stage] = $name.Substring(5)
            return '{}'
        }
        if ($text -like 'secret list*') {
            return (($global:ShellSetupTestState.Secrets.Keys |
                Where-Object { $_.StartsWith('dev/') } | ForEach-Object { $_.Substring(4) }) -join "`n")
        }
        if ($Arguments[0] -in @('variable', 'secret')) {
            Assert-True ($Arguments[[array]::IndexOf($Arguments, '--repo') + 1] -eq $global:ShellSetupTestState.Repository) 'GitHub settings targeted the template.'
            $stage = $Arguments[[array]::IndexOf($Arguments, '--env') + 1]
            $key = "$stage/$($Arguments[2])"
            if ($Arguments[0] -eq 'variable') {
                $global:ShellSetupTestState.Variables[$key] = $Arguments[[array]::IndexOf($Arguments, '--body') + 1]
            } else {
                $global:ShellSetupTestState.Secrets[$key] = $InputText.Trim()
            }
            return
        }
        if ($text -eq 'api repos/owner/app/git/ref/heads/dev') {
            if (-not $global:ShellSetupTestState.DevBranch) { Set-Variable LASTEXITCODE 1 -Scope Global; return 'HTTP 404' }
            return '{}'
        }
        if ($text -eq 'api repos/owner/app/git/ref/heads/main') {
            return (@{ object = @{ sha = $global:ShellSetupTestState.Remote.main } } | ConvertTo-Json -Compress)
        }
        if ($text -like 'api --method POST repos/owner/app/git/refs*') {
            $global:ShellSetupTestState.DevBranch = $true
            $global:ShellSetupTestState.Remote.dev = ($Arguments[-1] -split '=', 2)[1]
            if (-not $global:ShellSetupTestState.SkipCi) { throw 'Dev was created from a commit without a CI-skip marker.' }
            return '{}'
        }
        throw "Unexpected GitHub command: $text"
    }
    function aws {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        $text = $Arguments -join ' '
        $global:ShellSetupTestState.Calls.Add("aws $text")
        switch ("$($Arguments[0]) $($Arguments[1])") {
            'cloudformation describe-stacks' {
                if ($global:ShellSetupTestState.PreflightReadDenied) { Set-Variable LASTEXITCODE 254 -Scope Global; return '(AccessDenied) Cannot inspect stack' }
                $app = ($global:ShellSetupTestState.Repository -split '/')[-1]
                $id = "arn:aws:cloudformation:us-east-2:123456789012:stack/$app-prod/old"
                if ($global:ShellSetupTestState.PreflightStack -and $Arguments[3] -in @("$app-prod", $id)) {
                    return (@{ Stacks = @(@{ StackId = $id; StackName = "$app-prod"; StackStatus = 'CREATE_COMPLETE'
                        Parameters = @(@{ ParameterKey = 'AppName'; ParameterValue = $app }, @{ ParameterKey = 'Stage'; ParameterValue = 'prod' }) }) } | ConvertTo-Json -Depth 10)
                }
                Set-Variable LASTEXITCODE 1 -Scope Global; return '(ValidationError) Stack does not exist'
            }
            'cloudformation list-stack-resources' { return '{"StackResourceSummaries":[]}' }
            'dynamodb describe-table' { Set-Variable LASTEXITCODE 1 -Scope Global; return '(ResourceNotFoundException)' }
            'ecr describe-repositories' { Set-Variable LASTEXITCODE 1 -Scope Global; return '(RepositoryNotFoundException)' }
            'secretsmanager describe-secret' { Set-Variable LASTEXITCODE 1 -Scope Global; return '(ResourceNotFoundException)' }
            'lambda get-function' { Set-Variable LASTEXITCODE 1 -Scope Global; return '(ResourceNotFoundException)' }
            'logs describe-log-groups' { return '{"logGroups":[]}' }
            'cloudwatch describe-alarms' { return '{"MetricAlarms":[],"CompositeAlarms":[]}' }
            'iam list-roles' { return '{"Roles":[]}' }
            'cognito-idp list-user-pools' { return '{"UserPools":[]}' }
            'cognito-idp describe-user-pool-domain' { return '{"DomainDescription":{}}' }
            'apigatewayv2 get-apis' { return '{"Items":[]}' }
            'sns list-topics' { return '{"Topics":[]}' }
            's3api list-buckets' { return '{"Buckets":[]}' }
            's3api head-bucket' { Set-Variable LASTEXITCODE 1 -Scope Global; return '(404) Not found' }
            'sts get-caller-identity' {
                if ($global:ShellSetupTestState.MissingProfile) {
                    Set-Variable LASTEXITCODE 253 -Scope Global
                    return "aws: [ERROR]: The config profile ($($Arguments[5])) could not be found"
                }
                if ($global:ShellSetupTestState.ExpiredIdentity) { Set-Variable LASTEXITCODE 1 -Scope Global; return 'expired credentials' }
                return "{`"Account`":`"$($global:ShellSetupTestState.Account)`",`"Arn`":`"arn:aws:iam::$($global:ShellSetupTestState.Account):user/setup`"}"
            }
            'configure get' {
                if ($global:ShellSetupTestState.MissingProfile) {
                    Set-Variable LASTEXITCODE 253 -Scope Global
                    return "aws: [ERROR]: The config profile ($($Arguments[-1])) could not be found"
                }
                if ($global:ShellSetupTestState.SsoMode -eq 'existing-sso' -and $Arguments[2] -eq 'sso_session') { return 'organization' }
                Set-Variable LASTEXITCODE 1 -Scope Global
                return ''
            }
            'configure list-profiles' {
                if ($global:ShellSetupTestState.FailProfileInspection) {
                    Set-Variable LASTEXITCODE 253 -Scope Global
                    return 'Unable to parse config file'
                }
                if ($global:ShellSetupTestState.MissingProfile) { return '' }
                return "default`ntest-profile"
            }
            'configure sso' { $global:ShellSetupTestState.MissingProfile = $false; Set-Variable LASTEXITCODE 0 -Scope Global; return }
            'sso login' { $global:ShellSetupTestState.ExpiredIdentity = $false; Set-Variable LASTEXITCODE 0 -Scope Global; return }
            'login --profile' { $global:ShellSetupTestState.MissingProfile = $false; $global:ShellSetupTestState.ExpiredIdentity = $false; Set-Variable LASTEXITCODE 0 -Scope Global; return }
            'iam list-open-id-connect-providers' {
                $list = if ($global:ShellSetupTestState.Provider) { @(@{ Arn = 'arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com' }) } else { @() }
                return (@{ OpenIDConnectProviderList = @($list) } | ConvertTo-Json -Depth 5 -Compress)
            }
            'iam create-open-id-connect-provider' { $global:ShellSetupTestState.Provider = $true; return '{}' }
            'iam get-open-id-connect-provider' { return '{"ClientIDList":["sts.amazonaws.com"]}' }
            'iam get-role' {
                if ($Arguments[3] -eq $global:ShellSetupTestState.ForeignRoleName) {
                    return '{"Role":{"Tags":[]}}'
                }
                if (-not $global:ShellSetupTestState.Role) { Set-Variable LASTEXITCODE 1 -Scope Global; return '(NoSuchEntity)' }
                return (@{ Role = @{ Tags = @(@{ Key = 'GitHubRepository'; Value = $global:ShellSetupTestState.Repository }) } } | ConvertTo-Json -Depth 5 -Compress)
            }
            'iam create-role' { $global:ShellSetupTestState.Role = $true; $global:ShellSetupTestState.RoleCreates++; return '{}' }
            'iam update-assume-role-policy' { return '{}' }
            'iam put-role-policy' { return '{}' }
            default { throw "Unexpected AWS command: $text" }
        }
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, [switch]$SkipHttpErrorCheck, $StatusCodeVariable, $ContentType, $Body, $TimeoutSec)
        if ($Uri -eq 'https://abc.execute-api.us-east-2.amazonaws.com/health') {
            Assert-True (-not $Headers) 'Bypass credentials must not be sent to the AWS API.'
            return @{ status = 'ok' }
        }
        $global:ShellSetupTestState.Calls.Add("vercel $Method $Uri")
        Set-Variable $StatusCodeVariable 200 -Scope 1
        $path = ([uri]$Uri).AbsolutePath
        if ($path -eq '/v2/user') {
            if ($global:ShellSetupTestState.VercelDeny) { Set-Variable $StatusCodeVariable 403 -Scope 1; return @{} }
            return @{ user = @{ id = 'user_test' } }
        }
        if ($path -eq '/v2/teams') {
            return @{ teams = @(@{ id = 'team_test'; name = 'Test team' }); pagination = @{} }
        }
        if ($path -eq '/v9/projects') { return @{ projects = @($global:ShellSetupTestState.Projects.Values); pagination = @{} } }
        if ($path -match '^/v1/projects/([^/]+)/unpause$' -and $Method -eq 'POST') {
            if ($global:ShellSetupTestState.DenyUnpause) { Set-Variable $StatusCodeVariable 403 -Scope 1; return @{} }
            $found = @($global:ShellSetupTestState.Projects.Values | Where-Object id -EQ $Matches[1])
            Assert-True ($found.Count -eq 1) 'Unpause targeted another project.'
            $found[0].paused = $false
            $global:ShellSetupTestState.Unpauses++
            return @{}
        }
        if ($path -match '^/v1/projects/([^/]+)/protection-bypass$' -and $Method -eq 'PATCH') {
            $secret = ($Body | ConvertFrom-Json -AsHashtable).generate.secret
            Assert-True ($secret -cmatch '^[A-F0-9]{32}$') 'The bypass must be a new 32-character secret.'
            $global:ShellSetupTestState.GeneratedBypasses += $secret
            return @{ protectionBypass = @{} }
        }
        if ($path -match '^/v9/projects/([^/]+)$') {
            $key = $Matches[1]
            $found = @($global:ShellSetupTestState.Projects.Values | Where-Object { $_.name -eq $key -or $_.id -eq $key })
            if ($found.Count -eq 0) {
                Set-Variable $StatusCodeVariable 404 -Scope 1
                return @{}
            }
            if ($Method -eq 'PATCH') {
                $found[0].ssoProtection = ($Body | ConvertFrom-Json -AsHashtable).ssoProtection
            }
            return $found[0]
        }
        if ($path -eq '/v11/projects' -and $Method -eq 'POST') {
            $data = $Body | ConvertFrom-Json
            $project = @{
                id = "prj_$($data.name)"; accountId = 'team_test'; name = $data.name
                ssoProtection = @{ deploymentType = $data.ssoProtection.deploymentType }; targets = @{}
            }
            $global:ShellSetupTestState.Projects[$data.name] = $project
            return $project
        }
        if ($path -match '^/v9/projects/([^/]+)/domains$') {
            $items = if ($global:ShellSetupTestState.Domains.ContainsKey($Matches[1])) { @($global:ShellSetupTestState.Domains[$Matches[1]].Values) } else { @() }
            return @{ domains = @($items) }
        }
        if ($path -match '^/v10/projects/([^/]+)/domains$' -and $Method -eq 'POST') {
            $id = $Matches[1]
            $data = $Body | ConvertFrom-Json
            $domain = @{ name = $data.name; gitBranch = $data.gitBranch; verified = $true }
            if (-not $global:ShellSetupTestState.Domains.ContainsKey($id)) { $global:ShellSetupTestState.Domains[$id] = @{} }
            $global:ShellSetupTestState.Domains[$id][$domain.name] = $domain
            return $domain
        }
        if ($path -match '^/v9/projects/([^/]+)/domains/([^/]+)$' -and $Method -eq 'PATCH') {
            $domain = $global:ShellSetupTestState.Domains[$Matches[1]][$Matches[2]]
            $domain.gitBranch = ($Body | ConvertFrom-Json).gitBranch
            return $domain
        }
        if ($path -eq '/v13/deployments/deployment-123.vercel.app') {
            $target = if ($global:ShellSetupTestState.ReturnedTarget -eq 'auto') {
                $global:ShellSetupTestState.ActualTarget
            } else { $global:ShellSetupTestState.ReturnedTarget }
            $projectId = if ($global:ShellSetupTestState.ReturnedProjectId) {
                $global:ShellSetupTestState.ReturnedProjectId
            } else { $env:VERCEL_PROJECT_ID }
            return @{ projectId = $projectId; readyState = 'READY'; target = $target }
        }
        throw "Unexpected Vercel call: $Method $Uri"
    }
    function npm {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        if (($Arguments -join ' ') -ne 'run build') { throw 'Unexpected npm command.' }
        $dist = Join-Path $global:ShellSetupTestState.Fixture 'website/dist'
        $null = New-Item -ItemType Directory -Path $dist -Force
        Set-Content (Join-Path $dist 'index.html') '<div id="app"></div>'
        Set-Content (Join-Path $dist 'app.js') "const api = '$env:VUE_APP_API_BASE'"
    }
    function npx {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        if ($Arguments -contains 'alias') {
            Assert-True ($global:ShellSetupTestState.ActualTarget -ne 'production') 'Production must never be assigned the Preview alias.'
            Assert-True ($Arguments -contains 'test-shell-456-dev.vercel.app') 'Wrong Preview alias.'
            $global:ShellSetupTestState.AliasCalls.Add($Arguments -join ' ')
            return 'Alias assigned'
        }
        Assert-True ($Arguments -contains '--prebuilt') 'Publisher did not use prebuilt output.'
        $global:ShellSetupTestState.Uploads++
        if ($Arguments -contains '--prod') {
            $global:ShellSetupTestState.ActualTarget = 'production'
            Assert-True ($Arguments -contains 'githubCommitRef=main') 'Production metadata must refer to main.'
        } else {
            $global:ShellSetupTestState.ActualTarget = $null
            Assert-True ($Arguments -contains 'preview') 'Dev must explicitly target Preview.'
            Assert-True ($Arguments -contains 'githubCommitRef=dev') 'Preview metadata must refer to dev.'
        }
        $global:ShellSetupTestState.UploadPath = (Get-Location).Path
        $outputConfig = Get-Content '.vercel/output/config.json' -Raw | ConvertFrom-Json
        Assert-True ($outputConfig.routes[0].headers.'Content-Security-Policy'.Contains('https://abc.execute-api.us-east-2.amazonaws.com')) 'Uploaded CSP has the wrong API.'
        $files = @(Get-ChildItem -File -Recurse -Force)
        Assert-True ($files.Count -eq 4) 'Only the manifest, route config, index and JS should be staged.'
        foreach ($file in $files) {
            Assert-True (-not (Get-Content $file.FullName -Raw).Contains($env:VERCEL_TOKEN)) 'Vercel token leaked into staged files.'
            if ($env:VERCEL_AUTOMATION_BYPASS_SECRET) {
                Assert-True (-not (Get-Content $file.FullName -Raw).Contains($env:VERCEL_AUTOMATION_BYPASS_SECRET)) 'Bypass secret leaked into staged files.'
            }
        }
        if ($global:ShellSetupTestState.FailDeploy) { Set-Variable LASTEXITCODE 1 -Scope Global; return 'mock upload failure' }
        return 'https://deployment-123.vercel.app'
    }
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $TimeoutSec, $MaximumRedirection)
        if ($Method -eq 'Options') {
            Assert-True (-not $Headers.ContainsKey('x-vercel-protection-bypass')) 'Bypass secret leaked to AWS CORS request.'
            return @{ Headers = @{ 'Access-Control-Allow-Origin' = @($Headers.Origin) } }
        }
        Assert-True ($MaximumRedirection -eq 0) 'Do not forward a protection-bypass header through redirects.'
        if ($Uri -eq 'https://test-shell-456-dev.vercel.app') {
            Assert-True ($Headers['x-vercel-protection-bypass'] -eq 'test-bypass-not-a-real-credential') 'Protected Preview check lacks its bypass header.'
        } else {
            Assert-True (-not $Headers.ContainsKey('x-vercel-protection-bypass')) 'Production checks must not use the Preview bypass secret.'
        }
        return @{
            Content = '<div id="app"></div>'
            Headers = @{ 'Content-Security-Policy' = @("default-src 'self'; connect-src 'self' https://abc.execute-api.us-east-2.amazonaws.com https://cognito-idp.us-east-2.amazonaws.com;") }
        }
    }
    Test-Case 'Wizard configures one project with Production and protected Preview' {
        & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null
        Assert-True ($script:mock.Projects.Count -eq 1) 'Expected exactly one shared Vercel project.'
        Assert-True ($script:mock.Environments.Count -eq 2) 'Expected two GitHub environments.'
        Assert-True ($script:mock.Variables['prod/APP_NAME'] -eq 'test-shell') 'App name was not configured.'
        Assert-True ($script:mock.Variables['dev/WEBSITE_URL'] -eq 'https://test-shell-456-dev.vercel.app') 'Wrong dev website URL.'
        Assert-True ($script:mock.Variables['prod/VERCEL_PROJECT_ID'] -eq $script:mock.Variables['dev/VERCEL_PROJECT_ID']) 'Both stages must use the same project.'
        Assert-True ($script:mock.Domains['prj_test-shell-456']['test-shell-456-dev.vercel.app'].gitBranch -eq 'dev') 'Preview alias must not be a production domain.'
        Assert-True (-not $script:mock.Domains['prj_test-shell-456']['test-shell-456.vercel.app'].gitBranch) 'Production domain must not be assigned to dev.'
        Assert-True ($script:mock.Projects['test-shell-456'].ssoProtection.deploymentType -eq 'prod_deployment_urls_and_all_previews') 'Preview protection was not enabled.'
        Assert-True ($script:mock.Secrets['prod/VERCEL_TOKEN'] -eq $env:VERCEL_TOKEN) 'Token was not transferred over stdin.'
        Assert-True ($script:mock.BranchPolicies['prod'] -eq 'main' -and $script:mock.BranchPolicies['dev'] -eq 'dev') 'Branch restrictions were not configured.'
        $saved = Get-Content (Join-Path $fixture '.setup/state.json') -Raw
        $installation = $saved | ConvertFrom-Json
        Assert-True ($installation.Repository -eq 'owner/test-shell' -and $installation.TemplateRepository -eq 'owner/shell') 'Setup did not create the repository matching the requested application name.'
        Assert-True (-not $saved.Contains($env:VERCEL_TOKEN)) 'Token leaked into local state.'
        Assert-True (-not $saved.Contains($env:VERCEL_AUTOMATION_BYPASS_SECRET)) 'Bypass secret leaked into local state.'
        Assert-True ([bool]$script:mock.Secrets['dev/VERCEL_AUTOMATION_BYPASS_SECRET']) 'Missing dev automation secret.'
        Assert-True ($script:mock.Secrets['dev/VERCEL_AUTOMATION_BYPASS_SECRET'] -ne $env:VERCEL_AUTOMATION_BYPASS_SECRET) 'New application reused another project bypass.'
        Assert-True (-not $script:mock.Secrets.ContainsKey('prod/VERCEL_AUTOMATION_BYPASS_SECRET')) 'Preview bypass must be scoped to dev.'
        $pushes = @($script:mock.Calls | Where-Object { $_ -like "git * push https://github.com/$($script:mock.Repository).git *" })
        Assert-True ($pushes.Count -eq 1 -and $pushes[0].EndsWith('HEAD:refs/heads/main')) 'Wizard did not seed only main before explicit deployments.'
        $create = $script:mock.Calls.IndexOf('gh repo create owner/test-shell --private')
        $preflight = @($script:mock.Calls | Select-Object -First $create | Where-Object { $_ -like 'aws cloudformation describe-stacks*' })
        Assert-True ($preflight.Count -eq 2) 'Setup did not inspect both AWS stacks before creating the repository.'
        $runs = @($script:mock.Runs.main) + @($script:mock.Runs.dev)
        Assert-True ($runs.Count -eq 2 -and @($runs | Where-Object event -NE 'workflow_dispatch').Count -eq 0) 'Initialization pushes triggered CI instead of explicit setup deployments.'
        $mainDispatch = $script:mock.Calls.IndexOf('gh workflow run ci-cd.yml --repo owner/test-shell --ref main')
        $devDispatch = $script:mock.Calls.IndexOf('gh workflow run ci-cd.yml --repo owner/test-shell --ref dev')
        Assert-True ($mainDispatch -ge 0 -and $devDispatch -gt $mainDispatch) 'Missing setup deployments.'
        Assert-True (@($script:mock.Calls | Select-Object -Skip ($mainDispatch + 1) -First ($devDispatch - $mainDispatch - 1) |
            Where-Object { $_ -like 'gh run view *' }).Count -eq 0) 'Setup waited for main before dispatching dev.'
    }
    Test-Case 'AWS collisions and inventory errors prevent repository creation and linking' {
        $script:mock.Projects.Clear()
        foreach ($mode in @('cancel', 'denied')) {
            $script:mock.RepoExists = $false; $script:mock.Linked = $false
            $script:mock.PreflightStack = $mode -eq 'cancel'
            $script:mock.PreflightReadDenied = $mode -eq 'denied'
            $before = $script:mock.Calls.Count
            $error = if ($mode -eq 'cancel') { 'Choose another application name' } else { 'Cannot inspect stack' }
            try { Assert-Throws { & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null } $error }
            finally { $script:mock.PreflightStack = $false; $script:mock.PreflightReadDenied = $false }
            $calls = @($script:mock.Calls | Select-Object -Skip $before)
            Assert-True (@($calls | Where-Object { $_ -match '^gh repo create|^git remote set-url|^aws iam (create|update|put)|^vercel (POST|PATCH|DELETE)' }).Count -eq 0) 'Failed preflight created or configured the application.'
        }
        $script:mock.RepoExists = $true; $script:mock.Linked = $true
    }
    Test-Case 'Failed Production fails setup after both initial pipelines were started' {
        $before = $script:mock.Calls.Count
        $script:mock.FailProduction = $true
        try { Assert-Throws { Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null } 'main deployment failed' }
        finally { $script:mock.FailProduction = $false }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like 'gh workflow run*--ref dev' }).Count -eq 1) 'Dev was not launched independently of main.'
    }
    Test-Case 'A green run with skipped frontend cannot complete setup' {
        $script:mock.SkipFrontend = $true
        try { Assert-Throws { Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null } 'did not succeed' }
        finally { $script:mock.SkipFrontend = $false }
    }
    Test-Case 'A green run with skipped live verification cannot complete setup' {
        foreach ($field in @('SkipLiveJob', 'SkipLiveStep')) {
            $script:mock[$field] = $true
            try { Assert-Throws { Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null } 'did not succeed' }
            finally { $script:mock[$field] = $false }
        }
    }
    Test-Case 'Divergent branches fail before automatic push or dispatch' {
        $before = $script:mock.Calls.Count
        $script:mock.Divergent = $true
        try { Assert-Throws { Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null } 'Refusing to overwrite' }
        finally { $script:mock.Divergent = $false }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like '* push *' -or $_ -like 'gh workflow run*' }).Count -eq 0) 'Divergent branch caused deployment.'
    }
    Test-Case 'The deployment helper dispatches unchanged branches instead of relying on a no-op push' {
        $before = $script:mock.Calls.Count
        Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like 'gh workflow run*' }).Count -eq 2) 'No-op rerun did not start both deployments.'
        Assert-True (@($calls | Where-Object { $_ -like '* push *' }).Count -eq 0) 'No-op rerun unnecessarily pushed.'
    }
    Test-Case 'CI-skip commit messages still deploy through explicit workflow dispatch' {
        $script:mock.Remote.main = 'b' * 40
        $script:mock.Remote.dev = 'b' * 40
        $script:mock.SkipCi = $true
        $before = $script:mock.Calls.Count
        try { Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null }
        finally { $script:mock.SkipCi = $false }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like "* push https://github.com/$($script:mock.Repository).git *" }).Count -eq 2) 'Skipped-CI commits were not pushed.'
        Assert-True (@($calls | Where-Object { $_ -like 'gh workflow run*' }).Count -eq 2) 'Skipped-CI commits were not deployed.'
    }
    Test-Case 'The deployment helper reuses an active matching run without a duplicate' {
        $script:mock.RunCounter++
        $script:mock.Runs.main += @{
            databaseId = $script:mock.RunCounter; status = 'in_progress'; headSha = $script:mock.Commit; event = 'workflow_dispatch'
        }
        $before = $script:mock.Calls.Count
        Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like 'gh workflow run*--ref main' }).Count -eq 0) 'Recovery queued duplicate Production.'
        $script:mock.Runs.main[-1].status = 'completed'
    }
    Test-Case 'Enabled skip flags stop automatic deployment before pushing' {
        $path = Join-Path $fixture 'config/override.env'
        $before = $script:mock.Calls.Count
        foreach ($flag in @('SKIP_DEPLOY_WEBSITE', 'SKIP_TEST_INFRASTRUCTURE', 'SKIP_TEST_BACKEND',
            'SKIP_TEST_WEBSITE_UNIT', 'SKIP_TEST_WEBSITE_E2E', 'SKIP_TEST_WEBSITE_AUTH', 'SKIP_POST_DEPLOY_TESTS')) {
            Set-Content -LiteralPath $path -Value "$flag=true"
            try { Assert-Throws { Start-SetupDeployments -Repository $script:mock.Repository -Root $fixture 6>$null } 'Remove enabled deployment skip flags' }
            finally { Remove-Item -LiteralPath $path }
        }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like '* push *' -or $_ -like 'gh workflow run*' }).Count -eq 0) 'Skip flags still deployed.'
    }
    Test-Case 'Deployment cannot target a template repository even when explicitly requested' {
        $before = $script:mock.Calls.Count
        Assert-Throws { Start-SetupDeployments -Repository 'owner/shell' -Root $fixture 6>$null } 'Refusing to deploy template'
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like '* push *' -or $_ -like 'gh workflow run*' -or $_ -like 'gh run *' }).Count -eq 0) 'Template deployment made changes or started Actions.'
    }
    Test-Case 'Saved setup state never permits reuse of an existing repository' {
        $before = $script:mock.Calls.Count
        Assert-Throws { & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null } 'already exists'
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like 'aws *' -or $_ -like 'gh workflow run*' -or $_ -like '* push *' }).Count -eq 0) 'Existing repository caused cloud changes or deployment.'
    }
    Test-Case 'Implicit GitHub repository context cannot redirect setup to the template' {
        $savedRepository = $env:GH_REPO
        $env:GH_REPO = 'owner/shell'
        $before = $script:mock.Calls.Count
        try { Assert-Throws { & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null } 'already exists' }
        finally { $env:GH_REPO = $savedRepository }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like 'gh repo view*' }).Count -eq 0) 'Setup trusted implicit repository context.'
        Assert-True (@($calls | Where-Object { $_ -like 'gh workflow run*' }).Count -eq 0) 'Existing repository context started Actions.'
    }
    Test-Case 'AWS sign-in supports existing credentials and missing default or named profiles' {
        foreach ($mode in @('console', 'existing-sso', 'new-sso', 'missing-console', 'missing-sso')) {
            $script:mock.RepoExists = $false
            $script:mock.Linked = $false
            $script:mock.Role = $false
            $script:mock.Projects.Clear()
            $script:mock.Secrets.Clear()
            $script:mock.ExpiredIdentity = $true
            $script:mock.SsoMode = $mode
            $script:mock.MissingProfile = $mode.StartsWith('missing-')
            $profile = if ($mode -eq 'missing-console') { 'default' } else { 'test-profile' }
            Set-Content (Join-Path $fixture 'config/setup.env') "APP_NAME=test-shell`nAWS_REGION=us-east-2`nAWS_PROFILE=$profile"
            $before = $script:mock.Calls.Count
            & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null
            $calls = @($script:mock.Calls | Select-Object -Skip $before)
            if ($mode -in @('console', 'missing-console')) {
                Assert-True (@($calls | Where-Object { $_ -like 'aws login --profile*' }).Count -eq 1) 'Console browser sign-in was not started.'
                Assert-True ($calls -contains "aws login --profile $profile --region us-east-2") 'Browser sign-in used the wrong profile or region.'
            } else {
                Assert-True (@($calls | Where-Object { $_ -like 'aws sso login --profile*' }).Count -eq 1) 'SSO browser sign-in was not started.'
                $configured = @($calls | Where-Object { $_ -like 'aws configure sso --profile*' }).Count
                Assert-True ($configured -eq $(if ($mode -in @('new-sso', 'missing-sso')) { 1 } else { 0 })) 'SSO configuration was not reused/created correctly.'
            }
            if ($mode.StartsWith('missing-')) {
                Assert-True (@($calls | Where-Object { $_ -like 'aws configure get*' }).Count -eq 0) 'Setup inspected SSO keys in a nonexistent profile.'
            }
        }
        $script:mock.SsoMode = 'console'
    }
    Test-Case 'Malformed AWS profile configuration fails before sign-in or repository creation' {
        $script:mock.RepoExists = $false
        $script:mock.Linked = $false
        $script:mock.ExpiredIdentity = $true
        $script:mock.FailProfileInspection = $true
        $before = $script:mock.Calls.Count
        try { Assert-Throws { & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null } 'Unable to parse config file' }
        finally { $script:mock.FailProfileInspection = $false; $script:mock.ExpiredIdentity = $false }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -match '^aws (login|sso login|configure sso)|^gh repo create' }).Count -eq 0) 'Broken configuration started sign-in or created a repository.'
        $script:mock.RepoExists = $true
    }
    Test-Case 'Repository collisions fail before even inspecting another AWS account' {
        $script:mock.Account = '999999999999'
        $before = $script:mock.RoleCreates
        Assert-Throws { & (Join-Path $fixture 'setup-scripts/setup.ps1') 6>$null } 'already exists'
        Assert-True ($script:mock.RoleCreates -eq $before) 'Account mismatch changed infrastructure.'
    }
    $script:mock.Account = '123456789012'
    Test-Case 'Domain configuration repairs a Preview alias assigned to Production' {
        $script:mock.Domains['prj_test-shell-456']['test-shell-456-dev.vercel.app'].gitBranch = $null
        $null = Set-VercelProjectDomain -Token $env:VERCEL_TOKEN -OwnerId 'team_test' -ProjectId 'prj_test-shell-456' -Domain 'test-shell-456-dev.vercel.app' -Branch 'dev'
        Assert-True ($script:mock.Domains['prj_test-shell-456']['test-shell-456-dev.vercel.app'].gitBranch -eq 'dev') 'Dev domain was left as a Production domain.'
    }
    Test-Case 'Vercel authorization failures propagate explicitly' {
        $script:mock.VercelDeny = $true
        Assert-Throws { Invoke-VercelApi -Token $env:VERCEL_TOKEN -Path '/v2/user' } 'HTTP 403'
        $script:mock.VercelDeny = $false
    }
    $savedOrg = $env:VERCEL_ORG_ID
    $savedProject = $env:VERCEL_PROJECT_ID
    try {
        $env:VERCEL_ORG_ID = 'team_test'
        $env:VERCEL_PROJECT_ID = 'prj_test-shell-456'
        Test-Case 'Dev cannot become the first Production deployment' {
            & {
                $waiting = @{ Reads = 0; Sleeps = 0; Ready = $false; Denied = $false }
                function Invoke-VercelApi {
                    param($Token, $OwnerId, $Path)
                    if ($waiting.Denied) { throw 'Vercel read denied' }
                    $waiting.Reads++
                    return @{
                        id = 'prj_test'; accountId = 'team_test'
                        targets = $(if ($waiting.Ready) { @{ production = @{ readyState = 'READY' } } } else { @{} })
                    }
                }
                function Start-Sleep {
                    param($Seconds)
                    $waiting.Sleeps++
                    $waiting.Ready = $true
                }
                Wait-VercelProduction -Token 'fake' -OwnerId team_test -ProjectId prj_test -Attempts 2 6>$null
                Assert-True ($waiting.Reads -eq 2 -and $waiting.Sleeps -eq 1) 'Preview did not wait for Production readiness.'
                $waiting.Ready = $false
                Assert-Throws { Wait-VercelProduction -Token fake -OwnerId team_test -ProjectId prj_test -Attempts 1 6>$null } 'Timed out'
                $waiting.Denied = $true
                Assert-Throws { Wait-VercelProduction -Token fake -OwnerId team_test -ProjectId prj_test 6>$null } 'Vercel read denied'
                $waiting.Denied = $false
                Assert-Throws { Wait-VercelProduction -Token fake -OwnerId team_test -ProjectId prj_other 6>$null } 'ownership'
            }
        }
        Test-Case 'Preview readiness timeout never uploads or changes aliases and cleans staging' {
            & {
                function Start-Sleep { param($Seconds) }
                $uploads = $script:mock.Uploads
                $aliases = $script:mock.AliasCalls.Count
                Assert-Throws {
                    & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage dev -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456-dev.vercel.app' 6>$null
                } 'Timed out'
                Assert-True ($script:mock.Uploads -eq $uploads -and $script:mock.AliasCalls.Count -eq $aliases) 'Timed-out Preview changed a deployment or alias.'
                Assert-True (-not (Get-Location).Path.Contains('shell-vercel-')) 'Timed-out Preview left the working directory in staging.'
            }
        }
        $script:mock.Projects['test-shell-456'].targets.production = @{ readyState = 'READY' }
        Test-Case 'Publishing uploads only configured public assets and cleans staging' {
            & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage prod -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456.vercel.app' 6>$null
            Assert-True (-not (Test-Path $script:mock.UploadPath)) 'Publisher did not clean staging.'
            Assert-True ($script:mock.AliasCalls.Count -eq 0) 'Production must not reassign the dev alias.'
        }
        Test-Case 'Dev targets Preview, assigns only its stable alias and verifies with a bypass header' {
            & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage dev -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456-dev.vercel.app' 6>$null
            Assert-True ($script:mock.AliasCalls.Count -eq 1) 'Preview alias was not assigned.'
        }
        Test-Case 'A mismatched Vercel target never reassigns the Preview alias' {
            $script:mock.ReturnedTarget = 'production'
            Assert-Throws {
                & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage dev -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456-dev.vercel.app' 6>$null
            } 'wrong deployment environment'
            Assert-True ($script:mock.AliasCalls.Count -eq 1) 'Wrong deployment was assigned the dev alias.'
            $script:mock.ReturnedTarget = 'auto'
        }
        Test-Case 'Dev refuses missing bypass credentials before building or uploading' {
            $env:VERCEL_AUTOMATION_BYPASS_SECRET = $null
            $uploads = $script:mock.Uploads
            Assert-Throws {
                & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage dev -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456-dev.vercel.app' 6>$null
            } 'Missing VERCEL_AUTOMATION_BYPASS_SECRET'
            Assert-True ($script:mock.Uploads -eq $uploads) 'Missing bypass credentials did not stop deployment.'
            $env:VERCEL_AUTOMATION_BYPASS_SECRET = 'test-bypass-not-a-real-credential'
        }
        Test-Case 'Dev refuses disabled authentication protection before upload' {
            $project = $script:mock.Projects['test-shell-456']
            $protection = $project.ssoProtection
            $project.ssoProtection = $null
            $uploads = $script:mock.Uploads
            try {
                Assert-Throws {
                    & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage dev -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456-dev.vercel.app' 6>$null
                } 'Preview authentication protection'
                Assert-True ($script:mock.Uploads -eq $uploads) 'Unprotected Preview was uploaded.'
            } finally { $project.ssoProtection = $protection }
        }
        Test-Case 'A deployment from another project never receives the Preview alias' {
            $script:mock.ReturnedProjectId = 'prj_unexpected'
            try {
                Assert-Throws {
                    & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage dev -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456-dev.vercel.app' 6>$null
                } 'configured project'
                Assert-True ($script:mock.AliasCalls.Count -eq 1) 'Another project received the dev alias.'
            } finally { $script:mock.ReturnedProjectId = $null }
        }
        Test-Case 'A ready Production deployment resumes a paused project, without changing unpaused projects' {
            $project = $script:mock.Projects['test-shell-456']
            $project.paused = $true
            & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage prod -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456.vercel.app' 6>$null
            Assert-True (-not $project.paused -and $script:mock.Unpauses -eq 1) 'Production was not resumed.'
            & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage prod -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456.vercel.app' 6>$null
            Assert-True ($script:mock.Unpauses -eq 1) 'An unpaused project was changed.'
            $project.paused = $true
            $script:mock.ReturnedProjectId = 'prj_unexpected'
            Assert-Throws {
                & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage prod -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456.vercel.app' 6>$null
            } 'configured project'
            Assert-True ($project.paused -and $script:mock.Unpauses -eq 1) 'Unverified deployment resumed the project.'
            $script:mock.ReturnedProjectId = $null
            $script:mock.DenyUnpause = $true
            Assert-Throws {
                & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage prod -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456.vercel.app' 6>$null
            } 'HTTP 403'
            Assert-True $project.paused 'Failed unpause was treated as success.'
            $script:mock.DenyUnpause = $false
            $project.paused = $false
        }
        Test-Case 'Failed publishing propagates the error and still cleans staging' {
            $script:mock.FailDeploy = $true
            Assert-Throws {
                & (Join-Path $fixture 'setup-scripts/publish-website.ps1') -Stage prod -ApiUrl 'https://abc.execute-api.us-east-2.amazonaws.com' -WebsiteUrl 'https://test-shell-456.vercel.app' 6>$null
            } 'mock upload failure'
            Assert-True (-not (Test-Path $script:mock.UploadPath)) 'Failed publisher left staging behind.'
        }
    } finally {
        $env:VERCEL_ORG_ID = $savedOrg
        $env:VERCEL_PROJECT_ID = $savedProject
    }
    $source = Join-Path $temp 'shell-copy'
    $null = New-Item -ItemType Directory -Path $source
    Copy-Item (Join-Path $fixture 'setup-scripts'), (Join-Path $fixture 'aws') -Destination $source -Recurse
    $null = New-Item -ItemType Directory -Path (Join-Path $source 'config') -Force
    Set-Content (Join-Path $source 'config/setup.env') "APP_NAME=app`nAWS_REGION=us-east-2`nAWS_PROFILE=test-profile"
    Set-Content (Join-Path $source 'local-file.txt') 'preserve this'
    $script:mock.NewApp = $true
    $script:mock.Linked = $false
    $script:mock.Repository = 'owner/app'
    $script:mock.Role = $false
    Test-Case 'Existing repository names fail before cloud configuration or Git changes' {
        $script:mock.RepoExists = $true
        $before = $script:mock.Calls.Count
        Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'already exists'
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -match 'repo create|aws |vercel |remote set-url' }).Count -eq 0) 'Name collision made changes.'
        $script:mock.RepoExists = $false
    }
    Test-Case 'Repository availability errors fail rather than assuming the name is free' {
        $script:mock.FailRepoCheck = $true
        Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'HTTP 403'
        $script:mock.FailRepoCheck = $false
    }
    Test-Case 'Legacy template state cannot bypass creation of the application repository' {
        $null = New-Item -ItemType Directory -Path (Join-Path $source '.setup') -Force
        Write-JsonFile (Join-Path $source '.setup/state.json') @{
            Repository = 'owner/shell'; AppName = 'app'; AccountId = '123456789012'; Region = 'us-east-2'; Profile = 'test-profile'
        }
        $script:mock.FailLink = $true
        try { Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'mock linking failure' }
        finally { $script:mock.FailLink = $false }
        $pending = Get-Content (Join-Path $source '.setup/state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($pending.Repository -eq 'owner/app' -and $pending.TemplateRepository -eq 'owner/shell') 'Legacy state was reused as the deployment target.'
    }
    Test-Case 'A repository created during failed setup is not reused on retry' {
        Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'already exists'
        $pending = Get-Content (Join-Path $source '.setup/state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($pending.Repository -eq 'owner/app' -and -not $pending.RepositoryLinked) 'Failed setup lost its recorded identity.'
        Assert-True (Test-Path $source) 'Failed linking renamed the folder.'
    }
    Test-Case 'An untagged repository-ID-specific role is still rejected without overwriting it' {
        $script:mock.RepoExists = $false
        $script:mock.ForeignRoleName = 'app-456-github-deploy'
        $before = $script:mock.Calls.Count
        try { Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'Choose another application name' }
        finally { $script:mock.ForeignRoleName = $null; $script:mock.Linked = $false }
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -match '^aws iam (create-role|update-assume-role-policy|put-role-policy)|^gh workflow run ' }).Count -eq 0) 'Setup overwrote or deployed through an unowned role.'
        $seedPushes = @($calls | Where-Object { $_ -match '^git .* push ' })
        Assert-True ($seedPushes.Count -eq 1 -and $seedPushes[0].EndsWith('HEAD:refs/heads/main') -and $script:mock.SkipCi) 'Failed setup pushed something other than CI-skipped initialization.'
    }
    Test-Case 'Vercel collision hard-fails before repository creation without deleting or reusing it' {
        $script:mock.RepoExists = $false
        $script:mock.Projects['app-456'] = @{ name = 'app-456'; id = 'prj_existing'; accountId = 'team_test' }
        $before = $script:mock.Calls.Count
        Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'Choose another application name'
        Assert-True ($script:mock.VercelDeletePrompts -eq 0) 'Setup requested deletion.'
        Assert-True ($script:mock.Projects['app-456'].id -eq 'prj_existing') 'Setup replaced the existing project.'
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -match '^gh repo create|^git remote set-url|^vercel (PATCH|POST|DELETE)|^aws iam (create|update|put|add)-|git .* push ' }).Count -eq 0) 'Collision caused cloud changes or deployment.'
        $script:mock.Linked = $false
        $script:mock.VercelDeletePrompts = 0
    }
    Test-Case 'Fresh setup deploys in place without touching a sibling folder' {
        $script:mock.RepoExists = $false
        $script:mock.Projects.Remove('app-456')
        $script:mock.ForeignRoleName = 'app-github-deploy'
        $script:mock.Role = $false
        $script:mock.Secrets.Remove('dev/VERCEL_AUTOMATION_BYPASS_SECRET')
        $env:VERCEL_AUTOMATION_BYPASS_SECRET = $null
        $before = $script:mock.Calls.Count
        $generatedBefore = $script:mock.GeneratedBypasses.Count
        $destination = Join-Path $temp 'app'
        $null = New-Item -ItemType Directory -Path $destination
        Set-Content (Join-Path $destination 'unrelated.txt') 'leave this alone'
        Set-Location $source
        $output = & (Join-Path $source 'setup-scripts/setup.ps1') 6>&1 | Out-String
        Assert-True (Test-Path $source) 'Setup moved or renamed the current folder.'
        Assert-True ((Get-Location).Path -eq $source) 'PowerShell left the current folder.'
        Assert-True ((Get-Content (Join-Path $source 'local-file.txt')) -eq 'preserve this') 'Local files were lost.'
        Assert-True ((Get-Content (Join-Path $destination 'unrelated.txt')) -eq 'leave this alone') 'Setup changed the sibling folder.'
        Assert-True (-not (Test-Path (Join-Path $destination '.setup'))) 'Setup configured the sibling folder.'
        Assert-True ($output.Contains("Rename this local folder to 'app' afterward")) 'Setup did not ask for a later manual rename.'
        Assert-True ($script:mock.VercelDeletePrompts -eq 0) 'Setup requested deletion.'
        Assert-True ($script:mock.Projects['app-456'].id -ne 'prj_existing') 'Setup reused the old Vercel project.'
        $calls = @($script:mock.Calls | Select-Object -Skip $before)
        Assert-True (@($calls | Where-Object { $_ -like 'aws iam create-role --role-name app-456-github-deploy *' }).Count -eq 1) 'Setup did not create a repository-ID-specific role.'
        Assert-True (@($calls | Where-Object { $_ -match '--role-name app-github-deploy(?: |$)' }).Count -eq 0) 'Setup touched the legacy role.'
        $roleArn = 'arn:aws:iam::123456789012:role/app-456-github-deploy'
        Assert-True ($script:mock.Secrets['prod/AWS_ROLE_ARN'] -eq $roleArn -and $script:mock.Secrets['dev/AWS_ROLE_ARN'] -eq $roleArn) 'GitHub environments did not receive the new role ARN.'
        Assert-True (@($calls | Where-Object { $_ -match '^vercel DELETE|^vercel PATCH .*prj_existing' }).Count -eq 0) 'Setup deleted or modified the existing Vercel project.'
        Assert-True ($script:mock.Calls -contains 'git remote set-url origin https://github.com/owner/app.git') 'Origin was not switched.'
        Assert-True (@($script:mock.Calls | Select-Object -Skip $before | Where-Object { $_ -eq 'gh repo create owner/app --private' }).Count -eq 1) 'Fresh setup did not create exactly one empty application repository.'
        Assert-True (@($script:mock.Calls | Where-Object { $_ -match '^git .*clone' }).Count -eq 0) 'Setup cloned another folder.'
        Assert-True ($script:mock.GeneratedBypasses.Count -eq ($generatedBefore + 1)) 'Expected one project-specific bypass.'
        Assert-True (@($script:mock.Calls | Where-Object { $_ -like '* push https://github.com/owner/shell*' -or
            $_ -like 'gh workflow run*--repo owner/shell*' -or $_ -like 'gh api --method *repos/owner/shell/*' }).Count -eq 0) 'Setup mutated or deployed the template.'
        Assert-Throws { & (Join-Path $source 'setup-scripts/setup.ps1') 6>$null } 'already exists'
        Assert-True ($script:mock.GeneratedBypasses.Count -eq ($generatedBefore + 1)) 'Rejected retry replaced the project bypass.'
    }
    Test-Case 'Real Git initialization preserves cloned history and skips bootstrap CI' {
        $realRoot = Join-Path $temp 'git-test'
        $local = Join-Path $realRoot 'local'
        $remote = Join-Path $realRoot 'remote'
        $null = New-Item -ItemType Directory -Path $local, $remote -Force
        $null = Invoke-Checked $gitExecutable -Arguments @('init', '-b', 'main', $local)
        $null = Invoke-Checked $gitExecutable -Arguments @('init', '-b', 'main', $remote)
        foreach ($repoPath in @($local, $remote)) {
            $null = Invoke-Checked $gitExecutable -Arguments @('-C', $repoPath, 'config', 'user.name', 'Setup Test')
            $null = Invoke-Checked $gitExecutable -Arguments @('-C', $repoPath, 'config', 'user.email', 'setup@example.com')
            Set-Content (Join-Path $repoPath 'app.txt') (Split-Path $repoPath -Leaf)
            $null = Invoke-Checked $gitExecutable -Arguments @('-C', $repoPath, 'add', '.')
            $null = Invoke-Checked $gitExecutable -Arguments @('-C', $repoPath, 'commit', '-m', 'Initial')
        }
        $remoteHead = Invoke-Checked $gitExecutable -Arguments @('-C', $remote, 'rev-parse', 'HEAD')
        $bare = Join-Path $realRoot 'remote.git'
        $null = Invoke-Checked $gitExecutable -Arguments @('init', '--bare', '-b', 'main', $bare)
        $null = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'remote', 'add', 'origin', $remote)
        $null = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'config', 'remote.origin.pushurl', $remote)
        # Run the actual helper with native Git; only the GitHub URL is substituted.
        $null = New-Item -ItemType Directory -Path (Join-Path $local '.setup')
        Set-Content (Join-Path $local '.gitignore') '.setup/'
        $null = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'add', '.gitignore')
        $null = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'commit', '-m', 'Ignore state')
        $sourceHead = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'rev-parse', 'HEAD')
        $helper = Join-Path $scripts 'common.ps1'
        $testScript = {
            param($Helper, $Local, $Bare, $GitExecutable)
            . $Helper
            function Invoke-Checked {
                param($Command, [string[]]$Arguments)
                $arguments = @($Arguments | ForEach-Object {
                    if ($_ -eq 'https://github.com/owner/app.git') { $Bare } else { $_ }
                })
                $result = Invoke-External $GitExecutable -Arguments $arguments
                return $result.Text
            }
            function git {
                param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                & $GitExecutable @Arguments
                $global:LASTEXITCODE = $LASTEXITCODE
            }
            Push-Location $Local
            try { Connect-AppRepository -Root $Local -State @{ Repository = 'owner/app'; AppName = 'app' } }
            finally { Pop-Location }
        }
        & $testScript $helper $local $bare $gitExecutable
        Assert-True ((Get-Content (Join-Path $local 'app.txt')) -eq 'local') 'Initialization changed files.'
        $message = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'log', '-1', '--format=%B')
        Assert-True ($message.Contains('[skip ci]')) 'The real initialization commit does not suppress push-triggered CI.'
        Assert-True ((Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'remote', 'get-url', '--push', 'origin')) -eq $bare) 'Push URL still points to the template.'
        $null = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'merge-base', '--is-ancestor', $sourceHead, 'HEAD')
        Assert-True ((Invoke-Checked $gitExecutable -Arguments @('-C', $remote, 'rev-parse', 'HEAD')) -eq $remoteHead) 'Setup modified the source repository.'
        $null = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'push', 'origin', 'main')
        $localHead = Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'rev-parse', 'HEAD')
        Assert-True ((Invoke-Checked $gitExecutable -Arguments @('--git-dir', $bare, 'rev-parse', 'main')) -eq $localHead) 'Normal push failed.'
        Assert-Throws { & $testScript $helper $local $bare $gitExecutable } 'is not empty'
        Assert-True ((Invoke-Checked $gitExecutable -Arguments @('-C', $local, 'rev-parse', 'HEAD')) -eq $localHead) 'Rejected initialization changed local history.'
        Assert-True ((Invoke-Checked $gitExecutable -Arguments @('--git-dir', $bare, 'rev-parse', 'main')) -eq $localHead) 'Rejected initialization changed the destination.'
    }
    Write-Host "`n$script:passed setup tests passed." -ForegroundColor Green
    & (Join-Path $PSScriptRoot 'test-destroy-project.ps1')
    & (Join-Path $PSScriptRoot 'test-smoke-tests.ps1')
} finally {
    Set-Location $originalLocation
    $env:VERCEL_TOKEN = $oldToken
    $env:VERCEL_AUTOMATION_BYPASS_SECRET = $oldBypass
    $env:VUE_APP_COGNITO_ISSUER = $oldIssuer
    $env:VUE_APP_COGNITO_CLIENT_ID = $oldClient
    $env:GITHUB_STEP_SUMMARY = $oldSummary
    Remove-Variable -Name ShellSetupTestState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
