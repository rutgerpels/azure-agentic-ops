#Requires -Version 7.2
<#
.SYNOPSIS
Owned Azure lifecycle for the Entra-authenticated Foundry incident assistant.
.DESCRIPTION
Provision creates the platform only. Up also publishes and bootstraps the agent.
Verify runs tests inside the Azure application container, never on this computer.
Foundry accepts only the enabled hosts' published possible outbound IPs; keys and SCM basic auth are disabled.
.PARAMETER Action
Preflight, Provision, Up, Ready, Probe, Verify, Attach, Observe, Detach, Reset, Down,
TeamsUp, TeamsReady, TeamsPackage, TeamsVerify, TeamsAttach, TeamsObserve, TeamsDetach or TeamsDown.
Probe runs a bounded Responses request-contract ladder in Azure and saves a non-content receipt.
Attach binds the app to an owned Arc-enabled checkout deployment for read-only live evidence:
it grants Log Analytics Reader on that checkout workspace, an exact read-only custom
SRE role on its owned agent, and switches the app to live mode.
Observe runs one live evidence read and agent turn in Azure; it never declares recovery.
Detach returns the app to fixture mode and removes both grants and the owned custom role.
Verify always evaluates the agent against fixtures, whichever evidence mode is attached.
TeamsAttach binds only the Teams host, without inference; TeamsObserve explicitly
requests a new live read and agent turn. TeamsDetach removes only its reader grant.
.PARAMETER SubscriptionId
Explicit authorized demo subscription.
.PARAMETER TenantId
Explicit authorized demo tenant. A different token tenant terminates every action.
.PARAMETER EnvironmentName
Neutral deployment name, separate from the checkout application's lifecycle.
.PARAMETER CheckoutEnvironmentName
Owned checkout deployment to Attach (for example checkout01). It must use Arc with the
service controller installed, in the same subscription.
.PARAMETER RetentionDays
Informational retention intent for ownership metadata and resource tags.
It does not block readiness or publication and is not an automatic deletion timer.
.PARAMETER TeamsUserObjectId
Enabled member's Entra object ID for the optional fixture-first personal Teams pilot.
Required on first TeamsUp. Never inferred from the browser operator.
.EXAMPLE
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Up -SubscriptionId <guid> -TenantId <guid>
.EXAMPLE
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Verify -SubscriptionId <guid> -TenantId <guid>
.EXAMPLE
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Attach -SubscriptionId <guid> -TenantId <guid> -CheckoutEnvironmentName checkout01
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Preflight', 'Provision', 'Up', 'Ready', 'Probe', 'Verify', 'Attach', 'Observe', 'Detach', 'Reset', 'Down',
        'TeamsUp', 'TeamsReady', 'TeamsPackage', 'TeamsVerify', 'TeamsAttach', 'TeamsObserve', 'TeamsDetach', 'TeamsDown')]
    [string]$Action,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$EnvironmentName = 'assist01',
    [string]$CheckoutEnvironmentName = '',
    [string]$TeamsUserObjectId = '',
    [ValidateRange(1, 7)][int]$RetentionDays = 1
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\scripts\Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
$repository = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $repository)
$subscription = $SubscriptionId.ToString()
$tenant = $TenantId.ToString()
$location = 'swedencentral'
$groupName = "rg-retailtx-incident-$EnvironmentName-$location"
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$directory = Join-Path $repositoryRoot ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'incident-agent-ownership.json'
$normalStartup = 'python -m uvicorn app:app --host 0.0.0.0 --port 8000 --workers 1 --proxy-headers --forwarded-allow-ips="*" --no-access-log'
$runtimeRole = 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
$bootstrapRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
$logReaderRole = '73c42c96-874c-492b-b04d-ab87d138a893'
$checkoutSettingNames = @('CHECKOUT_WORKSPACE_ID', 'CHECKOUT_WORKSPACE_RESOURCE_ID',
    'CHECKOUT_OWNER_TOKEN', 'CHECKOUT_ARC_RESOURCE_ID', 'CHECKOUT_APP_RESOURCE_ID',
    'CHECKOUT_SRE_RESOURCE_ID', 'CHECKOUT_SRE_ENDPOINT', 'CHECKOUT_LATENCY_RULE_ID',
    'CHECKOUT_SERVICE_RULE_ID', 'CHECKOUT_CREATED_AT')

function Invoke-IncidentAzure {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 120)
    Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Get-IncidentToken {
    param([ValidateSet('https://management.azure.com/', 'https://graph.microsoft.com/')]
        [string]$Resource = 'https://management.azure.com/')
    $value = Invoke-IncidentAzure @('account', 'get-access-token', '--resource', $Resource)
    if ($value.tenant -ine $tenant) { throw 'Token tenant does not match the authorized demo tenant.' }
    return ConvertTo-SecureString $value.accessToken -AsPlainText -Force
}

function ConvertFrom-IncidentJson {
    param([Parameter(Mandatory)][string]$Json)
    $options = @{ AsHashtable = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $options.DateKind = 'String'
    }
    return ConvertFrom-Json -InputObject $Json @options
}

function Invoke-IncidentRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [object]$Body,
        [switch]$AllowMissing,
        [switch]$Text,
        [switch]$AllowWarming
    )
    $parsed = [uri]$Uri
    $scm = if ($script:state -and $script:state.outputs.ContainsKey('scmUrl')) {
        ([uri]$script:state.outputs.scmUrl).Host
    } else { '' }
    $teamsScm = if ($script:state -and $script:state.outputs['teams'] -and
        $script:state.outputs.teams.Count -gt 0) {
        ([uri]$script:state.outputs.teams.scmUrl).Host
    } else { '' }
    if ($parsed.Scheme -cne 'https' -or $parsed.UserInfo -or $parsed.Port -ne 443 -or
        $parsed.Host -notin @('management.azure.com', 'graph.microsoft.com', $scm, $teamsScm)) {
        throw 'Unexpected control-plane or owned SCM endpoint.'
    }
    $resource = if ($parsed.Host -ceq 'graph.microsoft.com') {
        'https://graph.microsoft.com/'
    } else { 'https://management.azure.com/' }
    $request = @{
        Uri = $Uri; Method = $Method; Authentication = 'Bearer'
        Token = Get-IncidentToken $resource; TimeoutSec = 90
        MaximumRedirection = 0; SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 35 -Compress
    }
    try { $response = Invoke-WebRequest @request }
    catch [System.Threading.Tasks.TaskCanceledException], [System.Net.Http.HttpRequestException] {
        if ($AllowWarming -and $parsed.Host -in @($scm, $teamsScm)) {
            Write-Verbose "Owned SCM transport is warming: $($_.Exception.GetType().Name)."
            return $null
        }
        throw
    }
    finally { $request.Token = $null }
    $content = if ($response.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($response.Content)
    } else { [string]$response.Content }
    if ($AllowMissing -and $response.StatusCode -eq 404) { return $null }
    if ($AllowWarming -and $response.StatusCode -in @(404, 409, 502, 503)) { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        $code = ''
        if ($content -and $content.TrimStart().StartsWith('{')) {
            $failure = $content | ConvertFrom-Json -AsHashtable
            if ($failure.ContainsKey('error') -and $failure.error -is [hashtable] -and
                $failure.error.ContainsKey('code') -and
                $failure.error.code -cmatch '^[A-Za-z0-9._-]{1,80}$') {
                $code = " ($($failure.error.code))"
            }
        }
        throw "Owned service request failed: $Method HTTP $($response.StatusCode)$code. Response content withheld."
    }
    if ($Text) { return $content }
    if ($content) { return ConvertFrom-IncidentJson $content }
}

function Save-IncidentState {
    Save-RetailState -State $script:state -Path $statePath
}

