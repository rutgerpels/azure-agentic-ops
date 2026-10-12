#Requires -Version 7.2
# Local native skill lifecycle/readiness/reset contracts; no Azure or guest writes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\disk\DiskSre.ps1')
. (Join-Path $root 'scripts\guest\GuestMonitor.ps1')
. (Join-Path $root 'scripts\guest\GuestRecoverySkill.ps1')
$subscription = [guid]::NewGuid().ToString()
$EnvironmentName = 'demo01'
$vmId = "/subscriptions/$subscription/resourceGroups/guest/providers/Microsoft.Compute/virtualMachines/guest"
$script:state = @{ withSreExecution = $true; withMonitoring = $true; faultLifetime = 'Manual'
    vmId = $vmId; ownerToken = [guid]::NewGuid().ToString(); agentPrincipalId = [guid]::NewGuid().ToString()
    agentId = "/subscriptions/$subscription/resourceGroups/guest/providers/Microsoft.App/agents/guest"
    workspaceId = "/subscriptions/$subscription/resourceGroups/guest/providers/Microsoft.OperationalInsights/workspaces/guest"
    workspaceCustomerId = [guid]::NewGuid().ToString() }
$statePath = 'unused-local-state'
$connection = @{ endpoint = 'unused-local-endpoint' }
$script:liveSkill = $null
$script:liveAgent = $null
$script:livePlan = $null
$script:inventoryMode = 'Array'
$script:writes = @()
$script:checks = 0
$script:uncertainPut = $false
$script:badPlan = $false
$script:nativeMode = $true
$script:policy = @{ permissions = @{ allow = @()
    ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
    deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
function Save-RetailState { param($State, $Path) }
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe recovery skill input accepted.' }
    $script:checks++
}
function Copy-Value { param($Value) return ($Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable) }
function Get-GuestMonitorPlan {
    param($Connection)
    if ($script:badPlan) { throw 'Mock plan drift.' }
    return $script:livePlan
}
function Invoke-DiskSreRequest {
    param($Connection, $Method, $Path, $Body, [switch]$AllowMissing, [switch]$PreserveCollection)
    if ($Method -cne 'GET') { $script:writes += "$Method $Path" }
    if ($Path -ceq '/api/v2/extendedAgent/skills') {
        if (-not $PreserveCollection) { throw 'Collection response shape must be preserved.' }
        $items = @(if ($script:liveSkill) { $script:liveSkill })
        if ($script:inventoryMode -ceq 'Array') { return ,$items }
        if ($script:inventoryMode -ceq 'Envelope') { return @{ value = $items } }
        if ($script:inventoryMode -ceq 'Partial') { return @{ value = $items; nextLink = 'not-complete' } }
        if ($script:inventoryMode -ceq 'Ambiguous') { return ,@($script:liveSkill, $script:liveSkill) }
        return $null
    }
    if ($Path -ceq '/api/v2/extendedAgent/skills/guest-service-recovery') {
        if ($Method -ceq 'PUT') {
            if ($script:uncertainPut) { throw 'Mock uncertain request.' }
            $script:liveSkill = Copy-Value $Body
            return
        }
        if ($Method -ceq 'DELETE') { $script:liveSkill = $null; return }
    }
    if ($Path -ceq '/api/v2/agent/settings/global') { return $script:policy }
    if ($Path -ceq '/api/v2/extendedAgent/agents/meta_agent') {
        return @{ name = 'meta_agent'; properties = @{ enableVanillaMode = $script:nativeMode } }
    }
    if ($Path -ceq '/api/v2/extendedAgent/agents/retailtx-guest-demo01') {
        if ($Method -ceq 'GET') { return $script:liveAgent }
        if ($Method -ceq 'DELETE') { $script:liveAgent = $null; return }
    }
    if ($Path -ceq '/api/v2/incidentManagement/incidentFilters/retailtx-guest-demo01') {
        if ($Method -ceq 'GET') { return $script:livePlan }
        if ($Method -ceq 'DELETE') { $script:livePlan = $null; return }
    }
    if ($Path -like '/api/v1/threads/*/messages') { return $script:messages }
    throw "Unexpected mock request: $Method $Path"
}
$binding = Get-GuestRecoveryBinding
if ($binding.actionPrincipalId -cne $script:state.agentPrincipalId -or $binding.ContainsKey('runId')) {
    throw 'Runtime fault values must not be embedded in the reusable fixture binding.'
}
$probe = @"
Set-StrictMode -Version Latest
`$root = '$root'
`$subscription = '$subscription'
`$EnvironmentName = '$EnvironmentName'
`$vmId = '$vmId'
`$script:state = '$(ConvertTo-DiskSreCanonicalJson $script:state)' | ConvertFrom-Json -AsHashtable
. (Join-Path `$root 'scripts\disk\DiskSre.ps1')
. (Join-Path `$root 'scripts\guest\GuestMonitor.ps1')
. (Join-Path `$root 'scripts\guest\GuestRecoverySkill.ps1')
(New-GuestRecoveryInvestigator).properties.instructions
"@
$first = (& pwsh -NoProfile -NonInteractive -Command $probe) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'First independent binding generation failed.' }
$second = (& pwsh -NoProfile -NonInteractive -Command $probe) -join "`n"
if ($LASTEXITCODE -ne 0 -or $first -cne $second -or -not $first.Contains('GuestRecoveryBinding')) {
    throw 'Investigator binding serialization differs between independent processes.'
}
$specification = New-GuestRecoverySkillSpecification
foreach ($mode in @($false, $null, 'true')) {
    $script:nativeMode = $mode
    Assert-Rejected { Initialize-GuestRecoverySkill $connection }
}
$script:nativeMode = $true
if ($script:writes.Count -or $script:state['recoverySkill']) {
    throw 'Missing native mode caused upload intent or mutation.'
}
$script:liveSkill = Copy-Value $specification
Assert-Rejected { Initialize-GuestRecoverySkill $connection }
if ($script:writes.Count) { throw 'Unowned skill collision mutated resources.' }
$script:liveSkill = $null
$script:uncertainPut = $true
Assert-Rejected { Initialize-GuestRecoverySkill $connection }
if ($script:state.recoverySkill.phase -cne 'Requested' -or $script:writes.Count -ne 1) {
    throw 'Uncertain skill request intent was not preserved.'
}
$script:uncertainPut = $false
Assert-Rejected { Initialize-GuestRecoverySkill $connection }
if ($script:writes.Count -ne 1) { throw 'Uncertain skill PUT was replayed.' }
# A later exact independent read reconciles intent, without another PUT.
$script:liveSkill = Copy-Value $specification
$investigator = Initialize-GuestRecoverySkill $connection
$null = Initialize-GuestRecoverySkill $connection
if ($script:writes.Count -ne 1) { throw 'Repeat create changed an already verified skill.' }
if ($investigator.properties.allowedSkills[0] -cne 'guest-service-recovery' -or
    $investigator.properties.enableSkills -ne $true -or
    $investigator.properties.instructions -match 'Invoke-GuestServiceApproval.ps1 Propose|SCRIPT=|runId":') {
    throw 'Skill routing retained an operator command prerequisite or historical run binding.'
}
$script:liveAgent = Copy-Value $investigator
$script:livePlan = @{ name = 'retailtx-guest-demo01'; properties = @{ agentMode = 'review' } }
$null = Assert-GuestRecoverySkillReady $connection
$script:nativeMode = $false
Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
$script:nativeMode = $true
$script:inventoryMode = 'Envelope'
$null = Assert-GuestRecoverySkillReady $connection
foreach ($mode in @('Partial', 'Ambiguous', 'Empty')) {
    $script:inventoryMode = $mode
    Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
}
$script:inventoryMode = 'Array'
foreach ($field in @('skillContent', 'description', 'tools')) {
    $original = $script:liveSkill.properties[$field]
    $script:liveSkill.properties[$field] = if ($field -ceq 'tools') { @('ExecutePythonCode') } else { 'foreign' }
    Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
    Assert-Rejected { Remove-GuestRecoverySkill $connection }
    $script:liveSkill.properties[$field] = $original
}
foreach ($field in @('additionalFiles', 'sourcePluginInstallation')) {
    $original = $script:liveSkill.properties[$field]
    $script:liveSkill.properties[$field] = @('foreign')
    Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
    Assert-Rejected { Remove-GuestRecoverySkill $connection }
    $script:liveSkill.properties[$field] = $original
}
foreach ($field in @('instructions', 'allowedSkills', 'enableSkills', 'tools', 'addSystemSkills')) {
    $original = $script:liveAgent.properties[$field]
    $script:liveAgent.properties[$field] = 'foreign'
    Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
    Assert-Rejected { Remove-GuestRecoverySkill $connection }
    $script:liveAgent.properties[$field] = $original
}
$script:policy.permissions.allow = @('RunAzCliWriteCommands')
Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
$script:policy.permissions.allow = @()
$script:badPlan = $true
Assert-Rejected { Remove-GuestRecoverySkill $connection }
$script:badPlan = $false
if ($script:writes.Count -ne 1) { throw 'Removal mutated before validating all owned surfaces.' }
$originalPrincipal = $script:state.agentPrincipalId
$script:state.agentPrincipalId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-GuestRecoverySkillReady $connection }
$script:state.agentPrincipalId = $originalPrincipal
Remove-GuestRecoverySkill $connection
Remove-GuestRecoverySkill $connection
if ($script:state.recoverySkill.phase -cne 'Removed' -or $script:writes.Count -ne 4) {
    throw 'Exact owned removal is incomplete or repeated DELETE was submitted.'
}
Assert-Rejected { Assert-GuestRecoverySkillReady $connection }

