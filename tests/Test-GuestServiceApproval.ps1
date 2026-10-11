#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\scripts\Invoke-GuestServiceApproval.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$text = $ast.Extent.Text
$operationAssignment = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -ceq 'observationOperation'
}, $true)
$guestAssignment = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -ceq 'guest' -and $node.Right.Extent.Text.Contains('$observationOperation')
}, $true)
if (-not $operationAssignment -or -not $guestAssignment) { throw 'Missing explicit approval verification read source.' }
foreach ($mode in @('Operator', 'VmIdentity', $null)) {
    $state = @{ monitorReadMode = $mode }
    $result = @{ receipt = @{ source = 'OperatorCli' }; evidence = @{ source = 'VmIdentity' } }
    . ([scriptblock]::Create($operationAssignment.Extent.Text))
    . ([scriptblock]::Create($guestAssignment.Extent.Text))
    $expected = if ($mode -ceq 'Operator') { 'Telemetry' } else { 'Status' }
    $source = if ($mode -ceq 'Operator') { 'OperatorCli' } else { 'VmIdentity' }
    if ($observationOperation -cne $expected -or $guest.source -cne $source) {
        throw 'Approval verification read source does not preserve explicit/legacy identity.'
    }
}
foreach ($name in @('Assert-ApprovalPolicy', 'New-ApprovedRepairCommand', 'Assert-ApprovedExecution',
    'Assert-ApprovalStatus', 'Assert-ApprovedRecovery', 'Assert-ApprovalInventory', 'Get-ApprovedRepairOperation')) {
    $helper = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($helper.Extent.Text))
}
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid approval proof input accepted.' }
}
$policy = @{ permissions = @{ allow = @()
    ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
    deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
Assert-ApprovalPolicy $policy
Assert-Rejected { Assert-ApprovalPolicy @{ permissions = @{ allow = @(); ask = @(); deny = @() } } }
Assert-Rejected { Assert-ApprovalPolicy @{ permissions = @{ allow = @('RunAzCliWriteCommands') } } }
Assert-Rejected { Assert-ApprovalPolicy @{ permissions = @{ ask = $policy.permissions.ask; deny = $policy.permissions.deny } } }
$fixture = @{ ownerToken = [guid]::NewGuid().ToString(); sourceHashes = @{ 'controller.py' = 'a' * 64 }
    agentPrincipalId = [guid]::NewGuid().ToString(); subscriptionId = [guid]::NewGuid().ToString()
    vmId = '/subscriptions/test/resourceGroups/fixture/providers/Microsoft.Compute/virtualMachines/test' }
$initial = @{ runId = [guid]::NewGuid().ToString(); actor = [guid]::NewGuid().ToString()
    phase = 'fault-active'; canary = $false; deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(8).ToString('o') }
$guest = @{ marker = $initial.Clone(); active = $false; healthy = $false
    observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
$command = New-ApprovedRepairCommand $fixture $guest
if ($command -notmatch "echo ([A-Za-z0-9+/=]+) \| base64 --decode \| python3'") { throw 'Expected short repair wrapper.' }
$code = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
if ($code -notmatch '(?m)^r=(.+)$') { throw 'Expected explicit current-run request.' }
$request = $Matches[1] | ConvertFrom-Json -AsHashtable
if (-not $code.Contains("r['sourceHashes']=json.load(open('/opt/retailtx-guest/config.json'))['sourceHashes']") -or
    -not $code.Contains("'/opt/retailtx-guest/controller.py'")) { throw 'Wrapper must invoke existing attested controller.' }
if ($request.actor -cne $fixture.agentPrincipalId -or $request.runId -cne $initial.runId -or
    [DateTimeOffset]$request.expectedDeadlineUtc -ne [DateTimeOffset]$initial.deadlineUtc) {
    throw 'Repair request does not bind action identity, run and deadline.'
}
$policyLoop = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $node.Extent.Text.StartsWith('foreach ($approval in $policyApprovals', [StringComparison]::Ordinal)
}, $true)
if (-not $policyLoop) { throw 'Missing exact pending policy-card validation.' }
$saved = @{ expectedCommand = $command; initial = $initial }
$owner = $fixture.ownerToken
$threadId = [guid]::NewGuid().ToString()
$directory = 'unused-unit-test-path'
$script:policyReceipt = $null
function Save-RetailState {
    param([hashtable]$State, [string]$Path)
    $script:policyReceipt = $State
}
$card = @{ id = [guid]::NewGuid().ToString(); command = $command; status = 'Pending'
    expiredByTimeout = $false; decisionTimestamp = $null; approveForThread = $false; approveScope = 'none' }
$policyApprovals = @($card)
. ([scriptblock]::Create($policyLoop.Extent.Text))
if ($script:policyReceipt -or $pendingApprovalReceipt.phase -cne 'ExactHumanPolicyApprovalPending') {
    throw 'Exact card inspection must prepare, but not yet persist, a pending approval receipt.'
}
$policyApprovals = @($card, $card)
$script:policyReceipt = $null
Assert-Rejected {
    Assert-ApprovalInventory $policyApprovals $saved.expectedCommand
    . ([scriptblock]::Create($policyLoop.Extent.Text))
}
if ($script:policyReceipt) { throw 'Duplicate pending cards must never persist a safe approval receipt.' }
$policyApprovals = @($card)
foreach ($alteredCode in @($code.Replace('/opt/retailtx-guest/controller.py', '/opt/retailtx-gust/controller.py'),
    "$code`n")) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($alteredCode))
    $card.command = [regex]::Replace($command, '(?<=echo )[A-Za-z0-9+/=]+(?= \| base64)', $encoded)
    $script:policyReceipt = $null
    Assert-Rejected { . ([scriptblock]::Create($policyLoop.Extent.Text)) }
    if ($script:policyReceipt) { throw 'Altered policy card must not persist a safe approval receipt.' }
}
$card.command = $command
foreach ($change in @(
    @{ approveForThread = $true }, @{ approveScope = 'thread' }, @{ expiredByTimeout = $true },
    @{ decisionTimestamp = [DateTimeOffset]::UtcNow.ToString('o') }
)) {
    foreach ($field in $change.Keys) {
        $original = $card[$field]
        $card[$field] = $change[$field]
        Assert-Rejected { . ([scriptblock]::Create($policyLoop.Extent.Text)) }
        $card[$field] = $original
    }
}
$initialDeadline = $initial.deadlineUtc
$initial.deadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o')
Assert-Rejected { . ([scriptblock]::Create($policyLoop.Extent.Text)) }
$initial.deadlineUtc = $initialDeadline
$guest.marker.canary = $true
Assert-Rejected { New-ApprovedRepairCommand $fixture $guest }
$guest.marker.canary = $false
$guest.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
Assert-Rejected { New-ApprovedRepairCommand $fixture $guest }
$guest.observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
$execution = @{ id = [guid]::NewGuid().ToString(); command = $command; requiredScopes = $null
    originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $command } } | ConvertTo-Json) }
