#Requires -Version 7.2
# Dot-sourced by the checkout lifecycle; all writes use its explicit subscription.
function Get-CheckoutArcMachine {
    param([Parameter(Mandatory)][hashtable]$State)
    $machine = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
        -Uri "https://management.azure.com$($State.outputs.arcMachineId)?api-version=2024-07-10" -AllowMissing
    if ($machine -and ($machine.tags.ownerToken -cne $State.ownerToken -or
            $machine.tags.managedBy -cne 'invoke-checkoutdemo')) {
        throw 'Arc machine ownership does not match this checkout deployment.'
    }
    return $machine
}

function Initialize-CheckoutArc {
    param([Parameter(Mandatory)][hashtable]$State)
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
    do {
        $machine = Get-CheckoutArcMachine $State
        if ($machine -and $machine.properties['status'] -ceq 'Connected') { break }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw 'Arc onboarding did not become Connected. Inspect bootstrap; do not use native VM commands as a substitute.'
        }
        Start-Sleep -Seconds 15
    } while ($true)

    if ($State.outputs.bootstrapIdentityId) {
        $identity = Invoke-Az @('vm', 'identity', 'show', '--ids', $State.outputs.vmId)
        if ($identity -and $identity['userAssignedIdentities'] -and
            $identity.userAssignedIdentities.ContainsKey($State.outputs.bootstrapIdentityId)) {
            $null = Invoke-Az @('vm', 'identity', 'remove', '--ids', $State.outputs.vmId,
                '--identities', $State.outputs.bootstrapIdentityId)
        }
        $null = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Method DELETE -AllowMissing `
            -Uri "https://management.azure.com$($State.outputs.bootstrapRoleId)?api-version=2022-04-01"
        $null = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Method DELETE -AllowMissing `
            -Uri "https://management.azure.com$($State.outputs.bootstrapIdentityId)?api-version=2023-01-31"
    }
    $State.arcRegistered = $true
    if (-not $State.arcRoleName) { $State.arcRoleName = [guid]::NewGuid().ToString() }
    if (-not $State.arcAssignmentName) { $State.arcAssignmentName = [guid]::NewGuid().ToString() }
    $State.arcRoleId = "$($State.outputs.resourceGroupId)/providers/Microsoft.Authorization/roleDefinitions/$($State.arcRoleName)"
    $State.arcAssignmentId = "$($State.outputs.arcMachineId)/providers/Microsoft.Authorization/roleAssignments/$($State.arcAssignmentName)"
    Save-RetailState $State $statePath
    $group = Invoke-Az @('group', 'show', '--name', $groupName)
    $null = Invoke-Az @('deployment', 'group', 'create', '--resource-group', $groupName,
        '--name', 'checkout-arc', '--template-file', (Join-Path $repository 'infra\checkout\arc.bicep'),
        '--parameters', "machineName=$($State.outputs.arcMachineName)",
        "workspaceName=$(($State.outputs.workspaceId -split '/')[-1])",
        "actionPrincipalId=$($State.outputs.srePrincipalId)",
        "alertName=$($State.outputs.serviceAlertRuleName)", "actionGroupId=$($State.outputs.actionGroupId)",
        "commandRoleName=$($State.arcRoleName)", "actionAssignmentName=$($State.arcAssignmentName)",
        "tags=$($group.tags | ConvertTo-Json -Compress)") -TimeoutSeconds 900
    $State.arcMonitoringConfigured = $true
    Save-RetailState $State $statePath
}

