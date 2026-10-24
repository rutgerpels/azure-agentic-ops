#Requires -Version 7.2
function Assert-CheckoutLatencyAlertSettled {
    <#
    .SYNOPSIS
    Block redeployment or cleanup while the last alert deployment is unsettled.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State['latencyAlertDeploymentName']) { return }
    if ($State.latencyAlertDeploymentName -cnotmatch '^checkout-latency-alert-[0-9a-f]{32}$') {
        throw 'Unexpected latency alert deployment receipt; retain state and reconcile.'
    }
    $deployment = Invoke-TokenRequest -Resource 'https://management.azure.com/' `
        -Uri "https://management.azure.com/subscriptions/$subscription/resourceGroups/$groupName/providers/Microsoft.Resources/deployments/$($State.latencyAlertDeploymentName)?api-version=2022-09-01" -AllowMissing
    Assert-CheckoutDeploymentSettled $deployment
}

function Initialize-CheckoutLatencyAlert {
    <#
    .SYNOPSIS
    Deploy only the latency alert, retrying confirmed workspace propagation failures.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $group = Invoke-Az @('group', 'show', '--name', $groupName)
    if ($group.tags.ownerToken -cne $State.ownerToken -or
        $group.tags.managedBy -cne 'invoke-checkoutdemo') {
        throw 'Latency alert deployment ownership mismatch.'
    }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $name = 'checkout-latency-alert-' + [guid]::NewGuid().ToString('N')
        $State.latencyAlertDeploymentName = $name
        Save-RetailState $State $statePath
        $arguments = @('deployment', 'group', 'create', '--resource-group', $groupName,
            '--name', $name, '--template-file', (Join-Path $repository 'infra\checkout\latency-alert.bicep'),
            '--parameters', "alertName=$($State.outputs.alertRuleName)", "location=$Location",
            "workspaceId=$($State.outputs.workspaceId)", "actionGroupId=$($State.outputs.actionGroupId)",
            "tags=$($group.tags | ConvertTo-Json -Compress)")
        $hint = "Inspect 'az deployment operation group list --resource-group $groupName --name $name'."
        try {
            $null = Invoke-Az $arguments -TimeoutSeconds 120
            return
        } catch {
            $failure = $_
            if ($failure.Exception -is [TimeoutException]) {
                throw [TimeoutException]::new("Latency alert deployment timed out; Azure outcome unknown. No retry was submitted. $hint", $failure.Exception)
            }
            # Each attempt has a fresh receipt; a CLI failure cannot reuse historical failed operations.
            $deployment = Invoke-Az @('deployment', 'group', 'show',
                '--resource-group', $groupName, '--name', $name) -TimeoutSeconds 30
            if ($deployment.properties.provisioningState -cne 'Failed') {
                throw [InvalidOperationException]::new("Latency alert deployment outcome is not confirmed Failed. No retry was submitted. $hint", $failure.Exception)
            }
            $operations = @(Invoke-Az @('deployment', 'operation', 'group', 'list',
                '--resource-group', $groupName, '--name', $name) -TimeoutSeconds 30)
            $failed = @($operations | Where-Object { $_.properties.provisioningState -ceq 'Failed' })
            $unsettled = @($operations | Where-Object { $_.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled') })
            $retryable = $failed.Count -eq 1 -and $unsettled.Count -eq 0
            if ($retryable) {
                $operation = $failed[0].properties
                $errorDetails = $operation.statusMessage
                if ($errorDetails -is [string]) {
                    $errorDetails = $errorDetails | ConvertFrom-Json -AsHashtable
                }
                $errorDetails = if ($errorDetails -is [System.Collections.IDictionary]) { $errorDetails['error'] }
                $retryable = $operation.targetResource.resourceType -ceq 'Microsoft.Insights/scheduledQueryRules' -and
                    $operation.targetResource.resourceName -ceq $State.outputs.alertRuleName -and
                    $errorDetails -is [System.Collections.IDictionary] -and $errorDetails['code'] -ceq 'BadRequest' -and
                    $errorDetails['message'] -cmatch '^The workspace could not be found(?: Activity ID: [0-9a-fA-F-]+\.?)?$' -and
                    -not $errorDetails['details']
            }
            if (-not $retryable) {
                throw [InvalidOperationException]::new("Latency alert deployment failed; not a confirmed workspace propagation error. $hint", $failure.Exception)
            }
            if ($attempt -eq 6) {
                throw [InvalidOperationException]::new("Latency alert workspace remained unavailable after six attempts. Owned state is retained. $hint", $failure.Exception)
            }
            Write-Warning "Azure Monitor cannot yet find the provisioned workspace. Retrying only the latency alert in 15 seconds (attempt $attempt of 6)."
            Start-Sleep -Seconds 15
        }
    }
}
