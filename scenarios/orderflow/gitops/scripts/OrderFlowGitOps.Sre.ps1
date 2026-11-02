#Requires -Version 7.2
<#
.SYNOPSIS
SRE Agent data-plane configuration for OrderFlow GitOps (dot-sourced by the lifecycle script).
.DESCRIPTION
Modeled on option-1 OrderFlow.Sre.ps1 (same endpoints, audience, endpoint validation and
journaled observe-not-replay writes). Differences: the investigator only reads Azure and
uses provided GitHub issue + Copilot-assign tools under native Ask approval; Azure writes,
shells and Python are denied; no Azure repair role exists.
#>
$script:sreAgentName = 'orderflow-gitops-investigator'
$script:sreFilterName = 'orderflow-gitops-response'
$script:sreReaderRoles = @(
    'acdd72a7-3385-48ef-bd42-f606fba81ae7', # Reader
    '43d0d8ad-25c7-4714-9337-8ba259a9fe05', # Monitoring Reader
    '73c42c96-874c-492b-b04d-ab87d138a893'  # Log Analytics Reader
)

function Assert-OrderFlowGitOpsSreTool {
    <#
    .SYNOPSIS
    Validate provided connector tool names; reject anything that can write code, branches, PRs or files.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IssueTools, [Parameter(Mandatory)][AllowEmptyString()][string]$AssignTool)
    if (-not @($IssueTools).Count) { throw 'SreIssueTools must list the GitHub issue search/create tool names from the SRE connector.' }
    if (-not $AssignTool) { throw 'SreAssignTool must name the Copilot-assign tool from the SRE connector.' }
    foreach ($tool in @($IssueTools) + $AssignTool) {
        if ($tool -cnotmatch '^[A-Za-z0-9_.:-]{1,128}$') { throw "Tool name '$tool' has unexpected characters." }
        $normalized = (($tool -creplace '([a-z0-9])([A-Z])', '$1_$2') -replace '[.:-]', '_').ToLowerInvariant()
        $words = @($normalized -split '_' | Where-Object { $_ })
        $forbidden = @('pr', 'prs', 'pull', 'pulls', 'merge', 'push', 'branch', 'branches', 'commit', 'commits', 'fork',
            'workflow', 'workflows', 'release', 'tag', 'tags', 'ref', 'refs', 'repository', 'repo')
        if (@($words | Where-Object { $_ -cin $forbidden }).Count -or $normalized -match 'pull_?request|pullrequest') {
            throw "Tool '$tool' looks like a PR/push/merge/branch tool; refusing to grant it to the SRE Agent."
        }
        if (@($words | Where-Object { $_ -cin @('file', 'files', 'content', 'contents', 'blob', 'tree') }).Count) {
            throw "Tool '$tool' looks like a repository file tool; refusing to grant it to the SRE Agent."
        }
    }
    foreach ($tool in $IssueTools) {
        if ($tool -cnotmatch '(?i)issue') { throw "Issue tool '$tool' does not look like an issue tool." }
    }
    if ($AssignTool -cnotmatch '(?i)assign') { throw "Assign tool '$AssignTool' does not look like an assignment tool." }
    if ($AssignTool -cin $IssueTools) { throw 'SreAssignTool must not also be listed in SreIssueTools.' }
}

function Get-OrderFlowGitOpsSrePolicy {
    <#
    .SYNOPSIS
    Expected agent-wide approval policy: GitHub issue/assign = Ask; Azure writes and shells = Deny.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    @{
        permissions = @{
            allow = @()
            ask = @(@($State.sre.issueTools) + $State.sre.assignTool)
            deny = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)', 'RunInTerminal', 'RunShellCommand', 'ExecutePythonCode')
        }
    }
}

function Test-OrderFlowGitOpsSrePolicy {
    <#
    .SYNOPSIS
    Order-insensitive exact comparison of allow/ask/deny lists.
    #>
    param($Actual, [Parameter(Mandatory)][hashtable]$Expected)
    if ($Actual -isnot [System.Collections.IDictionary] -or -not $Actual.Contains('permissions')) { return $false }
    foreach ($kind in @('allow', 'ask', 'deny')) {
        $value = $Actual.permissions[$kind]
        if ($null -ne $value -and $value -isnot [System.Collections.IList]) { return $false }
        if ((@($value | Sort-Object -CaseSensitive) -join "`n") -cne (@($Expected.permissions[$kind] | Sort-Object -CaseSensitive) -join "`n")) {
            return $false
        }
    }
    $true
}

