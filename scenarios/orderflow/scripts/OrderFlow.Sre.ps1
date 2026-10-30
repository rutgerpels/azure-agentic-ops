#Requires -Version 7.2
# Scenario-owned helpers; no dependency on Retailx SRE configuration.
function Get-OrderFlowSreConnection {
    param([hashtable]$State)
    $agent = Invoke-OrderFlowRequest $State "https://management.azure.com$($State.outputs.agentId)?api-version=2026-01-01"
    if ($agent.tags.ownerToken -cne $State.ownerToken -or
        $agent.properties.actionConfiguration.mode -cne 'Review' -or
        $agent.properties.actionConfiguration.identity -ine $State.outputs.sreIdentityId) {
        throw 'SRE ownership, action identity or Review mode drifted.'
    }
    $endpoint = [uri]$agent.properties.agentEndpoint
    if ($endpoint.Scheme -cne 'https' -or $endpoint.UserInfo -or -not $endpoint.IsDefaultPort -or
        -not $endpoint.Host.EndsWith('.azuresre.ai') -or $endpoint.AbsolutePath -cne '/') {
        throw 'Unexpected SRE endpoint.'
    }
    $endpoint.AbsoluteUri.TrimEnd('/')
}

function Invoke-OrderFlowSre {
    param([hashtable]$State, [string]$Endpoint, [string]$Path, [string]$Method = 'GET',
        [hashtable]$Body, [switch]$Raw, [string]$IfMatch, [switch]$AllowMissing)
    if (-not $Path.StartsWith('/api/') -or $Path.Contains('..')) { throw 'Unexpected SRE path.' }
    Invoke-OrderFlowRequest $State "$Endpoint$Path" -Audience 'https://azuresre.dev' `
        -Method $Method -Body $Body -Raw:$Raw -IfMatch $IfMatch -AllowMissing:$AllowMissing
}

function Test-OrderFlowExpected {
    param($Actual, $Expected)
    if ($Expected -is [hashtable]) {
        if ($Actual -isnot [hashtable]) { return $false }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.ContainsKey($key) -or -not (Test-OrderFlowExpected $Actual[$key] $Expected[$key])) { return $false }
        }
        return $true
    }
    if ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count) { return $false }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            if (-not (Test-OrderFlowExpected $Actual[$i] $Expected[$i])) { return $false }
        }
        return $true
    }
    return ($Actual -ceq $Expected)
}

function Invoke-OrderFlowConfigWrite {
    param([hashtable]$State, [string]$StatePath, [string]$Endpoint, [string]$Path, [hashtable]$Payload, [string]$IfMatch)
    $current = Invoke-OrderFlowSre $State $Endpoint $Path -AllowMissing
    if (Test-OrderFlowExpected $current $Payload) { return }
    $State.configured = $false
    $State.pendingOperation = 'sre-config'
    $State.configStage = @{ path = $Path; expected = $Payload; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    Save-OrderFlowState $State $StatePath
    $null = Invoke-OrderFlowSre $State $Endpoint $Path PUT $Payload -IfMatch $IfMatch
    Complete-OrderFlowConfigObservation $State $StatePath $Endpoint
}

function Complete-OrderFlowConfigObservation {
    param([hashtable]$State, [string]$StatePath, [string]$Endpoint)
    $stage = $State.configStage
    $current = Invoke-OrderFlowSre $State $Endpoint $stage.path
    if (-not (Test-OrderFlowExpected $current $stage.expected)) {
        throw 'Original SRE configuration stage not observed. Keep pending state; do not replay the PUT.'
    }
    $State.pendingOperation = $null
    $State.configStage = $null
    Save-OrderFlowState $State $StatePath
}

function Get-OrderFlowPolicy {
    @{
        permissions = @{
            allow = @()
            ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
            deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode')
        }
    }
}

function Assert-OrderFlowPolicy {
    param([hashtable]$Actual)
    $expected = Get-OrderFlowPolicy
    foreach ($kind in @('allow', 'ask', 'deny')) {
        if ($Actual.permissions[$kind] -isnot [array] -or
            (($Actual.permissions[$kind] | Sort-Object -CaseSensitive) -join "`n") -cne
            (($expected.permissions[$kind] | Sort-Object -CaseSensitive) -join "`n")) {
            throw 'SRE approval policy drifted; refusing fault admission.'
        }
    }
}

function Get-OrderFlowList {
    param($Response)
    if ($Response -is [array]) { return ,$Response }
    if ($Response -is [hashtable] -and $Response.ContainsKey('value') -and
        $Response.value -is [array] -and -not $Response['nextLink'] -and -not $Response['continuationToken']) {
        return ,$Response.value
    }
    throw 'SRE list response is incomplete or unsupported; inspect the provider schema, do not assume empty.'
}

