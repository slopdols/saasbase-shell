Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-BootstrapCommand {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE). Installation stopped." }
}

function Update-SetupPath {
    $paths = @(
        $env:Path
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
        (Join-Path $env:ProgramFiles 'PowerShell\7')
        (Join-Path $env:ProgramFiles 'Git\cmd')
        (Join-Path $env:ProgramFiles 'GitHub CLI')
        (Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    )
    $env:Path = ($paths | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Get-MissingSetupTools {
    $missing = @()
    foreach ($tool in @('pwsh', 'git', 'gh', 'aws')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            $missing += $tool
            continue
        }
        if ($tool -eq 'pwsh') {
            $version = & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot check PowerShell version.' }
            if ([version]($version | Select-Object -Last 1) -lt [version]'7.2') { $missing += $tool }
        }
        if ($tool -eq 'aws') {
            $version = & aws --version 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw 'Cannot check AWS CLI version.' }
            if ($version -notmatch 'aws-cli/(\d+\.\d+\.\d+)') { throw 'Unrecognized AWS CLI version.' }
            if ([version]$Matches[1] -lt [version]'2.32.0') { $missing += $tool }
        }
    }
    return $missing
}

function Install-WindowsSetupTools {
    Update-SetupPath
    $missing = @(Get-MissingSetupTools)
    if ($missing.Count -eq 0) { return }
    Write-Host "Need to install/update: $($missing -join ', '). Installers may request administrator permission."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing WinGet from Microsoft.'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager
        Update-SetupPath
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'WinGet installation did not make winget available.' }
    }
    $packages = @{ pwsh = 'Microsoft.PowerShell'; git = 'Git.Git'; gh = 'GitHub.cli'; aws = 'Amazon.AWSCLI' }
    foreach ($tool in $missing) {
        Invoke-BootstrapCommand winget @(
            'install', '--id', $packages[$tool], '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
    }
    Update-SetupPath
    $remaining = @(Get-MissingSetupTools)
    if ($remaining.Count -gt 0) { throw "Tools still unavailable or outdated after installation: $($remaining -join ', ')." }
}
