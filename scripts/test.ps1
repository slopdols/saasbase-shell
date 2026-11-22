#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'setup-scripts\common.ps1')
$previousCI = $env:CI
$env:CI = 'true'
Push-Location $root
try {
    $bash = 'bash'
    if ($IsWindows) {
        $git = Get-Command git -CommandType Application | Select-Object -First 1
        $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
        $candidates = @(
            (Join-Path $gitRoot 'bin\bash.exe'),
            (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
        )
        $bash = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $bash) { throw 'Git Bash is required for the local infrastructure suites on Windows.' }
    }
    & (Join-Path $root 'setup-scripts\tests\run-tests.ps1')
    foreach ($script in @('iac/tests/test-deploy-stack.sh', 'setup-scripts/tests/test-deploy-plan.sh', 'setup-scripts/tests/test-install-tools.sh')) {
        Write-Host (Invoke-Checked $bash -Arguments @($script))
    }
    Push-Location (Join-Path $root 'backend')
    try { Write-Host (Invoke-Checked python -Arguments @('-m', 'pytest', '--import-mode=importlib')) }
    finally { Pop-Location }
    Write-Host (Invoke-Checked $bash -Arguments @('scripts/python-check.sh'))
    Push-Location (Join-Path $root 'website')
    try {
        foreach ($script in @('test:unit', 'test:e2e', 'test:e2e:auth', 'build')) {
            Write-Host (Invoke-Checked npm -Arguments @('run', $script))
        }
    } finally { Pop-Location }
    $templates = @((Join-Path $root 'iac\main.yaml')) + @(Get-ChildItem (Join-Path $root 'iac\templates') -Filter '*.yaml' | ForEach-Object FullName)
    Write-Host (Invoke-Checked cfn-lint -Arguments (@('--non-zero-exit-code', 'error', '--template') + $templates))
    Write-Host 'All local suites and build checks passed. Live deployment checks run separately in CI.'
} finally { Pop-Location; $env:CI = $previousCI }
