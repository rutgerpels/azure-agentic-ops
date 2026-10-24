#Requires -Version 7.2
function Get-CheckoutRouteSettings {
    param([hashtable]$State)
    $rows = @(Invoke-Az @('webapp', 'config', 'appsettings', 'list', '--resource-group', $groupName,
        '--name', $State.outputs.webAppName, '--query',
        "[?name=='PRICE_ROUTE_BE' || name=='PRICE_ROUTE_NL' || name=='ROUTE_CHANGE_REF'].{name:name,value:value}"))
    $settings = @{}
    foreach ($row in $rows) {
        if ($settings.ContainsKey($row.name)) { throw 'Duplicate checkout route setting.' }
        $settings[$row.name] = $row.value
    }
    return $settings
}

function Get-CheckoutRecoveryBoundary {
    param([hashtable]$State, [hashtable]$Settings, $Routes, [hashtable]$Service)
    $fault = $State.activeFault
    if ($fault.phase -notin @('injected', 'verify-recovery')) {
        throw 'Fault admission outcome is unsettled; use its exact Undo before reuse.'
    }
    if ($Settings['PRICE_ROUTE_BE'] -cne 'primary' -or $Settings['PRICE_ROUTE_NL'] -cne 'primary' -or
        -not $Routes -or $Routes.BE -cne 'primary' -or $Routes.NL -cne 'primary') {
        throw 'Recovery is not confirmed by both ARM settings and the running application.'
    }
    if ($fault.scenario -eq 'service') {
        if (-not $Service -or -not $Service.active -or -not $Service.healthy -or
            -not $Service.marker -or $Service.marker.phase -cne 'recovered' -or
            $Service.marker.runId -cne $fault.runId -or $Service.marker.actor -cne $fault.actor -or
            -not $Service.marker['recoveredAtUtc']) {
            throw 'No same-run service recovery timestamp is available.'
        }
        $boundary = [DateTimeOffset]$Service.marker.recoveredAtUtc
    } else {
        if (($fault.phase -eq 'injected' -and -not $fault['injectionConfirmedAtUtc']) -or
            ($Settings['ROUTE_CHANGE_REF'] -cne $fault.changeRef -and
                -not ($fault.phase -eq 'verify-recovery' -and $Settings['ROUTE_CHANGE_REF'] -ceq 'baseline'))) {
            throw 'The observed route rollback is not bound to this latency fault.'
        }
        if (-not $fault['recoveryObservedAtUtc']) {
            $fault.recoveryObservedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-RetailState $State $statePath
        }
        $boundary = [DateTimeOffset]$fault.recoveryObservedAtUtc
    }
    if ($boundary -lt [DateTimeOffset]$fault.requestedAt -or $boundary -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Recovery timestamp predates the current fault or is future-dated.'
    }
    return $boundary
}

function Assert-CheckoutFaultSelection {
    param([Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('latency', 'service')][string]$Selected,
        [switch]$Undo)
    if ($Selected -eq 'service' -and -not $State.enableArc) {
        throw 'Service faults require a deployment created with -WithArc.'
    }
    if ($State.pendingArcCommand) { throw 'An Arc command is unsettled. ObserveArc before another action.' }
    if ($State.activeFault) {
        if (-not $Undo) { throw "A $($State.activeFault.scenario) fault is active or pending verification. Fix it and run Ready first." }
        if ($State.activeFault.scenario -cne $Selected) {
            throw "Undo must select the active $($State.activeFault.scenario) scenario."
        }
    }
}