$script:state.currentFault = @{ runId = [guid]::NewGuid().ToString(); canary = $false }
$script:incident = @{ threadId = [guid]::NewGuid().ToString() }
$script:messages = @{ state = 'Idle'; value = @() }
function Get-GuestMonitorIncident { return $script:incident }
function Get-GuestMonitorConnection { return $connection }
Assert-GuestRecoveryResetSafe @{ observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
$script:messages.state = 'Running'
Assert-Rejected { Assert-GuestRecoveryResetSafe @{} }
$script:messages.state = 'Idle'
$script:messages.value = @(@{ approval = @{ status = 'Pending' } })
Assert-Rejected { Assert-GuestRecoveryResetSafe @{} }
$start = [DateTimeOffset]::UtcNow.AddMinutes(-2)
$execution = @{ status = 'Completed'; startedTimestamp = $start.ToString('o')
    completedTimestamp = $start.AddSeconds(5).ToString('o'); requiredScopes = @()
    command = "az vm run-command invoke --ids $vmId --subscription $subscription --scripts 'readable' --no-wait --output json"
    originalFunctionCall = '{"Name":"RunAzCliWriteCommands"}' }
$approval = @{ status = 'Approved'; command = $execution.command; approveForThread = $false; approveScope = 'none' }
$script:messages.value = @(@{ approval = $approval })
Assert-Rejected { Assert-GuestRecoveryResetSafe @{} }
$script:messages.value = @(@{ azCliExecution = $execution }, @{ approval = $approval })
$correlation = [guid]::NewGuid().ToString()
$script:events = @('Started', 'Succeeded') | ForEach-Object {
    @{ resourceId = $vmId; caller = $script:state.agentPrincipalId
        operationName = @{ value = 'Microsoft.Compute/virtualMachines/runCommand/action' }
        status = @{ value = $_ }; correlationId = $correlation
        operationId = [guid]::NewGuid().ToString()
        eventTimestamp = $start.AddSeconds($(if ($_ -ceq 'Started') { 2 } else { 20 })).ToString('o') }
}
function Invoke-Azure { param($Arguments) return $script:events }
$guest = @{ observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
Assert-GuestRecoveryResetSafe $guest
$execution.originalFunctionCall = '{"Name":"RunAzCliReadCommands"}'
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }
$execution.originalFunctionCall = '{"Name":"RunAzCliWriteCommands"}'
$approval.approveForThread = $true
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }
$approval.approveForThread = $false
$script:messages.value = @(@{ azCliExecution = $execution })
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }
$script:messages.value = @(@{ azCliExecution = $execution }, @{ approval = $approval })
$script:events[1].correlationId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }
$script:events[1].correlationId = $correlation
$execution.status = 'Pending'
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }
$execution.status = 'Completed'
$script:events = @()
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }
$script:incident.threadId = $null
Assert-Rejected { Assert-GuestRecoveryResetSafe $guest }

& (Join-Path $root 'scripts\Invoke-GuestService.ps1') Connect -SubscriptionId $subscription `
    -EnvironmentName dry01 -WithRecoverySkill -WhatIf
& (Join-Path $root 'scripts\Invoke-GuestService.ps1') SkillCheck -SubscriptionId $subscription `
    -EnvironmentName dry01 -WhatIf
Assert-Rejected {
    & (Join-Path $root 'scripts\Invoke-GuestService.ps1') Up -SubscriptionId $subscription -WithRecoverySkill -WhatIf
}
"Guest recovery skill contracts passed ($script:checks rejection checks; mocked lifecycle writes only)."
