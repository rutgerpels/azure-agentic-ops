#Requires -Version 7.2
<#
.SYNOPSIS
Remove an owned OrderFlow GitOps environment, including after a terminal restart.
.DESCRIPTION
Loads retained ownership from this checkout, pauses production/test deployment, inventories
cleanup targets once, and reuses Down's ownership-checked ordered deletion.
Rerunning observes pending deletes without resubmitting them, then verifies owned
and provider-managed group absence and removes only recorded, matched monitoring
grants. State and receipts are retained. GitHub environments and credentials stay.
.PARAMETER EnvironmentName
Existing environment name in this checkout's .azure\orderflow-gitops directory.
.PARAMETER ActionsSettled
Presenter attestation that SRE cards/threads, Copilot tasks, deployment approvals
and unknown operations have been reconciled. This does not approve any agent action.
.PARAMETER WaitSeconds
Observation window per deletion stage. On timeout, rerun the same command later.
.EXAMPLE
.\scenarios\orderflow\gitops\scripts\Remove-OrderFlowGitOps.ps1 -EnvironmentName demo1 -ActionsSettled
.EXAMPLE
.\scenarios\orderflow\gitops\scripts\Remove-OrderFlowGitOps.ps1 -EnvironmentName demo1 -WhatIf
.OUTPUTS
Cleanup completion information; errors preserve pending operations and receipts.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$EnvironmentName,
    [switch]$ActionsSettled,
    [ValidateRange(1, 7200)]
    [int]$WaitSeconds = 90
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrderFlowGitOps.psm1') -Force
$directory = Get-OrderFlowGitOpsStateDirectory $EnvironmentName
$path = Join-Path $directory 'ownership.json'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw 'No retained ownership in this checkout. Use the original owning checkout; do not run Up or copy manifests to remove resources.'
}
$saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
$subscription = [guid]$saved.subscriptionId
if ($subscription -eq [guid]::Empty) { throw 'Saved subscription is empty.' }
$state = Read-OrderFlowGitOpsState $path $subscription $EnvironmentName
Assert-OrderFlowGitOpsRepository $state.gitHubRepository
if (-not $WhatIfPreference -and -not $ActionsSettled) {
    throw 'First reconcile SRE requests, Copilot tasks, deployment approvals and unknown operations. Then rerun with -ActionsSettled. No setup, Up, Reset or terminal-variable restoration is needed.'
}
$targets = "$($state.gitHubRepository); subscription $subscription; $($state.resourceGroups.Values -join ', ')"
if (-not $PSCmdlet.ShouldProcess($targets, 'Pause OrderFlow production/test deployment and legacy handoff, capture or reuse private inventory, delete owned Azure resources and exact recorded monitoring grants')) { return }
$lock = Enter-OrderFlowGitOpsLock $directory
try {
    $state = Read-OrderFlowGitOpsState $path $subscription $EnvironmentName
    Invoke-OrderFlowGitOpsCleanup $state $path -TimeoutSeconds $WaitSeconds
} finally { $lock.Dispose() }
