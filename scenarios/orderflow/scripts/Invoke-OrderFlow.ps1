#Requires -Version 7.2
<#
.SYNOPSIS
Operate one independently owned OrderFlow rehearsal.
.DESCRIPTION
Up provisions once and stops healthy. Fault is presenter-only and admitted once
per generation. Unknown mutations are not replayed. Observe is read-only except
for persisting receipts. Native SRE approval, not this script, authorizes repair.
.PARAMETER Action
Up, Publish, ConfigureSre, Ready, Fault, Observe, Undo, Verify or Down.
.PARAMETER EnvironmentName
Unique 3-12 character lowercase environment identifier.
.PARAMETER SubscriptionId
Explicit authorized Azure subscription.
.EXAMPLE
.\scenarios\orderflow\scripts\Invoke-OrderFlow.ps1 Ready -EnvironmentName orders01 -SubscriptionId <guid>
.OUTPUTS
Non-secret operation status. Detailed state remains ignored under .azure.
.NOTES
Never remove the state file to bypass an unknown operation or ownership check.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Up', 'Publish', 'ConfigureSre', 'Ready', 'Fault', 'Observe', 'Undo', 'Verify', 'Down')]
    [string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,11}$')][string]$EnvironmentName,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$Location = 'eastus2',
    [string]$PresenterCidr,
    [string]$SshPublicKeyPath,
    [guid]$AdminObjectId,
    [ValidateSet('User', 'ServicePrincipal')][string]$AdminPrincipalType = 'User',
    [guid]$OrderRequestId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scenarioRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $scenarioRoot)
$directory = Join-Path $repositoryRoot ".azure\orderflow\$EnvironmentName"
$statePath = Join-Path $directory 'ownership.json'
Import-Module (Join-Path $PSScriptRoot 'OrderFlow.Common.psm1') -Force
. (Join-Path $PSScriptRoot 'OrderFlow.Sre.ps1')
$group = "rg-orderflow-$EnvironmentName"

