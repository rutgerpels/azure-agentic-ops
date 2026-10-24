#Requires -Version 7.2
function Install-CheckoutServiceController {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State.pendingArcCommand) { throw 'An Arc command is unsettled. Use ObserveArc; do not submit another.' }
    if ($State.activeFault) { throw 'Cannot change preparation during an active fault.' }
    if ($State['controllerInstalled'] -eq $true) { return }
    $names = @('service_control.py', 'retailtx-price-primary.service',
        'retailtx-checkout-boot.service', 'retailtx-checkout-observer.service',
        'retailtx-checkout-observer.timer')
    $files = @{}
    foreach ($name in $names) {
        $content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r`n", "`n")
        $files[$name] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    }
    $payload = ConvertTo-RetailGuestPayload @{
        files = $files; ownerToken = $State.ownerToken; checkoutUrl = $State.outputs.webAppUrl
        actionPrincipalId = $State.outputs.srePrincipalId
    }
    $installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'install_controller.py') -Raw
    $script = @('set -eu', "python3 - '$payload' <<'PY'", $installer, 'PY') -join "`n"
    $view = Invoke-CheckoutArcCommand $State -Operation 'install-controller' -Script $script
    return $view
}

function Get-CheckoutServiceObservation {
    param([Parameter(Mandatory)][hashtable]$State)
    $query = "Syslog | where TimeGenerated > ago(10m) and _ResourceId =~ '$($State.outputs.arcMachineId)' " +
        "| where ProcessName == 'RetailTxCheckout' | extend r = parse_json(SyslogMessage) " +
        "| where tostring(r.ownerToken) == '$($State.ownerToken)' and tostring(r.event) == 'checkout-service-observation' " +
        "| extend observed = todatetime(r.observedAtUtc) | top 1 by observed desc | project receipt=tostring(r)"
    $result = Invoke-TokenRequest -Resource 'https://api.loganalytics.io' -Method POST `
        -Uri "https://api.loganalytics.io/v1/workspaces/$($State.outputs.workspaceCustomerId)/query" `
        -Body @{ query = $query }
    if ($result.tables[0].rows.Count -ne 1) { throw 'No fresh Arc price-service observation.' }
    $receipt = $result.tables[0].rows[0][0] | ConvertFrom-Json -AsHashtable
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$receipt.observedAtUtc).TotalSeconds
    if ($receipt.schemaVersion -ne 1 -or $receipt.active -isnot [bool] -or $receipt.healthy -isnot [bool] -or
        -not $receipt.ContainsKey('marker') -or
        $age -gt 180 -or $age -lt -30 -or $receipt.ownerToken -cne $State.ownerToken -or
        $receipt.service -cne 'retailtx-price-primary.service') {
        throw 'Arc service evidence is stale or does not match this checkout host.'
    }
    return $receipt
}

function Invoke-CheckoutServiceAction {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Request)
    $json = $Request | ConvertTo-Json -Compress
    if ($json.Contains("'")) { throw 'Unexpected character in fixed controller request.' }
    Invoke-CheckoutArcCommand $State -Operation "service-$($Request.action)" `
        -Script "python3 /opt/retailtx-checkout/service_control.py '$json'"
}

function Get-CheckoutServiceInstruction {
    param([Parameter(Mandatory)][hashtable]$State)
    $text = Get-Content -LiteralPath (Join-Path $repository 'docs\agent-context\runbooks\checkout-service.md') -Raw
    $values = @{
        environmentName = $EnvironmentName; subscriptionId = $subscription
        resourceGroupName = $groupName; location = $Location
        webAppName = $State.outputs.webAppName; arcMachineName = $State.outputs.arcMachineName
        arcMachineId = $State.outputs.arcMachineId; workspaceCustomerId = $State.outputs.workspaceCustomerId
        ownerToken = $State.ownerToken; actionPrincipalId = $State.outputs.srePrincipalId
    }
    foreach ($key in $values.Keys) { $text = $text.Replace("{{$key}}", [string]$values[$key]) }
    if ($text -match '\{\{[a-zA-Z]+\}\}') { throw 'Service investigator has unresolved configuration.' }
    return $text
}
