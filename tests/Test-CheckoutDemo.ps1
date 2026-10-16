#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts\Azure.Common.psm1') -Force
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repository 'scripts\Invoke-CheckoutDemo.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'Checkout lifecycle has syntax errors.' }
foreach ($definition in $ast.FindAll({
    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
foreach ($helper in Get-ChildItem (Join-Path $repository 'scripts\checkout\*.ps1')) {
    . $helper.FullName
}
$subscription = '11111111-1111-1111-1111-111111111111'
$EnvironmentName = 'demo01'
$Location = 'swedencentral'
$groupName = 'rg-retailtx-checkout-demo01-swedencentral'
$group = "/subscriptions/$subscription/resourceGroups/$groupName"
$customAgentName = 'retailtx-checkout-demo01'
$deploymentName = 'retailtx-checkout-demo01'
$statePath = 'mock-state-only'
$script:resolveConnection = ${function:Get-SreConnection}
$script:queryLatency = ${function:Get-CheckoutLatency}
$script:checks = 0
$script:writes = @()
$script:failPut = $false
$script:policyDrift = $false
$script:grantDrift = $false
$script:cleanupMode = $false
$script:identityDrift = $false
$script:oldTelemetry = $false
$script:delayWorker = $false
$script:alerts = @()
$script:thread = @{ state = 'Idle'; value = @() }

function Copy-TestValue { param($Value) $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -like "*$Message*") "Expected rejection: $Message; got $failure"
}
function New-TestState {
    $script:agentOwner = $subscription
    $script:agentCreatedAt = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    $script:operatorAccountType = 'user'
    $script:operatorClaims = @{ tid = $subscription; aud = 'https://management.azure.com/'
        oid = '33333333-3333-3333-3333-333333333333' }
    $script:routes = @{ BE = 'primary'; NL = 'primary' }
    $script:armSettings = @{ PRICE_ROUTE_BE = 'primary'; PRICE_ROUTE_NL = 'primary'; ROUTE_CHANGE_REF = 'baseline' }
    $script:service = @{ active = $true; healthy = $true; marker = $null }
    $script:persisted = @{
        schemaVersion = 2; enableArc = $true; arcRegistered = $true; controllerInstalled = $true
        tenantId = $subscription
        arcProbeVerified = $true; ownerToken = $subscription; activeFault = $null; pendingArcCommand = $null
        createdAtUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
        arcAssignmentId = "$group/providers/Microsoft.HybridCompute/machines/demo/providers/Microsoft.Authorization/roleAssignments/$subscription"
        arcRoleName = $subscription; arcRoleId = "$group/providers/Microsoft.Authorization/roleDefinitions/$subscription"
        outputs = @{
            resourceGroupId = $group
            sreIdentityId = "$group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-checkout-demo01-sre"
            webAppUrl = 'https://demo.azurewebsites.net'; webAppName = 'demo'; vmName = 'demo'
            arcMachineName = 'arc-demo'; arcMachineId = "$group/providers/Microsoft.HybridCompute/machines/demo"
            workspaceId = "$group/providers/Microsoft.OperationalInsights/workspaces/demo"
            workspaceCustomerId = $subscription; appInsightsName = 'demo'
            alertRuleName = 'alert-checkout-latency-demo01'; serviceAlertRuleName = 'alert-checkout-service-demo01'
            alertRuleId = "$group/providers/Microsoft.Insights/scheduledQueryRules/latency"
            serviceAlertRuleId = "$group/providers/Microsoft.Insights/scheduledQueryRules/service"
            agentId = "$group/providers/Microsoft.App/agents/demo"; agentName = 'demo'
            srePrincipalId = '22222222-2222-2222-2222-222222222222'
        }
    }
}
function Get-CheckoutState { Copy-TestValue $script:persisted }
function Save-RetailState { param($State, $Path) $script:persisted = Copy-TestValue $State }
function Invoke-WebRequest { @{ StatusCode = 200; Content = (@{ routes = $script:routes } | ConvertTo-Json) } }
function Get-CheckoutLatency {
    param($State, $After)
    $rows = @{}
    foreach ($country in @('BE', 'NL')) {
        $rows[$country] = @{ n = $(if ($script:oldTelemetry -and $null -ne $After) { 0 } else { 10 })
            newest = [DateTimeOffset]::UtcNow.ToString('o')
            failures = $(if ($script:service.healthy) { 0 } else { 10 })
            primaryCount = $(if ($script:routes[$country] -eq 'primary') { 10 } else { 0 })
            p95 = $(if ($script:routes[$country] -eq 'primary') { 80 } else { 1800 }) }
    }
    $rows
}
function Get-CheckoutServiceObservation { Copy-TestValue $script:service }
function Get-CheckoutArcMachine { @{ properties = @{ status = 'Connected' } } }
function Get-SreConnection { param($State) & $script:resolveConnection $State }
function Invoke-Az {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    switch ("$($Arguments[0]) $($Arguments[1])") {
        'vm extension' { return @() }
        'resource show' {
            if ($Arguments[3] -eq $script:persisted.outputs.agentId) {
                return @{ tags = @{ ownerToken = $script:agentOwner; managedBy = 'invoke-checkoutdemo' }
                    systemData = @{ createdAt = $script:agentCreatedAt }
                    properties = @{ runningState = 'Running'; agentEndpoint = 'https://demo.azuresre.ai'
                        actionConfiguration = @{ mode = 'Review'
                            identity = $(if ($script:identityDrift) { 'foreign' } else { $script:persisted.outputs.sreIdentityId }) } } }
            }
            if ($Arguments[3] -eq $script:persisted.outputs.sreIdentityId) {
                return @{ tags = @{ ownerToken = $subscription }
                    properties = @{ principalId = $script:persisted.outputs.srePrincipalId } }
            }
            return @{ properties = @{ enabled = $true } }
        }
        'resource list' { return @($script:persisted.outputs.agentId) }
        'account show' { return @{ user = @{ type = $script:operatorAccountType } } }
        'account get-access-token' {
            if ('https://management.azure.com/' -cnotin $Arguments) { throw 'Expected the ARM token audience.' }
            $claims = $script:operatorClaims | ConvertTo-Json -Compress
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims))
            return @{ accessToken = "header.$payload.signature" }
        }
        'webapp config' {
            if ($Arguments[3] -eq 'list') {
                return @($script:armSettings.Keys | ForEach-Object { @{ name = $_; value = $script:armSettings[$_] } })
            }
            if ($Arguments[3] -cne 'set') { throw 'Unexpected web app command.' }
            Assert-Test ($null -ne $script:persisted.activeFault) 'Fault intent must precede a write.'
            $script:writes += 'latency'
            $script:armSettings.PRICE_ROUTE_BE = if ('PRICE_ROUTE_BE=legacy' -in $Arguments) { 'legacy' } else { 'primary' }
            $script:armSettings.ROUTE_CHANGE_REF = ($Arguments | Where-Object { $_ -like 'ROUTE_CHANGE_REF=*' }).Split('=')[1]
            if (-not $script:delayWorker) { $script:routes.BE = $script:armSettings.PRICE_ROUTE_BE }
            return
        }
        default { throw "Unexpected Azure mock call: $($Arguments -join ' ')" }
    }
}
function Invoke-SreRequest {
    param($Connection, $Method, $Path, $Body, [switch]$AllowMissing)
    if ($Method -cne 'GET') { throw 'No SRE writes are allowed in lifecycle tests.' }
    if ($Path -like '*/incidentFilters/*') {
        $name = ($Path -split '/')[-1]
        return @{ properties = @{ isEnabled = $true; agentMode = 'review'; handlingAgent = $name
            titleContains = $(if ($name -like '*-service') { $script:persisted.outputs.serviceAlertRuleName }
                else { $script:persisted.outputs.alertRuleName })
            mergeEnabled = $false; azMonitorFilterSettings = @{
                targetResource = $script:persisted.outputs.workspaceId
                targetResourceType = 'Microsoft.OperationalInsights/workspaces' } } }
    }
    if ($Path -like '*/extendedAgent/agents/*') {
        return @{ properties = @{ tools = @('RunAzCliReadCommands', 'RunAzCliWriteCommands')
            instructions = $(if ($Path -like '*-service') { Get-CheckoutServiceInstruction $script:persisted }
                else { Get-InvestigatorInstruction $script:persisted.outputs }) } }
    }
    if ($Path -like '*/settings/global') {
        $value = Get-CheckoutApprovalPolicy
        if ($script:policyDrift) { $value.permissions.allow = @('RunAzCliWriteCommands') }
        return $value
    }
    if ($Path -like '*/incidents?*') {
        $alert = $script:alerts[0]
        return @{ id = ($alert.id -split '/')[-1]; alertId = $alert.id
            targetResourceId = $script:persisted.outputs.workspaceId
            alertRuleResourceId = $alert.properties.essentials.alertRule; threadId = $subscription }
    }
    if ($Path -like '*/messages') { return $script:thread }
    throw "Unexpected SRE mock path $Path"
}
function Invoke-TokenRequest {
    param($Resource, $Uri, $Method = 'GET', $Body, [switch]$AllowMissing)
    if ($script:cleanupMode) {
        $path = ([uri]$Uri).AbsolutePath
        if ($path.EndsWith('/roleAssignments')) {
            return @{ value = @($script:cleanupDocs.Values | Where-Object { $_['id'] -like '*/roleAssignments/*' }) }
        }
        if ($Method -eq 'DELETE') {
            $script:deletes += $path
            if (-not $script:retainDeletes) { $script:cleanupDocs.Remove($path) }
            return
        }
        if ($Method -cne 'GET') { throw 'Unexpected cleanup write.' }
        return $script:cleanupDocs[$path]
    }
    if ($Uri -like '*Microsoft.AlertsManagement/alerts?*') { return @{ value = $script:alerts } }
    if ($Uri -like '*api.loganalytics.io*') {
        $script:observedKql = $Body.query
        return @{ tables = @(@{ columns = @(); rows = @() }) }
    }
    if ($Uri -like '*scheduledQueryRules*') { return @{ properties = @{ enabled = $true } } }
    if ($Uri -like '*/roleAssignments/*') {
        return @{ properties = @{ principalId = $(if ($script:grantDrift) { 'other' } else { $script:persisted.outputs.srePrincipalId })
            scope = $script:persisted.outputs.arcMachineId; roleDefinitionId = $script:persisted.arcRoleId } }
    }
    if ($Uri -like '*/roleDefinitions/*') {
        return @{ properties = @{ assignableScopes = @($group); permissions = @(@{
            actions = @('Microsoft.HybridCompute/machines/read', 'Microsoft.HybridCompute/machines/runcommands/read',
                'Microsoft.HybridCompute/machines/runcommands/write')
            notActions = @(); dataActions = @(); notDataActions = @() }) } }
    }
    if ($Method -eq 'PUT') {
        Assert-Test ($null -ne $script:persisted.pendingArcCommand) 'Arc journal must precede PUT.'
        Assert-Test (-not $Body.properties.source.script.Contains("`r")) 'Guest scripts must have LF endings.'
        $script:writes += 'arc'
        if ($script:failPut) { throw 'Unknown transport outcome' }
        $script:arcView = @{ executionState = 'Succeeded'; exitCode = 0; output = ''; error = '' }
        if ($Body.properties.source.script -match "^python3 /opt/retailtx-checkout/service_control.py '(.+)'$") {
            $request = $Matches[1] | ConvertFrom-Json -AsHashtable
            if ($request.action -eq 'fault') {
                $script:service = @{ active = $false; healthy = $false
                    marker = @{ runId = $request.runId; actor = $request.actor; phase = 'fault-active' } }
            } elseif ($request.action -eq 'reset') {
                $script:service.active = $true
                $script:service.healthy = $true
                $script:service.marker.phase = 'recovered'
                $script:service.marker.recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            } else { throw 'Unexpected controller action.' }
        }
        return
    }
    if ($Uri -like '*/runCommands/*') { return @{ properties = @{ instanceView = $script:arcView } } }
    throw "Unexpected ARM mock request $Method $Uri"
}

