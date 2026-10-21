#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\Azure.Common.psm1') -Force
$script:checks = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

Assert-RetailEnvironmentName checkout01
foreach ($name in '../demo01', 'demo/01', 'Demo01', 'x', 'demo01;exit', 'demo01-test') {
    $rejected = $false
    try { Assert-RetailEnvironmentName $name } catch { $rejected = $true }
    Assert-Test $rejected "Unsafe environment name accepted: $name"
}
$value = "a'b`"`$literal"
$payload = ConvertTo-RetailGuestPayload @{ value = $value }
$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
Assert-Test ($decoded.value -ceq $value) 'Guest payload must preserve data without shell interpretation.'

$tenant = [guid]'11111111-1111-1111-1111-111111111111'
$actor = '22222222-2222-2222-2222-222222222222'
$claims = @{ tid = $tenant.ToString(); oid = $actor; aud = 'https://management.azure.com/' }
$token = "synthetic.$(ConvertTo-RetailGuestPayload $claims).synthetic"
Assert-Test ((Get-RetailTokenActor -AccessToken $token -TenantId $tenant) -ceq $actor) `
    'Actor metadata must come from the selected tenant and ARM audience.'
foreach ($invalid in @(
    @{ tid = $actor; oid = $actor; aud = 'https://management.azure.com/' },
    @{ tid = $tenant.ToString(); oid = $actor; aud = 'https://example.invalid/' }
)) {
    $token = "synthetic.$(ConvertTo-RetailGuestPayload $invalid).synthetic"
    $rejected = $false
    try { $null = Get-RetailTokenActor -AccessToken $token -TenantId $tenant } catch { $rejected = $true }
    Assert-Test $rejected 'Actor metadata from a different context must be rejected.'
}

$directory = Join-Path ([IO.Path]::GetTempPath()) "retailtx-checkout-common-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$path = Join-Path $directory 'state.json'
try {
    Save-RetailState @{ ownerToken = 'synthetic'; outputs = @{ route = 'primary' } } $path
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test ($state.ownerToken -ceq 'synthetic' -and $state.outputs.route -ceq 'primary') `
        'Saved ownership state must round-trip.'
    Assert-Test (-not (Test-Path -LiteralPath "$path.tmp")) 'Atomic save must not retain its temporary file.'
} finally {
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $directory
}
[pscustomobject]@{ checks = $script:checks; result = 'Passed (no live writes)' }
