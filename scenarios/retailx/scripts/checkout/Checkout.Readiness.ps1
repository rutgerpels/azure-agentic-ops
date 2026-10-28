#Requires -Version 7.2
<# Read-only pre-peak readiness brief: an SRE custom agent run by a Review-mode scheduled task. #>

function Get-CheckoutReadinessSpec {
    param([Parameter(Mandatory)][hashtable]$State)
    $name = "$customAgentName-readiness"
    return @{
        agentName = $name; taskName = $name
        # Daily at 05:00 UTC (07:00 CEST, 06:00 CET), before stores open.
        schedule = '0 5 * * *'
        tools = @(Get-CheckoutReadTools)
        instruction = Get-CheckoutReadinessInstruction $State
        prompt = "Produce the checkout pre-peak readiness brief for environment $EnvironmentName now. " +
            'Follow your instructions exactly; observe and recommend only, never change anything.'
        description = "Daily read-only checkout readiness brief (GREEN/AMBER/RED) for $EnvironmentName."
    }
}

function Get-CheckoutReadinessInstruction {
    param([Parameter(Mandatory)][hashtable]$State)
    $text = Get-Content -LiteralPath (Join-Path $repository 'docs\agent-context\runbooks\checkout-readiness.md') -Raw
    $text = $text.Replace("`r`n", "`n")
    $arc = [bool]($State['enableArc'])
    $text = if ($arc) { $text -replace '(?m)^<!-- arc:(start|end) -->\n', '' }
        else { $text -replace '(?s)<!-- arc:start -->\n.*?<!-- arc:end -->\n', '' }
    $values = @{
        environmentName = $EnvironmentName; subscriptionId = $subscription; resourceGroupName = $groupName
        webAppName = $State.outputs.webAppName; workspaceCustomerId = $State.outputs.workspaceCustomerId
        latencyAlertRuleId = $State.outputs.alertRuleId
        readInvestigationGuidance = Get-CheckoutReadInstruction $State.outputs -WithServiceLogs:$arc
    }
    if ($arc) {
        $values.arcMachineId = $State.outputs.arcMachineId
        $values.serviceAlertRuleId = $State.outputs.serviceAlertRuleId
        $values.ownerToken = $State.ownerToken
    }
    foreach ($key in $values.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$key])) { throw "Readiness brief is missing $key." }
        $text = $text.Replace("{{$key}}", [string]$values[$key])
    }
    if ($text -match '\{\{[a-zA-Z]+\}\}' -or $text.Contains('<!-- arc:')) { throw 'Readiness brief has unresolved configuration.' }
    return $text.Trim()
}

function Get-CheckoutReadinessDrift {
    <# Returns the differences between the live readiness agent/task and the expected read-only Review-mode spec. #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Connection)
    $spec = Get-CheckoutReadinessSpec $State
    $problems = [Collections.Generic.List[string]]::new()
    $agent = Invoke-SreRequest $Connection GET "/api/v2/extendedAgent/agents/$($spec.agentName)" -AllowMissing
    if (-not $agent -or -not $agent['properties']) {
        $problems.Add("Readiness agent $($spec.agentName) is missing. Run ConfigureReadiness.")
    } else {
        $tools = @($agent.properties['tools'] | Sort-Object -CaseSensitive) -join ','
        if ($tools -cne (($spec.tools | Sort-Object -CaseSensitive) -join ',')) {
            $problems.Add("Readiness agent $($spec.agentName) must have only read-only tools.")
        }
        if ("$($agent.properties['instructions'])".Replace("`r`n", "`n").Trim() -cne $spec.instruction) {
            $problems.Add("Readiness agent $($spec.agentName) instructions drifted.")
        }
    }
    $task = Invoke-SreRequest $Connection GET "/api/v2/extendedAgent/scheduledtasks/$($spec.taskName)" -AllowMissing
    if (-not $task -or -not $task['properties']) {
        $problems.Add("Readiness scheduled task $($spec.taskName) is missing. Run ConfigureReadiness.")
    } else {
        $properties = $task.properties
        if ($properties['agent'] -cne $spec.agentName -or $properties['cronExpression'] -cne $spec.schedule -or
            $properties['agentPrompt'] -cne $spec.prompt) {
            $problems.Add("Readiness scheduled task $($spec.taskName) agent, schedule or prompt drifted.")
        }
        if ($properties['agentMode'] -ine 'Review') {
            $problems.Add("Readiness scheduled task $($spec.taskName) is not in Review mode.")
        }
        if ($properties['isEnabled'] -ne $true -and $properties['status'] -cne 'Active') {
            $problems.Add("Readiness scheduled task $($spec.taskName) is paused or disabled.")
        }
        if ($properties['status'] -ceq 'Failed') {
            $problems.Add("Readiness scheduled task $($spec.taskName) failed repeatedly; inspect its runs, then rerun ConfigureReadiness.")
        }
    }
    return , $problems.ToArray()
}

function Set-CheckoutReadinessAutomation {
    param([Parameter(Mandatory)][hashtable]$Connection, [Parameter(Mandatory)][hashtable]$State)
    Assert-CheckoutAgentMode $State
    $spec = Get-CheckoutReadinessSpec $State
    $agentBody = @{ name = $spec.agentName; properties = @{
            instructions = $spec.instruction
            handoffDescription = 'Produce the read-only checkout readiness brief. Never changes anything.'
            handoffs = @(); enableVanillaMode = $true; tools = $spec.tools } }
    $null = Invoke-SreRequest $Connection PUT "/api/v2/extendedAgent/agents/$($spec.agentName)" $agentBody
    # The task references its handling agent, so it is written after the agent exists.
    $taskBody = @{ name = $spec.taskName; type = 'ScheduledTask'; tags = @(); properties = @{
            name = $spec.taskName; description = $spec.description; cronExpression = $spec.schedule
            agentPrompt = $spec.prompt; agent = $spec.agentName; agentMode = 'Review'; isEnabled = $true } }
    $null = Invoke-SreRequest $Connection PUT "/api/v2/extendedAgent/scheduledtasks/$($spec.taskName)" $taskBody
    $drift = Get-CheckoutReadinessDrift $State $Connection
    if ($drift.Count) { throw "Readiness automation was written but did not verify: $($drift -join ' ')" }
}