New-TestState
$instruction = Get-CheckoutServiceInstruction $script:persisted
Assert-Test ($instruction.Contains('--no-wait --only-show-errors -o json')) 'SRE submission must not wait for ARM completion.'
Assert-Test ($instruction.Contains('--start-time <faultStartUtc>')) 'Activity Log timestamps must use start-time, not offset.'
$originalBoundary = $script:persisted.createdAtUtc
$null = Get-SreConnection (Get-CheckoutState)
Assert-Test ($script:persisted.createdAtUtc -ceq $originalBoundary) 'Existing generation boundaries must be preserved.'
$script:persisted.Remove('createdAtUtc')
$null = Get-SreConnection (Get-CheckoutState)
Assert-Test ([DateTimeOffset]$script:persisted.createdAtUtc -eq [DateTimeOffset]$script:agentCreatedAt) `
    'Missing boundaries must come from the owned, identity-validated SRE resource.'
$script:persisted.Remove('createdAtUtc')
$script:agentOwner = 'foreign'
Assert-Rejected { Get-SreConnection (Get-CheckoutState) } 'binding drifted'
Assert-Test (-not $script:persisted.ContainsKey('createdAtUtc')) 'Foreign resources cannot establish a generation.'
$script:agentOwner = $subscription
$script:agentCreatedAt = $null
Assert-Rejected { Get-SreConnection (Get-CheckoutState) } 'deployment generation'
Assert-Test (-not $script:persisted.ContainsKey('createdAtUtc')) 'Missing creation evidence must not invent a boundary.'

foreach ($context in @('tenant', 'audience', 'identity', 'non-user')) {
    New-TestState
    $Scenario = 'service'
    $before = $script:writes.Count
    switch ($context) {
        'tenant' { $script:operatorClaims.tid = '44444444-4444-4444-4444-444444444444'; $message = 'token context' }
        'audience' { $script:operatorClaims.aud = 'https://graph.microsoft.com'; $message = 'token context' }
        'identity' { $script:operatorClaims.oid = 'not-an-object-id'; $message = 'Guid' }
        'non-user' { $script:operatorAccountType = 'servicePrincipal'; $message = 'human operator' }
    }
    Assert-Rejected { Invoke-CheckoutFault } $message
    Assert-Test ($script:writes.Count -eq $before -and $null -eq $script:persisted.activeFault) `
        'Invalid operator context must fail before fault intent or Azure writes.'
}
Assert-Rejected { Get-RetailTokenActor -AccessToken 'malformed' -TenantId $subscription } 'Malformed operator token'

