#Requires -Version 7.2
<#
.SYNOPSIS
Lifecycle for the SRE Agent portal-learning environment (Belgium checkout latency).
.DESCRIPTION
Up deploys the checkout estate WITHOUT the SRE Agent, publishes the front end and writes
.azure\<env>\sre-portal-values.md with every value needed to configure the agent by hand in the
portal (see docs\sre-agent-portal-setup.md). Ready checks the estate without any agent checks.
Inject/Undo control the manual-lifetime latency fault. Down removes everything owned.
.PARAMETER Action
Up, Ready, Inject, Undo or Down.
.PARAMETER AlertEmail
Alert recipient for Up. Defaults to RETAILTX_ALERT_EMAIL. Never committed.
.EXAMPLE
./scripts/Invoke-CheckoutLearn.ps1 Up -SubscriptionId <guid> -AlertEmail ops@example.com
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Up', 'Ready', 'Inject', 'Undo', 'Down')][string]$Action,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'learn01',
    [string]$Location = 'swedencentral',
    [string]$AlertEmail = $env:RETAILTX_ALERT_EMAIL,
    [ValidateRange(1, 30)][int]$RetentionDays = 7
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName

$repository = Split-Path -Parent $PSScriptRoot
$subscription = $SubscriptionId.ToString()
$managedBy = 'invoke-checkoutlearn'
$groupName = "rg-retailtx-checkout-$EnvironmentName-$Location"
$deploymentName = "retailtx-checkout-$EnvironmentName"
$stateDirectory = Join-Path $repository ".azure\$EnvironmentName"
$statePath = Join-Path $stateDirectory 'learn-state.json'
$valuesPath = Join-Path $stateDirectory 'sre-portal-values.md'
$templatePath = Join-Path $repository 'docs\agent-context\checkout-learn-investigator.md'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 600)
    Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Get-LearnState {
    if (-not (Test-Path -LiteralPath $statePath)) { throw "No state for '$EnvironmentName'. Run Up first." }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
    if ($state.subscriptionId -ine $subscription -or $state.resourceGroupName -cne $groupName) {
        throw 'Saved state belongs to another subscription or environment.'
    }
    return $state
}

function Get-LearnRouteSetting {
    param([Parameter(Mandatory)][hashtable]$State)
    $rows = @(Invoke-Az @('webapp', 'config', 'appsettings', 'list', '--resource-group', $groupName,
            '--name', $State.outputs.webAppName, '--query',
            "[?name=='PRICE_ROUTE_BE' || name=='PRICE_ROUTE_NL' || name=='ROUTE_CHANGE_REF'].{name:name,value:value}"))
    $settings = @{}
    foreach ($row in $rows) { $settings[$row.name] = $row.value }
    return $settings
}

function Get-LearnLatency {
    param([Parameter(Mandatory)][hashtable]$State, [int]$Minutes = 5)
    $credentials = Invoke-Az @('account', 'get-access-token', '--resource', 'https://api.loganalytics.io')
    $token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
    $credentials = $null
    $query = "AppRequests | where TimeGenerated > ago($($Minutes)m) and Name == 'POST /checkout' " +
    "| extend country = tostring(Properties['retail.country']), route = tostring(Properties['retail.price_route']) " +
    "| summarize p95 = round(percentile(DurationMs, 95)), n = count(), failures = countif(Success == false), primaryCount = countif(route == 'primary') by country"
    try {
        $result = Invoke-RestMethod -Method Post -Authentication Bearer -Token $token -TimeoutSec 120 `
            -Uri "https://api.loganalytics.io/v1/workspaces/$($State.outputs.workspaceCustomerId)/query" `
            -ContentType 'application/json' -Body (@{ query = $query } | ConvertTo-Json -Compress)
    } finally { $token = $null }
    $table = $result.tables[0]
    $names = @($table.columns | ForEach-Object { $_.name })
    $rows = @{}
    foreach ($row in $table.rows) {
        $record = @{}
        for ($index = 0; $index -lt $names.Count; $index++) { $record[$names[$index]] = $row[$index] }
        $rows[$record.country] = $record
    }
    return $rows
}

