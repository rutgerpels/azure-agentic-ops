#Requires -Version 7.2
function Assert-CheckoutDeploymentSettled {
    param($Deployment)
    if ($Deployment -and $Deployment.properties['provisioningState'] -notin @('Succeeded', 'Failed', 'Canceled')) {
        throw 'An owned deployment is nonterminal or unknown. Wait or cancel it before Down; retain the manifest.'
    }
}

function Remove-CheckoutDeploymentRecord {
    <#
    .SYNOPSIS
    Delete one owned subscription deployment receipt and wait for verified absence.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotin @($deploymentName, "checkout-oba-reader-$EnvironmentName",
            "checkout-monitor-settings-$EnvironmentName", "checkout-sre-monitoring-$EnvironmentName")) {
        throw 'Unexpected subscription deployment record; refusing deletion.'
    }
    $uri = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Resources/deployments/$Name`?api-version=2022-09-01"
    $record = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri -AllowMissing
    if ($null -eq $record) { return }
    Assert-CheckoutDeploymentSettled $record
    $null = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Method DELETE -Uri $uri -AllowMissing
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        if ($null -eq (Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri -AllowMissing)) { return }
        if ($attempt -eq 12) {
            throw "Deployment record $Name remains after 12 verification checks; retain state and retry Down."
        }
        if ($attempt -eq 1) {
            Write-Information "Waiting for Azure to finish deleting deployment history record $Name..." -InformationAction Continue
        }
        Start-Sleep -Seconds 5
    }
}

function Find-CheckoutSubscriptionGrant {
    param([string]$PrincipalId, [string]$RoleId)
    $principal = ([guid]$PrincipalId).ToString()
    $filter = [uri]::EscapeDataString("principalId eq '$principal'")
    $uri = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Authorization/roleAssignments" +
        '?api-version=2022-04-01&$filter=' + $filter
    $list = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri
    if (-not $list.ContainsKey('value') -or $list['nextLink']) { throw 'Subscription grant discovery is incomplete.' }
    $matching = @($list.value | Where-Object {
        $_.properties.principalId -ieq $principal -and
        $_.properties.scope -ieq "/subscriptions/$subscription" -and
        ($_.properties.roleDefinitionId -split '/')[-1] -ieq $RoleId
    })
    if ($matching.Count -gt 1) { throw 'Ambiguous subscription grant; reconcile before cleanup.' }
    if ($matching.Count) { return $matching[0].id }
}

function Restore-CheckoutCleanupOutputs {
    param([Parameter(Mandatory)][hashtable]$State)
    $base = "https://management.azure.com/subscriptions/$subscription"
    $deployment = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
        -Uri "$base/providers/Microsoft.Resources/deployments/$deploymentName`?api-version=2022-09-01" -AllowMissing
    if ($deployment -and $deployment.properties.parameters.ownerToken.value -cne $State.ownerToken) {
        throw 'Subscription deployment ownership changed; refusing cleanup discovery.'
    }
    Assert-CheckoutDeploymentSettled $deployment
    $estate = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
        -Uri "$base/resourceGroups/$groupName/providers/Microsoft.Resources/deployments/checkout-estate?api-version=2022-09-01" -AllowMissing
    Assert-CheckoutDeploymentSettled $estate
    Assert-CheckoutLatencyAlertSettled $State
    foreach ($path in @(
        "$base/resourceGroups/$groupName/providers/Microsoft.Resources/deployments/checkout-arc",
        "$base/providers/Microsoft.Resources/deployments/checkout-monitor-settings-$EnvironmentName"
    )) {
        Assert-CheckoutDeploymentSettled (Invoke-TokenRequest -Resource 'https://management.azure.com/' `
            -Uri "${path}?api-version=2022-09-01" -AllowMissing)
    }
    if ($estate -and $estate.properties['outputs']) {
        foreach ($key in $estate.properties.outputs.Keys) {
            $value = $estate.properties.outputs[$key].value
            if ($State.outputs[$key] -and $State.outputs[$key] -cne $value) {
                throw "Deployment output $key changed; reconcile ownership before cleanup."
            }
            $State.outputs[$key] = $value
        }
    }
    foreach ($grant in @(
        @{ name = "checkout-oba-reader-$EnvironmentName"; principal = 'observabilityPrincipalId'
            identity = "id-retailtx-checkout-$EnvironmentName-observability"; output = 'observabilityReaderAssignmentId'
            role = '43d0d8ad-25c7-4714-9337-8ba259a9fe05' },
        @{ name = "checkout-sre-monitoring-$EnvironmentName"; principal = 'srePrincipalId'
            identity = "id-retailtx-checkout-$EnvironmentName-sre"; output = 'sreMonitoringAssignmentId'
            role = '749f88d5-cbae-40b8-bcfc-e573ddc772fa' }
    )) {
        $record = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
            -Uri "$base/providers/Microsoft.Resources/deployments/$($grant.name)?api-version=2022-09-01" -AllowMissing
        Assert-CheckoutDeploymentSettled $record
        $identity = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
            -Uri "$base/resourceGroups/$groupName/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($grant.identity)?api-version=2023-01-31" -AllowMissing
        if ($identity) {
            if ($identity.tags.ownerToken -cne $State.ownerToken -or
                ($State.outputs[$grant.principal] -and
                    $State.outputs[$grant.principal] -ine $identity.properties.principalId)) {
                throw 'Cleanup identity ownership or principal drifted.'
            }
            $State.outputs[$grant.principal] = $identity.properties.principalId
        }
        $principal = $State.outputs[$grant.principal]
        if ($record -and (-not $principal -or
            $record.properties.parameters.principalId.value -ine $principal)) {
            throw 'Subscription grant deployment is not linked to the owned estate; reconcile before deletion.'
        }
        if (-not $principal) { continue }
        $found = Find-CheckoutSubscriptionGrant $principal $grant.role
        if ($record -and $record.properties['outputs']) {
            $recorded = $record.properties.outputs.assignmentId.value
            if ($found -and $found -ine $recorded) { throw 'Discovered grant disagrees with its deployment receipt.' }
            $State.outputs[$grant.output] = $recorded
        }
        if ($found) {
            if ($State.outputs[$grant.output] -and $State.outputs[$grant.output] -ine $found) {
                throw 'Discovered grant disagrees with the ownership manifest.'
            }
            $State.outputs[$grant.output] = $found
        }
    }
    Save-RetailState $State $statePath
}

function Remove-CheckoutSubscriptionGrant {
    param([Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$RoleId)
    $prefix = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleAssignments/"
    if (-not $Id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ($Id.Substring($prefix.Length) -as [guid])) { throw 'Unexpected subscription role assignment ID.' }
    $uri = "https://management.azure.com${Id}?api-version=2022-04-01"
    $assignment = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri -AllowMissing
    if ($assignment) {
        if ($assignment.properties.principalId -ine $PrincipalId -or
            $assignment.properties.roleDefinitionId -ine "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$RoleId") {
            throw 'Subscription role assignment drifted; refusing deletion.'
        }
        $null = Invoke-TokenRequest -Resource 'https://management.azure.com/' -Method DELETE -Uri $uri
    }
    if ((Invoke-TokenRequest -Resource 'https://management.azure.com/' -Uri $uri -AllowMissing) -or
        (Find-CheckoutSubscriptionGrant $PrincipalId $RoleId)) {
        throw 'Subscription grant removal is not yet verified. Retain state and retry Down.'
    }
}
