#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$scratch = Join-Path ([IO.Path]::GetTempPath()) "orderflow-resume-$([guid]::NewGuid().ToString('N'))"
$relative = 'scenarios\orderflow\gitops\scripts'
$checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)
    try { & $Operation } catch {
        Assert-Test ($_.Exception.Message -like $Pattern) "Unexpected error: $($_.Exception.Message)"
        return
    }
    throw "Expected error matching $Pattern"
}
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $scratch $relative) -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts') -Force
    foreach ($name in @('Resume-OrderFlowGitOps.ps1', 'OrderFlowGitOps.psm1')) {
        Copy-Item -LiteralPath (Join-Path $root "$relative\$name") -Destination (Join-Path $scratch "$relative\$name")
    }
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Azure.Common.psm1') -Destination (Join-Path $scratch 'scripts')
    Import-Module (Join-Path $scratch "$relative\OrderFlowGitOps.psm1") -Force
    $fixture = New-OrderFlowGitOpsState -SubscriptionId '11111111-1111-1111-1111-111111111111' `
        -EnvironmentName 'unit1' -Location eastus2 -AdminObjectId '22222222-2222-2222-2222-222222222222' `
        -GitHubRepository 'contoso/orderflow'
    $fixture.phase = 'provisioned'
    $fixture.outputs.prod.portalUrl = 'https://synthetic.example'
    $fixturePath = Join-Path $scratch '.azure\orderflow-gitops\unit1\ownership.json'
    $null = New-Item -ItemType Directory -Path (Split-Path $fixturePath) -Force
    $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixturePath
    $helper = Join-Path $scratch "$relative\Resume-OrderFlowGitOps.ps1"
    Push-Location $scratch
    try {
        $original = [IO.File]::ReadAllBytes($fixturePath)
        $common = @{ EnvironmentName = ''; SubscriptionId = '' }
        $statePath = $null
        . $helper -EnvironmentName unit1
        Assert-Test ($common.EnvironmentName -ceq 'unit1') 'Environment was not restored in caller scope.'
        Assert-Test ($common.SubscriptionId -eq [guid]'11111111-1111-1111-1111-111111111111') 'Subscription not restored.'
        Assert-Test ($repo -ceq 'contoso/orderflow' -and $portal -ceq 'https://synthetic.example') 'Repository/portal missing.'
        Assert-Test ($statePath -ceq $fixturePath -and $state.phase -ceq 'provisioned') 'State context missing.'
        Assert-Test ([Convert]::ToBase64String($original) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePath))) 'Ownership was changed.'
        Assert-Throws { & $helper -EnvironmentName unit1 } '*Dot-source this helper*'
        Assert-Throws { . $helper -EnvironmentName absent1 } '*No retained ownership file*'
        Assert-Throws { . $helper -EnvironmentName '..\unit1' } '*does not match*'
        Push-Location (Join-Path $scratch 'scripts')
        try {
            Assert-Throws { . $helper -EnvironmentName unit1 } '*owning repository root*'
        } finally { Pop-Location }

        $fixture.pendingOperation = @{ name = 'deploy-prod' }
        $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixturePath
        $warnings = @()
        . $helper -EnvironmentName unit1 -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Test (($warnings -join ' ') -like '*pending/unknown*') 'Pending operation warning missing.'
        Assert-Test ($state.pendingOperation.name -ceq 'deploy-prod') 'Pending operation was discarded.'

        $fixture.pendingOperation = $null
        $fixture.phase = 'creating'
        $fixture.outputs.prod = @{}
        $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixturePath
        . $helper -EnvironmentName unit1 -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Test (-not $portal -and ($warnings -join ' ') -like '*not provisioned*') 'Incomplete deployment was treated as ready.'

        $fixture.phase = 'removed'
        $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixturePath
        $common = @{ EnvironmentName = 'unchanged' }
        Assert-Throws { . $helper -EnvironmentName unit1 } '*generation is removed*'
        Assert-Test ($common.EnvironmentName -ceq 'unchanged') 'Failed resume partially changed caller context.'
        $fixture.phase = 'provisioned'
        $fixture.resourceGroups.prod = 'foreign-group'
        $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixturePath
        Assert-Throws { . $helper -EnvironmentName unit1 } '*Invalid or mismatched*'
        Set-Content -LiteralPath $fixturePath -Value '{invalid'
        Assert-Throws { . $helper -EnvironmentName unit1 } '*Conversion from JSON failed*'
    } finally { Pop-Location }
    [pscustomobject]@{ checks = $checks; result = 'Passed (local-only resume)' }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