function Publish-LearnFrontend {
    param([Parameter(Mandatory)][hashtable]$State)
    $package = Join-Path $stateDirectory 'checkout-frontend.zip'
    $sources = @('app.py', 'requirements.txt', 'static') | ForEach-Object { Join-Path $repository "app\checkout\frontend\$_" }
    Compress-Archive -Path $sources -DestinationPath $package -Force
    $null = Invoke-Az @('webapp', 'deploy', '--resource-group', $groupName, '--name', $State.outputs.webAppName,
        '--src-path', $package, '--type', 'zip') -TimeoutSeconds 1200
}

function Get-LearnInstruction {
    param([Parameter(Mandatory)][hashtable]$State)
    $values = @{
        ENVIRONMENT = $EnvironmentName; WEB_APP = $State.outputs.webAppName; RESOURCE_GROUP = $groupName
        VM = $State.outputs.vmName; APP_INSIGHTS = $State.outputs.appInsightsName
        WORKSPACE_ID = $State.outputs.workspaceId; WORKSPACE_GUID = $State.outputs.workspaceCustomerId
        SUBSCRIPTION = $subscription
    }
    $text = Get-Content -LiteralPath $templatePath -Raw
    foreach ($key in $values.Keys) { $text = $text.Replace("{{$key}}", [string]$values[$key]) }
    if ($text -match '\{\{[A-Z_]+\}\}') { throw 'Investigator template has an unresolved placeholder.' }
    return $text.TrimEnd()
}