Assert-ApprovedExecution $execution $command
$execution.status = 'Pending'
$status = @{ id = $execution.id; command = $command; status = 'Pending'; requiredScopes = $null
    startedTimestamp = $null; completedTimestamp = $null }
Assert-ApprovalStatus $status $execution $command
$status.startedTimestamp = [DateTimeOffset]::UtcNow.ToString('o')
Assert-Rejected { Assert-ApprovalStatus $status $execution $command }
$status.startedTimestamp = $null
$status.requiredScopes = @('OBO')
Assert-Rejected { Assert-ApprovalStatus $status $execution $command }
$execution.requiredScopes = @('elevation')
Assert-Rejected { Assert-ApprovedExecution $execution $command }
$execution.requiredScopes = $null
$execution.command = "$command; echo unsafe"
Assert-Rejected { Assert-ApprovedExecution $execution $command }
$guest.active = $true
$guest.healthy = $true
$guest.marker.phase = 'recovered'
$guest.marker.recoveryReason = 'repair'
$guest.marker.recoveredBy = $fixture.agentPrincipalId
$guest.marker.recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
Assert-ApprovedRecovery $guest $initial $fixture.agentPrincipalId
$roundTrip = $initial | ConvertTo-Json | ConvertFrom-Json -AsHashtable
Assert-ApprovedRecovery $guest $roundTrip $fixture.agentPrincipalId
foreach ($field in @('recoveredBy', 'runId', 'recoveryReason')) {
    $original = $guest.marker[$field]
    $guest.marker[$field] = 'watchdog'
    Assert-Rejected { Assert-ApprovedRecovery $guest $initial $fixture.agentPrincipalId }
    $guest.marker[$field] = $original
}
$guest.ownerToken = $fixture.ownerToken
$guest.service = 'retailtx-demo-posting-worker'
$guest.watchdogEnabled = $true
$guest.watchdogActive = $true
Assert-ApprovedRecovery $guest $initial $fixture.agentPrincipalId -Owner $fixture.ownerToken
foreach ($change in @(
    @{ ownerToken = [guid]::NewGuid().ToString() }, @{ service = 'wrong-service' },
    @{ watchdogEnabled = $false }, @{ watchdogActive = $false }, @{ active = 'true' },
    @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o') },
    @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o') }
)) {
    $bad = $guest.Clone()
    foreach ($key in $change.Keys) { $bad[$key] = $change[$key] }
    Assert-Rejected { Assert-ApprovedRecovery $bad $initial $fixture.agentPrincipalId -Owner $fixture.ownerToken }
}
$guest.marker.canary = $true
Assert-Rejected { Assert-ApprovedRecovery $guest $initial $fixture.agentPrincipalId -Owner $fixture.ownerToken }
$guest.marker.canary = $false
$guest.active = $false
$guest.healthy = $false
$guest.marker.phase = 'fault-active'
$asyncCommand = New-ApprovedRepairCommand $fixture $guest -CompletionMode AsyncAudit
if ($command.Contains('--no-wait') -or $asyncCommand -cne $command.Replace(' --output json', ' --no-wait --output json')) {
    throw 'Async submission must only add no-wait; legacy canonical repair must remain unchanged.'
}
$fixture.agentId = '/subscriptions/test/resourceGroups/fixture/providers/Microsoft.App/agents/test'
$dispatch = [DateTimeOffset]::UtcNow.AddMinutes(-12)
$proposal = @{ completionMode = 'AsyncAudit'; expectedCommand = $asyncCommand; threadId = $threadId
    requestedAt = $dispatch.AddSeconds(-10).ToString('o'); initial = $initial.Clone() }
