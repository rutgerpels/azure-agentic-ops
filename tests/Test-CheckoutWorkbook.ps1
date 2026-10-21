#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$compiled = & bicep build (Join-Path $repository 'infra\checkout\main.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Checkout Bicep compilation failed.' }
$template = $compiled -join "`n" | ConvertFrom-Json -AsHashtable
Assert-Test ($template.parameters.alertsOnly.type -ceq 'bool' -and
    $template.parameters.alertsOnly.defaultValue -eq $false) 'Existing deployments must retain agent mode by default.'
$estate = @($template.resources | Where-Object { $_.name -ceq 'checkout-estate' })[0]
Assert-Test ($estate.properties.parameters.alertsOnly.value -ceq "[parameters('alertsOnly')]") `
    'The subscription deployment must propagate alerts-only to the estate.'
foreach ($name in @('checkout-oba-reader-', 'checkout-sre-monitoring-', 'checkout-monitor-settings-')) {
    $resource = @($template.resources | Where-Object { $_.name.Contains($name) })[0]
    Assert-Test ($resource.condition.Contains("not(parameters('alertsOnly'))")) `
        "$name must not create subscription configuration or grants in alerts-only mode."
}
$estateTemplate = $estate.properties.template
$agentResources = @($estateTemplate.resources | Where-Object {
    $_.type -like 'Microsoft.Monitor/*' -or $_.type -ceq 'Microsoft.App/agents' -or
    $_.type -ceq 'Microsoft.ManagedIdentity/userAssignedIdentities' -or
    $_.type -ceq 'Microsoft.Authorization/roleAssignments'
})
Assert-Test ($agentResources.Count -eq 14) 'Every agent, agent identity and grant must be covered by the condition checks.'
foreach ($resource in $agentResources) {
    Assert-Test ($resource.condition -ceq "[not(parameters('alertsOnly'))]") `
        "$($resource.name) must be absent in alerts-only mode."
}
$alert = @($estateTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.Insights/scheduledQueryRules' })[0]
Assert-Test (-not $alert.ContainsKey('condition') -and $alert.properties.enabled -eq $true) `
    'Latency alerts must remain enabled in both modes.'
$actionGroup = @($estateTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.Insights/actionGroups' })[0]
Assert-Test ($actionGroup.properties.enabled -eq $true -and
    @($actionGroup.properties.emailReceivers).Count -eq 1 -and $actionGroup.properties.Keys.Count -eq 3) `
    'The action group must retain email notifications without automation receivers.'
$dashboard = @($estateTemplate.resources | Where-Object { $_.name -ceq 'checkout-workbook' })[0]
Assert-Test (-not $dashboard.ContainsKey('condition')) 'The workbook must deploy in both modes.'
$workbookTemplate = $dashboard.properties.template
$workbook = $workbookTemplate.resources[0]
Assert-Test ($workbook.type -ceq 'Microsoft.Insights/workbooks' -and $workbook.kind -ceq 'shared') `
    'The workbook must be a persistent shared resource, deleted with the estate.'
Assert-Test ($workbook.properties.sourceId -ceq "[parameters('workspaceId')]") `
    'Workbook queries must bind to the deployed workspace, never a live hardcoded ID.'
$variables = $workbookTemplate.variables
Assert-Test ($variables.requests.Contains('Name == "POST /checkout"') -and
    $variables.requests.Contains('Properties["retail.country"]') -and
    $variables.requests.Contains('country in ("BE", "NL")')) 'Charts must use bounded checkout country telemetry.'
$panels = @{}
foreach ($panel in $variables.panels) {
    $panels[$panel.name] = $panel.query
    Assert-Test ($panel.query.Contains("variables('requests')") -and $panel.query -notmatch '\$\{requests\}') `
        'Every chart must resolve the shared checkout query rather than interpolate a raw multiline string.'
    Assert-Test ($panel.query.Contains('bin(TimeGenerated, 1m)')) 'Every chart must show time-bucketed telemetry.'
}
Assert-Test ($panels.Count -eq 4) 'Expected latency, dependency, success and volume charts.'
Assert-Test ($panels['checkout-latency'].Contains('Success == true') -and
    $panels['checkout-latency'].Contains('percentile(DurationMs, 95)') -and
    $panels['checkout-latency'].Contains('samples >= 5')) 'Latency must match successful-request alert evidence with sample gating.'
Assert-Test ($panels['price-dependency'].Contains('distinct OperationId, country') -and
    $panels['price-dependency'].Contains('join kind=inner checkouts on OperationId') -and
    $panels['price-dependency'].Contains('"erp-price-service", "legacy-price-gateway"')) `
    'Dependency country must come from a deduplicated checkout operation join with known targets.'
Assert-Test ($panels['checkout-success'].Contains('100.0 * successes / samples') -and
    $panels['checkout-success'].Contains('real(null)')) 'Thin success samples must not produce a healthy-looking rate.'
Assert-Test ($workbook.properties.serializedData.Contains('datatable(country:string) ["BE", "NL"]') -and
    $workbook.properties.serializedData.Contains('join kind=leftouter recent') -and
    $workbook.properties.serializedData.Contains('UNKNOWN / insufficient or stale data')) `
    'Missing countries must remain visible as unknown in the freshness table.'
$chart = $variables.copy[0].input.content
Assert-Test ($chart.visualization -ceq 'timechart' -and $chart.timeContext.durationMs -eq 3600000 -and
    $chart.resources[0] -ceq "[parameters('workspaceId')]") 'Charts must bind to the workspace with a one-hour window.'
Assert-Test ($template.outputs.workbookId.value.Contains("outputs.workbookId.value")) 'Lifecycle outputs must expose the workbook.'
[pscustomobject]@{ checks = $script:checks; result = 'Passed (compiled Bicep and workbook contracts; no Azure deployment)' }
