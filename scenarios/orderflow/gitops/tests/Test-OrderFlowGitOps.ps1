#Requires -Version 7.2
<#
.SYNOPSIS
Offline tests for the OrderFlow GitOps lifecycle. No Azure, GitHub or network calls:
external boundaries are replaced inside the module scope.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$gitOpsRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $gitOpsRoot 'scripts\OrderFlowGitOps.psm1') -Force -PassThru
. (Join-Path $gitOpsRoot 'scripts\OrderFlowGitOps.Sre.ps1')
$repositoryRoot = Get-OrderFlowGitOpsPath 'Root'
$scratch = Join-Path $repositoryRoot ".azure\orderflow-gitops-tests\$([guid]::NewGuid().ToString('N'))"
$script:checks = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock]$Operation, [string]$Message, [string]$Like)
    $threw = $false
    try { & $Operation } catch {
        $threw = $true
        if ($Like -and $_.Exception.Message -notlike $Like) { throw "$Message (unexpected error: $($_.Exception.Message))" }
    }
    Assert-Test $threw $Message
}

function New-TestState {
    $state = New-OrderFlowGitOpsState -SubscriptionId '11111111-1111-1111-1111-111111111111' -EnvironmentName 'unit1' `
        -Location 'eastus2' -PresenterCidr '203.0.113.10/32' -AdminObjectId '33333333-3333-3333-3333-333333333333' `
        -GitHubRepository 'contoso/orderflow-demo'
    $state.phase = 'provisioned'
    $state.outputs.shared = @{ suffix = 'abc123'; acrName = 'crofgabc123'; tenantId = '44444444-4444-4444-4444-444444444444'
        deployClientIdProd = 'p'; deployClientIdTest = 't'
        sreAgentId = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-ofgitops-unit1-shared/providers/Microsoft.App/agents/sre-ofg-abc123"
        srePrincipalId = '55555555-5555-5555-5555-555555555555' }
    $state.outputs.prod = @{ smokeJobName = 'orderflow-smoke'; appInsightsName = 'appi-ofg-prod'; nsgName = 'nsg-ofg-prod'
        alertId = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-ofgitops-unit1-prod/providers/Microsoft.Insights/scheduledQueryRules/alert-ofg-prod-dependency" }
    $state.outputs.test = @{ smokeJobName = 'orderflow-smoke' }
    $state
}

function Set-AzureMock {
    param([scriptblock]$Handler)
    & $module {
        param($handler)
        $script:azCalls = [Collections.Generic.List[string]]::new()
        $script:azHandler = $handler
        function script:Invoke-OrderFlowGitOpsAzure {
            param($State, [string[]]$Arguments, [int]$TimeoutSeconds = 120, [hashtable]$Environment)
            $script:azCalls.Add($Arguments -join ' ')
            & $script:azHandler $Arguments
        }
    } $Handler
}

function Get-AzureCall { & $module { $script:azCalls.ToArray() } }

try {
    # Parse every lifecycle script.
    $errors = @()
    foreach ($file in (Get-ChildItem (Join-Path $gitOpsRoot 'scripts'), $PSScriptRoot -File -Filter '*.ps*1')) {
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        $errors += @($parseErrors)
    }
    Assert-Test ($errors.Count -eq 0) "PowerShell parsing failed: $errors"

    # Input validation.
    Assert-OrderFlowGitOpsCidr '203.0.113.10/32'
    foreach ($cidr in @('0.0.0.0/0', '10.0.0.0/8', '999.1.1.1/32', '::1/128', '203.0.113.1', '203.0.113.01/32')) {
        Assert-Throws { Assert-OrderFlowGitOpsCidr $cidr } "Unsafe CIDR admitted: $cidr"
    }
    Assert-Test ((ConvertTo-OrderFlowGitOpsRepository 'https://github.com/contoso/demo.git') -ceq 'contoso/demo') 'https origin not parsed'
    Assert-Test ((ConvertTo-OrderFlowGitOpsRepository 'git@github.com:contoso/demo.git') -ceq 'contoso/demo') 'ssh origin not parsed'
    Assert-Throws { ConvertTo-OrderFlowGitOpsRepository 'https://user:token@github.com/contoso/demo.git' } 'Credential URL admitted'
    Assert-Throws { ConvertTo-OrderFlowGitOpsRepository 'https://example.com/contoso/demo.git' } 'Non-GitHub origin admitted'
    Assert-Test ((Get-OrderFlowGitOpsGroupName 'unit1').shared -ceq 'rg-ofgitops-unit1-shared') 'Group naming changed'
    Assert-Test ((New-OrderFlowGitOpsToken) -cmatch '^[0-9a-f]{8}$') 'Branch token format'
    Assert-OrderFlowGitOpsBranch 'orderflow-fault/0a1b2c3d'
    foreach ($branch in @('main', 'refs/heads/main', 'orderflow-fault/main', 'copilot/fix', 'orderflow-fault/0A1B2C3D')) {
        Assert-Throws { Assert-OrderFlowGitOpsBranch $branch } "Unsafe push branch admitted: $branch"
    }

    # Exclusive per-environment lock.
    $lockDirectory = Join-Path $scratch 'lock'
    $lock = Enter-OrderFlowGitOpsLock $lockDirectory
    try {
        Assert-Throws { Enter-OrderFlowGitOpsLock $lockDirectory } 'Second lock holder admitted' -Like '*holds this environment lock*'
    } finally { $lock.Dispose() }
    $lock = Enter-OrderFlowGitOpsLock $lockDirectory
    $lock.Dispose()
    Assert-Test $true 'Lock reacquired after release'

    # Manifest: refuse adoption, persist journal, validate ownership.
    $state = New-TestState
    $statePath = Join-Path $scratch 'unit1\ownership.json'
    Set-AzureMock { param($a) if ($a[0] -ceq 'group' -and $a[1] -ceq 'exists') { $a[3] -ceq 'rg-ofgitops-unit1-test' } }
    Assert-Throws { Assert-OrderFlowGitOpsGroupAbsent $state } 'Existing group adopted' -Like '*refusing adoption*'
    Assert-Test (-not (Test-Path -LiteralPath $statePath)) 'Manifest must not be written when adoption is refused'
    Assert-Throws { New-OrderFlowGitOpsGroup $state $statePath 'test' } 'Unrecorded existing group adopted' -Like '*refusing adoption*'
    Assert-Test (-not (Get-AzureCall | Where-Object { $_ -like 'group create*' })) 'Group create attempted for foreign group'
    Set-AzureMock {
        param($a)
        if ($a[1] -ceq 'exists') { return $false }
        if ($a[1] -ceq 'create') {
            $tags = @{}; foreach ($pair in $a[($a.IndexOf('--tags') + 1)..($a.Count - 1)]) { $k, $v = $pair -split '=', 2; $tags[$k] = $v }
            return @{ name = $a[3]; tags = $tags }
        }
    }
    Assert-OrderFlowGitOpsGroupAbsent $state
    Save-OrderFlowGitOpsState $state $statePath 'test'
    New-OrderFlowGitOpsGroup $state $statePath 'shared'
    Assert-Test ('rg-ofgitops-unit1-shared' -cin $state.createdGroups -and -not $state.pendingOperation) 'Group creation not recorded'
    $journal = @(Get-Content -LiteralPath (Join-Path (Split-Path $statePath) 'journal.jsonl'))
    Assert-Test ($journal.Count -ge 3 -and $journal[1] -like '*start group-create*') 'Intent not journaled before mutation'
    $loaded = Read-OrderFlowGitOpsState $statePath '11111111-1111-1111-1111-111111111111' 'unit1'
    Assert-Test ($loaded.ownerToken -ceq $state.ownerToken) 'Manifest round-trip failed'
    Assert-Throws { Read-OrderFlowGitOpsState $statePath '22222222-2222-2222-2222-222222222222' 'unit1' } 'Foreign subscription manifest accepted'
    $bad = New-TestState
    $bad.outputs.prod.alertId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/other/providers/x/y/z'
    Assert-Throws { Assert-OrderFlowGitOpsState $bad '11111111-1111-1111-1111-111111111111' 'unit1' } 'Out-of-scope output accepted'

    # Action gating and pending operations.
    $gate = New-TestState
    $gate.pendingOperation = @{ name = 'deployment'; detail = @{} }
    Assert-Throws { Assert-OrderFlowGitOpsAction $gate 'Fault' } 'Fault admitted with unknown deployment'
    Assert-Throws { Assert-OrderFlowGitOpsAction $gate 'Down' } 'Down admitted with unknown deployment'
    Assert-OrderFlowGitOpsAction $gate 'Status'
    $gate.pendingOperation = @{ name = 'delete-env'; detail = @{} }
    Assert-OrderFlowGitOpsAction $gate 'Down'
    $gate.pendingOperation = $null
    $gate.phase = 'creating'
    Assert-Throws { Assert-OrderFlowGitOpsAction $gate 'Ready' } 'Ready admitted before provisioning'
    $gate.phase = 'deployment-failed'
    Assert-Throws { Assert-OrderFlowGitOpsAction $gate 'Up' } 'Up replay admitted after terminal failure'
    $gate.phase = 'removed'
    Assert-Throws { Assert-OrderFlowGitOpsAction $gate 'Status' } 'Removed generation reused'

    # Deployment observation never replays; Failed is terminal.
    $observe = New-TestState
    $observePath = Join-Path $scratch 'observe\ownership.json'
    $observe.pendingOperation = @{ name = 'deployment'; detail = @{ stage = 'prod'; resourceGroup = 'rg-ofgitops-unit1-prod'; deploymentName = 'd1' } }
    Set-AzureMock { param($a) if ($a[2] -ceq 'show') { @{ properties = @{ provisioningState = 'Running' } } } }
    $null = Resolve-OrderFlowGitOpsPending $observe $observePath
    Assert-Test ($observe.pendingOperation -and -not (Get-AzureCall | Where-Object { $_ -like '*create*' })) 'Running deployment settled or replayed'
    Set-AzureMock { param($a) if ($a[2] -ceq 'show') { @{ properties = @{ provisioningState = 'Failed' } } } }
    $null = Resolve-OrderFlowGitOpsPending $observe $observePath
    Assert-Test ($observe.phase -ceq 'deployment-failed' -and -not $observe.pendingOperation) 'Failed deployment not terminal'

    # Rule comparison: semantic, order-insensitive by rule name.
    $baselineText = Get-Content -LiteralPath (Join-Path $repositoryRoot (Get-OrderFlowGitOpsPath 'Baseline')) -Raw
    $rulesText = Get-Content -LiteralPath (Join-Path $repositoryRoot (Get-OrderFlowGitOpsPath 'Rules')) -Raw
    Assert-Test (Test-OrderFlowGitOpsRuleSetEqual $rulesText $baselineText) 'Committed rules differ from baseline'
    $shuffled = $baselineText | ConvertFrom-Json -AsHashtable
    [array]::Reverse($shuffled.rules)
    $first = $shuffled.rules[0].properties
    $reordered = [ordered]@{}
    foreach ($key in @($first.Keys | Sort-Object -Descending)) { $reordered[$key] = $first[$key] }
    $shuffled.rules[0].properties = $reordered
    $shuffled.Remove('$schema-note')
    Assert-Test (Test-OrderFlowGitOpsRuleSetEqual ($shuffled | ConvertTo-Json -Depth 20) $baselineText) 'Rule/key order changed equality'
    $changed = $baselineText | ConvertFrom-Json -AsHashtable
    $changed.rules[0].properties.priority = 101
    Assert-Test (-not (Test-OrderFlowGitOpsRuleSetEqual $changed $baselineText)) 'Property change not detected'
    $dropped = $baselineText | ConvertFrom-Json -AsHashtable
    $dropped.rules = @($dropped.rules | Select-Object -Skip 1)
    Assert-Test (-not (Test-OrderFlowGitOpsRuleSetEqual $dropped $baselineText)) 'Removed rule not detected'
    $duplicate = $baselineText | ConvertFrom-Json -AsHashtable
    $duplicate.rules = @($duplicate.rules) + $duplicate.rules[0]
    Assert-Throws { Get-OrderFlowGitOpsRuleMap $duplicate } 'Duplicate rule names accepted'

    # Fault application: idempotent, refuses non-baseline input.
    $faultText = Get-Content -LiteralPath (Get-OrderFlowGitOpsPath 'Fault') -Raw
    $fault = Get-OrderFlowGitOpsFault $faultText
    Assert-Test ($fault.label -ceq 'orderflow-fault' -and $fault.title -and $fault.body -and $fault.rules.Count -eq 1) 'Fault file not normalized'
    $applied = Add-OrderFlowGitOpsFaultRule $baselineText $baselineText $fault
    Assert-Test ($applied.changed -and @($applied.document.rules).Count -eq @(($baselineText | ConvertFrom-Json).rules).Count + 1) 'Fault not applied'
    Assert-Test ($applied.document.Contains('$schema-note')) 'Top-level note lost'
    $faultedText = ConvertTo-OrderFlowGitOpsJsonText $applied.document
    Assert-Test (-not $faultedText.Contains("`r") -and $faultedText.EndsWith("}`n")) 'Rules JSON must use LF and a trailing newline'
    $again = Add-OrderFlowGitOpsFaultRule $faultedText $baselineText $fault
    Assert-Test (-not $again.changed) 'Fault application not idempotent'
    Assert-Throws { Add-OrderFlowGitOpsFaultRule $changed $baselineText $fault } 'Fault stacked on non-baseline rules' -Like '*does not equal the baseline*'
    $foreignFault = $faultText | ConvertFrom-Json -AsHashtable
    $foreignFault.targetFile = 'scenarios/orderflow/gitops/infra/env.bicep'
    Assert-Throws { Get-OrderFlowGitOpsFault $foreignFault } 'Fault targeting another file accepted'
    $foreignFault = $faultText | ConvertFrom-Json -AsHashtable
    $foreignFault.label = 'bug'
    Assert-Throws { Get-OrderFlowGitOpsFault $foreignFault } 'Fault with another label accepted'

    # Reset is a no-op when origin/main already equals the baseline (no push, no PR).
    $resetState = New-TestState
    $resetPath = Join-Path $scratch 'reset\ownership.json'
    & $module {
        param($rules, $baseline, $faultFile)
        $script:mainFault = $faultFile
        $script:gitCalls = [Collections.Generic.List[string]]::new()
        $script:ghCalls = [Collections.Generic.List[string]]::new()
        $script:mainRules = $rules
        $script:mainBaseline = $baseline
        function script:Invoke-OrderFlowGitOpsGit {
            param([string[]]$Arguments, [string]$InputText, [hashtable]$Environment, [int]$TimeoutSeconds)
            $script:gitCalls.Add($Arguments -join ' ')
            switch ($Arguments[0]) {
                'fetch' { '' }
                'rev-parse' { 'a' * 40 }
                'show' {
                    if ($Arguments[1] -like '*baseline*') { $script:mainBaseline }
                    elseif ($Arguments[1] -like '*faults/*') { $script:mainFault }
                    else { $script:mainRules }
                }
                default { throw "unexpected git $($Arguments[0])" }
            }
        }
        function script:Invoke-OrderFlowGitOpsGh { param([string[]]$Arguments, [switch]$Json) $script:ghCalls.Add($Arguments -join ' '); , @() }
    } $baselineText $baselineText $faultText
    $reset = Invoke-OrderFlowGitOpsReset $resetState $resetPath
    $gitCalls = & $module { $script:gitCalls.ToArray() }
    $ghCalls = @(& $module { $script:ghCalls.ToArray() })
    Assert-Test ($reset.result -ceq 'NoOp') 'Reset not a no-op at baseline'
    Assert-Test (-not ($gitCalls | Where-Object { $_ -like 'push*' -or $_ -like 'commit-tree*' }) -and -not $ghCalls.Count) 'Reset mutated at baseline'
    Assert-Test (-not $resetState.pendingOperation -and -not (Test-Path -LiteralPath $resetPath)) 'Reset recorded state at baseline'
    & $module { param($rules) $script:mainRules = $rules } $faultedText
    $preview = Invoke-OrderFlowGitOpsReset $resetState $resetPath -Preview
    Assert-Test ($preview.result -ceq 'Preview') 'Reset preview did not detect faulted main'
    $faultSource = Get-OrderFlowGitOpsFaultSource ('a' * 40)
    Assert-Test (-not $faultSource.changed) 'Fault source not idempotent when main is faulted'

    # SRE tool policy: issue/assign tools only, never PR/push/merge/branch/file tools.
    Assert-OrderFlowGitOpsSreTool @('search_issues', 'issue_write', 'create_issue', 'issue_read') 'assign_copilot_to_issue'
    Assert-OrderFlowGitOpsSreTool @('GitHub.SearchIssues', 'GitHub.CreateIssue') 'GitHub.AssignCopilotToIssue'
    foreach ($tool in @('create_pull_request', 'merge_pull_request', 'push_files', 'create_branch', 'create_or_update_file',
            'CreatePullRequest', 'update_pull_request_branch', 'delete_file', 'create_pull_request_with_copilot', 'issue_pr_link',
            'fork_repository', 'get_file_contents')) {
        Assert-Throws { Assert-OrderFlowGitOpsSreTool @('search_issues', $tool) 'assign_copilot_to_issue' } "Unsafe SRE tool admitted: $tool"
        Assert-Throws { Assert-OrderFlowGitOpsSreTool @('search_issues') $tool } "Unsafe SRE assign tool admitted: $tool"
    }
    Assert-Throws { Assert-OrderFlowGitOpsSreTool @('search_issues') '' } 'Missing assign tool admitted'
    Assert-Throws { Assert-OrderFlowGitOpsSreTool @('list_labels') 'assign_copilot_to_issue' } 'Non-issue tool admitted'
    Assert-Throws { Assert-OrderFlowGitOpsSreTool @('search issues') 'assign_copilot_to_issue' } 'Malformed tool name admitted'
    $sreState = New-TestState
    $sreState.sre = @{ attempted = $true; configured = $false; issueTools = @('search_issues', 'issue_write'); assignTool = 'assign_copilot_to_issue' }
    $policy = Get-OrderFlowGitOpsSrePolicy $sreState
    Assert-Test (-not $policy.permissions.allow.Count) 'SRE policy must allow nothing silently'
    Assert-Test ('assign_copilot_to_issue' -cin $policy.permissions.ask -and 'issue_write' -cin $policy.permissions.ask) 'GitHub tools must require Ask'
    Assert-Test ('RunAzCliWriteCommands' -cin $policy.permissions.deny -and 'RunInTerminal' -cin $policy.permissions.deny -and
        'ExecutePythonCode' -cin $policy.permissions.deny) 'Azure writes and shells must be denied'
    $reversed = @{ permissions = @{ allow = @(); ask = @($policy.permissions.ask | Sort-Object -Descending); deny = @($policy.permissions.deny | Sort-Object -Descending) } }
    Assert-Test (Test-OrderFlowGitOpsSrePolicy $reversed $policy) 'Policy comparison should ignore order'
    $reversed.permissions.allow = @('RunAzCliWriteCommands')
    Assert-Test (-not (Test-OrderFlowGitOpsSrePolicy $reversed $policy)) 'Allow drift not detected'
    $alert = @{ name = 'alert-ofg-prod-dependency'; scope = '/subscriptions/x/resourceGroups/rg-ofgitops-unit1-prod/providers/Microsoft.OperationalInsights/workspaces/log'
        scopeType = 'Microsoft.OperationalInsights/workspaces' }
    $investigator = Get-OrderFlowGitOpsInvestigator $sreState $alert
    Assert-Test ($investigator.name -ceq 'orderflow-gitops-investigator') 'Investigator name changed'
    Assert-Test ($investigator.properties.instructions -notmatch '\{\{' -and $investigator.properties.instructions.Contains('contoso/orderflow-demo')) 'Runbook placeholders unresolved'
    Assert-Test ('RunAzCliWriteCommands' -cnotin $investigator.properties.tools -and 'assign_copilot_to_issue' -cin $investigator.properties.tools) 'Investigator tools unsafe'
    $plan = Get-OrderFlowGitOpsResponsePlan $alert
    Assert-Test ($plan.properties.agentMode -ceq 'review' -and $plan.properties.mergeEnabled -eq $false -and
        $plan.properties.titleContains -ceq 'alert-ofg-prod-dependency') 'Response plan must be Review mode for the prod alert'

    # Down verifies ownership tags before deleting; env groups first, then shared; observes absence.
    $downState = New-TestState
    $downPath = Join-Path $scratch 'down\ownership.json'
    $downState.createdGroups = @($downState.resourceGroups.Values)
    $script:foreignTags = @{ scenario = 'orderflow-gitops'; managedBy = 'invoke-orderflow-gitops'; ownerToken = '99999999-9999-9999-9999-999999999999'
        environment = 'unit1'; stage = 'prod' }
    $foreign = $script:foreignTags
    Set-AzureMock ({ param($a) if ($a[1] -ceq 'exists') { return $true }; if ($a[1] -ceq 'show') { return @{ name = $a[3]; tags = $foreign } } }.GetNewClosure())
    Assert-Throws { Invoke-OrderFlowGitOpsDown $downState $downPath -TimeoutSeconds 1 -PollSeconds 0 } 'Foreign group deleted' -Like '*ownership tag*'
    Assert-Test (-not (Get-AzureCall | Where-Object { $_ -like 'group delete*' })) 'Delete issued before ownership verification'
    $script:deleted = [Collections.Generic.HashSet[string]]::new()
    $script:owner = $downState.ownerToken
    Set-AzureMock {
        param($a)
        switch ("$($a[0]) $($a[1])") {
            'group exists' { return -not $script:deleted.Contains($a[3]) }
            'group show' {
                $stage = ($a[3] -split '-')[-1]
                return @{ name = $a[3]; tags = @{ scenario = 'orderflow-gitops'; managedBy = 'invoke-orderflow-gitops'; ownerToken = $script:owner
                        environment = 'unit1'; stage = $stage }; properties = @{ provisioningState = 'Succeeded' } }
            }
            'resource list' { return , @(@{ type = 'Microsoft.Network/networkWatchers'; tags = $null }) }
            'group delete' { $null = $script:deleted.Add($a[3]); return $null }
        }
    }
    Invoke-OrderFlowGitOpsDown $downState $downPath -TimeoutSeconds 5 -PollSeconds 0 -WarningAction SilentlyContinue
    $deletes = @(Get-AzureCall | Where-Object { $_ -like 'group delete*' })
    Assert-Test ($deletes.Count -eq 3 -and $deletes[2] -like '*-shared *') 'Shared group must be deleted last'
    Assert-Test ($downState.phase -ceq 'removed' -and -not $downState.pendingOperation) 'Down did not observe absence'
    Set-AzureMock { param($a) if ($a[1] -ceq 'exists') { return $true }; if ($a[1] -ceq 'show') { return @{ name = $a[3]; tags = @{} } } }
    $untaggedState = New-TestState
    Assert-Throws { Invoke-OrderFlowGitOpsDown $untaggedState (Join-Path $scratch 'untagged\ownership.json') -TimeoutSeconds 1 -PollSeconds 0 } 'Untagged group deleted'

    # Smoke: bounded wait; a timeout is never success.
    $smokeState = New-TestState
    Set-AzureMock {
        param($a)
        if ($a[2] -ceq 'start') { return @{ name = 'orderflow-smoke-abc12' } }
        if ($a[2] -ceq 'execution') { return @{ properties = @{ status = 'Running' } } }
    }
    $smoke = Start-OrderFlowGitOpsSmoke $smokeState 'prod' -TimeoutSeconds 1 -PollSeconds 0
    Assert-Test ($smoke.status -ceq 'TimedOut' -and -not $smoke.succeeded) 'Smoke timeout treated as success'
    Set-AzureMock {
        param($a)
        if ($a[2] -ceq 'start') { return @{ name = 'orderflow-smoke-abc12' } }
        if ($a[2] -ceq 'execution') { return @{ properties = @{ status = 'Succeeded' } } }
    }
    $smoke = Start-OrderFlowGitOpsSmoke $smokeState 'test' -TimeoutSeconds 5 -PollSeconds 0
    Assert-Test ($smoke.succeeded -and (Get-AzureCall)[0] -like '*--resource-group rg-ofgitops-unit1-test*') 'Smoke success or scoping wrong'
    Set-AzureMock { param($a) if ($a[2] -ceq 'start') { return @{ name = 'bad name; rm' } } }
    Assert-Throws { Start-OrderFlowGitOpsSmoke $smokeState 'prod' -TimeoutSeconds 1 -PollSeconds 0 } 'Unrecognized execution name accepted'

    # Deployment inputs mirror the workflow bicepparam environment variables.
    $variables = Get-OrderFlowGitOpsEnvVariable (& { $s = New-TestState; $s.imageTag = 'sha-0123456789abcdef'; $s.deploySha = 'b' * 40; $s })
    foreach ($name in @('ORDERFLOW_SHARED_RG', 'ORDERFLOW_SUFFIX', 'ORDERFLOW_PRESENTER_CIDR', 'ORDERFLOW_IMAGE_TAG', 'ORDERFLOW_DEPLOY_SHA',
            'ORDERFLOW_OWNER_TOKEN', 'ORDERFLOW_ENVIRONMENT_NAME')) {
        Assert-Test ($variables.Contains($name)) "Missing deploy input $name"
        Assert-Test ((Get-Content -LiteralPath (Join-Path (Get-OrderFlowGitOpsPath 'Deploy') 'prod.bicepparam') -Raw).Contains("'$name'")) "prod.bicepparam does not read $name"
    }
    Assert-Throws { Get-OrderFlowGitOpsEnvVariable (New-TestState) } 'Empty image tag accepted'
    $sharedParameters = Select-OrderFlowGitOpsParameter (Join-Path (Get-OrderFlowGitOpsPath 'Infra') 'shared.bicep') (Get-OrderFlowGitOpsParameterCandidate (New-TestState))
    Assert-Test ($sharedParameters.githubRepository -ceq 'contoso/orderflow-demo' -and $sharedParameters.prodResourceGroup -ceq 'rg-ofgitops-unit1-prod') 'Shared parameters not mapped'
    $github = Get-OrderFlowGitOpsGitHubVariable (New-TestState)
    Assert-Test ($github['orderflow-prod'].AZURE_CLIENT_ID -ceq 'p' -and $github['orderflow-test'].ORDERFLOW_RESOURCE_GROUP -ceq 'rg-ofgitops-unit1-test') 'GitHub variables mapped wrongly'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $scratch
    if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent)) { Remove-Item -LiteralPath $parent -Force }
}

[pscustomobject]@{ Result = 'Passed'; Checks = $script:checks }