function Get-OrderFlowInvestigator {
    param([hashtable]$State)
    $instruction = Get-Content (Join-Path $scenarioRoot 'docs\runbook.md') -Raw
    $tokens = @{
        subscription = $State.subscriptionId
        group = $State.resourceGroup
        ruleId = $State.outputs.ruleId
        workspace = $State.outputs.workspaceCustomerId
        runId = $State.ownerToken
    }
    foreach ($key in $tokens.Keys) { $instruction = $instruction.Replace("{{$key}}", [string]$tokens[$key]) }
    if ($instruction -match '\{\{') { throw 'Unresolved SRE instruction token.' }
    @{
        name = 'orderflow-investigator'
        properties = @{
            instructions = $instruction
            handoffDescription = 'Investigate OrderFlow dependency failures and propose one approved baseline restoration.'
            handoffs = @(); enableVanillaMode = $true
            tools = @('GetArmResourceAsJson', 'GetAzCliHelp', 'RunAzCliReadCommands', 'RunAzCliWriteCommands')
        }
    }
}

function Get-OrderFlowResponsePlan {
    param([hashtable]$State)
    @{
        name = 'orderflow-response'; type = 'IncidentFilter'
        properties = @{
            isEnabled = $true; agentMode = 'review'; handlingAgent = 'orderflow-investigator'
            titleContains = $State.outputs.alertName; mergeEnabled = $false
            azMonitorFilterSettings = @{
                targetResourceType = 'Microsoft.OperationalInsights/workspaces'
                targetResource = $State.outputs.workspaceId
            }
        }
    }
}

function Assert-OrderFlowRepairRole {
    param([hashtable]$State, [switch]$DefinitionOnly)
    $role = Invoke-OrderFlowRequest $State "https://management.azure.com$($State.outputs.repairRoleId)?api-version=2022-04-01"
    $expected = @('Microsoft.Network/networkSecurityGroups/securityRules/read',
        'Microsoft.Network/networkSecurityGroups/securityRules/write')
    if (@($role.properties.permissions).Count -ne 1 -or
        (($role.properties.permissions[0].actions | Sort-Object) -join ',') -cne (($expected | Sort-Object) -join ',') -or
        @($role.properties.permissions[0].dataActions).Count -or
        @($role.properties.permissions[0].notActions).Count -or
        @($role.properties.permissions[0].notDataActions).Count -or
        ($role.properties.assignableScopes -join ',') -ine "/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.resourceGroup)") {
        throw 'Owned SRE repair role definition drifted.'
    }
    if ($DefinitionOnly) { return }
    $grant = Invoke-OrderFlowRequest $State "https://management.azure.com$($State.outputs.repairAssignmentId)?api-version=2022-04-01"
    $canonicalRole = "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/" +
        ([guid](($State.outputs.repairRoleId -split '/')[-1])).ToString()
    if ($grant.properties.principalId -ine $State.outputs.srePrincipalId -or
        $grant.properties.roleDefinitionId -ine $canonicalRole -or
        $grant.properties.scope -ine $State.outputs.ruleId) {
        throw 'Owned SRE repair role or exact-rule assignment drifted.'
    }
}

function Assert-OrderFlowNoHooks {
    param([hashtable]$State, [string]$Endpoint)
    $hooks = Get-OrderFlowList (Invoke-OrderFlowSre $State $Endpoint '/api/v2/extendedAgent/hooks')
    if ($hooks.Count) { throw 'Hooks may override native approval. Remove unexpected hooks through reviewed configuration first.' }
}

function Set-OrderFlowSre {
    param([hashtable]$State, [string]$StatePath)
    $State.configured = $false
    Save-OrderFlowState $State $StatePath
    $endpoint = Get-OrderFlowSreConnection $State
    Assert-OrderFlowRepairRole $State
    Assert-OrderFlowNoHooks $State $endpoint
    Assert-OrderFlowSreSettled $State -Endpoint $endpoint
    $response = Invoke-OrderFlowSre $State $endpoint '/api/v2/agent/settings/global' -Raw
    $settings = $response.Content | ConvertFrom-Json -AsHashtable
    $expectedPolicy = Get-OrderFlowPolicy
    $matches = $settings.ContainsKey('permissions')
    if ($matches) {
        foreach ($kind in @('allow', 'ask', 'deny')) {
            if ($settings.permissions[$kind] -isnot [array] -or
                (($settings.permissions[$kind] | Sort-Object -CaseSensitive) -join "`n") -cne
                (($expectedPolicy.permissions[$kind] | Sort-Object -CaseSensitive) -join "`n")) { $matches = $false }
        }
    }
    if (-not $matches) {
        $etag = @($response.Headers['ETag'])[0]
        if (-not $etag) {
            if (-not $settings.ContainsKey('permissions') -or @($settings.permissions.allow).Count -or
                @($settings.permissions.ask).Count -or @($settings.permissions.deny).Count) {
                throw 'Nonempty policy without ETag cannot be safely overwritten.'
            }
            $etag = '*'
        }
        Invoke-OrderFlowConfigWrite $State $StatePath $endpoint '/api/v2/agent/settings/global' $expectedPolicy -IfMatch $etag
    }
    Invoke-OrderFlowConfigWrite $State $StatePath $endpoint '/api/v2/extendedAgent/agents/orderflow-investigator' (Get-OrderFlowInvestigator $State)
    Invoke-OrderFlowConfigWrite $State $StatePath $endpoint '/api/v2/incidentManagement/incidentFilters/orderflow-response' (Get-OrderFlowResponsePlan $State)
    Assert-OrderFlowSre $State -DuringConfiguration
}

