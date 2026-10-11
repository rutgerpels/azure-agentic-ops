#Requires -Version 7.2
# Local ownership, freshness, alert correlation and policy gates; no Azure calls.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\guest\GuestMonitor.ps1')
. (Join-Path $root 'scripts\guest\GuestNativeRead.ps1')
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\Invoke-GuestServiceApproval.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$node = $ast.Find({ param($candidate)
    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $candidate.Name -ceq 'Assert-ApprovalIncidentThread'
}, $true)
. ([scriptblock]::Create($node.Extent.Text))
$lifecycleAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\Invoke-GuestService.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
foreach ($name in @('ConvertFrom-GuestJson', 'Assert-GuestMarker', 'Update-GuestStatus', 'Get-GuestStatus')) {
    $helper = $lifecycleAst.Find({ param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($helper.Extent.Text))
}
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe monitoring input accepted.' }
    $script:checks++
}
$subscription = [guid]::NewGuid().ToString()
$EnvironmentName = 'demo01'
$FoundationEnvironment = 'foundation'
$location = 'swedencentral'
$groupId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-guest-$EnvironmentName-$location"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-$EnvironmentName"
$foundationId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-$FoundationEnvironment-$location"
$script:state = @{
    withMonitoring = $true; withSreExecution = $true; ownerToken = [guid]::NewGuid().ToString()
    vmId = $vmId
    workspaceId = "$foundationId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-$FoundationEnvironment"
    dceId = "$foundationId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-$FoundationEnvironment"
    privateLinkScopeId = "$foundationId/providers/Microsoft.Insights/privateLinkScopes/ampls-retailtx-$FoundationEnvironment"
    workspaceCustomerId = [guid]::NewGuid().ToString()
    currentFault = @{ runId = [guid]::NewGuid().ToString(); canary = $false
        startBeforeUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    agentId = "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName"
    alertId = "$groupId/providers/Microsoft.Insights/scheduledQueryRules/alert-retailtx-guest-$EnvironmentName"
    monitorAccess = @{}
}
Assert-GuestMonitorBinding
$monitorAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\guest\GuestMonitor.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$instructionAssignment = $monitorAst.Find({ param($candidate)
    $candidate -is [Management.Automation.Language.AssignmentStatementAst] -and
    $candidate.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $candidate.Left.VariablePath.UserPath -ceq 'instructions'
}, $true)
if (-not $instructionAssignment) { throw 'Missing investigator instructions.' }
$script:state.agentPrincipalId = [guid]::NewGuid().ToString()
. ([scriptblock]::Create($instructionAssignment.Extent.Text))
foreach ($fragment in @(
    'RunAzCliReadCommands',
    'do not require a connector',
    "az monitor log-analytics query --workspace $($script:state.workspaceCustomerId) --subscription $subscription --timespan PT10M",
    "where _ResourceId =~ '$vmId'",
    "tostring(receipt.ownerToken) == '$($script:state.ownerToken)'",
    'todatetime(receipt.observedAtUtc)',
    'arg_max(observedAt, *)',
    'receipt.marker.runId', 'receipt.marker.canary', 'receipt.marker.deadlineUtc',
    'instanceView.statuses', '--start-time',
    'STOP before proposing repair',
    'STOP for human portal approval'
)) {
    if (-not $instructions.Contains($fragment, [StringComparison]::Ordinal)) {
        throw "Investigator omitted exact read/safety guidance: $fragment"
    }
}
if ($instructions -match 'receipt\.(canary|deadlineUtc|recoveryReason|recoveredBy)\b') {
    throw 'Investigator must use the nested receipt.marker schema.'
}
foreach ($field in @('workspaceId', 'dceId', 'privateLinkScopeId')) {
    $original = $script:state[$field]
    $script:state[$field] = '/subscriptions/foreign/resource'
    Assert-Rejected { Assert-GuestMonitorBinding }
    $script:state[$field] = $original
}
$evidence = @{ vmId = $vmId; workspaceCustomerId = $script:state.workspaceCustomerId
    receipt = @{ schemaVersion = 1; ownerToken = $script:state.ownerToken
        service = 'retailtx-demo-posting-worker'; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        active = $true; healthy = $true; watchdogEnabled = $true; watchdogActive = $true
        bootId = [guid]::NewGuid().ToString()
        marker = @{ runId = $script:state.currentFault.runId; phase = 'recovered' } } }
Assert-GuestTelemetry $evidence -RequireHealthy
$script:state.monitorTransport = 'Public'
Assert-Rejected { Assert-GuestTelemetry $evidence }
$evidence.transport = 'Private'
Assert-Rejected { Assert-GuestTelemetry $evidence }
$evidence.transport = 'Public'
$evidence.queryAddresses = @('20.1.2.3')
$evidence.ingestionAddresses = @('20.1.2.4')
Assert-GuestTelemetry $evidence -RequireHealthy
foreach ($field in @('queryAddresses', 'ingestionAddresses')) {
    $old = $evidence[$field]
    foreach ($addresses in @(@{ value = @() }, @{ value = @('20.1.2.3', '10.89.0.1') },
        @{ value = @('127.0.0.1') }, @{ value = @('169.254.169.254') })) {
        $evidence[$field] = $addresses.value
        Assert-Rejected { Assert-GuestTelemetry $evidence }
    }
    $evidence[$field] = $old
}
$script:state.Remove('monitorTransport')
if ((Get-GuestMonitorTransport) -cne 'Private') { throw 'Legacy state must remain private.' }
$evidence.Remove('transport')
$evidence.Remove('queryAddresses')
$evidence.Remove('ingestionAddresses')
foreach ($change in @(
    @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o') },
    @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o') },
    @{ ownerToken = [guid]::NewGuid().ToString() }, @{ service = 'foreign' },
    @{ active = 'true' }, @{ watchdogActive = $false }
)) {
    $receipt = $evidence.receipt.Clone()
    foreach ($key in $change.Keys) { $evidence.receipt[$key] = $change[$key] }
    Assert-Rejected { Assert-GuestTelemetry $evidence -RequireHealthy }
    $evidence.receipt = $receipt
}
$evidence.receipt.marker.phase = 'fault-active'
Assert-Rejected { Assert-GuestTelemetry $evidence -RequireHealthy }
$evidence.receipt.marker.phase = 'recovered'
$evidence.receipt.marker.runId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-GuestTelemetry $evidence }
$expected = @{}
Add-GuestMonitorInventory $expected
if ($expected.Count -ne 19 -or -not $expected.ContainsKey("$vmId/extensions/AzureMonitorLinuxAgent")) {
    throw 'Monitoring teardown inventory is incomplete.'
}
$script:dnsLink = @{ id = "$groupId/providers/Microsoft.Network/privateDnsZones/privatelink.monitor.azure.com/virtualNetworkLinks/guest"
    tags = @{ ownerToken = $script:state.ownerToken }; registrationEnabled = $false
    virtualNetwork = @{ id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-$EnvironmentName" } }
function Invoke-Azure {
    param([string[]]$Arguments)
    if (($Arguments[0..5] -join ' ') -cne 'network private-dns link vnet show --ids' -or $Arguments[6] -cne $script:dnsLink.id) {
        throw 'Unexpected DNS-link read.'
    }
    return $script:dnsLink
}
Assert-GuestMonitorDnsLink @{ id = $script:dnsLink.id }
$script:dnsLink.registrationEnabled = $true
Assert-Rejected { Assert-GuestMonitorDnsLink @{ id = $script:dnsLink.id } }
$script:dnsLink.registrationEnabled = $false
$script:dnsLink.virtualNetwork.id = "$groupId/providers/Microsoft.Network/virtualNetworks/foreign"
Assert-Rejected { Assert-GuestMonitorDnsLink @{ id = $script:dnsLink.id } }
$script:dnsLink.id = "$groupId/providers/Microsoft.Network/privateDnsZones/privatelink.monitor.azure.com/virtualNetworkLinks/agent"
$script:dnsLink.virtualNetwork.id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName"
Assert-GuestMonitorDnsLink @{ id = $script:dnsLink.id }
$script:dnsLink.tags.ownerToken = 'foreign'
Assert-Rejected { Assert-GuestMonitorDnsLink @{ id = $script:dnsLink.id } }
$peering = @{ name = 'monitor-guest'; remoteVirtualNetwork = @{
    id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-$EnvironmentName" }
    allowVirtualNetworkAccess = $true; allowForwardedTraffic = $false
    allowGatewayTransit = $false; useRemoteGateways = $false }
Assert-GuestMonitorPeering $peering -AgentSide
$peering.allowForwardedTraffic = $true
Assert-Rejected { Assert-GuestMonitorPeering $peering -AgentSide }
$threadId = [guid]::NewGuid()
$alertGuid = [guid]::NewGuid().ToString()
$incident = @{ ownerToken = $script:state.ownerToken; agentId = $script:state.agentId
    runId = $script:state.currentFault.runId; threadId = $threadId.ToString(); monitorCondition = 'Fired'
    sreIncident = @{ id = $alertGuid; threadId = $threadId.ToString(); targetResourceId = $vmId
        alertRuleResourceId = $script:state.alertId
        alertId = "$vmId/providers/Microsoft.AlertsManagement/alerts/$alertGuid" } }
$null = Assert-ApprovalIncidentThread $threadId $script:state $incident
$incident.runId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-ApprovalIncidentThread $threadId $script:state $incident }
$incident.runId = $script:state.currentFault.runId
$incident.sreIncident.threadId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-ApprovalIncidentThread $threadId $script:state $incident }
$incident.sreIncident.threadId = $threadId.ToString()
$incident.sreIncident.targetResourceId = '/foreign'
Assert-Rejected { Assert-ApprovalIncidentThread $threadId $script:state $incident }
# All grant validation must precede any deletion, including forged late entries.
$script:deletes = @()
function Invoke-Azure {
    param([string[]]$Arguments)
    if ($Arguments[0..2] -join ' ' -ceq 'role assignment delete') { $script:deletes += $Arguments; return }
    if ($Arguments[0..2] -join ' ' -ceq 'role assignment list') { return $script:assignments }
    throw 'Unexpected Azure call in local test.'
}
$grantId = [guid]::NewGuid().ToString()
$principal = [guid]::NewGuid().ToString()
$grant = @{ name = $grantId; id = "$($script:state.workspaceId)/providers/Microsoft.Authorization/roleAssignments/$grantId"
    principalId = $principal }
$script:state.monitorAccess.vm = $grant
$script:assignments = @(@{ id = $grant.id; scope = $script:state.workspaceId; principalId = $principal
    roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/73c42c96-874c-492b-b04d-ab87d138a893" })
Assert-GuestMonitorGrant $script:assignments[0] $grant
$script:state.monitorAccess.forged = @{ name = [guid]::NewGuid().ToString(); principalId = $principal; id = '/foreign' }
Assert-Rejected { Remove-GuestMonitorAccess }
if ($script:deletes.Count) { throw 'Cleanup mutated a grant before validating the entire manifest.' }
$script:state.monitorAccess.Remove('forged')
$script:assignments[0].principalId = [guid]::NewGuid().ToString()
Assert-Rejected { Remove-GuestMonitorAccess }
$script:assignments = @()
Remove-GuestMonitorAccess
$script:state.monitorAccess = @{}
Remove-GuestMonitorAccess
$policy = @{ permissions = @{ allow = @()
    ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
    deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
Assert-GuestMonitorPolicy $policy
$policy.permissions.allow = @('RunAzCliWriteCommands')
Assert-Rejected { Assert-GuestMonitorPolicy $policy }
$policy.permissions.allow = @()
$policy.permissions.deny = @()
Assert-Rejected { Assert-GuestMonitorPolicy $policy }
foreach ($operation in @('Monitor', 'Telemetry', 'Connect', 'Arm', 'Incident')) {
    & (Join-Path $root 'scripts\Invoke-GuestService.ps1') $operation -SubscriptionId $subscription -EnvironmentName 'dry01' -WhatIf
}
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
$directory = Join-Path $root ".azure\guest-monitor-tests-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$statePath = Join-Path $directory 'state.json'
$script:state.nativeRead = @{ commandId = [guid]::NewGuid().ToString() }
try {
    $script:queryResult = @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; message = 'HTTP Error 403: Forbidden' }) }
    function Invoke-Azure {
        param([string[]]$Arguments, [int]$TimeoutSeconds)
        if (($Arguments[0..2] -join ' ') -cne 'vm run-command invoke' -or $Arguments[4] -cne $vmId) {
            throw 'Unexpected telemetry diagnostic invocation.'
        }
        return $script:queryResult
    }
    function Invoke-GuestNativeRead {
        param([string]$Kind, [string]$ScriptPath)
        if ($Kind -cne 'Telemetry' -or -not (Test-Path $ScriptPath)) { throw 'Unexpected native diagnostic.' }
        return $script:queryResult
    }
    Assert-Rejected { Get-GuestTelemetry }
    $savedResult = Get-Content -LiteralPath (Join-Path $directory 'guest-monitor-query-result.json') -Raw |
        ConvertFrom-Json -AsHashtable
    if ($savedResult.value[0].message -cne $script:queryResult.value[0].message) {
        throw 'Telemetry failure did not preserve its diagnostic result.'
    }
    $evidence.receipt.marker.runId = $script:state.currentFault.runId
    $script:queryResult.value[0].message = "RETAILTX_TELEMETRY=$($evidence | ConvertTo-Json -Depth 10 -Compress)"
    $receipt = Get-GuestTelemetry
    if ($receipt.receipt.ownerToken -cne $script:state.ownerToken -or
        -not (Test-Path -LiteralPath (Join-Path $directory 'guest-monitor-telemetry.json'))) {
        throw 'Fresh telemetry receipt was not persisted.'
    }
    $script:state.monitorTransport = 'Public'
    $script:state.monitorReadMode = 'Operator'
    $script:state.workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-guest-$EnvironmentName"
    $script:state.dceId = $null
    $script:state.privateLinkScopeId = $null
    $script:state.Remove('nativeRead')
    $script:state.pendingCommand = $null
    $script:state.journal = @()
    $script:state.monitorConfigured = $true
    $evidence.receipt.marker.actor = [guid]::NewGuid().ToString()
    $evidence.receipt.marker.startedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
    $evidence.receipt.marker.deadlineUtc = ([DateTimeOffset]$evidence.receipt.marker.startedAtUtc).AddSeconds(600).ToString('o')
    $evidence.receipt.marker.startBeforeUtc = ([DateTimeOffset]$evidence.receipt.marker.startedAtUtc).AddSeconds(90).UtcDateTime.ToString('o')
    $evidence.receipt.marker.durationSeconds = 600
    $evidence.receipt.marker.canary = $false
    $script:operatorRows = @(@{ receipt = ($evidence.receipt | ConvertTo-Json -Depth 12 -Compress) })
    $script:operatorQueries = 0
    function Invoke-GuestNativeRead { throw 'Operator LAW reads must not send any guest command.' }
    function Invoke-Azure {
        param([string[]]$Arguments, [int]$TimeoutSeconds)
        if (($Arguments[0..2] -join ' ') -ceq 'resource show --ids') {
            return @{ id = $script:state.workspaceId; tags = @{ ownerToken = $script:state.ownerToken }; properties = @{
                customerId = $script:state.workspaceCustomerId; publicNetworkAccessForIngestion = 'Enabled'
                publicNetworkAccessForQuery = 'Enabled'; features = @{ disableLocalAuth = $true }
            } }
        }
        if (($Arguments[0..2] -join ' ') -cne 'monitor log-analytics query' -or
            $Arguments[4] -cne $script:state.workspaceCustomerId -or $TimeoutSeconds -ne 90 -or
            $Arguments[8] -notmatch [regex]::Escape("where _ResourceId =~ '$vmId'") -or
            $Arguments[8] -notmatch [regex]::Escape("tostring(receipt.ownerToken) == '$($script:state.ownerToken)'")) {
            throw 'Unexpected operator query, identity or scope.'
        }
        $script:operatorQueries++
        return $script:operatorRows
    }
    $pending = @{ commandId = [guid]::NewGuid().ToString(); action = 'fault'; outcome = 'unknown'; request = @{
        runId = $evidence.receipt.marker.runId; actor = $evidence.receipt.marker.actor
        startBeforeUtc = ([DateTimeOffset]$evidence.receipt.marker.startBeforeUtc).ToOffset([TimeSpan]::FromHours(2)).ToString('o')
        durationSeconds = 600; canary = $false
    } }
    $pending = $pending | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
    $script:state.pendingCommand = $pending
    $script:state.journal = @($pending)
    $script:state.pendingCommand.request.actor = [guid]::NewGuid().ToString()
    $null = Get-GuestTelemetry
    if (-not $script:state.pendingCommand -or $script:state.phase -cne 'outcome-unknown') {
        throw 'Operator telemetry reconciled an unknown foreign fault actor.'
    }
    $script:state.pendingCommand.request.actor = $evidence.receipt.marker.actor
    $null = Get-GuestTelemetry
    if ($script:state.pendingCommand -or $script:state.journal[0].outcome -cne 'readback-confirmed') {
        throw 'Equivalent UTC/offset admission instants did not reconcile the persisted write intent without replay.'
    }
    foreach ($timestamp in @(
        ([DateTimeOffset]$evidence.receipt.marker.startBeforeUtc).AddTicks(1).ToString('o'),
        ([DateTimeOffset]$evidence.receipt.marker.startBeforeUtc).AddSeconds(1).ToString('o'),
        'not-a-timestamp', $null
    )) {
        $pending.request.startBeforeUtc = $timestamp
        $script:state.pendingCommand = $pending
        try { $null = Get-GuestTelemetry } catch {
            if ($timestamp -and $timestamp -cne 'not-a-timestamp') { throw }
        }
        if (-not $script:state.pendingCommand) { throw 'Different/missing/invalid admission instant cleared pending intent.' }
    }
    $pending.request.startBeforeUtc = [DateTimeOffset]$evidence.receipt.marker.startBeforeUtc
    $script:state.pendingCommand = $pending
    $null = Get-GuestTelemetry
    if ($script:state.pendingCommand) { throw 'Typed offset admission did not reconcile the same instant.' }
    $operatorEvidence = Get-GuestTelemetry
    Assert-GuestTelemetry $operatorEvidence -RequireHealthy
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind') -and
        $operatorEvidence.receipt.marker.startBeforeUtc -isnot [string]) {
        throw 'Operator receipt did not reuse the guest JSON timestamp-preserving parser.'
    }
    if ($operatorEvidence.queryReader -cne 'OperatorCli' -or $operatorEvidence.ContainsKey('queryAddresses') -or
        $script:operatorQueries -ne 8) { throw 'Operator provenance misrepresented as VM identity/DNS evidence.' }
    $status = Get-GuestStatus
    if ($status.ownerToken -cne $script:state.ownerToken -or $script:operatorQueries -ne 9 -or
        $script:state.phase -cne 'ready' -or $script:state.lastEvidence.ownerToken -cne $script:state.ownerToken) {
        throw 'Status did not use and persist authenticated operator evidence without a guest command.'
    }
    foreach ($change in @(@{ ownerToken = [guid]::NewGuid().ToString() },
        @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o') },
        @{ watchdogActive = $false }, @{ active = 'true' })) {
        $changedReceipt = $evidence.receipt.Clone()
        foreach ($key in $change.Keys) { $changedReceipt[$key] = $change[$key] }
        $script:operatorRows = @(@{ receipt = ($changedReceipt | ConvertTo-Json -Depth 12 -Compress) })
        Assert-Rejected { Get-GuestTelemetry }
    }
    foreach ($change in @(@{ runId = [guid]::NewGuid().ToString() }, @{ durationSeconds = 601 },
        @{ phase = 'invalid' }, @{ canary = $true }, @{ actor = 'invalid' },
        @{ deadlineUtc = [DateTimeOffset]::UtcNow.AddDays(1).ToString('o') })) {
        $changedReceipt = $evidence.receipt.Clone()
        $changedReceipt.marker = $evidence.receipt.marker.Clone()
        foreach ($key in $change.Keys) { $changedReceipt.marker[$key] = $change[$key] }
        $script:operatorRows = @(@{ receipt = ($changedReceipt | ConvertTo-Json -Depth 12 -Compress) })
        Assert-Rejected { Get-GuestTelemetry }
    }
    $script:operatorRows = @(@{ receipt = ($evidence.receipt | ConvertTo-Json -Depth 12 -Compress) })
    foreach ($change in @(
        @{ queryReader = 'VmIdentity' }, @{ queriedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o') },
        @{ queriedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o') })) {
        $changed = $operatorEvidence.Clone()
        foreach ($key in $change.Keys) { $changed[$key] = $change[$key] }
        Assert-Rejected { Assert-GuestTelemetry $changed }
    }
    foreach ($rows in @(@{ value = @() }, @{ value = @(@{ receipt = '' }) },
        @{ value = @(@{ receipt = '[]' }) }, @{ value = @(@{ receipt = '{}' }) },
        @{ value = @(@{ receipt = '{' }) }, @{ value = @(@{ receipt = 'null' }) },
        @{ value = @(@{ receipt = '{}' }, @{ receipt = '{}' }) })) {
        $script:operatorRows = $rows.value
        Assert-Rejected { Get-GuestTelemetry }
    }
    $script:operatorRows = @(@{ receipt = ($evidence.receipt | ConvertTo-Json -Depth 12 -Compress) })
    $script:state.nativeRead = @{ phase = 'Accepted' }
    $queries = $script:operatorQueries
    Assert-Rejected { Get-GuestTelemetry }
    if ($queries -ne $script:operatorQueries) { throw 'Operator mode hid an unresolved native operation.' }
    $script:state.Remove('nativeRead')
    $script:state.monitorReadMode = 'VmIdentity'
    Assert-Rejected { Assert-GuestTelemetry $operatorEvidence }
    $script:state.monitorReadMode = 'Operator'
    $script:state.withSreExecution = $false
    Assert-Rejected { Get-GuestMonitorReadMode }
    $script:state.withSreExecution = $true
    $script:state.monitorTransport = 'Private'
    Assert-Rejected { Get-GuestMonitorReadMode }
    $script:state.monitorTransport = 'Public'
    $script:state.monitorReadMode = 'Automatic'
    Assert-Rejected { Get-GuestMonitorReadMode }
    $script:state.Remove('monitorReadMode')
    if ((Get-GuestMonitorReadMode) -cne 'VmIdentity') { throw 'Legacy mode changed silently.' }
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
"Guest monitoring contracts passed ($script:checks rejection checks)."