function Invoke-CheckoutFault {
    param([switch]$Undo)
    $state = Get-CheckoutState
    if ($state.schemaVersion -ne 2) { throw 'Use the matching legacy lifecycle to undo this old deployment.' }
    if (-not $Undo) {
        $ready = Invoke-Ready
        if (-not $ready.ready) { throw "Fault admission refused: $($ready.blockers -join '; ')" }
        $state = Get-CheckoutState
    }
    Assert-CheckoutFaultSelection $state $Scenario -Undo:$Undo
    if (-not $PSCmdlet.ShouldProcess($groupName, "$(if ($Undo) { 'Undo' } else { 'Inject' }) $Scenario fault")) {
        return
    }
    if ($Undo -and -not $state.activeFault) {
        $ready = Invoke-Ready
        if (-not $ready.ready) { throw 'No owned active fault is recorded, but baseline is unhealthy. Inspect rather than inventing a repair.' }
        return [pscustomobject]@{ scenario = $Scenario; status = 'Already healthy; no write performed.' }
    }
    if ($Undo) {
        if ($state['alertsOnly'] -eq $true) {
            Assert-CheckoutAlertsOnlyIsolation $state
            Assert-CheckoutIncidentsSettled $state -AllowFired
        } else { Assert-CheckoutIncidentsSettled $state (Get-SreConnection $state) -AllowFired }
    }
    $account = Invoke-Az @('account', 'show')
    if ($account.user.type -cne 'user') { throw 'A signed-in human operator is required for fault/reset commands.' }
    $credentials = Invoke-Az @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
    try { $actor = Get-RetailTokenActor -AccessToken $credentials.accessToken -TenantId $state.tenantId }
    finally { $credentials = $null }
    if (-not $Undo) {
        $runId = [guid]::NewGuid().ToString()
        $state.activeFault = @{ scenario = $Scenario; runId = $runId; actor = $actor
            phase = 'injecting'; requestedAt = [DateTimeOffset]::UtcNow.ToString('o')
            changeRef = 'CHG-' + $runId.Replace('-', '').Substring(0, 12) }
        Save-RetailState $state $statePath
    }
    $fault = $state.activeFault
    if ($Scenario -eq 'service') {
        $request = @{ action = $(if ($Undo) { 'reset' } else { 'fault' })
            ownerToken = $state.ownerToken; runId = $fault.runId; actor = $actor }
        if (-not $Undo) { $request.startBeforeUtc = [DateTimeOffset]::UtcNow.AddSeconds(150).ToString('o') }
        $null = Invoke-CheckoutServiceAction $state $request
    } else {
        $settings = if ($Undo) { @('PRICE_ROUTE_BE=primary', 'ROUTE_CHANGE_REF=baseline') }
        else { @('PRICE_ROUTE_BE=legacy', "ROUTE_CHANGE_REF=$($fault.changeRef)") }
        $null = Invoke-Az (@('webapp', 'config', 'appsettings', 'set', '--resource-group', $groupName,
                '--name', $state.outputs.webAppName, '--settings') + $settings) -TimeoutSeconds 180
        $observed = Get-CheckoutRouteSettings $state
        $expectedRoute = if ($Undo) { 'primary' } else { 'legacy' }
        $expectedChange = if ($Undo) { 'baseline' } else { $fault.changeRef }
        if ($observed['PRICE_ROUTE_BE'] -cne $expectedRoute -or $observed['PRICE_ROUTE_NL'] -cne 'primary' -or
            $observed['ROUTE_CHANGE_REF'] -cne $expectedChange) {
            throw 'The route write is not yet confirmed. Retain intent; do not replay injection.'
        }
        if (-not $Undo) { $fault.injectionConfirmedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    }
    $fault.phase = if ($Undo) { 'verify-recovery' } else { 'injected' }
    Save-RetailState $state $statePath
    [pscustomobject]@{ scenario = $Scenario; runId = $fault.runId; phase = $fault.phase
        changeRef = $fault.changeRef; next = $(if ($Undo) { 'Wait for fresh healthy evidence, then Ready.' }
            elseif ($state['alertsOnly'] -eq $true) { 'Show the workbook and Azure Monitor alert; reset manually with Undo -Scenario latency. No agent is configured.' }
            else { 'Use the real checkout and wait for the matching SRE incident. No other fault was started.' }) }
}