$operationLock = $null
try {
if ($Action -eq 'Up') {
    Assert-OrderFlowCidr $PresenterCidr
    if (-not $SshPublicKeyPath -or -not (Test-Path -LiteralPath $SshPublicKeyPath) -or
        $AdminObjectId -eq [guid]::Empty) { throw 'Up requires SshPublicKeyPath and AdminObjectId.' }
    $publicKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()
    if ($publicKey -notmatch '^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Expected an SSH public key, never a private key.' }
    if (Test-Path -LiteralPath $statePath) { throw 'This generation already has state. Use Observe, never replay Up.' }
    if (-not $PSCmdlet.ShouldProcess($group, 'Provision a new OrderFlow environment; no fault')) { return }
    $operationLock = Enter-OrderFlowLock $directory
    if (Test-Path -LiteralPath $statePath) { throw 'State was created by another process. Observe; do not replay Up.' }
    $state = @{
        schemaVersion = 1; scenario = 'orderflow'; subscriptionId = $SubscriptionId.ToString()
        environmentName = $EnvironmentName; resourceGroup = $group; ownerToken = [guid]::NewGuid().ToString()
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outputs = @{}
        sourceHash = Get-OrderFlowSourceHash; phase = 'creating'; pendingOperation = 'group-create'
        fault = $null; repair = $null; observations = @(); configured = $false
        cleanup = @{ assignmentRemoved = $false; roleRemoved = $false }
        deploymentName = "orderflow-$EnvironmentName"
    }
    if (Invoke-OrderFlowAzure $state @('group', 'exists', '--name', $group)) { throw 'Resource group already exists; refusing adoption.' }
    $null = New-Item -ItemType Directory -Force -Path $directory
    Save-OrderFlowState $state $statePath
    $null = Invoke-OrderFlowAzure $state @('group', 'create', '--name', $group, '--location', $Location,
        '--tags', 'scenario=orderflow', 'managedBy=invoke-orderflow', "ownerToken=$($state.ownerToken)")
    $state.pendingOperation = 'deployment'
    Save-OrderFlowState $state $statePath
    $parametersPath = Join-Path $directory 'parameters.json'
    $parameters = @{
        environmentName = @{ value = $EnvironmentName }; ownerToken = @{ value = $state.ownerToken }
        location = @{ value = $Location }; presenterCidr = @{ value = $PresenterCidr }
        sshPublicKey = @{ value = $publicKey }; adminObjectId = @{ value = $AdminObjectId.ToString() }
        adminPrincipalType = @{ value = $AdminPrincipalType }
    }
    @{ parameters = $parameters } | ConvertTo-Json -Depth 10 | Set-Content $parametersPath -Encoding utf8NoBOM
    $null = Invoke-OrderFlowAzure $state @('deployment', 'group', 'create', '--resource-group', $group,
        '--name', $state.deploymentName, '--template-file', (Join-Path $scenarioRoot 'infra\main.bicep'),
        '--parameters', "@$parametersPath") -TimeoutSeconds 1800
    Update-OrderFlowOutputs $state
    $state.pendingOperation = 'publish'
    Save-OrderFlowState $state $statePath
    Publish-OrderFlowPortal $state $directory
    $state.pendingOperation = $null
    $state.phase = 'published'
    Save-OrderFlowState $state $statePath
    Assert-OrderFlowHealthy $state
    Write-Output 'Provisioned and healthy. ConfigureSre and Ready are required before Fault.'
    return
}

if (-not (Test-Path -LiteralPath $statePath)) { throw 'No owned OrderFlow environment. Run Up first.' }
$operationLock = Enter-OrderFlowLock $directory
$state = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
Assert-OrderFlowState $state $SubscriptionId $EnvironmentName
Assert-OrderFlowAction $state $Action

if ($Action -eq 'Observe' -and $state.pendingOperation -ceq 'down') {
    if (-not (Invoke-OrderFlowAzure $state @('group', 'exists', '--name', $group))) {
        Assert-OrderFlowRoleAbsent $state
        $state.phase = 'removed'; $state.pendingOperation = $null
        Save-OrderFlowState $state $statePath
        Write-Output 'Resource group absence verified. Retained ownership receipts; no automatic deletion retry.'
        return
    }
    throw 'Resource group remains present. Inspect provider deletion state; no retry is performed.'
}
Assert-OrderFlowOwner $state
if ($Action -eq 'Observe' -and $state.pendingOperation -ceq 'group-create') {
    $state.phase = 'deployment-failed'
    $state.failure = @{ deploymentState = 'GroupOnly'; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $state.pendingOperation = $null
    Save-OrderFlowState $state $statePath
    Write-Output 'Exact owned group creation observed. Cleanup only; no provisioning was replayed.'
    return
}
if ($Action -eq 'Observe' -and $state.pendingOperation -ceq 'sre-config') {
    Complete-OrderFlowConfigObservation $state $statePath (Get-OrderFlowSreConnection $state)
    Write-Output 'Exact SRE configuration stage observed. Run ConfigureSre to verify/continue; completed stages are not rewritten.'
    return
}
if ($Action -eq 'Observe' -and $state.pendingOperation -in @('remove-role-assignment', 'remove-role-definition')) {
    $assignment = $state.pendingOperation -ceq 'remove-role-assignment'
    $id = if ($assignment) { $state.outputs.repairAssignmentId } else { $state.outputs.repairRoleId }
    $resource = Invoke-OrderFlowRequest $state "https://management.azure.com$id`?api-version=2022-04-01" -AllowMissing
    if ($resource) { throw 'Cleanup target remains present. Inspect the original operation; do not replay deletion.' }
    if ($assignment) { $state.cleanup.assignmentRemoved = $true } else { $state.cleanup.roleRemoved = $true }
    $state.pendingOperation = $null
    Save-OrderFlowState $state $statePath
    Write-Output 'Exact cleanup target absence verified. Run Down to continue the next cleanup stage.'
    return
}
if ($Action -eq 'Observe' -and $state.pendingOperation -ceq 'deployment') {
    Update-OrderFlowOutputs $state
    Save-OrderFlowState $state $statePath
    if ($state.phase -ceq 'deployment-failed') {
        Write-Output 'Terminal failure observed; owned partial inventory recovered for Down only. No provisioning replay.'
    } else { Write-Output 'Deployment completion observed. Publish the portal explicitly.' }
    return
}
switch ($Action) {
    'Publish' {
        if (-not $PSCmdlet.ShouldProcess($group, 'Publish the original portal artifact')) { return }
        $state.pendingOperation = 'publish'; Save-OrderFlowState $state $statePath
        Publish-OrderFlowPortal $state $directory
        $state.pendingOperation = $null; $state.phase = 'published'
        Save-OrderFlowState $state $statePath
        Assert-OrderFlowHealthy $state
    }
    'ConfigureSre' {
        if (-not $PSCmdlet.ShouldProcess($group, 'Configure owned SRE investigation and native approval policy')) { return }
        Set-OrderFlowSre $state $statePath
        $state.configured = $true
        Save-OrderFlowState $state $statePath
    }
    'Ready' {
        if ($state.sourceHash -cne (Get-OrderFlowSourceHash)) { throw 'Source differs from provisioned generation.' }
        Assert-OrderFlowRule (Get-OrderFlowRule $state) (Get-OrderFlowBaseline)
        Assert-OrderFlowSre $state
        Assert-OrderFlowHealthy $state
        Write-Output 'Ready: fresh healthy requests, baseline rule and SRE configuration verified. No fault injected.'
    }
    'Fault' {
        if (-not $PSCmdlet.ShouldProcess($group, 'Deny portal-to-order-API traffic for one rehearsal')) { return }
        if ($state.sourceHash -cne (Get-OrderFlowSourceHash)) { throw 'Source differs from provisioned generation.' }
        Assert-OrderFlowSre $state
        Assert-OrderFlowRule (Get-OrderFlowRule $state) (Get-OrderFlowBaseline)
        Assert-OrderFlowHealthy $state
        $properties = Get-OrderFlowBaseline
        $runId = $state.ownerToken
        $properties.access = 'Deny'
        $properties.description = "OrderFlow presenter fault $runId"
        $state.fault = @{ runId = $runId; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); expected = $properties }
        $state.pendingOperation = 'fault'; Save-OrderFlowState $state $statePath
        $null = Invoke-OrderFlowRequest $state "https://management.azure.com$($state.outputs.ruleId)?api-version=2024-05-01" `
            -Method PUT -Body @{ properties = $properties }
        # A transport success is not proof of propagation; Observe checks rule state and real requests.
        $state.fault.accepted = $true
        Save-OrderFlowState $state $statePath
        Write-Output 'Fault request accepted. Run Observe to verify degradation; watch native SRE for approval.'
    }
    'Observe' {
        if ($state.pendingOperation -in @('group-create', 'publish')) {
            throw 'Operation outcome needs operator inspection of the exact Azure operation. State is retained; no replay.'
        }
        $rule = Get-OrderFlowRule $state
        $probe = Get-OrderFlowProbe $state
        $state.observations = @(@($state.observations) + @($probe) | Select-Object -Last 60)
        if ($state.pendingOperation -ceq 'fault') {
            Assert-OrderFlowRule $rule $state.fault.expected
            if ($probe.statusCode -eq 503) {
                $state.pendingOperation = $null; $state.phase = 'degraded'
                $state.fault.confirmedAtUtc = $probe.observedAtUtc
            }
        } elseif ($state.pendingOperation -ceq 'undo') {
            Assert-OrderFlowRule $rule (Get-OrderFlowBaseline)
            $state.pendingOperation = $null
        }
        Save-OrderFlowState $state $statePath
        $probe | ConvertTo-Json
        if ($state.pendingOperation) { Write-Warning "Outcome remains pending/unknown: $($state.pendingOperation). Do not replay." }
    }
    'Undo' {
        if (-not $state.fault -or $state.repair) { throw 'Undo requires one confirmed fault and no previous undo attempt.' }
        if (-not $PSCmdlet.ShouldProcess($group, 'Presenter emergency restoration, NOT an SRE recovery')) { return }
        Assert-OrderFlowRule (Get-OrderFlowRule $state) $state.fault.expected
        $state.repair = @{ actor = 'presenter'; requestedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
        $state.pendingOperation = 'undo'; Save-OrderFlowState $state $statePath
        $null = Invoke-OrderFlowRequest $state "https://management.azure.com$($state.outputs.ruleId)?api-version=2024-05-01" `
            -Method PUT -Body @{ properties = (Get-OrderFlowBaseline) }
        $state.repair.accepted = $true; Save-OrderFlowState $state $statePath
        Write-Output 'Undo accepted. Observe before Verify. This must not be presented as an SRE repair.'
    }
    'Verify' {
        if (-not $state.fault -or -not $state.fault['confirmedAtUtc'] -or $OrderRequestId -eq [guid]::Empty) {
            throw 'Verify requires a confirmed fault and a new post-repair OrderRequestId from the portal.'
        }
        Assert-OrderFlowRule (Get-OrderFlowRule $state) (Get-OrderFlowBaseline)
        Assert-OrderFlowHealthy $state
        $receipt = Invoke-RestMethod "$($state.outputs.webAppUrl)/api/orders/$OrderRequestId" -TimeoutSec 12 -MaximumRedirection 0
        if ($receipt.request_id -ine $OrderRequestId.ToString() -or
            [DateTimeOffset]$receipt.created_at -le [DateTimeOffset]$state.fault.confirmedAtUtc) {
            throw 'Order receipt is not fresh evidence for this rehearsal.'
        }
        $state.phase = 'customer-recovered'
        $state.recovery = @{
            verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            orderRequestId = $OrderRequestId.ToString()
            attribution = $(if ($state.repair) { 'presenter-undo' } else { 'not-yet-verified' })
        }
        Save-OrderFlowState $state $statePath
        Write-Output 'Customer recovery verified. SRE attribution still requires the native approval/execution record and Azure Activity caller evidence.'
    }
    'Down' {
        if ($state.pendingOperation) {
            throw 'Resolve the pending operation before deletion. Unknown writes are not safe to race with teardown.'
        }
        if ($state.outputs['agentId'] -and $state.phase -cne 'deployment-failed') { Assert-OrderFlowSreSettled $state }
        Assert-OrderFlowInventory $state
        if (-not $PSCmdlet.ShouldProcess($group, 'Delete the verified owned group and retain receipts until absence')) { return }
        # Custom role definitions can outlive RG deletion; remove only our exact recorded grant and definition.
        if ($state.outputs['repairRoleId'] -and -not $state.cleanup.assignmentRemoved) {
            Assert-OrderFlowRepairRole $state
            $state.pendingOperation = 'remove-role-assignment'; Save-OrderFlowState $state $statePath
            $null = Invoke-OrderFlowRequest $state "https://management.azure.com$($state.outputs.repairAssignmentId)?api-version=2022-04-01" -Method DELETE
            Write-Output 'Exact repair assignment deletion requested. Observe its absence, then run Down again.'
            return
        }
        if ($state.outputs['repairRoleId'] -and -not $state.cleanup.roleRemoved) {
            Assert-OrderFlowRepairRole $state -DefinitionOnly
            $state.pendingOperation = 'remove-role-definition'; Save-OrderFlowState $state $statePath
            $null = Invoke-OrderFlowRequest $state "https://management.azure.com$($state.outputs.repairRoleId)?api-version=2022-04-01" -Method DELETE
            Write-Output 'Exact repair role deletion requested. Observe its absence, then run Down again.'
            return
        }
        Assert-OrderFlowRoleAbsent $state
        $state.pendingOperation = 'down'; Save-OrderFlowState $state $statePath
        $null = Invoke-OrderFlowAzure $state @('group', 'delete', '--name', $group, '--yes', '--no-wait')
        Write-Output 'Deletion requested once. Run Observe to independently verify absence; retain state on failure.'
    }
}
} finally {
    if ($operationLock) { $operationLock.Dispose() }
}