function Get-OrderFlowGitOpsSreConnection {
    <#
    .SYNOPSIS
    Verify agent ownership, Review mode and action identity; return its validated endpoint.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $agentId = Get-OrderFlowGitOpsOutput $State 'sre' 'agentId'
    $agent = Invoke-OrderFlowGitOpsRequest $State "https://management.azure.com$($agentId)?api-version=2026-01-01"
    if ($agent.tags.ownerToken -cne $State.ownerToken -or
        $agent.properties.actionConfiguration.mode -cne 'Review' -or
        $agent.properties.actionConfiguration.identity -ine (Get-OrderFlowGitOpsOutput $State 'sre' 'sreIdentityId')) {
        throw 'SRE ownership, action identity or Review mode drifted.'
    }
    $endpoint = [uri]$agent.properties.agentEndpoint
    if ($endpoint.Scheme -cne 'https' -or $endpoint.UserInfo -or -not $endpoint.IsDefaultPort -or
        -not $endpoint.Host.EndsWith('.azuresre.ai') -or $endpoint.AbsolutePath -cne '/') {
        throw 'Unexpected SRE endpoint.'
    }
    $endpoint.AbsoluteUri.TrimEnd('/')
}

function Invoke-OrderFlowGitOpsSre {
    <#
    .SYNOPSIS
    Call the SRE data plane on a validated endpoint and /api/ path.
    #>
    param([hashtable]$State, [string]$Endpoint, [string]$Path, [string]$Method = 'GET',
        [hashtable]$Body, [switch]$Raw, [string]$IfMatch, [switch]$AllowMissing)
    if (-not $Path.StartsWith('/api/') -or $Path.Contains('..')) { throw 'Unexpected SRE path.' }
    Invoke-OrderFlowGitOpsRequest $State "$Endpoint$Path" -Audience 'https://azuresre.dev' `
        -Method $Method -Body $Body -Raw:$Raw -IfMatch $IfMatch -AllowMissing:$AllowMissing
}

function Test-OrderFlowGitOpsExpected {
    <#
    .SYNOPSIS
    True when every expected key/value is present in the actual object (exact for arrays and scalars).
    #>
    param($Actual, $Expected)
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.Contains($key) -or -not (Test-OrderFlowGitOpsExpected $Actual[$key] $Expected[$key])) { return $false }
        }
        return $true
    }
    if ($Expected -is [System.Collections.IList]) {
        if ($Actual -isnot [System.Collections.IList] -or $Actual.Count -ne $Expected.Count) { return $false }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            if (-not (Test-OrderFlowGitOpsExpected $Actual[$i] $Expected[$i])) { return $false }
        }
        return $true
    }
    $Actual -ceq $Expected
}

function Get-OrderFlowGitOpsSreList {
    <#
    .SYNOPSIS
    Accept only complete list responses.
    #>
    param($Response)
    if ($Response -is [System.Collections.IList]) { return , @($Response) }
    if ($Response -is [System.Collections.IDictionary] -and $Response.Contains('value') -and
        $Response.value -is [System.Collections.IList] -and -not $Response['nextLink'] -and -not $Response['continuationToken']) {
        return , @($Response.value)
    }
    throw 'SRE list response is incomplete or unsupported; inspect the provider schema, do not assume empty.'
}

function Invoke-OrderFlowGitOpsSreWrite {
    <#
    .SYNOPSIS
    Journaled SRE configuration PUT: skip when already observed, observe after; never replay.
    #>
    param([hashtable]$State, [string]$StatePath, [string]$Endpoint, [string]$Path, [hashtable]$Payload, [string]$IfMatch)
    $current = Invoke-OrderFlowGitOpsSre $State $Endpoint $Path -AllowMissing
    if (Test-OrderFlowGitOpsExpected $current $Payload) { return }
    Set-OrderFlowGitOpsPending $State $StatePath 'sre-config' @{ path = $Path; expected = $Payload }
    $null = Invoke-OrderFlowGitOpsSre $State $Endpoint $Path PUT $Payload -IfMatch $IfMatch
    Complete-OrderFlowGitOpsSreObservation $State $StatePath $Endpoint
}

function Complete-OrderFlowGitOpsSreObservation {
    <#
    .SYNOPSIS
    Settle a pending sre-config stage only when the expected configuration is observed.
    #>
    param([hashtable]$State, [string]$StatePath, [string]$Endpoint)
    if (-not $Endpoint) { $Endpoint = Get-OrderFlowGitOpsSreConnection $State }
    $stage = $State.pendingOperation.detail
    $current = Invoke-OrderFlowGitOpsSre $State $Endpoint $stage.path -AllowMissing
    if (-not (Test-OrderFlowGitOpsExpected $current $stage.expected)) {
        throw 'Original SRE configuration stage not observed. Keep pending state; do not replay the PUT.'
    }
    Clear-OrderFlowGitOpsPending $State $StatePath 'sre-config observed'
}

function Get-OrderFlowGitOpsAlertTarget {
    <#
    .SYNOPSIS
    Read the owned prod alert rule to derive its name and monitored scope.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $alertId = Get-OrderFlowGitOpsOutput $State 'prod' 'alertId'
    $rule = Invoke-OrderFlowGitOpsRequest $State "https://management.azure.com$($alertId)?api-version=2023-12-01"
    $scope = @($rule.properties.scopes)[0]
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.resourceGroups.prod)/"
    if (-not $scope -or -not ([string]$scope).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Prod alert scope is outside the owned prod resource group.'
    }
    $type = (([string]$scope -split '/providers/')[-1] -split '/')[0..1] -join '/'
    @{ name = [string]$rule.name; scope = [string]$scope; scopeType = $type; id = $alertId }
}

function Get-OrderFlowGitOpsInvestigator {
    <#
    .SYNOPSIS
    Investigator subagent: runbook instructions with resolved placeholders; read-only Azure + issue/assign tools.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Alert)
    $instruction = Get-Content -LiteralPath (Get-OrderFlowGitOpsPath 'Runbook') -Raw
    $tokens = @{
        repository = $State.gitHubRepository
        subscription = $State.subscriptionId
        prodResourceGroup = $State.resourceGroups.prod
        alertName = $Alert.name
        appInsightsName = (Get-OrderFlowGitOpsOutput $State 'prod' 'appInsightsName')
        nsgName = (Get-OrderFlowGitOpsOutput $State 'prod' 'nsgName')
        issueTools = (@($State.sre.issueTools) -join ', ')
        assignTool = $State.sre.assignTool
    }
    foreach ($key in $tokens.Keys) { $instruction = $instruction.Replace("{{$key}}", [string]$tokens[$key]) }
    if ($instruction -match '\{\{') { throw 'Unresolved SRE instruction token in docs/runbook.md.' }
    @{
        name = $script:sreAgentName
        properties = @{
            instructions = $instruction
            handoffDescription = 'Investigate OrderFlow GitOps prod dependency failures, file one GitHub issue and assign Copilot. No Azure writes.'
            handoffs = @(); enableVanillaMode = $true
            tools = @(@('GetArmResourceAsJson', 'GetAzCliHelp', 'RunAzCliReadCommands') + @($State.sre.issueTools) + $State.sre.assignTool)
        }
    }
}

function Get-OrderFlowGitOpsResponsePlan {
    <#
    .SYNOPSIS
    Review-mode incident filter for the owned prod alert only.
    #>
    param([Parameter(Mandatory)][hashtable]$Alert)
    @{
        name = $script:sreFilterName; type = 'IncidentFilter'
        properties = @{
            isEnabled = $true; agentMode = 'review'; handlingAgent = $script:sreAgentName
            titleContains = $Alert.name; mergeEnabled = $false
            azMonitorFilterSettings = @{ targetResourceType = $Alert.scopeType; targetResource = $Alert.scope }
        }
    }
}

function Assert-OrderFlowGitOpsNoRepairRole {
    <#
    .SYNOPSIS
    The SRE identities may hold only reader roles; any other assignment is drift.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $principal = Get-OrderFlowGitOpsOutput $State 'sre' 'srePrincipalId'
    $assignments = @(Invoke-OrderFlowGitOpsAzure $State @('role', 'assignment', 'list', '--assignee', $principal, '--all'))
    foreach ($assignment in ($assignments | Where-Object { $_ })) {
        $role = ([string]$assignment.roleDefinitionId -split '/')[-1]
        if ($role -inotin $script:sreReaderRoles) {
            throw 'SRE identity has a non-reader role assignment; option 2 never grants Azure repair rights.'
        }
    }
}

function Assert-OrderFlowGitOpsNoHook {
    <#
    .SYNOPSIS
    Hooks could override native approval; require none.
    #>
    param([hashtable]$State, [string]$Endpoint)
    $hooks = Get-OrderFlowGitOpsSreList (Invoke-OrderFlowGitOpsSre $State $Endpoint '/api/v2/extendedAgent/hooks')
    if ($hooks.Count) { throw 'Hooks may override native approval. Remove unexpected hooks through reviewed configuration first.' }
}

function Assert-OrderFlowGitOpsSreSettled {
    <#
    .SYNOPSIS
    No active SRE thread, pending approval card or thread-level allow override.
    #>
    param([hashtable]$State, [string]$Endpoint)
    $threads = Get-OrderFlowGitOpsSreList (Invoke-OrderFlowGitOpsSre $State $Endpoint '/api/v1/threads')
    foreach ($thread in $threads) {
        $id = ([guid]$thread.id).ToString()
        $messages = Invoke-OrderFlowGitOpsSre $State $Endpoint "/api/v1/threads/$id/messages"
        if ($messages.state -cne 'Idle' -or -not $messages.ContainsKey('value') -or
            @($messages.value | Where-Object {
                    ($_['approval'] -and $_.approval.status -cnotin @('Approved', 'Rejected', 'Expired')) -or
                    ($_['azCliExecution'] -and $_.azCliExecution.status -cnotin @('Completed', 'Failed'))
                }).Count) {
            throw 'SRE has an active thread or pending action. Reject pending cards and settle the thread first.'
        }
        $permissions = Invoke-OrderFlowGitOpsSre $State $Endpoint "/api/v2/threads/$id/permissions"
        if (@($permissions.allow).Count) { throw 'Thread-level allow overrides native approval; fault admission is blocked.' }
    }
}

function Set-OrderFlowGitOpsSre {
    <#
    .SYNOPSIS
    Configure policy, investigator and response plan with journaled observe-not-replay writes.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string[]]$IssueTools, [Parameter(Mandatory)][string]$AssignTool)
    Assert-OrderFlowGitOpsSreTool $IssueTools $AssignTool
    $State.sre = @{ attempted = $true; configured = $false; issueTools = @($IssueTools); assignTool = $AssignTool }
    Save-OrderFlowGitOpsState $State $StatePath 'sre configure start'
    $endpoint = Get-OrderFlowGitOpsSreConnection $State
    Assert-OrderFlowGitOpsNoRepairRole $State
    Assert-OrderFlowGitOpsNoHook $State $endpoint
    Assert-OrderFlowGitOpsSreSettled $State $endpoint
    $alert = Get-OrderFlowGitOpsAlertTarget $State
    $expectedPolicy = Get-OrderFlowGitOpsSrePolicy $State
    $response = Invoke-OrderFlowGitOpsSre $State $endpoint '/api/v2/agent/settings/global' -Raw
    $settings = if ($response.Content) { $response.Content | ConvertFrom-Json -AsHashtable } else { @{} }
    if (-not (Test-OrderFlowGitOpsSrePolicy $settings $expectedPolicy)) {
        $etag = @($response.Headers['ETag'])[0]
        if (-not $etag) {
            if ($settings.Contains('permissions') -and (@($settings.permissions.allow).Count -or
                    @($settings.permissions.ask).Count -or @($settings.permissions.deny).Count)) {
                throw 'Nonempty policy without ETag cannot be safely overwritten.'
            }
            $etag = '*'
        }
        Invoke-OrderFlowGitOpsSreWrite $State $StatePath $endpoint '/api/v2/agent/settings/global' $expectedPolicy -IfMatch $etag
    }
    Invoke-OrderFlowGitOpsSreWrite $State $StatePath $endpoint "/api/v2/extendedAgent/agents/$script:sreAgentName" (Get-OrderFlowGitOpsInvestigator $State $alert)
    Invoke-OrderFlowGitOpsSreWrite $State $StatePath $endpoint "/api/v2/incidentManagement/incidentFilters/$script:sreFilterName" (Get-OrderFlowGitOpsResponsePlan $alert)
    Assert-OrderFlowGitOpsSre $State -DuringConfiguration
    $State.sre.configured = $true
    $State.sre.verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-OrderFlowGitOpsState $State $StatePath 'sre configured'
}

function Assert-OrderFlowGitOpsSre {
    <#
    .SYNOPSIS
    Fresh verification of the exact SRE configuration (required before Fault when ConfigureSre was attempted).
    #>
    param([Parameter(Mandatory)][hashtable]$State, [switch]$DuringConfiguration)
    if (-not $DuringConfiguration -and -not $State.sre.configured) { throw 'ConfigureSre was attempted but not verified. Run ConfigureSre again.' }
    Assert-OrderFlowGitOpsSreTool @($State.sre.issueTools) $State.sre.assignTool
    $endpoint = Get-OrderFlowGitOpsSreConnection $State
    Assert-OrderFlowGitOpsNoRepairRole $State
    Assert-OrderFlowGitOpsNoHook $State $endpoint
    if (-not (Test-OrderFlowGitOpsSrePolicy (Invoke-OrderFlowGitOpsSre $State $endpoint '/api/v2/agent/settings/global') (Get-OrderFlowGitOpsSrePolicy $State))) {
        throw 'SRE approval policy drifted; refusing fault admission.'
    }
    $alert = Get-OrderFlowGitOpsAlertTarget $State
    $expected = Get-OrderFlowGitOpsInvestigator $State $alert
    $actual = Invoke-OrderFlowGitOpsSre $State $endpoint "/api/v2/extendedAgent/agents/$script:sreAgentName"
    if ($actual.properties.instructions -cne $expected.properties.instructions -or
        (@($actual.properties.tools) -join ',') -cne (@($expected.properties.tools) -join ',') -or
        @($actual.properties['handoffs']).Count -or
        ($actual.properties['hooks'] -and $actual.properties.hooks.Count) -or
        ($actual.properties['permissions'] -and @($actual.properties.permissions.allow).Count)) {
        throw 'Investigator instructions, tools, hooks or permission overrides drifted.'
    }
    $permissions = Invoke-OrderFlowGitOpsSre $State $endpoint "/api/v2/extendedAgent/$script:sreAgentName/permissions"
    if (-not $permissions -or -not $permissions.ContainsKey('allow') -or @($permissions.allow).Count) {
        throw 'Investigator permission overrides are missing/unsupported or unsafe.'
    }
    $plan = Invoke-OrderFlowGitOpsSre $State $endpoint "/api/v2/incidentManagement/incidentFilters/$script:sreFilterName"
    $expectedPlan = Get-OrderFlowGitOpsResponsePlan $alert
    if ($plan.properties.isEnabled -ne $true -or $plan.properties.agentMode -cne 'review' -or
        $plan.properties.handlingAgent -cne $script:sreAgentName -or $plan.properties.mergeEnabled -ne $false -or
        $plan.properties.titleContains -cne $expectedPlan.properties.titleContains -or
        $plan.properties.azMonitorFilterSettings.targetResource -ine $alert.scope) {
        throw 'Exact Review-mode response plan missing or drifted.'
    }
    $connectivity = Invoke-OrderFlowGitOpsSre $State $endpoint '/api/v2/incidentManagement/checkConnectivityDetailed'
    if ($connectivity.success -ne $true -or $connectivity.incidentType -cne 'AzMonitor') {
        throw 'Azure Monitor intake is not ready. Inspect native SRE setup; no fault is admitted.'
    }
    Assert-OrderFlowGitOpsSreSettled $State $endpoint
}
