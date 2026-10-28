#Requires -Version 7.2
function Get-CheckoutReadTools {
    <# Selectable built-in read tools; names verified against the SRE system-tool catalog. #>
    return @('GetArmResourceAsJson', 'GetAzCliHelp', 'GetMetricTimeSeriesElementsForAzureResource',
        'ListAvailableMetrics', 'RunAzCliReadCommands')
}

function Get-CheckoutReadInstruction {
    param([Parameter(Mandatory)][hashtable]$Outputs, [switch]$WithServiceLogs)
    $text = Get-Content -LiteralPath (Join-Path $repository 'docs\agent-context\runbooks\checkout-investigation-reads.md') -Raw
    $text = $text.Replace("`r`n", "`n")
    $tables = @('AppRequests', 'AppDependencies', 'AppTraces')
    if ($WithServiceLogs) { $tables += 'Syslog' }
    $values = @{
        webAppId = "/subscriptions/$subscription/resourceGroups/$groupName/providers/Microsoft.Web/sites/$($Outputs.webAppName)"
        workspaceCustomerId = $Outputs.workspaceCustomerId
        schemaTables = ($tables | ForEach-Object { "``$_``" }) -join ', '
    }
    foreach ($key in $values.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$key])) { throw "Read guidance is missing $key." }
        $text = $text.Replace("{{$key}}", [string]$values[$key])
    }
    if ($text -match '\{\{[a-zA-Z]+\}\}') { throw 'Read guidance has unresolved configuration.' }
    return $text.Trim()
}

function Resolve-CheckoutAlertsOnlyMode {
    param([hashtable]$Previous, [switch]$Requested, [switch]$WithArc)
    if ($Previous -and $Requested -and $Previous['alertsOnly'] -ne $true) {
        throw 'Alerts-only mode requires a fresh deployment. Run Down on the agent environment first; incremental deployment does not remove agents.'
    }
    $enabled = $Requested.IsPresent -or ($Previous -and $Previous['alertsOnly'] -eq $true)
    if ($enabled -and ($WithArc -or ($Previous -and $Previous.enableArc))) {
        throw 'Alerts-only mode supports the latency scenario without -WithArc.'
    }
    return [bool]$enabled
}

function Assert-CheckoutAgentMode {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State['alertsOnly'] -eq $true) {
        throw 'SRE configuration and requests are disabled in alerts-only mode.'
    }
}

function Assert-CheckoutAlertsOnlyIsolation {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State.enableArc -or $State.ownsMonitorSettings -or $State.outputs['agentId'] -or
        $State.outputs['observabilityAgentId'] -or $State.outputs['srePrincipalId']) {
        throw 'Alerts-only deployment has unexpected agent or Arc bindings.'
    }
    $resources = @(Invoke-Az @('resource', 'list', '--resource-group', $groupName))
    if (@($resources | Where-Object { $_.type -in @('Microsoft.App/agents', 'Microsoft.Monitor/observabilityAgents') }).Count) {
        throw 'An autonomous agent exists in the alerts-only resource group.'
    }
    $alert = Invoke-Az @('resource', 'show', '--ids', $State.outputs.alertRuleId)
    if ((@($alert.properties.scopes) -join ',') -ine $State.outputs.workspaceId -or
        (@($alert.properties.actions.actionGroups) -join ',') -ine $State.outputs.actionGroupId) {
        throw 'Alerts-only alert scope or action group drifted.'
    }
    $group = Invoke-Az @('resource', 'show', '--ids', $State.outputs.actionGroupId)
    if (-not $group.properties.enabled -or @($group.properties.emailReceivers).Count -eq 0) {
        throw 'Alerts-only email notifications are missing or disabled.'
    }
    foreach ($property in $group.properties.Keys) {
        if ($property -like '*Receivers' -and $property -cne 'emailReceivers' -and @($group.properties[$property]).Count) {
            throw 'Alerts-only action group has a non-email receiver.'
        }
    }
    if (-not $State.outputs['workbookId']) { throw 'Checkout workbook output is missing. Run Up to deploy it.' }
    $workbook = Invoke-Az @('resource', 'show', '--ids', $State.outputs.workbookId, '--api-version', '2023-06-01')
    if ($workbook.properties.sourceId -ine $State.outputs.workspaceId -or
        $workbook.tags.ownerToken -cne $State.ownerToken) {
        throw 'Checkout workbook workspace or ownership drifted.'
    }
}