function Assert-IncidentState {
    param([hashtable]$Value)
    if ($Value.schemaVersion -ne 1 -or $Value.profile -cne 'incident-assistant' -or
        $Value.subscriptionId -ine $subscription -or $Value.tenantId -ine $tenant -or
        $Value.environmentName -cne $EnvironmentName -or $Value.location -cne $location -or
        $Value.resourceGroupName -cne $groupName -or $Value.nameSuffix -cnotmatch '^[a-f0-9]{6}$') {
        throw 'The incident manifest does not match this explicit environment.'
    }
    foreach ($key in @('ownerToken', 'runId', 'operatorId', 'operatorRoleId')) {
        $null = [guid]::Parse($Value[$key])
    }
    Assert-IncidentTeamsState $Value
    if ($Value.outputs.Count -gt 0) {
        $webName = "app-rtx-incident-$EnvironmentName-$($Value.nameSuffix)"
        $accountName = "aif-rtx-incident-$EnvironmentName-$($Value.nameSuffix)"
        if ($Value.outputs.webAppName -cne $webName -or
            $Value.outputs.webAppId -ine "$groupId/providers/Microsoft.Web/sites/$webName" -or
            $Value.outputs.foundryAccountName -cne $accountName -or
            $Value.outputs.foundryAccountId -ine "$groupId/providers/Microsoft.CognitiveServices/accounts/$accountName" -or
            $Value.outputs.foundryProjectId -ine "$groupId/providers/Microsoft.CognitiveServices/accounts/$accountName/projects/incident") {
            throw 'Saved application or Foundry resource binding is invalid.'
        }
        foreach ($url in @($Value.outputs.webAppUrl, $Value.outputs.scmUrl)) {
            $uri = [uri]$url
            if ($uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.AbsolutePath -cne '/' -or
                -not $uri.Host.StartsWith("$webName.", [StringComparison]::Ordinal) -or
                -not $uri.Host.EndsWith('.azurewebsites.net', [StringComparison]::Ordinal)) {
                throw 'Saved application endpoint is invalid.'
            }
        }
        if (-not ([uri]$Value.outputs.scmUrl).Host.Contains('.scm.')) {
            throw 'Saved deployment endpoint is invalid.'
        }
    }
}

function Get-IncidentGroup {
    $group = Invoke-IncidentRequest "https://management.azure.com${groupId}?api-version=2022-09-01" -AllowMissing
    if ($group) {
        if ($group.id -ine $groupId -or $group.location -cne $location -or
            $group.tags.ownerToken -cne $script:state.ownerToken -or
            $group.tags.environmentId -cne $EnvironmentName -or
            $group.tags.profile -cne 'incident-assistant' -or
            $group.tags.managedBy -cne 'invoke-incidentagent' -or $group.tags.demo -cne 'retailtx') {
            throw 'Resource group is not owned by this manifest; adoption/deletion refused.'
        }
    }
    return $group
}

function Get-IncidentApplication {
    if (-not $script:state.applicationObjectId) { return $null }
    $objectId = ([guid]$script:state.applicationObjectId).ToString()
    $app = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications/$objectId" -AllowMissing
    if ($app -and ($app.appId -ine $script:state.applicationClientId -or
        $app.displayName -cne "retailtx-incident-$EnvironmentName" -or
        "retailtx-owner:$($script:state.ownerToken)" -cnotin $app.tags -or
        $app.signInAudience -cne 'AzureADMyOrg')) {
        throw 'Entra application ownership or tenant audience drifted.'
    }
    return $app
}

