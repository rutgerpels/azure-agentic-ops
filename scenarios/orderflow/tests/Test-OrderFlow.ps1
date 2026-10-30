#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scenarioRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $scenarioRoot 'scripts\OrderFlow.Common.psm1') -Force -PassThru
. (Join-Path $scenarioRoot 'scripts\OrderFlow.Sre.ps1')
$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Operation, [string]$Message)
    $threw = $false
    try { & $Operation } catch { $threw = $true }
    Assert-Test $threw $Message
}

$errors = @()
foreach ($file in (Get-ChildItem (Join-Path $scenarioRoot 'scripts') -File)) {
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    $errors += @($parseErrors)
}
Assert-Test ($errors.Count -eq 0) "PowerShell parsing failed: $errors"
Assert-OrderFlowCidr '203.0.113.1/32'
foreach ($cidr in @('0.0.0.0/0', '10.0.0.0/8', '999.1.1.1/32', '::1/128', '203.0.113.1', '203.0.113.1/33')) {
    Assert-Throws { Assert-OrderFlowCidr $cidr } "Unsafe CIDR admitted: $cidr"
}

$baseline = Get-OrderFlowBaseline
$rule = @{ properties = $baseline.Clone() }
$rule.properties.provisioningState = 'Succeeded'
Assert-OrderFlowRule $rule $baseline
foreach ($entry in @{
    access = 'Deny'; sourceAddressPrefix = '*'; destinationPortRange = '22'
    priority = 100; direction = 'Outbound'; protocol = '*'
    description = 'another owner'; provisioningState = 'Updating'
}.GetEnumerator()) {
    $changed = @{ properties = $rule.properties.Clone() }
    $changed.properties[$entry.Key] = $entry.Value
    Assert-Throws { Assert-OrderFlowRule $changed $baseline } "Rule drift admitted: $($entry.Key)"
}
$changed = @{ properties = $rule.properties.Clone() }
$changed.properties.sourceAddressPrefixes = @('*')
Assert-Throws { Assert-OrderFlowRule $changed $baseline } 'Plural source bypass admitted.'

$policy = Get-OrderFlowPolicy
Assert-OrderFlowPolicy $policy
$policy.permissions.allow = @('RunAzCliWriteCommands')
Assert-Throws { Assert-OrderFlowPolicy $policy } 'Allow-over-Ask bypass admitted.'
$policy = Get-OrderFlowPolicy
$policy.permissions.ask = @()
Assert-Throws { Assert-OrderFlowPolicy $policy } 'Missing native approval admitted.'
$policy = Get-OrderFlowPolicy
$policy.permissions.deny = @()
Assert-Throws { Assert-OrderFlowPolicy $policy } 'Alternate write tools admitted.'

Assert-Test ((Get-OrderFlowList @{ value = @() }).Count -eq 0) 'Empty provider list failed.'
Assert-Throws { Get-OrderFlowList @{ items = @() } } 'Unsupported list silently became empty.'
Assert-Throws { Get-OrderFlowList @{ value = @(); nextLink = 'next' } } 'Truncated list admitted.'

$subscription = '11111111-1111-1111-1111-111111111111'
$owner = '22222222-2222-2222-2222-222222222222'
$groupId = "/subscriptions/$subscription/resourceGroups/rg-orderflow-test01"
$state = @{
    schemaVersion = 1; scenario = 'orderflow'; subscriptionId = $subscription
    environmentName = 'test01'; resourceGroup = 'rg-orderflow-test01'; deploymentName = 'orderflow-test01'
    ownerToken = $owner; configured = $true; phase = 'published'; pendingOperation = $null; fault = $null; outputs = @{
        ruleId = "$groupId/providers/Microsoft.Network/networkSecurityGroups/nsg-test/securityRules/PortalToOrderApi"
        webAppId = "$groupId/providers/Microsoft.Web/sites/portal-test"
        workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-test"
        workspaceCustomerId = '33333333-3333-3333-3333-333333333333'
        alertName = 'orderflow-test'
    }
}
Assert-OrderFlowState $state $subscription 'test01'
Assert-OrderFlowAction $state 'Fault'
$pending = $state.Clone(); $pending.pendingOperation = 'fault'
foreach ($action in @('Fault', 'Undo', 'Publish', 'ConfigureSre', 'Verify', 'Down')) {
    Assert-Throws { Assert-OrderFlowAction $pending $action } "Unknown mutation admitted $action."
}
Assert-OrderFlowAction $pending 'Observe'
$used = $state.Clone(); $used.fault = @{ runId = $owner }
foreach ($action in @('Fault', 'Publish', 'ConfigureSre', 'Ready')) {
    Assert-Throws { Assert-OrderFlowAction $used $action } "Second-generation action admitted $action."
}
Assert-OrderFlowAction $used 'Verify'
$failed = $state.Clone(); $failed.phase = 'deployment-failed'
Assert-OrderFlowAction $failed 'Down'
Assert-Throws { Assert-OrderFlowAction $failed 'Publish' } 'Failed deployment admitted publication.'
Assert-Throws { Assert-OrderFlowAction $failed 'Fault' } 'Failed deployment admitted a fault.'
$used.phase = 'removed'
Assert-Throws { Assert-OrderFlowAction $used 'Fault' } 'Retired generation admitted.'
Assert-Throws { Assert-OrderFlowState $state $subscription 'test02' } 'Cross-environment state admitted.'
$bad = $state.Clone(); $bad.outputs = $state.outputs.Clone()
$bad.outputs.ruleId = $bad.outputs.ruleId.Replace('rg-orderflow-test01', 'rg-retailx')
Assert-Throws { Assert-OrderFlowState $bad $subscription 'test01' } 'Foreign resource output admitted.'

