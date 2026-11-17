#Requires -Version 7.2
<#
.SYNOPSIS
Restore the OrderFlow walkthrough variables in a new PowerShell terminal.
.DESCRIPTION
Dot-source from the owning repository root. Reads and validates the retained local
ownership manifest only. Does not authenticate, contact Azure/GitHub, write state,
deploy, reset, resume a pending operation or verify live health.
.PARAMETER Name
Existing environment name used during Up. EnvironmentName is an alias.
.EXAMPLE
. .\scenarios\orderflow\gitops\scripts\Resume-OrderFlowGitOps.ps1 -EnvironmentName demo1
.OUTPUTS
None. Restores walkthrough variables in the caller's scope and writes an information message.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('EnvironmentName')]
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$Name
)

if ($MyInvocation.InvocationName -ne '.') {
    throw 'Dot-source this helper with a leading dot and space so variables survive: . .\scenarios\orderflow\gitops\scripts\Resume-OrderFlowGitOps.ps1 -EnvironmentName <existing-name>'
}

$orderFlowResumeContext = & {
    param($SelectedName, $ScriptDirectory)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path $ScriptDirectory 'OrderFlowGitOps.psm1') -Force
    $root = Get-OrderFlowGitOpsPath 'Root'
    if ((Get-Location).Provider.Name -ne 'FileSystem' -or
        [IO.Path]::GetFullPath((Get-Location).Path) -ine [IO.Path]::GetFullPath($root)) {
        throw 'Run this helper from its owning repository root. Do not copy ownership files between checkouts.'
    }
    $path = Join-Path (Get-OrderFlowGitOpsStateDirectory $SelectedName) 'ownership.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'No retained ownership file in this checkout for that environment. Locate the original owning checkout; do not redeploy or create replacement state.'
    }
    $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
    $subscription = [guid]$saved.subscriptionId
    if ($subscription -eq [guid]::Empty) { throw 'Saved subscription ID is empty.' }
    Assert-OrderFlowGitOpsState $saved $subscription $SelectedName
    Assert-OrderFlowGitOpsRepository $saved.gitHubRepository
    if ($saved.phase -ceq 'removed') { throw 'This generation is removed; there is no deployed demo to resume.' }
    @{
        state = $saved
        statePath = $path
        subscriptionId = $subscription
        environmentName = $SelectedName
        repo = $saved.gitHubRepository
        portal = Get-OrderFlowGitOpsOutput $saved 'prod' 'portalUrl' -Optional
    }
} $Name $PSScriptRoot

if ($orderFlowResumeContext.state.pendingOperation) {
    Write-Warning 'A pending/unknown operation is recorded. Run -Action Status @common to observe it before any further lifecycle action; do not replay it.'
} elseif ($orderFlowResumeContext.state.phase -cne 'provisioned') {
    Write-Warning 'The saved generation is not provisioned. Run -Action Status @common and follow its recovery guidance; do not restart deployment blindly.'
}
if (-not $orderFlowResumeContext.portal) {
    Write-Warning 'No production portal URL is recorded. $portal will be empty; live deployment completion is not established.'
}

$state = $orderFlowResumeContext.state
$statePath = $orderFlowResumeContext.statePath
$subscriptionId = $orderFlowResumeContext.subscriptionId
$environmentName = $orderFlowResumeContext.environmentName
$repo = $orderFlowResumeContext.repo
$portal = $orderFlowResumeContext.portal
$common = @{ SubscriptionId = $subscriptionId; EnvironmentName = $environmentName }
Remove-Variable orderFlowResumeContext
Write-Information 'Restored $state, $statePath, $subscriptionId, $environmentName, $repo, $portal and $common from local ownership. No live health, credentials, OIDC trust or readiness was checked. Continue at the first unfinished step; do not rerun Up.' -InformationAction Continue