function Test-IncidentPreflight {
    $graphToken = Get-IncidentToken 'https://graph.microsoft.com/'
    $graphToken = $null
    $quota = @(Invoke-IncidentAzure @('cognitiveservices', 'usage', 'list', '--location', $location,
        '--query', "[?name.value=='OpenAI.DataZoneStandard.gpt-5-mini']"))
    $existingCapacity = 0
    if ($script:state -and $script:state.outputs.Count -gt 0) {
        $existing = Invoke-IncidentRequest "https://management.azure.com$($script:state.outputs.foundryAccountId)/deployments/incident-reasoner?api-version=2025-06-01" -AllowMissing
        if ($existing) { $existingCapacity = [int]$existing.sku.capacity }
    }
    if (@($quota).Count -ne 1 -or $quota[0].limit - $quota[0].currentValue + $existingCapacity -lt 50) {
        throw 'Insufficient verified EU data-zone model quota for this deployment.'
    }
    foreach ($provider in @('Microsoft.CognitiveServices', 'Microsoft.Web', 'Microsoft.ManagedIdentity', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.AlertsManagement')) {
        $registration = Invoke-IncidentAzure @('provider', 'show', '--namespace', $provider)
        if ($registration.registrationState -cne 'Registered') { throw "Required provider is not registered: $provider." }
    }
    return @{ authorizedTenant = $true; modelQuotaAvailable = $true; providersRegistered = $true }
}

function Set-IncidentSettings {
    param([hashtable]$Values)
    $uri = "https://management.azure.com$($script:state.outputs.webAppId)/config/appsettings"
    $settings = Invoke-IncidentRequest "${uri}/list?api-version=2024-04-01" -Method POST
    foreach ($key in $Values.Keys) { $settings.properties[$key] = [string]$Values[$key] }
    $null = Invoke-IncidentRequest "${uri}?api-version=2024-04-01" -Method PUT -Body @{ properties = $settings.properties }
}

function Set-IncidentStartup {
    param([string]$Command, [switch]$Teams)
    $hostOutputs = Get-IncidentHostOutputs -Teams:$Teams
    $uri = "https://management.azure.com$($hostOutputs.webAppId)/config/web?api-version=2024-04-01"
    $configuration = Invoke-IncidentRequest $uri
    $configuration.properties.appCommandLine = $Command
    $null = Invoke-IncidentRequest $uri -Method PUT -Body @{ properties = $configuration.properties }
}

function Wait-IncidentRuntime {
    param([switch]$Teams)
    $hostOutputs = Get-IncidentHostOutputs -Teams:$Teams
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        try {
            $response = Invoke-WebRequest -Uri "$($hostOutputs.webAppUrl)/health/live" `
                -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 30
            if ($response.StatusCode -eq 200) {
                $content = if ($response.Content -is [byte[]]) {
                    [Text.Encoding]::UTF8.GetString($response.Content)
                } else { [string]$response.Content }
                if ([string]$response.Headers['Content-Type'] -cnotlike 'application/json*' -or
                    $content.Trim() -cne '{"status":"ok"}') {
                    throw 'Azure application returned an unexpected liveness contract; response body withheld.'
                }
                return
            }
            if ($response.StatusCode -notin @(404, 408, 429, 500, 502, 503, 504)) {
                throw "Azure application liveness failed: HTTP $($response.StatusCode)."
            }
            Write-Verbose "Azure application warming: HTTP $($response.StatusCode)."
        } catch [System.Threading.Tasks.TaskCanceledException], [System.Net.Http.HttpRequestException] {
            Write-Verbose "Azure application liveness transport is not ready: $($_.Exception.GetType().Name)."
        }
        Start-Sleep -Seconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Azure application did not answer its constant liveness probe before the startup deadline.'
}

function Invoke-IncidentCloudJob {
    param([ValidateSet('bootstrap', 'test', 'evaluate', 'probe', 'livecheck')][string]$Command,
        [switch]$Teams)
    $hostOutputs = Get-IncidentHostOutputs -Teams:$Teams
    $serve = if ($Teams) { 'python teams_server.py' } else { $normalStartup }
    $jobId = [guid]::NewGuid().ToString('N')
    $base = "/home/data/incident/jobs/$jobId"
    $script:state.activeJob = @{ id = $jobId; command = $Command; runId = $script:state.runId
        startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); status = 'running'; teams = [bool]$Teams }
    Save-IncidentState
    $startup = "mkdir -p /home/data/incident/jobs || exit 1; ( if mkdir $base.claim; then " +
        "python manage.py $Command > $base.json 2> $base.stderr && result=0 || result=`$?; " +
        "printf '%s' `"`$result`" > $base.exit; fi ) & exec $serve"
    try {
        Set-IncidentStartup $startup -Teams:$Teams
        $null = Invoke-IncidentAzure @('webapp', 'restart', '--resource-group', $groupName, '--name', $hostOutputs.webAppName)
        Wait-IncidentRuntime -Teams:$Teams
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
        do {
            Start-Sleep -Seconds 10
            $exit = Invoke-IncidentRequest "$($hostOutputs.scmUrl)/api/vfs/data/incident/jobs/$jobId.exit" -Text -AllowWarming
            if ($null -ne $exit) {
                if ($exit.Trim() -cne '0') {
                    $script:state.activeJob.status = 'failed'
                    Save-IncidentState
                    throw "Azure application $Command failed. Private diagnostics: /home/data/incident/jobs/$jobId.stderr"
                }
                $result = Invoke-IncidentRequest "$($hostOutputs.scmUrl)/api/vfs/data/incident/jobs/$jobId.json" -Text -AllowWarming
                if ($null -eq $result) { continue }
                if (-not $result) { throw "Azure application $Command returned no required JSON receipt." }
                $receipt = ConvertFrom-IncidentJson $result
                if ($receipt -isnot [hashtable] -or
                    ($Command -ne 'bootstrap' -and
                        (-not $receipt.ContainsKey('pass') -or $receipt.pass -cne $true))) {
                    throw "Azure application $Command returned an invalid or unsuccessful receipt."
                }
                $script:state.activeJob.status = 'passed'
                $script:state.activeJob.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                Save-IncidentState
                return $receipt
            }
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        $script:state.activeJob.status = 'timed-out'
        Save-IncidentState
        throw "Azure application $Command observation timed out; do not assume the job never ran."
    } finally {
        Set-IncidentStartup $serve -Teams:$Teams
    }
}

function Get-IncidentEvidenceSettings {
    param([switch]$Fixture, [switch]$Teams)
    $key = if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' }
    $binding = $script:state[$key]
    $enabled = -not $Teams -or ($script:state['teamsConfig'] -and
        $script:state.teamsConfig['evidenceMode'] -ceq 'live')
    if ($Fixture -or -not $binding -or -not $enabled) {
        $values = @{ DEMO_EVIDENCE_MODE = 'fixture' }
        foreach ($name in $checkoutSettingNames) { $values[$name] = '' }
        return $values
    }
    return @{
        DEMO_EVIDENCE_MODE = 'live'
        CHECKOUT_WORKSPACE_ID = $binding.workspaceCustomerId
        CHECKOUT_WORKSPACE_RESOURCE_ID = $binding.workspaceId
        CHECKOUT_OWNER_TOKEN = $binding.ownerToken
        CHECKOUT_ARC_RESOURCE_ID = $binding.arcMachineId
        CHECKOUT_APP_RESOURCE_ID = $binding.appInsightsId
        CHECKOUT_SRE_RESOURCE_ID = [string]$binding['sreAgentId']
        CHECKOUT_SRE_ENDPOINT = [string]$binding['sreEndpoint']
        CHECKOUT_LATENCY_RULE_ID = [string]$binding['latencyRuleId']
        CHECKOUT_SERVICE_RULE_ID = [string]$binding['serviceRuleId']
        CHECKOUT_CREATED_AT = [string]$binding['createdAtUtc']
    }
}

function Get-CheckoutBindingSource {
    param([Parameter(Mandatory)][string]$Name)
    Assert-RetailEnvironmentName $Name
    $path = Join-Path $repositoryRoot ".azure\$Name\checkout-state.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "No checkout ownership state for '$Name'." }
    $checkout = ConvertFrom-IncidentJson (Get-Content -LiteralPath $path -Raw)
    if ($checkout.schemaVersion -ne 2 -or $checkout.subscriptionId -ine $subscription -or
        $checkout.environmentName -cne $Name -or $checkout['enableArc'] -ne $true -or
        $checkout['controllerInstalled'] -ne $true) {
        throw 'Checkout is not an owned Arc deployment with its service controller installed in this subscription.'
    }
    $null = [guid]::Parse($checkout.ownerToken)
    $outputs = $checkout.outputs
    $null = [guid]::Parse($outputs.workspaceCustomerId)
    $checkoutGroupId = "/subscriptions/$subscription/resourceGroups/$($checkout.resourceGroupName)"
    if ($outputs.resourceGroupId -ine $checkoutGroupId) { throw 'Checkout resource group binding is invalid.' }
    foreach ($pair in @(
            @('workspaceId', 'Microsoft.OperationalInsights/workspaces/'),
            @('arcMachineId', 'Microsoft.HybridCompute/machines/'),
            @('appInsightsId', 'Microsoft.Insights/components/'),
            @('agentId', 'Microsoft.App/agents/'),
            @('alertRuleId', 'Microsoft.Insights/scheduledQueryRules/'),
            @('serviceAlertRuleId', 'Microsoft.Insights/scheduledQueryRules/'))) {
        $value = [string]$outputs[$pair[0]]
        if (-not $value.StartsWith("$checkoutGroupId/providers/$($pair[1])", [StringComparison]::OrdinalIgnoreCase) -or
            $value -cnotmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/[A-Za-z0-9./_-]+$') {
            throw "Checkout output $($pair[0]) is invalid."
        }
    }
    $group = Invoke-IncidentRequest "https://management.azure.com${checkoutGroupId}?api-version=2022-09-01"
    if ($group.tags.ownerToken -cne $checkout.ownerToken) {
        throw 'Checkout resource group is not owned by its manifest; binding refused.'
    }
    if ($checkout['alertsOnly'] -eq $true -or -not $checkout['createdAtUtc']) {
        throw 'SRE progress requires an owned agent and recorded checkout deployment generation.'
    }
    $created = [DateTimeOffset]$checkout.createdAtUtc
    if ($created -gt [DateTimeOffset]::UtcNow) { throw 'Checkout deployment generation is in the future.' }
    $agent = Invoke-IncidentRequest "https://management.azure.com$($outputs.agentId)?api-version=2026-01-01"
    $endpoint = [uri]$agent.properties.agentEndpoint
    if ($agent.id -ine $outputs.agentId -or $agent.tags.ownerToken -cne $checkout.ownerToken -or
        $endpoint.Scheme -cne 'https' -or $endpoint.UserInfo -or $endpoint.Port -ne 443 -or
        $endpoint.AbsolutePath -cne '/' -or $endpoint.Query -or $endpoint.Fragment -or
        $endpoint.Host -cnotmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.azuresre\.ai$') {
        throw 'SRE ownership or endpoint is invalid; attachment refused.'
    }
    return @{
        environmentName = $Name; ownerToken = $checkout.ownerToken
        workspaceCustomerId = $outputs.workspaceCustomerId; workspaceId = $outputs.workspaceId
        arcMachineId = $outputs.arcMachineId; appInsightsId = $outputs.appInsightsId
        sreAgentId = $outputs.agentId; sreEndpoint = $endpoint.AbsoluteUri.TrimEnd('/')
        latencyRuleId = $outputs.alertRuleId; serviceRuleId = $outputs.serviceAlertRuleId
        createdAtUtc = $created.ToString('o')
    }
}

function Get-IncidentSreRole {
    param([Parameter(Mandatory)][hashtable]$Binding)
    $scope = $Binding.sreAgentId -replace '/providers/Microsoft.App/agents/[^/]+$', ''
    return @{
        roleName = "retailtx-incident-sre-$($Binding.sreRoleId)"
        description = "Read-only incident progress; owned by $($script:state.ownerToken)"
        type = 'CustomRole'
        assignableScopes = @($scope)
        permissions = @(@{
            actions = @('Microsoft.App/agents/read')
            notActions = @()
            dataActions = @('Microsoft.App/agents/threads/read', 'Microsoft.App/agents/incidentManagement/read')
            notDataActions = @()
        })
    }
}

function Get-IncidentSreUris {
    param([Parameter(Mandatory)][hashtable]$Binding)
    $role = ([guid]$Binding.sreRoleId).ToString()
    $assignment = ([guid]$Binding.sreReaderAssignmentId).ToString()
    return @{
        role = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/${role}?api-version=2022-04-01"
        assignment = "https://management.azure.com$($Binding.sreAgentId)/providers/Microsoft.Authorization/roleAssignments/${assignment}?api-version=2022-04-01"
        roleId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$role"
    }
}

function Test-IncidentSreGrant {
    param([switch]$Teams, [switch]$AllowMissing)
    $binding = $script:state[$(if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' })]
    if (-not $binding['sreAgentId']) { return $true }
    $uris = Get-IncidentSreUris $binding
    $role = Invoke-IncidentRequest $uris.role -AllowMissing
    $assignment = Invoke-IncidentRequest $uris.assignment -AllowMissing
    if ($role) {
        $expected = Get-IncidentSreRole $binding
        foreach ($key in @('roleName', 'description', 'type')) {
            if ($role.properties[$key] -cne $expected[$key]) { throw 'Owned SRE reader role drifted.' }
        }
        if (@($role.properties.assignableScopes).Count -ne 1 -or
            $role.properties.assignableScopes[0] -ine $expected.assignableScopes[0] -or
            @($role.properties.permissions).Count -ne 1) { throw 'Owned SRE reader role scope drifted.' }
        foreach ($key in @('actions', 'notActions', 'dataActions', 'notDataActions')) {
            if ((@($role.properties.permissions[0][$key] | Sort-Object) -join ',') -cne
                (@($expected.permissions[0][$key] | Sort-Object) -join ',')) {
                throw 'Owned SRE reader role permissions drifted; refusing broader access.'
            }
        }
    }
    if ($assignment -and ($assignment.properties.principalId -ine $binding.runtimePrincipalId -or
        $assignment.properties.scope -ine $binding.sreAgentId -or
        $assignment.properties.roleDefinitionId -ine $uris.roleId)) {
        throw 'Owned SRE reader assignment drifted.'
    }
    if (-not $AllowMissing -and (-not $role -or -not $assignment)) { return $false }
    return $true
}

function Remove-IncidentSreGrant {
    param([switch]$Teams)
    $binding = $script:state[$(if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' })]
    if (-not $binding['sreAgentId']) { return }
    $null = Test-IncidentSreGrant -Teams:$Teams -AllowMissing
    $uris = Get-IncidentSreUris $binding
    if (Invoke-IncidentRequest $uris.assignment -AllowMissing) {
        $null = Invoke-IncidentRequest $uris.assignment -Method DELETE
    }
    if (Invoke-IncidentRequest $uris.assignment -AllowMissing) {
        throw 'SRE assignment removal is not verified; retain the binding.'
    }
    if (Invoke-IncidentRequest $uris.role -AllowMissing) {
        $null = Invoke-IncidentRequest $uris.role -Method DELETE
    }
    if (Invoke-IncidentRequest $uris.role -AllowMissing) {
        throw 'SRE reader role removal is not verified; retain the binding.'
    }
}

function Get-CheckoutGrantUri {
    param([switch]$Teams)
    $binding = $script:state[$(if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' })]
    $assignment = ([guid]$binding.readerAssignmentId).ToString()
    return "https://management.azure.com$($binding.workspaceId)/providers/Microsoft.Authorization/roleAssignments/${assignment}?api-version=2022-04-01"
}

function Test-CheckoutGrant {
    param([switch]$Teams)
    $binding = $script:state[$(if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' })]
    $principal = if ($binding['runtimePrincipalId']) {
        $binding.runtimePrincipalId
    } else { (Get-IncidentHostOutputs -Teams:$Teams).runtimePrincipalId }
    $grant = Invoke-IncidentRequest (Get-CheckoutGrantUri -Teams:$Teams) -AllowMissing
    if (-not $grant) { return $false }
    if ($grant.properties.principalId -ine $principal -or
        $grant.properties.roleDefinitionId -inotlike "*/roleDefinitions/$logReaderRole" -or
        $grant.properties.scope -ine $binding.workspaceId) {
        throw 'Checkout workspace grant drifted; automatic change refused.'
    }
    return $true
}

function Remove-CheckoutGrant {
    param([switch]$Teams)
    $key = if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' }
    if (-not $script:state[$key]) { return }
    Remove-IncidentSreGrant -Teams:$Teams
    if (Test-CheckoutGrant -Teams:$Teams) {
        $null = Invoke-IncidentRequest (Get-CheckoutGrantUri -Teams:$Teams) -Method DELETE
    }
    if (Invoke-IncidentRequest (Get-CheckoutGrantUri -Teams:$Teams) -AllowMissing) {
        throw 'Checkout workspace grant removal is not verified. Retain the binding and observe cleanup again.'
    }
}

function Restart-IncidentRuntime {
    param([switch]$Teams)
    $hostOutputs = Get-IncidentHostOutputs -Teams:$Teams
    $operation = if ($Teams) { 'start' } else { 'restart' }
    $null = Invoke-IncidentAzure @('webapp', $operation, '--resource-group', $groupName, '--name', $hostOutputs.webAppName)
    Wait-IncidentRuntime -Teams:$Teams
}

function Invoke-IncidentLiveCheck {
    param([switch]$Teams)
    $binding = $script:state[$(if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' })]
    if (-not $binding) { throw 'No checkout binding. Run the selected host Attach action first.' }
    if ($Teams -and $script:state.teamsConfig['evidenceMode'] -cne 'live') {
        throw 'The Teams attachment is not enabled for live evidence.'
    }
    $check = Invoke-IncidentCloudJob 'livecheck' -Teams:$Teams
    $check.checkoutEnvironmentName = $binding.environmentName
    $file = if ($Teams) { 'incident-teams-livecheck.json' } else { 'incident-livecheck.json' }
    Save-RetailState -State $check -Path (Join-Path $directory $file)
    return $check
}

function Connect-IncidentCheckout {
    param([switch]$Teams)
    if (-not $CheckoutEnvironmentName) { throw 'Attach requires -CheckoutEnvironmentName.' }
    $null = Get-IncidentGroup
    if (-not $script:state.agentVersion -or
        $script:state.agentVersion -cne $script:state.agentEndpointVersion) {
        throw 'The incident assistant is not configured. Run Up first.'
    }
    if ($Teams -and (-not $script:state['teamsConfig'] -or -not $script:state.teamsConfig.enabled)) {
        throw 'Enable the owned personal host with TeamsUp before TeamsAttach.'
    }
    $hostOutputs = Get-IncidentHostOutputs -Teams:$Teams
    $source = Get-CheckoutBindingSource $CheckoutEnvironmentName
    $key = if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' }
    $existing = $script:state[$key]
    if ($existing -and @($source.Keys | Where-Object {
        [string]$existing[$_] -ine [string]$source[$_]
    }).Count -gt 0) {
        throw 'A different checkout binding is recorded. Run Detach first.'
    }
    if ($existing -and $existing['runtimePrincipalId'] -and
        $existing.runtimePrincipalId -ine $hostOutputs.runtimePrincipalId) {
        throw 'The recorded checkout reader belongs to a different runtime. Detach before reattaching.'
    }
    if ($Teams) {
        $null = Stop-IncidentTeamsRuntime
        Set-IncidentStartup 'python teams_server.py' -Teams
    }
    # Record the assignment name before creating it so Detach/Down can always find it.
    $source.readerAssignmentId = if ($existing) { $existing.readerAssignmentId } else { [guid]::NewGuid().ToString() }
    $source.sreRoleId = if ($existing) { $existing.sreRoleId } else { [guid]::NewGuid().ToString() }
    $source.sreReaderAssignmentId = if ($existing) { $existing.sreReaderAssignmentId } else { [guid]::NewGuid().ToString() }
    $source.attachedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $source.runtimePrincipalId = $hostOutputs.runtimePrincipalId
    $script:state[$key] = $source
    if ($Teams) {
        $script:state.teamsConfig.evidenceMode = 'live'
        $script:state.teamsConfig.evidenceRevision = [guid]::NewGuid().ToString()
    }
    Save-IncidentState
    $null = Test-IncidentSreGrant -Teams:$Teams -AllowMissing
    $uris = Get-IncidentSreUris $source
    if (-not (Invoke-IncidentRequest $uris.role -AllowMissing)) {
        $null = Invoke-IncidentRequest $uris.role -Method PUT -Body @{ properties = Get-IncidentSreRole $source }
    }
    if (-not (Invoke-IncidentRequest $uris.assignment -AllowMissing)) {
        $null = Invoke-IncidentRequest $uris.assignment -Method PUT -Body @{
            properties = @{
                principalId = $hostOutputs.runtimePrincipalId; principalType = 'ServicePrincipal'
                roleDefinitionId = $uris.roleId
            }
        }
    }
    if (-not (Test-IncidentSreGrant -Teams:$Teams)) { throw 'SRE reader grant is not verified.' }
    if (-not (Test-CheckoutGrant -Teams:$Teams)) {
        $null = Invoke-IncidentRequest (Get-CheckoutGrantUri -Teams:$Teams) -Method PUT -Body @{
            properties = @{
                principalId = $hostOutputs.runtimePrincipalId; principalType = 'ServicePrincipal'
                roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$logReaderRole"
            }
        }
    }
    if ($Teams) {
        Set-IncidentTeamsSettings (Get-IncidentTeamsEvidenceSettings)
        Restart-IncidentRuntime -Teams
        $null = Test-IncidentTeamsReadiness
        return @{ attached = $true; evidenceMode = 'live'; checkoutEnvironmentName = $source.environmentName
            liveEvidenceObserved = $false; nextAction = 'Run TeamsObserve for a new Azure-hosted observation; no inference was replayed by attachment.' }
    }
    Set-IncidentSettings (Get-IncidentEvidenceSettings)
    Restart-IncidentRuntime
    $null = Test-IncidentReadiness
    $check = Invoke-IncidentLiveCheck
    return @{ attached = $true; evidenceMode = 'live'; checkoutEnvironmentName = $source.environmentName
        liveEvidenceUsable = $check.liveEvidenceUsable; health = $check.health
        note = 'New Log Analytics grants can take minutes to apply; rerun Observe if evidence is unknown.' }
}

function Disconnect-IncidentCheckout {
    param([switch]$Teams)
    $null = Get-IncidentGroup
    $key = if ($Teams) { 'teamsCheckoutBinding' } else { 'checkoutBinding' }
    $binding = $script:state[$key]
    if (-not $binding -and -not $Teams) {
        return @{ detached = $true; changed = $false; evidenceMode = 'fixture' }
    }
    $environment = if ($binding) { $binding.environmentName } else { '' }
    if ($Teams) {
        $hostPresent = Stop-IncidentTeamsRuntime -AllowMissing
        $script:state.teamsConfig.evidenceMode = 'fixture'
        if ($binding) { $script:state.teamsConfig.evidenceRevision = [guid]::NewGuid().ToString() }
        Save-IncidentState
        if ($hostPresent) {
            Set-IncidentStartup 'python teams_server.py' -Teams
            Set-IncidentTeamsSettings (Get-IncidentTeamsEvidenceSettings)
        }
        Remove-CheckoutGrant -Teams
        $script:state[$key] = $null
        Save-IncidentState
        if ($hostPresent) {
            Restart-IncidentRuntime -Teams
            $null = Test-IncidentTeamsReadiness
        }
        return @{ detached = $true; changed = [bool]$binding; evidenceMode = 'fixture'
            teamsHostPresent = [bool]$hostPresent; checkoutEnvironmentName = $environment }
    }
    # Stop live reads before removing the grant; keep the binding until the grant is gone.
    Set-IncidentSettings (Get-IncidentEvidenceSettings -Fixture)
    Restart-IncidentRuntime
    Remove-CheckoutGrant
    $script:state.checkoutBinding = $null
    Save-IncidentState
    $null = Test-IncidentReadiness
    return @{ detached = $true; changed = $true; evidenceMode = 'fixture'; checkoutEnvironmentName = $environment }
}

function Initialize-IncidentPlatform {
    $null = Test-IncidentPreflight
    $group = Get-IncidentGroup
    $tags = @{
        demo = 'retailtx'; environmentId = $EnvironmentName; profile = 'incident-assistant'
        expiresAt = $script:state.expiresAtUtc; managedBy = 'invoke-incidentagent'
        ownerToken = $script:state.ownerToken
    }
    if (-not $group) {
        $null = Invoke-IncidentRequest "https://management.azure.com${groupId}?api-version=2022-09-01" `
            -Method PUT -Body @{ location = $location; tags = $tags }
    }
    $app = Get-IncidentApplication
    if (-not $app) {
        if ($script:state.applicationObjectId) {
            throw 'The recorded Entra application is missing; refuse silent replacement.'
        }
        $filter = [uri]::EscapeDataString("displayName eq 'retailtx-incident-$EnvironmentName'")
        $existing = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id"
        if (@($existing.value).Count) { throw 'An unowned same-name Entra application already exists.' }
        $app = Invoke-IncidentRequest 'https://graph.microsoft.com/v1.0/applications' -Method POST -Body @{
            displayName = "retailtx-incident-$EnvironmentName"
            signInAudience = 'AzureADMyOrg'
            tags = @('retailtx', "retailtx-owner:$($script:state.ownerToken)", "retailtx-environment:$EnvironmentName")
            api = @{ requestedAccessTokenVersion = 2 }
            web = @{ redirectUris = @(); implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } }
            appRoles = @(@{ id = $script:state.operatorRoleId; allowedMemberTypes = @('User')
                description = 'Use the read-only retail incident assistant'; displayName = 'Incident operator'
                isEnabled = $true; value = 'Incident.Operator' })
        }
        $script:state.applicationObjectId = $app.id
        $script:state.applicationClientId = $app.appId
        Save-IncidentState
    }
    $parameters = @{
        environmentName = $EnvironmentName; location = $location; nameSuffix = $script:state.nameSuffix
        tags = $tags; browserClientId = $script:state.applicationClientId
        allowedOperatorId = $script:state.operatorId; ownerToken = $script:state.ownerToken
        runId = $script:state.runId; agentVersion = $script:state.agentVersion
        enableTeams = [bool]($script:state['teamsConfig'] -and $script:state.teamsConfig.enabled)
        teamsAllowedObjectId = if ($script:state['teamsConfig']) { $script:state.teamsConfig.userId } else { '' }
    }
    # Redeploying replaces all app settings, so carry the recorded evidence binding forward.
    $evidence = Get-IncidentEvidenceSettings
    $parameters.evidenceMode = $evidence.DEMO_EVIDENCE_MODE
    $parameters.checkoutWorkspaceId = $evidence.CHECKOUT_WORKSPACE_ID
    $parameters.checkoutWorkspaceResourceId = $evidence.CHECKOUT_WORKSPACE_RESOURCE_ID
    $parameters.checkoutOwnerToken = $evidence.CHECKOUT_OWNER_TOKEN
    $parameters.checkoutArcResourceId = $evidence.CHECKOUT_ARC_RESOURCE_ID
    $parameters.checkoutAppResourceId = $evidence.CHECKOUT_APP_RESOURCE_ID
    $parameters.checkoutSre = @{
        resourceId = $evidence.CHECKOUT_SRE_RESOURCE_ID; endpoint = $evidence.CHECKOUT_SRE_ENDPOINT
        latencyRuleId = $evidence.CHECKOUT_LATENCY_RULE_ID; serviceRuleId = $evidence.CHECKOUT_SERVICE_RULE_ID
        createdAt = $evidence.CHECKOUT_CREATED_AT
    }
    $teamsEvidence = Get-IncidentTeamsEvidenceSettings
    $parameters.teamsEvidenceMode = $teamsEvidence.DEMO_EVIDENCE_MODE
    $parameters.teamsEvidenceRevision = $teamsEvidence.TEAMS_EVIDENCE_REVISION
    $parameters.teamsCheckoutWorkspaceId = $teamsEvidence.CHECKOUT_WORKSPACE_ID
    $parameters.teamsCheckoutWorkspaceResourceId = $teamsEvidence.CHECKOUT_WORKSPACE_RESOURCE_ID
    $parameters.teamsCheckoutOwnerToken = $teamsEvidence.CHECKOUT_OWNER_TOKEN
    $parameters.teamsCheckoutArcResourceId = $teamsEvidence.CHECKOUT_ARC_RESOURCE_ID
    $parameters.teamsCheckoutAppResourceId = $teamsEvidence.CHECKOUT_APP_RESOURCE_ID
    $parameters.teamsCheckoutSre = @{
        resourceId = $teamsEvidence.CHECKOUT_SRE_RESOURCE_ID; endpoint = $teamsEvidence.CHECKOUT_SRE_ENDPOINT
        latencyRuleId = $teamsEvidence.CHECKOUT_LATENCY_RULE_ID; serviceRuleId = $teamsEvidence.CHECKOUT_SERVICE_RULE_ID
        createdAt = $teamsEvidence.CHECKOUT_CREATED_AT
    }
    $parameterFile = Join-Path $directory 'incident-parameters.json'
    $armParameters = @{}
    foreach ($key in $parameters.Keys) { $armParameters[$key] = @{ value = $parameters[$key] } }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'; parameters = $armParameters } |
        ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $parameterFile -Encoding utf8NoBOM
    $template = Join-Path $repository 'infra\incident\main.bicep'
    try {
        $null = Invoke-IncidentAzure @('deployment', 'group', 'validate', '--resource-group', $groupName,
            '--template-file', $template, '--parameters', "@$parameterFile") -TimeoutSeconds 300
        $preview = Invoke-IncidentAzure @('deployment', 'group', 'what-if', '--resource-group', $groupName,
            '--template-file', $template, '--parameters', "@$parameterFile", '--no-pretty-print') -TimeoutSeconds 300
        Save-RetailState -State $preview -Path (Join-Path $directory 'incident-whatif.json')
        $deployment = Invoke-IncidentAzure @('deployment', 'group', 'create', '--resource-group', $groupName,
            '--name', "retailtx-incident-$EnvironmentName", '--template-file', $template,
            '--parameters', "@$parameterFile") -TimeoutSeconds 1200
    } finally {
        if (Test-Path -LiteralPath $parameterFile) { Remove-Item -LiteralPath $parameterFile -Force }
    }
    $script:state.outputs = @{}
    foreach ($key in $deployment.properties.outputs.Keys) {
        $script:state.outputs[$key] = $deployment.properties.outputs[$key].value
    }
    Assert-IncidentState $script:state
    $script:state.phase = 'platform-provisioned'
    Save-IncidentState
    $null = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications/$($script:state.applicationObjectId)" `
        -Method PATCH -Body @{ web = @{ redirectUris = @("$($script:state.outputs.webAppUrl)/.auth/login/aad/callback") } }
    $credentials = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications/$($script:state.applicationObjectId)/federatedIdentityCredentials"
    $expected = @($credentials.value | Where-Object { $_.name -ceq 'appservice-auth' })
    if ($expected.Count -gt 1) { throw 'Duplicate browser federation credential.' }
    if ($expected.Count -eq 1) {
        if ($expected[0].subject -ine $script:state.outputs.authIdentityPrincipalId -or
            $expected[0].issuer -cne "https://login.microsoftonline.com/$tenant/v2.0" -or
            @($expected[0].audiences).Count -ne 1 -or $expected[0].audiences[0] -cne 'api://AzureADTokenExchange') {
            throw 'Browser federation credential drifted.'
        }
    } else {
        $null = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications/$($script:state.applicationObjectId)/federatedIdentityCredentials" `
            -Method POST -Body @{ name = 'appservice-auth'; issuer = "https://login.microsoftonline.com/$tenant/v2.0"
                subject = $script:state.outputs.authIdentityPrincipalId; audiences = @('api://AzureADTokenExchange') }
    }
    if (-not $script:state.servicePrincipalId) {
        $principal = Invoke-IncidentRequest 'https://graph.microsoft.com/v1.0/servicePrincipals' -Method POST -Body @{
            appId = $script:state.applicationClientId; appRoleAssignmentRequired = $true
            tags = @('retailtx', "retailtx-owner:$($script:state.ownerToken)")
        }
        $script:state.servicePrincipalId = $principal.id
        Save-IncidentState
    }
    $principalId = ([guid]$script:state.servicePrincipalId).ToString()
    $principal = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId"
    if ($principal.appId -ine $script:state.applicationClientId -or
        "retailtx-owner:$($script:state.ownerToken)" -cnotin $principal.tags -or
        -not $principal.appRoleAssignmentRequired) { throw 'Browser service principal binding drifted.' }
    $assignments = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignedTo"
    $match = @($assignments.value | Where-Object {
        $_.principalId -ieq $script:state.operatorId -and $_.appRoleId -ieq $script:state.operatorRoleId
    })
    if (-not $match.Count) {
        $null = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignedTo" `
            -Method POST -Body @{ principalId = $script:state.operatorId; resourceId = $principalId; appRoleId = $script:state.operatorRoleId }
    }
    $script:state.phase = 'platform-configured'
    Save-IncidentState
}

function Publish-IncidentApplication {
    $archive = Join-Path $directory 'incident-package.zip'
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $repository 'app\incident'), $archive)
        $null = Invoke-IncidentAzure @('webapp', 'deploy', '--resource-group', $groupName,
            '--name', $script:state.outputs.webAppName, '--src-path', $archive,
            '--type', 'zip', '--clean', 'true', '--restart', 'true',
            '--track-status', 'false', '--timeout', '900000') -TimeoutSeconds 1200
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
    $script:state.phase = 'application-published'
    Save-IncidentState
    $tests = Invoke-IncidentCloudJob 'test'
    if (-not $tests.pass -or $tests.testsRun -lt 1) {
        throw 'Azure application tests did not pass; agent bootstrap refused.'
    }
    $script:state.cloudTests = $tests
    Save-IncidentState
    $roleId = if ($script:state.bootstrapAssignmentId) {
        $script:state.bootstrapAssignmentId
    } else { [guid]::NewGuid().ToString() }
    $script:state.bootstrapAssignmentId = $roleId
    Save-IncidentState
    $roleUri = "https://management.azure.com$($script:state.outputs.foundryProjectId)/providers/Microsoft.Authorization/roleAssignments/${roleId}?api-version=2022-04-01"
    try {
        $null = Invoke-IncidentRequest $roleUri -Method PUT -Body @{
            properties = @{
                principalId = $script:state.outputs.runtimePrincipalId; principalType = 'ServicePrincipal'
                roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$bootstrapRole"
            }
        }
        $receipt = Invoke-IncidentCloudJob 'bootstrap'
        if ($receipt.agentName -cne 'incident-manager' -or -not $receipt.agentVersion -or
            [string]$receipt.endpointVersion -cne [string]$receipt.agentVersion) {
            throw 'Cloud bootstrap did not return the expected pinned agent version.'
        }
        $script:state.agentVersion = [string]$receipt.agentVersion
        $script:state.agentEndpointVersion = [string]$receipt.endpointVersion
        Save-IncidentState
        Set-IncidentSettings @{ FOUNDRY_AGENT_VERSION = $script:state.agentVersion }
    } finally {
        $assignment = Invoke-IncidentRequest $roleUri -AllowMissing
        if ($assignment) {
            if ($assignment.properties.principalId -ine $script:state.outputs.runtimePrincipalId -or
                $assignment.properties.roleDefinitionId -ine "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$bootstrapRole") {
                throw 'Temporary bootstrap grant drifted; automatic deletion refused.'
            }
            $null = Invoke-IncidentRequest $roleUri -Method DELETE
        }
        $script:state.bootstrapAssignmentId = ''
        Save-IncidentState
    }
    $script:state.phase = 'agent-configured'
    Save-IncidentState
}

function Assert-IncidentResourceOwnership {
    param([hashtable[]]$Resources)
    foreach ($resource in $Resources) {
        if ($resource.type -ieq 'Microsoft.Authorization/roleAssignments') { continue }
        if ($resource.id -ieq "$groupId/providers/Microsoft.CognitiveServices/accounts/aif-rtx-incident-$EnvironmentName-$($script:state.nameSuffix)/deployments/incident-reasoner") { continue }
        if (-not $resource.ContainsKey('tags') -or -not $resource.tags -or
            $resource.tags.ownerToken -cne $script:state.ownerToken) {
            throw "Resource group contains an unowned resource ($($resource.type)); operation refused."
        }
    }
}

function Test-IncidentModelNetwork {
    param([hashtable]$Foundry, [hashtable[]]$Hosts)
    if (-not $Hosts -or $Foundry.properties.networkAcls.defaultAction -cne 'Deny' -or
        @($Foundry.properties.networkAcls.virtualNetworkRules).Count -ne 0) {
        return $false
    }
    $expectedIps = @()
    foreach ($hostResource in $Hosts) {
        $addresses = [string]$hostResource.properties['possibleOutboundIpAddresses']
        if ([string]::IsNullOrWhiteSpace($addresses)) { return $false }
        foreach ($address in $addresses.Split(',')) {
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsed) -or
                $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
                $parsed.ToString() -cne $address) {
                return $false
            }
            $expectedIps += $address
        }
    }
    $expectedIps = @($expectedIps | Sort-Object -Unique)
    $allowedIps = @($Foundry.properties.networkAcls.ipRules | ForEach-Object { $_.value })
    return @($expectedIps | Where-Object { $_ -notin $allowedIps }).Count -eq 0 -and
        @($allowedIps | Where-Object { $_ -notin $expectedIps }).Count -eq 0
}

function Test-IncidentReadiness {
    $null = Get-IncidentGroup
    $app = Get-IncidentApplication
    if (-not $app) { throw 'Browser registration is missing.' }
    $web = Invoke-IncidentRequest "https://management.azure.com$($script:state.outputs.webAppId)?api-version=2024-04-01"
    $foundry = Invoke-IncidentRequest "https://management.azure.com$($script:state.outputs.foundryAccountId)?api-version=2025-06-01"
    $auth = Invoke-IncidentRequest "https://management.azure.com$($script:state.outputs.webAppId)/config/authsettingsV2?api-version=2024-04-01"
    $settings = Invoke-IncidentRequest "https://management.azure.com$($script:state.outputs.webAppId)/config/appsettings/list?api-version=2024-04-01" -Method POST
    $resources = @(Invoke-IncidentAzure @('resource', 'list', '--resource-group', $groupName))
    Assert-IncidentResourceOwnership -Resources $resources
    Wait-IncidentRuntime
    $checks = [ordered]@{
        resourcesOwned = $true
        backendResponsive = $true
        pinnedAgent = ($script:state.ContainsKey('agentEndpointVersion') -and
            [string]$settings.properties.FOUNDRY_AGENT_VERSION -ceq $script:state.agentVersion -and
            [bool]$script:state.agentVersion -and
            $script:state.agentEndpointVersion -ceq $script:state.agentVersion)
        runtimeIdentity = ($web.identity.principalId -ieq $script:state.outputs.runtimePrincipalId)
        httpsOnly = [bool]$web.properties.httpsOnly
        tenantAdmission = ($auth.properties.platform.enabled -and
            $auth.properties.globalValidation.requireAuthentication -and
            $auth.properties.identityProviders.azureActiveDirectory.registration.clientId -ieq $script:state.applicationClientId -and
            $auth.properties.identityProviders.azureActiveDirectory.registration.openIdIssuer -ceq "https://login.microsoftonline.com/$tenant/v2.0")
        operatorAdmission = ($script:state.operatorId -iin @($auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities))
        onlyLivenessAnonymous = (@($auth.properties.globalValidation.excludedPaths).Count -eq 1 -and
            $auth.properties.globalValidation.excludedPaths[0] -ceq '/health/live')
        secretlessSignIn = ($auth.properties.identityProviders.azureActiveDirectory.registration.clientSecretSettingName -ceq 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID' -and
            $settings.properties.OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID -ieq $script:state.outputs.authIdentityClientId -and
            @($app.passwordCredentials).Count -eq 0)
        modelKeysDisabled = [bool]$foundry.properties.disableLocalAuth
        modelNetworkRestricted = $false
        exactRun = ($settings.properties.DEMO_OWNER_TOKEN -ceq $script:state.ownerToken -and $settings.properties.DEMO_RUN_ID -ceq $script:state.runId)
        evidenceModeBound = $false
        checkoutGrantBound = $false
        bootstrapGrantRemoved = (-not [bool]$script:state.bootstrapAssignmentId)
    }
    $expectedEvidence = Get-IncidentEvidenceSettings
    $evidenceMode = $expectedEvidence.DEMO_EVIDENCE_MODE
    $checks.evidenceModeBound = @($expectedEvidence.Keys | Where-Object {
            [string]$settings.properties[$_] -cne [string]$expectedEvidence[$_]
        }).Count -eq 0
    $checks.checkoutGrantBound = if ($script:state['checkoutBinding']) {
        (Test-CheckoutGrant) -and (Test-IncidentSreGrant)
    } else { $true }
    $networkHosts = @($web)
    if ($script:state['teamsConfig'] -and $script:state.teamsConfig.enabled) {
        $teamsOutputs = Get-IncidentHostOutputs -Teams
        $teamsWeb = Invoke-IncidentRequest "https://management.azure.com$($teamsOutputs.webAppId)?api-version=2024-04-01"
        $networkHosts += $teamsWeb
    }
    $checks.modelNetworkRestricted = Test-IncidentModelNetwork -Foundry $foundry -Hosts $networkHosts
    $grants = @(Invoke-IncidentAzure @('role', 'assignment', 'list', '--assignee-object-id',
        $script:state.outputs.runtimePrincipalId, '--scope', $script:state.outputs.foundryProjectId,
        '--include-inherited', '--query', '[].{role:roleDefinitionId,scope:scope}'))
    $checks.runtimeLeastPrivilege = $grants.Count -eq 1 -and
        $grants[0].role -ieq "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$runtimeRole" -and
        $grants[0].scope -ieq $script:state.outputs.foundryProjectId
    foreach ($policy in @('scm', 'ftp')) {
        $publishing = Invoke-IncidentRequest "https://management.azure.com$($script:state.outputs.webAppId)/basicPublishingCredentialsPolicies/${policy}?api-version=2024-04-01"
        $checks["${policy}BasicAuthDisabled"] = -not $publishing.properties.allow
    }
    # Observe the login redirect without PowerShell's maximum-redirection error.
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $response = $null
    try {
        $response = $client.GetAsync($script:state.outputs.webAppUrl,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $checks.anonymousDenied = [int]$response.StatusCode -in @(302, 401, 403)
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
    }
    $ready = @($checks.Values | Where-Object { -not $_ }).Count -eq 0
    $receipt = @{ ready = $ready; checks = $checks; evidenceMode = $evidenceMode; liveCheckoutVerified = $false
        ownerToken = $script:state.ownerToken; runId = $script:state.runId; checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    Save-RetailState -State $receipt -Path (Join-Path $directory 'incident-readiness.json')
    if (-not $ready) { throw "Readiness failed: $(@($checks.Keys | Where-Object { -not $checks[$_] }) -join ', ')." }
    return @{ ready = $true; evidenceMode = $evidenceMode; liveCheckoutVerified = $false; webAppUrl = $script:state.outputs.webAppUrl }
}

function Remove-IncidentPlatform {
    $group = Get-IncidentGroup
    $app = Get-IncidentApplication
    $teamsInstalled = [bool]$script:state['teamsConfig']
    if ($script:state['teamsCheckoutBinding']) {
        if ($group) {
            $null = Stop-IncidentTeamsRuntime -AllowMissing
        }
        Remove-CheckoutGrant -Teams
        $script:state.teamsCheckoutBinding = $null
        $script:state.teamsConfig.evidenceMode = 'fixture'
        Save-IncidentState
    }
    # The checkout workspace grant lives outside this resource group.
    Remove-CheckoutGrant
    if ($script:state['checkoutBinding']) {
        $script:state.checkoutBinding = $null
        Save-IncidentState
    }
    if ($group) {
        $resources = @(Invoke-IncidentAzure @('resource', 'list', '--resource-group', $groupName))
        Assert-IncidentResourceOwnership -Resources $resources
        $null = Invoke-IncidentAzure @('group', 'delete', '--name', $groupName, '--yes') -TimeoutSeconds 1200
    }
    if ($app) {
        $null = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications/$($script:state.applicationObjectId)" -Method DELETE
    }
    if ($script:state.servicePrincipalId) {
        $principalId = ([guid]$script:state.servicePrincipalId).ToString()
        $principal = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId" -AllowMissing
        if ($principal) {
            if ($principal.appId -ine $script:state.applicationClientId -or
                "retailtx-owner:$($script:state.ownerToken)" -cnotin $principal.tags) {
                throw 'Unexpected service principal; deletion refused.'
            }
            $null = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId" -Method DELETE
        }
    }
    $groupResidual = Invoke-IncidentRequest "https://management.azure.com${groupId}?api-version=2022-09-01" -AllowMissing
    $appResidual = if ($script:state.applicationObjectId) {
        Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/applications/$($script:state.applicationObjectId)" -AllowMissing
    } else { $null }
    $principalResidual = if ($script:state.servicePrincipalId) {
        Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/servicePrincipals/$($script:state.servicePrincipalId)" -AllowMissing
    } else { $null }
    $clean = -not $groupResidual -and -not $appResidual -and -not $principalResidual
    $receipt = @{ activeResourcesRemoved = $clean; ownerToken = $script:state.ownerToken
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        retention = 'Azure and Entra soft-deleted data may remain under provider retention; not a purge claim.' }
    if ($teamsInstalled) {
        $receipt.teamsClientCleanup = 'Personal Teams installation is not inventoried. Uninstall the app in Teams; this is not a tenant/catalog purge claim.'
    }
    Save-RetailState -State $receipt -Path (Join-Path $directory 'incident-residuals.json')
    if (-not $clean) { throw 'Residual check failed; retain ownership manifest and retry Down.' }
    $script:state.phase = 'removed'
    $script:state.removedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-IncidentState
    return @{ removed = $true; retention = $receipt.retention; teamsClientCleanup = $receipt['teamsClientCleanup'] }
}

. (Join-Path $PSScriptRoot 'incident\Teams.ps1')

$script:state = $null
$context = Invoke-IncidentAzure @('account', 'show')
if ($context.tenantId -ine $tenant -or $context.state -cne 'Enabled') {
    throw 'The explicit subscription is not enabled in the authorized tenant.'
}
$credentials = Invoke-IncidentAzure @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
$actor = Get-RetailTokenActor -AccessToken $credentials.accessToken -TenantId $TenantId
$credentials = $null
if ($Action -eq 'Preflight') {
    Test-IncidentPreflight
    return
}
if ($Action -notin @('Ready', 'TeamsReady') -and -not $PSCmdlet.ShouldProcess($groupName, "$Action owned Azure incident assistant")) { return }
if (-not (Test-Path -LiteralPath $directory)) {
    if ($Action -notin @('Provision', 'Up')) { throw 'No ownership manifest. Run Up first.' }
    $null = New-Item -ItemType Directory -Path $directory
}
$lockPath = Join-Path $directory 'incident-agent.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if (Test-Path -LiteralPath $statePath) {
        $script:state = ConvertFrom-IncidentJson (Get-Content -LiteralPath $statePath -Raw)
        Assert-IncidentState $script:state
        if ($script:state.phase -ceq 'removed' -and $Action -ne 'Down') {
            throw 'This deployment is removed. Use a fresh neutral environment name; retain its cleanup receipt.'
        }
    } elseif ($Action -in @('Provision', 'Up')) {
        $script:state = @{
            schemaVersion = 1; profile = 'incident-assistant'; subscriptionId = $subscription
            tenantId = $tenant; environmentName = $EnvironmentName; location = $location
            resourceGroupName = $groupName; ownerToken = [guid]::NewGuid().ToString()
            runId = [guid]::NewGuid().ToString(); nameSuffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
            operatorId = $actor; operatorRoleId = [guid]::NewGuid().ToString()
            createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            expiresAtUtc = [DateTimeOffset]::UtcNow.AddDays($RetentionDays).ToString('o')
            applicationObjectId = ''; applicationClientId = ''; servicePrincipalId = ''
            bootstrapAssignmentId = ''; agentVersion = ''; agentEndpointVersion = ''
            outputs = @{}; phase = 'planned'
        }
        Save-IncidentState
    } else { throw 'No ownership manifest. Run Up first.' }
    switch ($Action) {
        'Provision' {
            Initialize-IncidentPlatform
            @{ platformProvisioned = $true; ready = $false; phase = $script:state.phase }
        }
        'Up' {
            Initialize-IncidentPlatform
            Publish-IncidentApplication
            if ($script:state['teamsConfig'] -and $script:state.teamsConfig.enabled) {
                Publish-IncidentTeams
                Test-IncidentTeamsReadiness
            } else {
                Test-IncidentReadiness
            }
        }
        'Ready' { Test-IncidentReadiness }
        'Probe' {
            $null = Test-IncidentReadiness
            $probe = Invoke-IncidentCloudJob 'probe'
            $probe.checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-RetailState -State $probe -Path (Join-Path $directory 'incident-probe.json')
            $probe
        }
        'Verify' {
            $null = Test-IncidentReadiness
            $tests = Invoke-IncidentCloudJob 'test'
            $evaluation = Invoke-IncidentCloudJob 'evaluate'
            Save-RetailState -State @{ ownerToken = $script:state.ownerToken; runId = $script:state.runId
                checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); tests = $tests
                evaluation = $evaluation; executionLocation = 'Azure App Service'; liveCheckoutVerified = $false
            } -Path (Join-Path $directory 'incident-verification.json')
            $null = Test-IncidentReadiness
            @{ cloudVerificationPassed = $true; executionLocation = 'Azure App Service'
                evidenceMode = 'fixture'; attachedEvidenceMode = (Get-IncidentEvidenceSettings).DEMO_EVIDENCE_MODE
                liveCheckoutVerified = $false }
        }
        'Attach' { Connect-IncidentCheckout }
        'Observe' {
            $null = Test-IncidentReadiness
            Invoke-IncidentLiveCheck
        }
        'Detach' { Disconnect-IncidentCheckout }
        'Reset' {
            $null = Get-IncidentGroup
            $script:state.runId = [guid]::NewGuid().ToString()
            Save-IncidentState
            Set-IncidentSettings @{ DEMO_RUN_ID = $script:state.runId }
            if ($script:state['teamsConfig'] -and $script:state.teamsConfig.enabled) {
                Set-IncidentTeamsRun
            }
            $null = Invoke-IncidentAzure @('webapp', 'restart', '--resource-group', $groupName, '--name', $script:state.outputs.webAppName)
            @{ reset = $true; effect = 'New evidence run and empty in-memory browser sessions; no live resource fault changed.' }
        }
        'Down' { Remove-IncidentPlatform }
        'TeamsUp' { Initialize-IncidentTeams }
        'TeamsReady' { Test-IncidentTeamsReadiness }
        'TeamsPackage' { New-IncidentTeamsPackage }
        'TeamsAttach' { Connect-IncidentCheckout -Teams }
        'TeamsDetach' { Disconnect-IncidentCheckout -Teams }
        'TeamsObserve' {
            $null = Test-IncidentTeamsReadiness
            Invoke-IncidentLiveCheck -Teams
        }
        'TeamsVerify' {
            $null = Test-IncidentTeamsReadiness
            $tests = Invoke-IncidentCloudJob 'test' -Teams
            $evaluation = Invoke-IncidentCloudJob 'evaluate' -Teams
            Save-RetailState -State @{ tests = $tests; evaluation = $evaluation
                ownerToken = $script:state.ownerToken; runId = $script:state.runId
                checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                executionLocation = 'Azure App Service'; teamsConversationVerified = $false
            } -Path (Join-Path $directory 'incident-teams-verification.json')
            @{ cloudFixtureVerificationPassed = $true; teamsConversationVerified = $false }
        }
        'TeamsDown' { Remove-IncidentTeams }
    }
} finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force
}