$investigator = Get-OrderFlowInvestigator $state
Assert-Test ($investigator.properties.instructions.Contains("OrderFlow presenter fault $owner")) 'Run binding missing.'
Assert-Test ($investigator.properties.instructions -notmatch '\{\{') 'Unresolved agent template.'
Assert-Test ($investigator.properties.tools.Count -eq 4) 'Unexpected investigator tools.'
$plan = Get-OrderFlowResponsePlan $state
Assert-Test ($plan.properties.agentMode -ceq 'review' -and -not $plan.properties.mergeEnabled) 'Unsafe response plan.'

# Mock external boundaries to exercise ownership and probe semantics without Azure.
& $module {
    $script:fakeGroup = @{ tags = @{ ownerToken = '22222222-2222-2222-2222-222222222222'
        scenario = 'orderflow'; managedBy = 'invoke-orderflow' }; properties = @{ provisioningState = 'Succeeded' } }
    function script:Invoke-OrderFlowAzure { param($State, $Arguments, $TimeoutSeconds); return $script:fakeGroup }
    $script:fakeResponse = @{ StatusCode = 200; Content = '{"status":"healthy"}' }
    function script:Invoke-WebRequest {
        param($Uri, $TimeoutSec, $MaximumRedirection, [switch]$SkipHttpErrorCheck)
        return $script:fakeResponse
    }
}
Assert-OrderFlowOwner $state
& $module { $script:fakeGroup.tags.ownerToken = 'foreign' }
Assert-Throws { Assert-OrderFlowOwner $state } 'Foreign group adopted.'
& $module { $script:fakeGroup.tags.ownerToken = '22222222-2222-2222-2222-222222222222'; $script:fakeGroup.properties.provisioningState = 'Deleting' }
Assert-Throws { Assert-OrderFlowOwner $state } 'Deleting group admitted.'
$state.outputs.webAppUrl = 'https://portal-test.azurewebsites.net'
Assert-Test ((Get-OrderFlowProbe $state).healthy) 'Healthy dependency probe rejected.'
& $module { $script:fakeResponse = @{ StatusCode = 503; Content = '{"status":"unavailable"}' } }
Assert-Test (-not (Get-OrderFlowProbe $state).healthy) 'HTTP dependency failure became healthy.'
& $module { $script:fakeResponse = @{ StatusCode = 200; Content = '{"status":"online"}' } }
Assert-Test (-not (Get-OrderFlowProbe $state).healthy) 'Process liveness became dependency health.'