$proposal.initial.deadlineUtc = $dispatch.AddMinutes(10).ToString('o')
$submission = @{ id = [guid]::NewGuid().ToString(); command = $asyncCommand; requiredScopes = $null
    originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $asyncCommand } } | ConvertTo-Json)
    status = 'Completed'; error = $null; startedTimestamp = $dispatch.ToString('o')
    completedTimestamp = $dispatch.AddSeconds(5).ToString('o') }
$decision = @{ id = [guid]::NewGuid().ToString(); threadId = $threadId; command = $asyncCommand
    status = 'Approved'; approveForThread = $false; approveScope = 'none'; effectiveApproveScope = 'none'
    expiredByTimeout = $false; decisionUser = @{ role = 'User' }
    createdTimestamp = $dispatch.AddSeconds(-8).ToString('o'); decisionTimestamp = $dispatch.AddSeconds(-1).ToString('o') }
$correlation = [guid]::NewGuid().ToString()
$accepted = @{ correlationId = $correlation; resourceId = $fixture.vmId; caller = $fixture.agentPrincipalId
    claims = @{ 'http://schemas.microsoft.com/identity/claims/objectidentifier' = $fixture.agentPrincipalId }
    operationName = @{ value = 'Microsoft.Compute/virtualMachines/runCommand/action' }
    status = @{ value = 'Accepted' }; eventTimestamp = $dispatch.AddSeconds(3).ToString('o') }
$succeeded = $accepted.Clone()
$succeeded.status = @{ value = 'Succeeded' }
$succeeded.eventTimestamp = $dispatch.AddMinutes(10).ToString('o')
$waiting = Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @() $null
if ($waiting.phase -cne 'SubmittedAwaitingAudit' -or $waiting.correlationId) { throw 'Submission must not masquerade as completion.' }
$bound = Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted) $waiting
if ($bound.phase -cne 'AzureOperationPending' -or $bound.correlationId -cne $correlation) {
    throw 'Started/Accepted audit must bind one durable correlation without accepting repair.'
}
$done = Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $succeeded) $bound
if ($done.phase -cne 'AzureOperationSucceeded' -or
    [DateTimeOffset]$done.auditDeadlineUtc -ne $dispatch.AddMinutes(30)) { throw 'Late same-correlation completion was not reconciled.' }