function Assert-OrderFlowSre {
    param([hashtable]$State, [switch]$DuringConfiguration)
    if (-not $DuringConfiguration -and -not $State.configured) { throw 'Run ConfigureSre first.' }
    $endpoint = Get-OrderFlowSreConnection $State
    Assert-OrderFlowRepairRole $State
    Assert-OrderFlowNoHooks $State $endpoint
    Assert-OrderFlowPolicy (Invoke-OrderFlowSre $State $endpoint '/api/v2/agent/settings/global')
    $actual = Invoke-OrderFlowSre $State $endpoint '/api/v2/extendedAgent/agents/orderflow-investigator'
    $expected = Get-OrderFlowInvestigator $State
    if ($actual.properties.instructions -cne $expected.properties.instructions -or
        ($actual.properties.tools -join ',') -cne ($expected.properties.tools -join ',') -or
        @($actual.properties['handoffs']).Count -or
        ($actual.properties['hooks'] -and $actual.properties.hooks.Count) -or
        ($actual.properties['permissions'] -and @($actual.properties.permissions.allow).Count)) {
        throw 'Investigator instructions, tools, hooks or permission overrides drifted.'
    }
    $permissions = Invoke-OrderFlowSre $State $endpoint '/api/v2/extendedAgent/orderflow-investigator/permissions'
    if (-not $permissions.ContainsKey('allow') -or @($permissions.allow).Count) {
        throw 'Investigator permission overrides are missing/unsupported or unsafe.'
    }
    $plan = Invoke-OrderFlowSre $State $endpoint '/api/v2/incidentManagement/incidentFilters/orderflow-response'
    if ($plan.properties.isEnabled -ne $true -or $plan.properties.agentMode -cne 'review' -or
        $plan.properties.handlingAgent -cne 'orderflow-investigator' -or $plan.properties.mergeEnabled -ne $false -or
        $plan.properties.titleContains -cne $State.outputs.alertName -or
        $plan.properties.azMonitorFilterSettings.targetResource -ine $State.outputs.workspaceId) {
        throw 'Exact Review-mode response plan missing or drifted.'
    }
    $connectivity = Invoke-OrderFlowSre $State $endpoint '/api/v2/incidentManagement/checkConnectivityDetailed'
    if ($connectivity.success -ne $true -or $connectivity.incidentType -cne 'AzMonitor') {
        throw 'Azure Monitor intake is not ready. Inspect native SRE setup; no fault is admitted.'
    }
    Assert-OrderFlowSreSettled $State -Endpoint $endpoint
    Assert-OrderFlowAlertSettled $State
}

function Assert-OrderFlowAlertSettled {
    param([hashtable]$State)
    $target = [uri]::EscapeDataString($State.outputs.workspaceId)
    $uri = "https://management.azure.com/subscriptions/$($State.subscriptionId)/providers/Microsoft.AlertsManagement/alerts" +
        "?api-version=2019-03-01&targetResource=$target&timeRange=30d&pageCount=100"
    $alerts = Invoke-OrderFlowRequest $State $uri
    if (-not $alerts.ContainsKey('value') -or $alerts['nextLink']) { throw 'Alert discovery incomplete; no fault admission.' }
    foreach ($alert in $alerts.value) {
        $essential = $alert.properties.essentials
        if ($essential.alertRule -ieq $State.outputs.alertId -and $essential.monitorCondition -cne 'Resolved') {
            throw 'The owned availability alert has not naturally cleared. Wait before fault admission.'
        }
    }
}

function Assert-OrderFlowSreSettled {
    param([hashtable]$State, [string]$Endpoint)
    if (-not $Endpoint) { $Endpoint = Get-OrderFlowSreConnection $State }
    $threads = Get-OrderFlowList (Invoke-OrderFlowSre $State $Endpoint '/api/v1/threads')
    foreach ($thread in $threads) {
        $id = ([guid]$thread.id).ToString()
        $messages = Invoke-OrderFlowSre $State $Endpoint "/api/v1/threads/$id/messages"
        if ($messages.state -cne 'Idle' -or -not $messages.ContainsKey('value') -or
            @($messages.value | Where-Object {
                ($_['approval'] -and $_.approval.status -cnotin @('Approved', 'Rejected', 'Expired')) -or
                ($_['azCliExecution'] -and $_.azCliExecution.status -cnotin @('Completed', 'Failed'))
            }).Count) {
            throw 'SRE has an active thread or pending action. Reject pending cards and settle the thread first.'
        }
        $permissions = Invoke-OrderFlowSre $State $Endpoint "/api/v2/threads/$id/permissions"
        if (@($permissions.allow).Count) { throw 'Thread-level allow overrides native approval; fault admission is blocked.' }
    }
}
