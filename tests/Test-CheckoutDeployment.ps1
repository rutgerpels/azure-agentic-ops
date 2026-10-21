#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\checkout\Checkout.Deployment.ps1')
$groupName = 'rg-retailtx-checkout-demo01-swedencentral'
$Location = 'swedencentral'
$statePath = 'mock-state-only'
$state = @{
    ownerToken = 'synthetic-owner'
    outputs = @{
        alertRuleName = 'alert-checkout-latency-demo01'
        workspaceId = '/synthetic/workspace'
        actionGroupId = '/synthetic/actiongroup'
    }
}
$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Reset-Test {
    $script:attempts = 0
    $script:inspections = 0
    $script:sleeps = 0
    $script:failures = 0
    $script:timeout = $false
    $script:inspectionFailure = $false
    $script:owner = $state.ownerToken
    $script:parentState = 'Failed'
    $script:missingReceipt = $false
    $script:receipts = @()
    $script:operations = @(@{
        properties = @{
            provisioningState = 'Failed'
            targetResource = @{
                resourceType = 'Microsoft.Insights/scheduledQueryRules'
                resourceName = $state.outputs.alertRuleName
            }
            statusMessage = @{ error = @{
                code = 'BadRequest'
                message = 'The workspace could not be found Activity ID: 11111111-1111-1111-1111-111111111111.'
            } }
        }
    })
}
function Invoke-Az {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    switch ($Arguments[0..2] -join ' ') {
        'group show --name' {
            return @{ tags = @{ ownerToken = $script:owner; managedBy = 'invoke-checkoutdemo' } }
        }
        'deployment group create' {
            $name = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
            Assert-Test ($name -cmatch '^checkout-latency-alert-[0-9a-f]{32}$' -and
                $name -ceq $script:savedReceipt -and $name -notin $script:receipts) `
                'Every attempt must persist a unique receipt before submission.'
            $script:receipts += $name
            Assert-Test ($TimeoutSeconds -eq 120 -and
                (Join-Path $repository 'infra\checkout\latency-alert.bicep') -in $Arguments -and
                "workspaceId=$($state.outputs.workspaceId)" -in $Arguments -and
                "actionGroupId=$($state.outputs.actionGroupId)" -in $Arguments) `
                'Only the owned alert template may be retried with a bounded timeout.'
            $script:attempts++
            if ($script:timeout) { throw [TimeoutException]::new('Azure outcome unknown.') }
            if ($script:attempts -le $script:failures) { throw 'CLI payload withheld: synthetic secret must stay hidden.' }
            return @{ properties = @{ provisioningState = 'Succeeded' } }
        }
        'deployment group show' {
            Assert-Test ($TimeoutSeconds -eq 30 -and $script:savedReceipt -in $Arguments) `
                'Parent status must be bounded and belong to this attempt, never an older failed receipt.'
            if ($script:missingReceipt) { throw 'Current deployment receipt not found.' }
            return @{ properties = @{ provisioningState = $script:parentState } }
        }
        'deployment operation group' {
            Assert-Test ($TimeoutSeconds -eq 30 -and $script:savedReceipt -in $Arguments) `
                'Failure inspection must be bounded and scoped to the alert deployment.'
            $script:inspections++
            if ($script:inspectionFailure) { throw 'Cannot read deployment operations.' }
            return $script:operations
        }
        default { throw "Unexpected Azure command: $($Arguments[0..2] -join ' ')" }
    }
}
function Save-RetailState {
    param($State, $Path)
    Assert-Test ($Path -ceq $statePath) 'Deployment admission must retain the owned manifest.'
    $script:savedReceipt = $State.latencyAlertDeploymentName
}
function Start-Sleep {
    param([int]$Seconds)
    Assert-Test ($Seconds -eq 15) 'Propagation retries must have a bounded interval.'
    $script:sleeps++
}
function Assert-Failure {
    param([string]$Message)
    $failure = $null
    try { Initialize-CheckoutLatencyAlert $state } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message.Contains($Message)) `
        "Expected failure containing '$Message'; got '$failure'."
    Assert-Test (-not $failure.Exception.Message.Contains('synthetic secret')) 'Top-level errors must not expose CLI payloads.'
}

Reset-Test
Initialize-CheckoutLatencyAlert $state
Assert-Test ($script:attempts -eq 1 -and $script:inspections -eq 0 -and $script:sleeps -eq 0) 'Immediate success must not wait.'

Reset-Test
$script:failures = 2
Initialize-CheckoutLatencyAlert $state
Assert-Test ($script:attempts -eq 3 -and $script:sleeps -eq 2) 'Propagation must recover within the same invocation.'

Reset-Test
$script:failures = 1
$script:operations[0].properties.statusMessage = $script:operations[0].properties.statusMessage | ConvertTo-Json -Depth 5 -Compress
Initialize-CheckoutLatencyAlert $state
Assert-Test ($script:attempts -eq 2) 'Azure operation statusMessage may be a JSON string.'

foreach ($kind in @('permission', 'query', 'wrong-resource', 'wrong-type', 'multiple', 'empty', 'missing-error', 'nested-error', 'running', 'mixed-running')) {
    Reset-Test
    $script:failures = 6
    switch ($kind) {
        'permission' { $script:operations[0].properties.statusMessage.error.code = 'AuthorizationFailed' }
        'query' { $script:operations[0].properties.statusMessage.error.message = 'Invalid query.' }
        'wrong-resource' { $script:operations[0].properties.targetResource.resourceName = 'another-alert' }
        'wrong-type' { $script:operations[0].properties.targetResource.resourceType = 'Microsoft.Compute/virtualMachines' }
        'multiple' { $script:operations += $script:operations[0] }
        'empty' { $script:operations = @() }
        'missing-error' { $script:operations[0].properties.statusMessage = $null }
        'nested-error' { $script:operations[0].properties.statusMessage.error.details = @(@{ code = 'InvalidQuery' }) }
        'running' { $script:operations[0].properties.provisioningState = 'Running' }
        'mixed-running' { $script:operations += @{ properties = @{ provisioningState = 'Running' } } }
    }
    Assert-Failure 'not a confirmed workspace propagation error'
    Assert-Test ($script:attempts -eq 1 -and $script:sleeps -eq 0) "$kind must not be retried."
}

Reset-Test
$script:failures = 6
Assert-Failure 'remained unavailable after six attempts'
Assert-Test ($script:attempts -eq 6 -and $script:sleeps -eq 5) 'Persistent propagation failures must exhaust the fixed budget.'

Reset-Test
$script:timeout = $true
Assert-Failure 'Azure outcome unknown'
Assert-Test ($script:attempts -eq 1 -and $script:inspections -eq 0 -and $script:sleeps -eq 0) `
    'Unknown Azure outcomes must never be replayed.'

