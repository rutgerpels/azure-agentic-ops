#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'scripts\checkout\Checkout.Cleanup.ps1')
$subscription = '11111111-1111-1111-1111-111111111111'
$EnvironmentName = 'demo01'
$deploymentName = 'retailtx-checkout-demo01'
$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Reset-Test {
    $script:record = @{ properties = @{ provisioningState = 'Succeeded' } }
    $script:reads = 0
    $script:deletes = 0
    $script:sleeps = 0
    $script:visibleAfterDelete = 0
    $script:readFailure = $false
    $script:deleteFailure = $false
}
function Invoke-TokenRequest {
    param($Resource, $Uri, $Method = 'GET', [switch]$AllowMissing)
    Assert-Test ($Resource -ceq 'https://management.azure.com/' -and $AllowMissing -and
        $Uri -ceq "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Resources/deployments/$deploymentName`?api-version=2022-09-01") `
        'Every request must target the explicit subscription and selected owned record.'
    if ($Method -ceq 'DELETE') {
        $script:deletes++
        if ($script:deleteFailure) { throw 'Synthetic delete permission failure.' }
        return
    }
    Assert-Test ($Method -ceq 'GET') 'Verification must not submit another deletion or mutation.'
    $script:reads++
    if ($script:readFailure -and $script:deletes) { throw 'Synthetic verification authentication failure.' }
    if ($script:deletes -and $script:reads -gt 1 + $script:visibleAfterDelete) { return $null }
    return $script:record
}
function Start-Sleep {
    param([int]$Seconds)
    Assert-Test ($Seconds -eq 5) 'Deletion verification intervals must remain bounded.'
    $script:sleeps++
}
function Assert-Rejected {
    param([string]$Message)
    $failure = $null
    try { Remove-CheckoutDeploymentRecord -Name $deploymentName } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message.Contains($Message)) "Expected '$Message'; got '$failure'."
}

Reset-Test
$script:record = $null
Remove-CheckoutDeploymentRecord -Name $deploymentName
Assert-Test ($script:reads -eq 1 -and $script:deletes -eq 0 -and $script:sleeps -eq 0) 'Already absent records must not be deleted again.'

Reset-Test
Remove-CheckoutDeploymentRecord -Name $deploymentName
Assert-Test ($script:deletes -eq 1 -and $script:reads -eq 2 -and $script:sleeps -eq 0) 'Immediate absence needs one DELETE and no wait.'

Reset-Test
$script:visibleAfterDelete = 3
Remove-CheckoutDeploymentRecord -Name $deploymentName
Assert-Test ($script:deletes -eq 1 -and $script:reads -eq 5 -and $script:sleeps -eq 3) `
    'Delayed visibility must be handled within one cleanup invocation without replaying DELETE.'

Reset-Test
$script:visibleAfterDelete = 20
Assert-Rejected 'remains after 12 verification checks'
Assert-Test ($script:deletes -eq 1 -and $script:reads -eq 13 -and $script:sleeps -eq 11) 'Persistent visibility must exhaust the fixed verification budget.'

Reset-Test
$script:record.properties.provisioningState = 'Running'
Assert-Rejected 'nonterminal'
Assert-Test ($script:deletes -eq 0) 'An active deployment must not be deleted.'

Reset-Test
$script:readFailure = $true
Assert-Rejected 'Synthetic verification authentication failure'
Assert-Test ($script:deletes -eq 1 -and $script:sleeps -eq 0) 'API failures must not be mistaken for absence or polled indefinitely.'

Reset-Test
$script:deleteFailure = $true
Assert-Rejected 'Synthetic delete permission failure'
Assert-Test ($script:deletes -eq 1 -and $script:reads -eq 1 -and $script:sleeps -eq 0) 'Deletion failures must remain surfaced without a success-shaped fallback.'

Reset-Test
$failure = $null
try { Remove-CheckoutDeploymentRecord -Name 'another-environment' } catch { $failure = $_ }
Assert-Test ($null -ne $failure -and $script:reads -eq 0 -and $script:deletes -eq 0) 'Foreign record names must fail before any request.'

[pscustomobject]@{ checks = $script:checks; result = 'Passed (mocked deployment-history cleanup)' }