function Get-CheckoutApprovalPolicy {
    <# GitHub follow-up tools write to a public repository, so each call needs human approval. #>
    param([string[]]$IssueTools = @())
    return @{ permissions = @{ allow = @()
        ask = @(@('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)') + @($IssueTools | Where-Object { $_ }))
        deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
}

function Assert-CheckoutApprovalPolicy {
    param([Parameter(Mandatory)][hashtable]$Settings, [string[]]$IssueTools = @())
    $expected = Get-CheckoutApprovalPolicy -IssueTools $IssueTools
    foreach ($kind in @('allow', 'ask', 'deny')) {
        $actual = $Settings['permissions'][$kind]
        if ($actual -isnot [array] -or
            (($actual | Sort-Object -CaseSensitive) -join "`n") -cne
            (($expected.permissions[$kind] | Sort-Object -CaseSensitive) -join "`n")) {
            throw 'SRE approval policy is missing or drifted; no fault admission.'
        }
    }
}

function Set-CheckoutApprovalPolicy {
    param([Parameter(Mandatory)][hashtable]$Connection, [string[]]$IssueTools = @())
    $response = Invoke-SreRequest $Connection GET '/api/v2/agent/settings/global' -RawResponse
    $settings = $response.Content | ConvertFrom-Json -AsHashtable
    $expected = Get-CheckoutApprovalPolicy -IssueTools $IssueTools
    $matches = $true
    try { Assert-CheckoutApprovalPolicy $settings -IssueTools $IssueTools } catch { $matches = $false }
    if ($matches) { return }
    $etag = @($response.Headers['ETag'])[0]
    if (-not $etag) {
        if (-not $settings.ContainsKey('permissions') -or
            @($settings.permissions.allow).Count -or @($settings.permissions.ask).Count -or
            @($settings.permissions.deny).Count) {
            throw 'Nonempty SRE policy has no ETag; refusing an unconditional overwrite.'
        }
        $etag = '*'
    }
    $null = Invoke-SreRequest $Connection PUT '/api/v2/agent/settings/global' $expected -IfMatch $etag
    Assert-CheckoutApprovalPolicy (Invoke-SreRequest $Connection GET '/api/v2/agent/settings/global') -IssueTools $IssueTools
}

function Assert-CheckoutIncidentsSettled {
    param([Parameter(Mandatory)][hashtable]$State,
        [hashtable]$Connection,
        [switch]$AllowFired)
    $target = [uri]::EscapeDataString($State.outputs.workspaceId)
    $uri = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.AlertsManagement/alerts" +
        "?api-version=2019-03-01&targetResource=$target&timeRange=30d&pageCount=100"
    $alerts = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri
    if (-not $alerts.ContainsKey('value') -or $alerts['nextLink']) {
        throw 'Checkout alert discovery is incomplete; incident admission is blocked.'
    }
    $rules = @($State.outputs.alertRuleId, $State.outputs['serviceAlertRuleId'])
    foreach ($alert in $alerts.value) {
        $essential = $alert.properties.essentials
        if ($essential.targetResource -ine $State.outputs.workspaceId -or
            $essential.alertRule -notin $rules) { continue }
        if ([DateTimeOffset]$essential.startDateTime -lt [DateTimeOffset]$State.createdAtUtc) { continue }
        if (-not $AllowFired -and $essential.monitorCondition -cne 'Resolved') {
            throw 'A checkout alert has not resolved. Wait for natural clearance before the next fault.'
        }
        if ($State['alertsOnly'] -eq $true) { continue }
        if (-not $Connection) { throw 'An SRE connection is required to check agent incidents.' }
        $id = [guid]::Parse(($alert.id -split '/')[-1]).ToString()
        $incident = Invoke-SreRequest $Connection GET "/api/v2/incidentManagement/incidents?incidentId=$id" -AllowMissing
        if (-not $incident) { continue }
        if ($incident.id -ine $id -or $incident.alertId -ine $alert.id -or
            $incident.targetResourceId -ine $State.outputs.workspaceId -or
            $incident.alertRuleResourceId -ine $essential.alertRule -or -not $incident['threadId']) {
            throw 'Checkout incident linkage is incomplete or inconsistent.'
        }
        $threadId = [guid]::Parse($incident.threadId).ToString()
        $thread = Invoke-SreRequest $Connection GET "/api/v1/threads/$threadId/messages"
        if ($thread.state -cne 'Idle' -or -not $thread.ContainsKey('value') -or
            @($thread.value | Where-Object { $_['approval'] -and
                $_.approval.status -cnotin @('Approved', 'Rejected', 'Expired') }).Count -or
            @($thread.value | Where-Object { $_['azCliExecution'] -and
                $_.azCliExecution.status -cnotin @('Completed', 'Failed') }).Count) {
            throw 'SRE is investigating or has an unsettled action. Deny pending cards and wait before reset/reuse.'
        }
    }
}