$roundTripBound = $bound | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
$null = Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $succeeded) $roundTripBound
foreach ($statusName in @('Failed', 'Pending', 'Running')) {
    $bad = $submission.Clone()
    $bad.status = $statusName
    Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $bad @($decision) @($accepted, $succeeded) $null }
}
foreach ($change in @(
    @{ error = 'result missing' }, @{ startedTimestamp = $null }, @{ completedTimestamp = $null },
    @{ requiredScopes = @('OBO') }, @{ completedTimestamp = $dispatch.AddSeconds(-1).ToString('o') }
)) {
    $bad = $submission.Clone()
    foreach ($key in $change.Keys) { $bad[$key] = $change[$key] }
    Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $bad @($decision) @($accepted, $succeeded) $null }
}
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @() @($accepted, $succeeded) $null }
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision, $decision) @($accepted, $succeeded) $null }
$extraDecision = $decision.Clone()
$extraDecision.command = "$asyncCommand; echo altered"
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision, $extraDecision) @($accepted, $succeeded) $null }
$extraDecision.approveScope = 'thread'
$extraDecision.approveForThread = $true
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision, $extraDecision) @($accepted, $succeeded) $null }
foreach ($change in @(
    @{ approveScope = 'thread' }, @{ approveForThread = $true }, @{ effectiveApproveScope = 'thread' },
    @{ status = 'Denied' }, @{ expiredByTimeout = $true }, @{ threadId = [guid]::NewGuid().ToString() },
    @{ decisionTimestamp = $dispatch.AddSeconds(1).ToString('o') }
)) {
    $bad = $decision.Clone()
    foreach ($key in $change.Keys) { $bad[$key] = $change[$key] }
    Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($bad) @($accepted, $succeeded) $null }
}
foreach ($change in @(
    @{ status = @{ value = 'Failed' } }, @{ status = @{ value = 'Canceled' } }, @{ status = @{ value = 'Unexpected' } },
    @{ correlationId = [guid]::NewGuid().ToString() }, @{ eventTimestamp = $dispatch.AddSeconds(-1).ToString('o') }
)) {
    $bad = $succeeded.Clone()
    foreach ($key in $change.Keys) { $bad[$key] = $change[$key] }
    Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $bad) $null }
}
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($succeeded) $null }
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $succeeded, $succeeded) $null }
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @() $bound }
foreach ($field in @('ownerToken', 'threadId', 'runId', 'vmId', 'principalId', 'executionId', 'approvalId', 'correlationId')) {
    $bad = $bound.Clone()
    $bad[$field] = [guid]::NewGuid().ToString()
    Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $succeeded) $bad }
}
$bad = $bound.Clone()
$bad.auditDeadlineUtc = $dispatch.AddMinutes(31).ToString('o')
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $succeeded) $bad }
foreach ($change in @(
    @{ caller = [guid]::NewGuid().ToString() }, @{ resourceId = '/subscriptions/foreign/vm' },
    @{ eventTimestamp = $dispatch.AddMinutes(31).ToString('o') }
)) {
    $late = $succeeded.Clone()
    foreach ($key in $change.Keys) { $late[$key] = $change[$key] }
    $notDone = Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $late) $null
    if ($notDone.phase -ceq 'AzureOperationSucceeded') { throw 'Wrong identity/VM or out-of-window success accepted.' }
}
$bad = $accepted.Clone()
$bad.claims = @{ 'http://schemas.microsoft.com/identity/claims/objectidentifier' = [guid]::NewGuid().ToString() }
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($bad, $succeeded) $null }
$proposal.completionMode = 'NativeCompleted'
Assert-Rejected { Get-ApprovedRepairOperation $fixture $proposal $submission @($decision) @($accepted, $succeeded) $null }
$proposal.completionMode = 'AsyncAudit'
$oldStart = [DateTimeOffset]::UtcNow.AddMinutes(-31)
$oldSubmission = $submission.Clone()
$oldSubmission.startedTimestamp = $oldStart.ToString('o')
$oldSubmission.completedTimestamp = $oldStart.AddSeconds(5).ToString('o')
$oldProposal = $proposal.Clone()
$oldProposal.requestedAt = $oldStart.AddSeconds(-10).ToString('o')
$oldProposal.initial = @{ deadlineUtc = $oldStart.AddMinutes(10).ToString('o'); runId = $initial.runId }
$oldDecision = $decision.Clone()
$oldDecision.createdTimestamp = $oldStart.AddSeconds(-8).ToString('o')
$oldDecision.decisionTimestamp = $oldStart.AddSeconds(-1).ToString('o')
Assert-Rejected { Get-ApprovedRepairOperation $fixture $oldProposal $oldSubmission @($oldDecision) @() $null }
$verificationRecord = $ast.Find({ param($candidate)
    $candidate -is [Management.Automation.Language.IfStatementAst] -and
    $candidate.Extent.Text.StartsWith('if ($completionEvidence) {', [StringComparison]::Ordinal) -and
    $candidate.Extent.Text.Contains('VerifiedWithoutFollowup')
}, $true)
if (-not $verificationRecord) { throw 'Missing non-interventional async acceptance path.' }
$completionEvidence = $done
$followupPath = 'unused-unit-test-recovery.json'
$observationOperation = 'Telemetry'
$script:policyReceipt = $null
function Invoke-ApprovalRequest { throw 'Async acceptance must not post a correction or execute any SRE action.' }
. ([scriptblock]::Create($verificationRecord.Extent.Text))
if ($script:policyReceipt.phase -cne 'VerifiedWithoutFollowup') {
    throw 'Async Verify did not save independent operator acceptance without an SRE correction.'
}
if (-not $text.Contains('guest-approval-operation.json') -or
    -not $text.Contains("'--max-events', '1000'") -or -not $text.Contains('$log.Count -ge 1000')) {
    throw 'Durable correlation and truncated-audit rejection must be wired into Read/Verify.'
}
foreach ($fragment in @(
    'Failed/missing output is not evidence of no approval or no action',
    'Never retry repair or create another approval card after submission',
    'native Completed means SUBMITTED',
    'independently repeat the exact built-in LAW query'
)) {
    if (-not $text.Contains($fragment)) { throw "Proposal omitted truthful independent verification guidance: $fragment" }
}
if ($text -match "/action`"|AutomatedApproval|ValidateSet\([^)]*'Approve'") {
    throw 'Human-only adapter must not implement execution approval.'
}
$safeReceipt = $text.IndexOf('Save-RetailState $pendingApprovalReceipt', [StringComparison]::Ordinal)
$telemetryGuard = $text.LastIndexOf('# Telemetry reuses lifecycle ownership/source/grant checks', [StringComparison]::Ordinal)
$auditGuard = $text.IndexOf("Action identity guest invocation observed before human approval", [StringComparison]::Ordinal)
if ($safeReceipt -lt $telemetryGuard -or $safeReceipt -lt $auditGuard -or
    $safeReceipt -lt $text.IndexOf('Verify requires exact completed native repair and idle thread.', [StringComparison]::Ordinal) -or
    -not $text.Contains("phase = 'InspectionUnverified'")) {
    throw 'Pending approval receipt must remain unverified until freshness and all inspection prerequisites pass.'
}
$pendingReceiptWriter = $ast.Find({ param($candidate)
    $candidate -is [Management.Automation.Language.IfStatementAst] -and
    $candidate.Extent.Text.StartsWith('if ($pendingApprovalReceipt)', [StringComparison]::Ordinal)
}, $true)
$pendingApprovalReceipt = $null
$script:policyReceipt = $null
. ([scriptblock]::Create($pendingReceiptWriter.Extent.Text))
if ($script:policyReceipt) { throw 'Failed/unset prerequisites produced a pending approval receipt.' }
$creation = $text.IndexOf("Invoke-ApprovalRequest Post '/api/v1/threads'", [StringComparison]::Ordinal)
$intent = $text.IndexOf('Save-RetailState $intent $requestPath', [StringComparison]::Ordinal)
$followup = $text.IndexOf('Invoke-ApprovalRequest Post "/api/v1/threads/$threadId/messages"', [StringComparison]::Ordinal)
$followupIntent = $text.IndexOf('Save-RetailState $intent $followupPath', [StringComparison]::Ordinal)
if ($intent -lt 0 -or $intent -ge $creation -or $followupIntent -lt 0 -or $followupIntent -ge $followup) {
    throw 'Durable intent must precede non-replayable POST.'
}
$environment = 'dry' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$directory = Join-Path $PSScriptRoot "..\.azure\$environment"
foreach ($operation in @('Configure', 'Propose', 'Read', 'Verify')) {
    & $path $operation -SubscriptionId ([guid]::NewGuid()) -EnvironmentName $environment -WhatIf
}
if (Test-Path -LiteralPath $directory) { throw 'WhatIf created approval state.' }
'Guest-service human approval contracts passed.'