function Wait-CheckoutArcCommand {
    param([Parameter(Mandatory)][hashtable]$State)
    $command = $State.pendingArcCommand
    if (-not $command) { throw 'No pending Arc command to observe.' }
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        $result = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
            -Uri "https://management.azure.com$($command.id)?api-version=2024-07-10" -AllowMissing
        $view = if ($result) { $result.properties['instanceView'] } else { $null }
        if ($view -and $view.executionState -in @('Succeeded', 'Failed', 'TimedOut', 'Canceled')) {
            $State.lastArcCommand = @{ id = $command.id; action = $command.action; result = $view
                observedAt = [DateTimeOffset]::UtcNow.ToString('o') }
            $State.pendingArcCommand = $null
            if ($command.action -ceq 'probe') { $State.arcProbeVerified = $false }
            elseif ($command.action -ceq 'install-controller') { $State.controllerInstalled = $false }
            if ($view.executionState -cne 'Succeeded' -or $view.exitCode -ne 0) {
                Save-RetailState $State $statePath
                throw "Arc command finished as $($view.executionState), exit $($view.exitCode). Inspect the saved receipt; no replay was attempted."
            }
            if ($command.action -ceq 'probe') {
                if ($view.output -notmatch '(?m)^checkout-arc-probe-ok$' -or -not [string]::IsNullOrWhiteSpace($view.error)) {
                    Save-RetailState $State $statePath
                    throw 'Arc executed the probe, but its expected posture receipt is missing or contains errors.'
                }
                $State.arcProbeVerified = $true
            } elseif ($command.action -ceq 'install-controller') {
                $State.controllerInstalled = $true
            }
            Save-RetailState $State $statePath
            return $view
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw 'Arc command outcome is UNKNOWN after five minutes. Use ObserveArc to read the same command, not resubmit it.'
        }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Invoke-CheckoutArcCommand {
    param([Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Operation)
    if ($State.pendingArcCommand) { throw 'An Arc command is unsettled. Use ObserveArc; do not submit another.' }
    $machine = Get-CheckoutArcMachine $State
    if (-not $machine -or $machine.properties['status'] -cne 'Connected') { throw 'Arc machine is not Connected.' }
    $name = 'rtx-' + [guid]::NewGuid().ToString('N').Substring(0, 24)
    $id = "$($State.outputs.arcMachineId)/runCommands/$name"
    $State.pendingArcCommand = @{ id = $id; action = $Operation; requestedAt = [DateTimeOffset]::UtcNow.ToString('o') }
    if ($Operation -ceq 'probe') { $State.arcProbeVerified = $false }
    elseif ($Operation -ceq 'install-controller') { $State.controllerInstalled = $false }
    Save-RetailState $State $statePath
    # Persist admission before the single PUT. Network errors leave an unknown command, never a retry.
    $null = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Method PUT `
        -Uri "https://management.azure.com$($id)?api-version=2024-07-10" `
        -Body @{ location = $Location; properties = @{ source = @{ script = $Script.Replace("`r`n", "`n") }
                timeoutInSeconds = 90; asyncExecution = $true } }
    return Wait-CheckoutArcCommand $State
}

function New-CheckoutArcPreparationResult {
    <#
    .SYNOPSIS
    Report preparation separately from the live Ready gate without labelling stderr an error.
    #>
    param([Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('ProbeArc', 'PrepareArc')][string]$Action,
        [switch]$AlreadyPrepared)
    [pscustomobject]@{
        action = $Action
        succeeded = $true
        alreadyPrepared = $AlreadyPrepared.IsPresent
        preparationComplete = ($State['arcProbeVerified'] -eq $true -and $State['controllerInstalled'] -eq $true)
        readiness = 'Not evaluated; continue only when Ready returns ready=True.'
        nextAction = $(if ($State['arcProbeVerified'] -ne $true) { 'ProbeArc' }
            elseif ($State['controllerInstalled'] -ne $true) { 'PrepareArc' } else { 'Ready' })
    }
}

function Remove-CheckoutArcRole {
    param([Parameter(Mandatory)][hashtable]$State)
    foreach ($id in @($State.arcAssignmentId, $State.arcRoleId)) {
        if (-not $id) { continue }
        $uri = "https://management.azure.com$($id)?api-version=2022-04-01"
        $existing = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri -AllowMissing
        if (-not $existing) { continue }
        if ($id -eq $State.arcAssignmentId -and
            ($existing.properties.principalId -ine $State.outputs.srePrincipalId -or
             $existing.properties.roleDefinitionId -notlike "*$($State.arcRoleName)")) {
            throw 'Arc action role assignment drifted; refusing to delete another grant.'
        }

        if ($id -eq $State.arcRoleId -and
            $existing.properties.assignableScopes -notcontains $State.outputs.resourceGroupId) {
            throw 'Arc custom role scope drifted; refusing removal.'
        }
        $null = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Method DELETE -Uri $uri -AllowMissing
        if (Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri -AllowMissing) {
            throw 'Arc role cleanup is not yet verified. Retry Down after propagation.'
        }
    }
}

function Assert-CheckoutArcPermissions {
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State['arcAssignmentId'] -or -not $State['arcRoleId']) { throw 'Arc command grants are not recorded.' }
    $assignment = Invoke-TokenRequest -Resource 'https://management.azure.com/' -AllowMissing `
        -Uri "https://management.azure.com$($State.arcAssignmentId)?api-version=2022-04-01"
    if (-not $assignment -or $assignment.properties.principalId -ine $State.outputs.srePrincipalId -or
        $assignment.properties.scope -ine $State.outputs.arcMachineId -or
        ($assignment.properties.roleDefinitionId -split '/')[-1] -ine $State.arcRoleName) {
        throw 'Exact-machine SRE Arc command assignment is missing or drifted.'
    }
    $role = Invoke-TokenRequest -Resource 'https://management.azure.com/' -AllowMissing `
        -Uri "https://management.azure.com$($State.arcRoleId)?api-version=2022-04-01"
    $actions = 'Microsoft.HybridCompute/machines/read,Microsoft.HybridCompute/machines/runcommands/read,Microsoft.HybridCompute/machines/runcommands/write'
    if (-not $role -or @($role.properties.assignableScopes).Count -ne 1 -or
        $role.properties.assignableScopes[0] -ine $State.outputs.resourceGroupId -or
        @($role.properties.permissions).Count -ne 1 -or
        (($role.properties.permissions[0].actions | Sort-Object) -join ',') -ine $actions -or
        @($role.properties.permissions[0].notActions).Count -or
        @($role.properties.permissions[0].dataActions).Count -or
        @($role.properties.permissions[0].notDataActions).Count) {
        throw 'Arc command role scope or permissions drifted.'
    }
}