foreach ($order in @(@('service', 'latency'), @('latency', 'service'))) {
    New-TestState
    foreach ($selected in $order) {
        $Scenario = $selected
        Assert-Test (Invoke-Ready).ready 'Common baseline should be ready.'
        $before = $script:writes.Count
        $null = Invoke-CheckoutFault
        Assert-Test ($script:persisted.activeFault.scenario -ceq $selected) 'Only the selected scenario may run.'
        Assert-Test ($script:writes.Count -eq $before + 1) 'One fault must cause only one write.'
        Assert-Rejected { Invoke-CheckoutFault } 'Fault admission refused'
        $Scenario = if ($selected -eq 'service') { 'latency' } else { 'service' }
        Assert-Rejected { Invoke-CheckoutFault -Undo } 'Undo must select'
        $Scenario = $selected
        $null = Invoke-CheckoutFault -Undo
        Assert-Test ($script:persisted.activeFault.phase -ceq 'verify-recovery') 'Undo must retain intent until verification.'
        Assert-Test (Invoke-Ready).ready 'Recovery must return to the shared baseline.'
        Assert-Test ($null -eq $script:persisted.activeFault) 'Ready must retire only the verified fault.'
        Assert-Test ($script:writes.Count -eq $before + 2) 'Recovery must not inject the next scenario.'
    }
}
New-TestState
$Scenario = 'latency'
$script:delayWorker = $true
$null = Invoke-CheckoutFault
Assert-Test (-not (Invoke-Ready).ready) 'Pre-injection worker health must not override current ARM settings.'
Assert-Test ($null -ne $script:persisted.activeFault) 'Delayed injection visibility must retain the active fault.'
Assert-Rejected { Invoke-CheckoutFault } 'Fault admission refused'
$script:delayWorker = $false
$script:armSettings.PRICE_ROUTE_BE = 'primary'
$script:oldTelemetry = $true
Assert-Test (-not (Invoke-Ready).ready) 'Pre-recovery telemetry cannot retire a quickly repaired latency fault.'
Assert-Test ($null -ne $script:persisted.activeFault) 'Recovery requires post-boundary samples.'
$script:oldTelemetry = $false
Assert-Test (Invoke-Ready).ready 'Post-recovery samples permit retirement.'
$cutoff = [DateTimeOffset]::UtcNow.AddMinutes(-1)
$null = & $script:queryLatency $script:persisted -After $cutoff
Assert-Test ($script:observedKql.Contains("TimeGenerated > datetime($($cutoff.UtcDateTime.ToString('o')))")) 'Actual KQL must enforce the recovery boundary.'
$script:identityDrift = $true
Assert-Rejected { Invoke-Ready } 'action identity binding drifted'
$script:identityDrift = $false
New-TestState
$Scenario = 'service'
$script:failPut = $true
$before = $script:writes.Count
Assert-Rejected { Invoke-CheckoutFault } 'Unknown transport outcome'
Assert-Test ($null -ne $script:persisted.pendingArcCommand) 'Unknown Arc result must remain journaled.'
Assert-Rejected { Invoke-CheckoutFault -Undo } 'unsettled'
Assert-Test ($script:writes.Count -eq $before + 1) 'Unknown Arc PUT must never be replayed.'
$script:failPut = $false
$script:arcView = @{ executionState = 'Failed'; exitCode = 1 }
Assert-Rejected { Wait-CheckoutArcCommand (Get-CheckoutState) } 'finished as Failed'
Assert-Test ($null -eq $script:persisted.pendingArcCommand) 'A terminal failed command is settled, not successful.'
New-TestState
$null = Invoke-CheckoutArcCommand (Get-CheckoutState) -Operation 'probe' -Script "set -eu`r`nprintf ok"
$script:policyDrift = $true
Assert-Test (-not (Invoke-Ready).ready) 'An allow rule must block admission.'
$script:policyDrift = $false
$script:grantDrift = $true
Assert-Test (-not (Invoke-Ready).ready) 'Wrong Arc action principal must block admission.'
$script:grantDrift = $false
$script:alerts = @(@{ id = "$group/providers/Microsoft.AlertsManagement/alerts/$subscription"
    properties = @{ essentials = @{ targetResource = $script:persisted.outputs.workspaceId
        alertRule = $script:persisted.outputs.alertRuleId; monitorCondition = 'Fired'
        startDateTime = [DateTimeOffset]::UtcNow.ToString('o') } } })
