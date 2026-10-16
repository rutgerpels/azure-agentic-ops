#Requires -Version 7.2
function Get-CheckoutApprovalPolicy {
    return @{ permissions = @{ allow = @()
        ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
        deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
}

function Assert-CheckoutApprovalPolicy {
    param([Parameter(Mandatory)][hashtable]$Settings)
    $expected = Get-CheckoutApprovalPolicy
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
    param([Parameter(Mandatory)][hashtable]$Connection)
    $response = Invoke-SreRequest $Connection GET '/api/v2/agent/settings/global' -RawResponse
    $settings = $response.Content | ConvertFrom-Json -AsHashtable
    $expected = Get-CheckoutApprovalPolicy
    $matches = $true
    try { Assert-CheckoutApprovalPolicy $settings } catch { $matches = $false }
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
    Assert-CheckoutApprovalPolicy (Invoke-SreRequest $Connection GET '/api/v2/agent/settings/global')
}

function Assert-CheckoutIncidentsSettled {
    param([Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Connection,
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