foreach ($expectedParentState in @('Running', 'Accepted', 'Succeeded', 'Canceled')) {
    Reset-Test
    $script:failures = 1
    $script:parentState = $expectedParentState
    Assert-Failure 'outcome is not confirmed Failed'
    Assert-Test ($script:attempts -eq 1 -and $script:inspections -eq 0 -and $script:sleeps -eq 0) `
        'A matching failed child must not override an active or otherwise unconfirmed parent.'
}

Reset-Test
$script:failures = 1
$script:missingReceipt = $true
Assert-Failure 'Current deployment receipt not found'
Assert-Test ($script:attempts -eq 1 -and $script:inspections -eq 0 -and $script:sleeps -eq 0) `
    'Failure before admission must not reuse an earlier matching failed deployment.'

Reset-Test
$script:failures = 1
$script:inspectionFailure = $true
Assert-Failure 'Cannot read deployment operations'
Assert-Test ($script:attempts -eq 1 -and $script:sleeps -eq 0) 'Unavailable diagnostics must fail closed.'

Reset-Test
$script:owner = 'another-owner'
Assert-Failure 'ownership mismatch'
Assert-Test ($script:attempts -eq 0) 'Foreign ownership must fail before any deployment.'

[pscustomobject]@{ checks = $script:checks; result = 'Passed (mocked Azure; no resource changes)' }
