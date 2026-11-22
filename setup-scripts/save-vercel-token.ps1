#Requires -Version 7.2
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
$secret = Read-Host 'Vercel token (hidden)' -AsSecureString
try {
    $token = [System.Net.NetworkCredential]::new('', $secret).Password
    if (-not $token) { throw 'A Vercel token is required.' }
    $null = Invoke-VercelApi -Token $token -Path '/v2/user'
    Save-SetupVercelToken -Secret $secret
} finally {
    $token = $null
    $secret.Dispose()
}