$entry = Get-Content (Join-Path $scenarioRoot 'scripts\Invoke-OrderFlow.ps1') -Raw
Assert-Test ($entry.Contains(".azure\orderflow\")) 'Missing isolated ownership namespace.'
Assert-Test ($entry.Contains('Assert-OrderFlowAction $state $Action')) 'Missing single-generation fault gate.'
Assert-Test ($entry.Contains("pendingOperation = 'fault'; Save-OrderFlowState")) 'Mutation intent must persist before fault.'
Assert-Test ($entry.Contains("pendingOperation = 'undo'; Save-OrderFlowState")) 'Mutation intent must persist before undo.'
Assert-Test ($entry -notmatch 'Start-Job|while\s*\(\$true\)|--force-deletion') 'Unexpected unbounded/replayed operation.'
$infra = Get-Content (Join-Path $scenarioRoot 'infra\sre.bicep') -Raw
Assert-Test ($infra.Contains('scope: rule')) 'SRE mutation must be scoped to exact rule.'
Assert-Test ($infra -notmatch 'Contributor|runCommand|roleAssignments/write') 'Unexpected broad remediation role.'

$before = Get-OrderFlowSourceHash
$generated = Join-Path $scenarioRoot "infra\generated-$([guid]::NewGuid().ToString('N')).json"
try {
    Set-Content -LiteralPath $generated -Value '{"generated":true}'
    Assert-Test ((Get-OrderFlowSourceHash) -ceq $before) 'Generated infrastructure affected deployment source hash.'
} finally { Remove-Item -LiteralPath $generated }

# Canonical subscription-qualified role IDs must match an RG-declared definition.
$roleGuid = '44444444-4444-4444-4444-444444444444'
$state.outputs.repairRoleId = "$groupId/providers/Microsoft.Authorization/roleDefinitions/$roleGuid"
$state.outputs.repairAssignmentId = "$($state.outputs.ruleId)/providers/Microsoft.Authorization/roleAssignments/55555555-5555-5555-5555-555555555555"
$state.outputs.srePrincipalId = '66666666-6666-6666-6666-666666666666'
function Invoke-OrderFlowRequest {
    param($State, $Uri)
    if ($Uri -match '/roleDefinitions/') {
        return @{ properties = @{ assignableScopes = @($groupId); permissions = @(@{
            actions = @('Microsoft.Network/networkSecurityGroups/securityRules/read',
                'Microsoft.Network/networkSecurityGroups/securityRules/write')
            notActions = @(); dataActions = @(); notDataActions = @()
        }) } }
    }
    return @{ properties = @{
        principalId = $State.outputs.srePrincipalId; scope = $State.outputs.ruleId
        roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$roleGuid"
    } }
}
Assert-OrderFlowRepairRole $state
$script:checks++

# Terminal deployment state is observed once, then admits cleanup only.
& $module {
    $script:partialRecovered = $false
    $script:deploymentStatus = 'Failed'
    function script:Invoke-OrderFlowAzure {
        param($State, $Arguments, $TimeoutSeconds)
        if ($Arguments -contains 'show') { return @{ properties = @{ provisioningState = $script:deploymentStatus } } }
        return @(@{ properties = @{ provisioningState = 'Failed' } })
    }
    function script:Set-OrderFlowPartialOutputs {
        param($State)
        $script:partialRecovered = $true
        $State.outputs.vmId = '/owned-vm'
        $State.outputs.repairRoleId = '/owned-role'
    }
}
$partial = $state.Clone(); $partial.outputs = @{}; $partial.pendingOperation = 'deployment'
Update-OrderFlowOutputs $partial
Assert-Test ($partial.phase -ceq 'deployment-failed' -and -not $partial.pendingOperation) 'Terminal failure remained stuck.'
Assert-Test ($partial.outputs.repairRoleId -ceq '/owned-role') 'Partial cleanup role was not recovered.'
Assert-OrderFlowAction $partial 'Down'
& $module { $script:deploymentStatus = 'Running' }
$running = $state.Clone(); $running.pendingOperation = 'deployment'
Assert-Throws { Update-OrderFlowOutputs $running } 'Running deployment became terminal.'
Assert-Test ($running.pendingOperation -ceq 'deployment') 'Running deployment intent was cleared.'

# A lost response after each configuration PUT preserves intent and blocks mutations.
function Save-OrderFlowState {
    param($State, $Path)
    $script:savedPending = $State.pendingOperation
}
function Invoke-OrderFlowSre {
    param($State, $Endpoint, $Path, $Method = 'GET', $Body, [switch]$Raw, $IfMatch, [switch]$AllowMissing)
    if ($Method -ceq 'PUT') {
        Assert-Test ($script:savedPending -ceq 'sre-config') 'Configuration PUT preceded durable intent.'
        $script:providerConfig = $Body
        $script:configWrites++
        throw 'Simulated lost response after provider applied PUT.'
    }
    return $script:providerConfig
}
foreach ($path in @('/api/v2/agent/settings/global', '/api/v2/extendedAgent/agents/orderflow-investigator',
    '/api/v2/incidentManagement/incidentFilters/orderflow-response')) {
    $script:providerConfig = $null; $script:configWrites = 0; $script:savedPending = $null
    $configuration = $state.Clone(); $configuration.pendingOperation = $null
    $payload = @{ name = 'owned'; properties = @{ enabled = $true } }
    Assert-Throws { Invoke-OrderFlowConfigWrite $configuration 'unused' 'https://test.azuresre.ai' $path $payload } 'Lost PUT response was swallowed.'
    Assert-Test ($configuration.pendingOperation -ceq 'sre-config' -and -not $configuration.configured) 'Lost PUT failed to retain stage.'
    Assert-Throws { Assert-OrderFlowAction $configuration 'Down' } 'Teardown raced unknown configuration.'
    Complete-OrderFlowConfigObservation $configuration 'unused' 'https://test.azuresre.ai'
    Assert-Test (-not $configuration.pendingOperation) 'Matching configuration observation did not settle stage.'
    Invoke-OrderFlowConfigWrite $configuration 'unused' 'https://test.azuresre.ai' $path $payload
    Assert-Test ($script:configWrites -eq 1) 'Observed configuration was replayed.'
}

[pscustomobject]@{ checks = $script:checks; result = 'Passed (offline; no Azure calls)' }
