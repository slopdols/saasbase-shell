#Requires -Version 7.2
[CmdletBinding()]
param()

# Backend quality gate: Python version + Ruff + Black + mypy strict.
# PowerShell twin of python-check.sh; run from the repository root:
#   pwsh -File scripts/python-check.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'setup-scripts\common.ps1')
Push-Location (Join-Path $root 'backend')
try {
    & python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 13) else 1)'
    if ($LASTEXITCODE -ne 0) { throw 'Python >= 3.13 is required.' }
    Write-Host (Invoke-Checked ruff -Arguments @('check', '.'))
    Write-Host (Invoke-Checked black -Arguments @('--check', '.'))
    Write-Host (Invoke-Checked mypy -Arguments @('api'))
} finally { Pop-Location }
