#Requires -Version 7.2
<#
.SYNOPSIS
Offline restart and safety contracts for the owned cleanup coordinator.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '..\scripts\OrderFlowGitOps.psm1') -Force -PassThru
$originalDown = & $module { (Get-Command Invoke-OrderFlowGitOpsDown).ScriptBlock }
$scratch = Join-Path (Get-OrderFlowGitOpsPath 'Root') ".azure\orderflow-gitops-tests\$([guid]::NewGuid().ToString('N'))"
$checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)
    try { & $Operation } catch {
        Assert-Test ($_.Exception.Message -like $Pattern) "Unexpected error: $($_.Exception.Message)"
        return
    }
    throw "Expected error matching $Pattern"
}
function New-Fixture {
    param([string]$Name)
    $state = New-OrderFlowGitOpsState -SubscriptionId '11111111-1111-1111-1111-111111111111' `
        -EnvironmentName unit1 -Location eastus2 -AdminObjectId '22222222-2222-2222-2222-222222222222' `
        -GitHubRepository 'contoso/orderflow'
    $state.phase = 'provisioned'
    $state.outputs.sre.srePrincipalId = '33333333-3333-3333-3333-333333333333'
    $path = Join-Path $scratch "$Name\ownership.json"
    Save-OrderFlowGitOpsState $state $path
    & $module {
        param($fixtureState)
        $script:calls = [Collections.Generic.List[string]]::new()
        $script:mode = ''
        $script:downCalls = 0
        $script:fixtureState = $fixtureState
        $script:workflowStates = @{
            'orderflow-gitops-cd.yml' = 'active'
            'orderflow-gitops-test-deploy.yml' = 'active'
        }
        $scope = "/subscriptions/$($fixtureState.subscriptionId)"
        $script:roles = @(@{
            id = "$scope/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-4444-444444444444"
            principalId = $fixtureState.outputs.sre.srePrincipalId; scope = $scope
            roleDefinitionId = "$scope/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
        })
        function script:Invoke-OrderFlowGitOpsGh {
            param([string[]]$Arguments, [switch]$Json)
            $script:calls.Add("gh $($Arguments -join ' ')")
            if ($Arguments[0] -eq 'workflow') {
                if ($Arguments[1] -ne 'disable') { throw 'Unexpected workflow mutation.' }
                if ($script:workflowStates[$Arguments[2]] -cne 'active') {
                    throw 'HTTP 403: Unable to disable a workflow that is not active.'
                }
                if ($script:mode -eq 'disable-denied') { throw 'HTTP 403: access denied.' }
                if ($script:mode -ne 'disable-unconfirmed') {
                    $script:workflowStates[$Arguments[2]] = 'disabled_manually'
                }
                return
            }
            if ($Arguments[0] -eq 'api') {
                if ($Arguments[1] -match '/actions/workflows/([^/]+)$') {
                    if ($script:mode -eq 'workflow-unreadable') { throw 'Workflow lookup failed.' }
                    return @{state = $script:workflowStates[$Matches[1]]}
                }
                if ($script:mode -eq 'active') {
                    return @{total_count = 1; workflow_runs = @(@{
                        id = 42; html_url = 'https://github.com/contoso/orderflow/actions/runs/42'
                        path = '.github/workflows/orderflow-gitops-test-deploy.yml'; status = 'queued'
                    })}
                }
                if ($script:mode -eq 'paginated-active') {
                    if ($Arguments[1].EndsWith('page=1')) {
                        return @{total_count = 2; workflow_runs = @(@{
                            id = 1; path = '.github/workflows/orderflow-gitops-cd.yml'; status = 'completed'
                        })}
                    }
                    return @{total_count = 2; workflow_runs = @(@{
                        id = 42; html_url = 'https://github.com/contoso/orderflow/actions/runs/42'
                        path = '.github/workflows/orderflow-gitops-test-deploy.yml'; status = 'in_progress'
                    })}
                }
                if ($script:mode -eq 'changing-pages') {
                    if ($Arguments[1].EndsWith('page=1')) {
                        return @{total_count = 2; workflow_runs = @(@{id = 1; path = 'other.yml'; status = 'completed'})}
                    }
                    return @{total_count = 3; workflow_runs = @(@{id = 2; path = 'other.yml'; status = 'completed'})}
                }
                if ($script:mode -eq 'duplicate-runs') {
                    return @{total_count = 2; workflow_runs = @(
                        @{id = 1; path = 'other.yml'; status = 'completed'},
                        @{id = 1; path = 'other.yml'; status = 'completed'}
                    )}
                }
                return @{total_count = 0; workflow_runs = @()}
            }
        }
        function script:Invoke-OrderFlowGitOpsAzure {
            param($State, [string[]]$Arguments)
            $script:calls.Add($Arguments -join ' ')
            switch ("$($Arguments[0]) $($Arguments[1])") {
                'account show' { return @{id = $State.subscriptionId} }
                'group show' {
                    $stage = $Arguments[3].Split('-')[-1]
                    return @{tags = @{
                        scenario = 'orderflow-gitops'; managedBy = 'invoke-orderflow-gitops'
                        ownerToken = $(if ($script:mode -eq 'foreign') { 'foreign' } else { $State.ownerToken })
                        environment = $State.environmentName; stage = $stage
                    }}
                }
                'containerapp env' {
                    return @{properties = @{infrastructureResourceGroup = "managed-$($Arguments[4])"}}
                }
                'group exists' {
                    if ($script:mode -eq 'real-down') {
                        return ($Arguments[3] -in $State.resourceGroups.Values -and -not $script:deletedGroups.Contains($Arguments[3]))
                    }
                    return ($script:mode -eq 'managed-present' -and $Arguments[3].StartsWith('managed-'))
                }
                'resource list' { return @() }
                'group delete' {
                    if (-not (Test-Path $script:cleanupInventoryPath)) { throw 'Deleted before saving inventory.' }
                    $null = $script:deletedGroups.Add($Arguments[3])
                    return
                }
                'role assignment' {
                    if ($Arguments[2] -eq 'list') { return $script:roles }
                    if ($Arguments[2] -eq 'delete') {
                        if ($script:mode -eq 'role-timeout') { throw 'Role delete timed out; unknown outcome.' }
                        $script:roles = @()
                        return
                    }
                }
            }
            throw "Unexpected Azure mock call: $($Arguments -join ' ')"
        }
        function script:Invoke-OrderFlowGitOpsDown {
            param($State, $Path, $TimeoutSeconds, $PollSeconds)
            $script:downCalls++
            if ($script:mode -eq 'timeout') {
                $State.pendingOperation = @{name = 'delete-env'; detail = @{groups = @($State.resourceGroups.prod)}}
                Save-OrderFlowGitOpsState $State $Path
                throw 'Still deleting; observe later.'
            }
            $State.phase = 'removed'; $State.pendingOperation = $null
            Save-OrderFlowGitOpsState $State $Path
        }
    } $state
    @{state = $state; path = $path; inventory = Join-Path (Split-Path $path) 'cleanup-inventory.json'}
}
function Get-Calls { & $module { $script:calls.ToArray() } }
try {
    $fixture = New-Fixture 'complete'
    Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path -TimeoutSeconds 1
    $hash = (Get-FileHash $fixture.inventory).Hash
    $reloaded = Read-OrderFlowGitOpsState $fixture.path $fixture.state.subscriptionId unit1
    Invoke-OrderFlowGitOpsCleanup $reloaded $fixture.path -TimeoutSeconds 1
    Assert-Test ((& $module { $script:downCalls }) -eq 1) 'Removed generation replayed Down.'
    Assert-Test (@(Get-Calls | Where-Object { $_ -like '*assignment delete*' }).Count -eq 1) 'Monitoring deletion replayed.'
    Assert-Test ((Get-FileHash $fixture.inventory).Hash -eq $hash) 'Retained inventory was overwritten.'
    Assert-Test (@(Get-Calls | Where-Object { $_ -like '*workflow disable*' }).Count -eq 2) 'Resume disabled an already paused workflow.'
    $progressPath = Join-Path (Split-Path $fixture.path) 'cleanup-progress.json'
    $progress = Get-Content $progressPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test ([bool]$progress.completedAtUtc) 'Final absence receipt missing.'

    foreach ($disabledState in @('disabled_manually', 'disabled_inactivity', 'disabled_fork')) {
        $fixture = New-Fixture $disabledState
        & $module {
            param($value)
            $script:workflowStates['orderflow-gitops-cd.yml'] = $value
            $script:workflowStates['orderflow-gitops-test-deploy.yml'] = $value
        } $disabledState
        Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path -TimeoutSeconds 1
        Assert-Test (-not (Get-Calls | Where-Object { $_ -like '*workflow disable*' })) 'Already disabled workflow was submitted again.'
        Assert-Test ((& $module { $script:downCalls }) -eq 1) 'Paused workflows blocked cleanup.'
    }
    $fixture = New-Fixture 'partially-paused'
    & $module { $script:workflowStates['orderflow-gitops-cd.yml'] = 'disabled_manually' }
    Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path -TimeoutSeconds 1
    $disableCalls = @(Get-Calls | Where-Object { $_ -like '*workflow disable*' })
    Assert-Test ($disableCalls.Count -eq 1 -and $disableCalls[0] -like '*orderflow-gitops-test-deploy.yml*') 'Mixed states did not disable only the active workflow.'

    foreach ($unexpectedState in @('active-after-disable', 'deleted', 'unknown', $null)) {
        $fixture = New-Fixture "unconfirmed-$unexpectedState"
        & $module {
            param($value)
            if ($value -eq 'active-after-disable') { $script:mode = 'disable-unconfirmed' }
            else { $script:workflowStates['orderflow-gitops-cd.yml'] = $value }
        } $unexpectedState
        Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*not confirmed disabled*'
        Assert-Test ((& $module { $script:downCalls }) -eq 0) 'Unconfirmed pause admitted deletion.'
        Assert-Test (-not (Test-Path $fixture.inventory)) 'Unconfirmed pause reached inventory capture.'
    }
    foreach ($mode in @('disable-denied', 'workflow-unreadable')) {
        $fixture = New-Fixture $mode
        & $module { param($value) $script:mode = $value } $mode
        Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } $(if ($mode -eq 'disable-denied') { '*access denied*' } else { '*lookup failed*' })
        Assert-Test ((& $module { $script:downCalls }) -eq 0) 'GitHub failure admitted deletion.'
    }

    $fixture = New-Fixture 'interrupted'
    & $module { $script:mode = 'timeout' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path -TimeoutSeconds 1 } '*Still deleting*'
    $hash = (Get-FileHash $fixture.inventory).Hash
    & $module { $script:mode = '' }
    $reloaded = Read-OrderFlowGitOpsState $fixture.path $fixture.state.subscriptionId unit1
    Invoke-OrderFlowGitOpsCleanup $reloaded $fixture.path -TimeoutSeconds 1
    Assert-Test ((Get-FileHash $fixture.inventory).Hash -eq $hash) 'Restart recaptured inventory.'
    Assert-Test ($reloaded.phase -eq 'removed') 'Restart did not finish.'

    $fixture = New-Fixture 'active'
    & $module { $script:mode = 'active' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*runs are not completed*42*'
    Assert-Test ((& $module { $script:downCalls }) -eq 0) 'Deleted with admitted run.'
    $calls = @(Get-Calls)
    Assert-Test (@($calls | Where-Object { $_ -like '*workflow disable*' }).Count -eq 2) 'Both deployment workflows must be disabled.'
    Assert-Test (-not ($calls | Where-Object { $_ -like '*status=*' })) 'Run discovery must not use transition-prone status buckets.'
    $fixture = New-Fixture 'paginated'
    & $module { $script:mode = 'paginated-active' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*runs are not completed*42*'
    Assert-Test ((& $module { $script:downCalls }) -eq 0) 'Active run on next page ignored.'
    foreach ($mode in @('changing-pages', 'duplicate-runs')) {
        $fixture = New-Fixture $mode
        & $module { param($value) $script:mode = $value } $mode
        Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*discovery changed or is incomplete*'
        Assert-Test ((& $module { $script:downCalls }) -eq 0) 'Incomplete discovery admitted deletion.'
    }
    $fixture = New-Fixture 'foreign'
    & $module { $script:mode = 'foreign' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*ownership tag*'

    $fixture = New-Fixture 'missing'
    $fixture.state.phase = 'removed'
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*without retained cleanup inventory*'
    $fixture = New-Fixture 'pending'
    $fixture.state.pendingOperation = @{name = 'deployment'}
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*Pending/unknown*'
    Assert-Test (@(Get-Calls).Count -eq 0) 'Non-delete pending operation crossed an external boundary.'

    $fixture = New-Fixture 'managed'
    & $module { $script:mode = 'managed-present' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*Group still present*'
    Assert-Test (-not (Get-Calls | Where-Object { $_ -like '*assignment delete*' })) 'Role deleted before managed group absent.'

    $fixture = New-Fixture 'role-timeout'
    & $module { $script:mode = 'role-timeout' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*Role delete timed out*'
    $reloaded = Read-OrderFlowGitOpsState $fixture.path $fixture.state.subscriptionId unit1
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $reloaded $fixture.path } '*will not replay*'
    Assert-Test (@(Get-Calls | Where-Object { $_ -like '*assignment delete*' }).Count -eq 1) 'Unknown role deletion replayed.'
    & $module { $script:roles = @(); $script:mode = '' }
    Invoke-OrderFlowGitOpsCleanup $reloaded $fixture.path
    Assert-Test (Test-Path (Join-Path (Split-Path $fixture.path) 'cleanup-progress.json')) 'Role absence not recorded on resume.'

    $fixture = New-Fixture 'legacy'
    $scope = "/subscriptions/$($fixture.state.subscriptionId)"
    $inventory = @{
        groups = @($fixture.state.resourceGroups.Values) + @('managed-prod', 'managed-test')
        srePrincipalId = $fixture.state.outputs.sre.srePrincipalId
        monitoringRoles = @()
    }
    $inventory | ConvertTo-Json -Depth 10 | Set-Content $fixture.inventory
    $hash = (Get-FileHash $fixture.inventory).Hash
    $fixture.state.phase = 'removed'
    & $module { $script:roles = @() }
    Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path
    Assert-Test ((Get-FileHash $fixture.inventory).Hash -eq $hash) 'Legacy inventory overwritten.'
    $inventory.ownerToken = 'foreign'
    $inventory | ConvertTo-Json -Depth 10 | Set-Content $fixture.inventory
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*another environment generation*'

    $fixture = New-Fixture 'changed-role'
    & $module { $script:mode = 'managed-present' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*Group still present*'
    & $module { $script:mode = ''; $script:roles[0].scope = '/subscriptions/foreign' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path } '*metadata changed*'
    Assert-Test (-not (Get-Calls | Where-Object { $_ -like '*assignment delete*' })) 'Changed role deleted.'

    $fixture = New-Fixture 'real-down'
    & $module {
        param($original, $inventoryPath)
        Set-Item Function:script:Invoke-OrderFlowGitOpsDown $original
        $script:mode = 'real-down'
        $script:deletedGroups = [Collections.Generic.HashSet[string]]::new()
        $script:cleanupInventoryPath = $inventoryPath
    } $originalDown $fixture.inventory
    Invoke-OrderFlowGitOpsCleanup $fixture.state $fixture.path -TimeoutSeconds 1
    $deletes = @(Get-Calls | Where-Object { $_ -like 'group delete*' })
    Assert-Test ($deletes.Count -eq 3 -and $deletes[-1] -like '*-shared *') 'Real Down did not preserve ordered deletion.'
    $reloaded = Read-OrderFlowGitOpsState $fixture.path $fixture.state.subscriptionId unit1
    Invoke-OrderFlowGitOpsCleanup $reloaded $fixture.path -TimeoutSeconds 1
    Assert-Test (@(Get-Calls | Where-Object { $_ -like 'group delete*' }).Count -eq 3) 'Real Down replayed deletes after restart.'
    & $module { $script:mode = 'managed-present' }
    Assert-Throws { Invoke-OrderFlowGitOpsCleanup $reloaded $fixture.path } '*Group still present*'
    $progress = Get-Content (Join-Path (Split-Path $fixture.path) 'cleanup-progress.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test (-not $progress.completedAtUtc) 'Failed reverification retained a success timestamp.'

    $fixture = New-Fixture 'preview'
    $fixtureRoot = Join-Path $scratch 'checkout'
    $relative = 'scenarios\orderflow\gitops\scripts'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $relative) -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'scripts') -Force
    foreach ($name in @('OrderFlowGitOps.psm1', 'Remove-OrderFlowGitOps.ps1')) {
        Copy-Item (Join-Path $PSScriptRoot "..\scripts\$name") (Join-Path $fixtureRoot "$relative\$name")
    }
    Copy-Item (Join-Path (Get-OrderFlowGitOpsPath 'Root') 'scripts\Azure.Common.psm1') (Join-Path $fixtureRoot 'scripts')
    $previewStatePath = Join-Path $fixtureRoot '.azure\orderflow-gitops\unit1\ownership.json'
    Save-OrderFlowGitOpsState $fixture.state $previewStatePath
    $hash = (Get-FileHash $previewStatePath).Hash
    $entry = Join-Path $fixtureRoot "$relative\Remove-OrderFlowGitOps.ps1"
    $output = & pwsh -NoProfile -File $entry -EnvironmentName unit1 -WhatIf 2>&1
    Assert-Test ($LASTEXITCODE -eq 0 -and "$output" -like '*What if*') 'Fresh-process preview failed.'
    Assert-Test ((Get-FileHash $previewStatePath).Hash -eq $hash) 'Preview changed ownership.'
    Assert-Test (-not (Test-Path (Join-Path (Split-Path $previewStatePath) 'operation.lock'))) 'Preview wrote a lock.'
    $output = & pwsh -NoProfile -File $entry -EnvironmentName unit1 2>&1
    Assert-Test ($LASTEXITCODE -ne 0 -and "$output" -like '*ActionsSettled*') 'Unsettled actions admitted.'
    # GitHub's pwsh wrapper propagates LASTEXITCODE, including this expected rejection.
    $global:LASTEXITCODE = 0

    [pscustomobject]@{checks = $checks; result = 'Passed (offline cleanup; no Azure/GitHub calls)'}
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