Assert-Test (-not (Invoke-Ready).ready) 'Prior alert clearance is required.'
$script:alerts[0].properties.essentials.monitorCondition = 'Resolved'
$script:thread.value = @(@{ approval = @{ status = 'Pending' } })
Assert-Test (-not (Invoke-Ready).ready) 'Stale pending approval must block the next scenario.'
$script:thread.value = @()
Assert-Test (Invoke-Ready).ready 'Resolved alerts with settled threads permit another scenario.'
$script:alerts[0].properties.essentials.startDateTime = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
$script:alerts[0].properties.essentials.monitorCondition = 'Fired'
Assert-Test (Invoke-Ready).ready 'Alerts retained from a deleted deployment must not belong to the new generation.'
$script:cleanupMode = $true
$script:deletes = @()
$script:retainDeletes = $false
$base = "/subscriptions/$subscription"
$grantId = "$base/providers/Microsoft.Authorization/roleAssignments/$subscription"
$principal = $script:persisted.outputs.srePrincipalId
$modulePath = "$base/providers/Microsoft.Resources/deployments/checkout-sre-monitoring-$EnvironmentName"
$script:cleanupDocs = @{
    "$base/providers/Microsoft.Resources/deployments/$deploymentName" = @{
        properties = @{ provisioningState = 'Failed'; parameters = @{ ownerToken = @{ value = $subscription } } } }
    "$group/providers/Microsoft.Resources/deployments/checkout-estate" = @{
        properties = @{ provisioningState = 'Succeeded'; outputs = @{ srePrincipalId = @{ value = $principal } } } }
    $modulePath = @{ properties = @{
        provisioningState = 'Failed'
        parameters = @{ principalId = @{ value = $principal } }
        outputs = @{ assignmentId = @{ value = $grantId } } } }
    $grantId = @{ id = $grantId; properties = @{ principalId = $principal; scope = $base
        roleDefinitionId = "$base/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa" } }
}
$partial = @{ ownerToken = $subscription; outputs = @{} }
Restore-CheckoutCleanupOutputs $partial
Assert-Test ($partial.outputs.sreMonitoringAssignmentId -ceq $grantId) 'Failed parent deployment must not lose scope-external cleanup.'
$script:cleanupDocs[$modulePath].properties.Remove('outputs')
$partial = @{ ownerToken = $subscription; outputs = @{} }
Restore-CheckoutCleanupOutputs $partial
Assert-Test ($partial.outputs.sreMonitoringAssignmentId -ceq $grantId) 'Existing assignment must be found even without deployment outputs.'
$script:cleanupDocs[$modulePath].properties.provisioningState = 'Running'
Assert-Rejected { Restore-CheckoutCleanupOutputs $partial } 'nonterminal'
$script:cleanupDocs[$modulePath].properties.provisioningState = 'Failed'
$parentPath = "$base/providers/Microsoft.Resources/deployments/$deploymentName"
$script:cleanupDocs[$parentPath].properties.provisioningState = 'Running'
Assert-Rejected { Restore-CheckoutCleanupOutputs $partial } 'nonterminal'
$script:cleanupDocs[$parentPath].properties.provisioningState = 'Failed'
$script:cleanupDocs[$modulePath].properties.parameters.principalId.value = 'foreign'
Assert-Rejected { Restore-CheckoutCleanupOutputs $partial } 'not linked'
Assert-Test ($script:deletes.Count -eq 0) 'Foreign deployment discovery must not delete anything.'
$script:cleanupDocs[$grantId].properties.principalId = 'foreign'
Assert-Rejected { Remove-CheckoutSubscriptionGrant $grantId $principal '749f88d5-cbae-40b8-bcfc-e573ddc772fa' } 'drifted'
$script:cleanupDocs[$grantId].properties.principalId = $principal
$script:retainDeletes = $true
Assert-Rejected { Remove-CheckoutSubscriptionGrant $grantId $principal '749f88d5-cbae-40b8-bcfc-e573ddc772fa' } 'not yet verified'
$script:retainDeletes = $false
Remove-CheckoutSubscriptionGrant $grantId $principal '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
Assert-Test (-not $script:cleanupDocs.ContainsKey($grantId)) 'Grant deletion must be observed.'
[pscustomobject]@{ checks = $script:checks; result = 'Passed (mocked Azure/SRE only)' }