function Write-LearnValues {
    param([Parameter(Mandatory)][hashtable]$State)
    $o = $State.outputs
    $instruction = Get-LearnInstruction $State
    $content = @"
# SRE Agent portal values for $EnvironmentName

Generated by Invoke-CheckoutLearn.ps1 Up. Local only (.azure is not committed).

| Item | Value |
|---|---|
| Subscription | $subscription |
| Resource group to monitor | $groupName |
| Location | $Location |
| Checkout URL | $($o.webAppUrl) |
| Web app | $($o.webAppName) |
| Log Analytics workspace | $($o.workspaceId) |
| Workspace customer ID (GUID) | $($o.workspaceCustomerId) |
| Application Insights | $($o.appInsightsName) |
| Latency alert rule (response plan "Title contains") | $($o.alertRuleName) |

Optional write permission for the agent identity (replace the principal with the agent's managed identity object ID):

``````powershell
az role assignment create --assignee-object-id <agent-identity-object-id> --assignee-principal-type ServicePrincipal ``
  --role "Website Contributor" --scope $($o.webAppId)
``````

Custom agent instructions (paste as is):

``````text
$instruction
``````
"@
    [IO.File]::WriteAllText($valuesPath, $content)
}

function Invoke-Up {
    if (-not $PSCmdlet.ShouldProcess($groupName, 'Deploy the SRE Agent learning environment')) { return }
    if (-not $AlertEmail -or $AlertEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw 'Provide -AlertEmail or RETAILTX_ALERT_EMAIL for the alert action group.'
    }
    $account = Invoke-Az @('account', 'show')
    $null = New-Item -ItemType Directory -Force -Path $stateDirectory
    $keyPath = Join-Path $stateDirectory 'dc1_ed25519'
    if (-not (Test-Path -LiteralPath "$keyPath.pub")) {
        & ssh-keygen -q -t ed25519 -N '' -C "retailtx-$EnvironmentName" -f $keyPath
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed.' }
    }
    $previous = if (Test-Path -LiteralPath $statePath) { Get-LearnState } else { $null }
    if (Invoke-Az @('group', 'exists', '--name', $groupName)) {
        $existingGroup = Invoke-Az @('group', 'show', '--name', $groupName)
        if (-not $previous -or $existingGroup.tags.ownerToken -cne $previous.ownerToken -or
            $existingGroup.tags.managedBy -cne $managedBy) {
            throw 'Existing resource group is not owned by this learning lifecycle; refusing adoption.'
        }
    }
    if ($previous -and $previous.activeFault) { throw 'Undo the active fault before redeploying.' }
    $state = if ($previous) { $previous } else { @{
        ownerToken = [guid]::NewGuid().ToString(); createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        activeFault = $false; outputs = @{}; subscriptionId = $subscription; tenantId = $account.tenantId
        environmentName = $EnvironmentName; resourceGroupName = $groupName
    } }
    Save-RetailState $state $statePath
    Write-Information 'Deploying Bicep without the SRE Agent (about 10 minutes)...' -InformationAction Continue
    $deployment = Invoke-Az @('deployment', 'sub', 'create', '--name', $deploymentName, '--location', $Location,
        '--template-file', (Join-Path $repository 'infra\checkout-learn\main.bicep'),
        '--parameters', "environmentName=$EnvironmentName", "location=$Location", "alertEmail=$AlertEmail",
        "adminPublicKey=$((Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim())",
        "ownerToken=$($state.ownerToken)",
        "expiresAt=$([DateTimeOffset]::UtcNow.AddDays($RetentionDays).ToString('yyyy-MM-dd'))") -TimeoutSeconds 3000
    $outputs = @{}
    foreach ($key in $deployment.properties.outputs.Keys) { $outputs[$key] = $deployment.properties.outputs[$key].value }
    $outputs.webAppId = (Invoke-Az @('webapp', 'show', '--resource-group', $groupName, '--name', $outputs.webAppName, '--query', 'id')) 
    $state.outputs = $outputs
    Save-RetailState $state $statePath
    Write-Information 'Publishing the checkout front end...' -InformationAction Continue
    Publish-LearnFrontend $state
    Write-LearnValues $state
    [pscustomobject]@{ environment = $EnvironmentName; resourceGroup = $groupName; checkoutUrl = $outputs.webAppUrl
        portalValues = $valuesPath
        next = 'Configure the SRE Agent with docs\sre-agent-portal-setup.md, wait about 5 minutes for telemetry, then run Ready.' }
}

function Invoke-Ready {
    $state = Get-LearnState
    $blockers = [Collections.Generic.List[string]]::new()
    $health = Invoke-WebRequest -Uri "$($state.outputs.webAppUrl)/health" -TimeoutSec 30 -SkipHttpErrorCheck
    $routes = if ($health.StatusCode -eq 200) { ($health.Content | ConvertFrom-Json).routes } else { $null }
    if (-not $routes) { $blockers.Add("Checkout front end health returned HTTP $($health.StatusCode).") }
    elseif ($routes.BE -cne 'primary' -or $routes.NL -cne 'primary') { $blockers.Add('A fault is active (route is not primary). Run Undo.') }
    $settings = Get-LearnRouteSetting $state
    if ($settings['PRICE_ROUTE_BE'] -cne 'primary' -or $settings['PRICE_ROUTE_NL'] -cne 'primary') {
        $blockers.Add('App settings are not both primary.')
    }
    $latency = Get-LearnLatency $state
    foreach ($country in @('BE', 'NL')) {
        $row = $latency[$country]
        if (-not $row -or $row.n -lt 5) { $blockers.Add("No fresh $country checkout telemetry (need 5 in 5 minutes).") }
        else {
            if ($row.p95 -ge 500) { $blockers.Add("$country checkout p95 is $($row.p95) ms; baseline should be below 500 ms.") }
            if ($row.failures -gt 0 -or $row.primaryCount -ne $row.n) { $blockers.Add("$country has failed or non-primary checkouts in the window.") }
        }
    }
    $alert = Invoke-Az @('resource', 'show', '--ids', $state.outputs.alertRuleId)
    if (-not $alert.properties.enabled) { $blockers.Add('Latency alert rule is disabled.') }
    if ($blockers.Count) { throw ("Not ready:`n- " + ($blockers -join "`n- ")) }
    [pscustomobject]@{ environment = $EnvironmentName; ready = $true; latencyP95Ms = @{ BE = $latency.BE.p95; NL = $latency.NL.p95 } }
}

function Set-LearnRoute {
    param([Parameter(Mandatory)][ValidateSet('legacy', 'primary')][string]$Route)
    $state = Get-LearnState
    if ($Route -eq 'legacy') {
        if ($state.activeFault) { throw 'The latency fault is already active.' }
        $null = Invoke-Ready
        $reference = "CHG-$([guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant())"
    } else { $reference = 'baseline' }
    if (-not $PSCmdlet.ShouldProcess($state.outputs.webAppName, "Set PRICE_ROUTE_BE=$Route")) { return }
    $null = Invoke-Az @('webapp', 'config', 'appsettings', 'set', '--resource-group', $groupName,
        '--name', $state.outputs.webAppName, '--settings', "PRICE_ROUTE_BE=$Route", "ROUTE_CHANGE_REF=$reference")
    $state.activeFault = ($Route -eq 'legacy')
    Save-RetailState $state $statePath
    $settings = Get-LearnRouteSetting $state
    if ($settings['PRICE_ROUTE_BE'] -cne $Route) { throw 'The route setting was not applied.' }
    [pscustomobject]@{ environment = $EnvironmentName; beRoute = $Route; changeReference = $reference
        next = $(if ($Route -eq 'legacy') { 'Wait 3-6 minutes for the latency alert, then watch the agent incident thread.' } else { 'Wait about 5 minutes, then run Ready.' }) }
}

function Invoke-Down {
    $state = Get-LearnState
    if (-not $PSCmdlet.ShouldProcess($groupName, 'Delete the SRE Agent learning environment')) { return }
    if (Invoke-Az @('group', 'exists', '--name', $groupName)) {
        $group = Invoke-Az @('group', 'show', '--name', $groupName)
        if ($group.tags.managedBy -cne $managedBy -or $group.tags.environmentId -cne $EnvironmentName -or
            $group.tags.ownerToken -cne $state.ownerToken) {
            throw 'Resource group is not owned by this learning lifecycle; refusing to delete.'
        }
        Write-Warning 'Delete any SRE Agent you created in a different resource group yourself; this script only removes the checkout resource group.'
        Write-Information "Deleting $groupName (about 10-20 minutes)..." -InformationAction Continue
        $null = Invoke-Az @('group', 'delete', '--name', $groupName, '--yes') -TimeoutSeconds 3600
    }
    if (Invoke-Az @('group', 'exists', '--name', $groupName)) { throw 'Resource group deletion is not yet verified.' }
    if (@(Invoke-Az @('resource', 'list', '--tag', "ownerToken=$($state.ownerToken)")).Count) {
        throw 'Owned active Azure resources remain; retain state and inspect residuals.'
    }
    try {
        $null = Invoke-Az @('deployment', 'sub', 'delete', '--name', $deploymentName)
    } catch { Write-Warning "Deployment record $deploymentName was not removed: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $statePath, $valuesPath -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ environment = $EnvironmentName; removed = $groupName }
}

$operationLock = $null
try {
    $null = New-Item -ItemType Directory -Path $stateDirectory -Force
    $operationLock = [IO.File]::Open((Join-Path $stateDirectory 'learn-operation.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    switch ($Action) {
        'Up' { Invoke-Up }
        'Ready' { Invoke-Ready }
        'Inject' { Set-LearnRoute -Route legacy }
        'Undo' { Set-LearnRoute -Route primary }
        'Down' { Invoke-Down }
    }
} finally { if ($operationLock) { $operationLock.Dispose() } }
