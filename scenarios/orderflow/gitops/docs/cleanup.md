# OrderFlow GitOps: owned cleanup

Continue from [README step 12](../../README.md#12-reset-and-clean-up) in the same
owning checkout and terminal (`$common`, `$statePath`, `$subscriptionId`, `$repo`).
These commands delete Azure resources: use only the authorized demo scope.
Settle SRE requests, Copilot tasks, deployment approvals and unknown operations
first. Do not remove ownership or replay a timed-out delete.

Pause future CD before removing its targets; check admitted runs separately:

```powershell
gh workflow disable orderflow-gitops-cd.yml --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Could not pause CD.' }
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body false
if ($LASTEXITCODE -ne 0) { throw 'Could not disable legacy handoff.' }
gh run list --repo $repo --limit 15
```

Inventory provider-managed groups and the exact platform monitoring grant
**before** the identities disappear. Keep this inventory private:

```powershell
Import-Module .\scenarios\orderflow\gitops\scripts\OrderFlowGitOps.psm1 -Force
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$managedGroups = @()
foreach ($stage in @('prod', 'test')) {
    $managedGroup = az containerapp env show --subscription $subscriptionId `
        --resource-group $state.resourceGroups[$stage] --name "cae-ofg-$stage" `
        --query properties.infrastructureResourceGroup --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $managedGroup) { throw "Could not inventory $stage infrastructure." }
    $managedGroups += $managedGroup
}
$srePrincipalId = Get-OrderFlowGitOpsOutput $state 'sre' 'srePrincipalId'
$roles = @(Invoke-OrderFlowGitOpsAzure $state @(
    'role', 'assignment', 'list', '--assignee-object-id', $srePrincipalId, '--all', '--include-inherited'
))
$scope = "/subscriptions/$subscriptionId"
$monitoringDefinition = "$scope/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
$monitoringRoles = @($roles | Where-Object {
    $_.principalId -ieq $srePrincipalId -and $_.scope -ieq $scope -and
    $_.roleDefinitionId -ieq $monitoringDefinition
})
$cleanupPath = Join-Path (Split-Path $statePath -Parent) 'cleanup-inventory.json'
if (Test-Path -LiteralPath $cleanupPath) { throw 'Existing inventory: inspect and reuse it, never overwrite cleanup evidence.' }
@{ groups = @($state.resourceGroups.Values) + $managedGroups
   srePrincipalId = $srePrincipalId; monitoringRoles = $monitoringRoles } |
    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cleanupPath
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Down @common
```

Down deletes SRE first while its identity exists, then test/prod, then shared.
If it stops, preserve the original journal and observe with Status. Do not run
the inventory block again against deleted resources.

After Down, verify all three owned groups and both managed groups are absent.
The group-scoped teardown does not remove a subscription-level monitoring grant.
Inspect the recorded ID privately and authorize only that exact removal:

```powershell
$cleanup = Get-Content -LiteralPath $cleanupPath -Raw | ConvertFrom-Json -AsHashtable
foreach ($group in $cleanup.groups) {
    if (Invoke-OrderFlowGitOpsAzure $state @('group', 'exists', '--name', $group)) {
        throw "Group still exists: $group. Observe its original deletion."
    }
}
$remaining = @(Invoke-OrderFlowGitOpsAzure $state @(
    'role', 'assignment', 'list', '--assignee-object-id', $cleanup.srePrincipalId, '--all', '--include-inherited'
))
foreach ($recorded in $cleanup.monitoringRoles) {
    $live = @($remaining | Where-Object { $_.id -ieq $recorded.id })
    if (-not $live.Count) { continue }
    if ($live.Count -ne 1 -or $live[0].principalId -ine $cleanup.srePrincipalId -or
        $live[0].scope -ine $scope -or $live[0].roleDefinitionId -ine $monitoringDefinition) {
        throw 'Role metadata changed; do not delete it.'
    }
    Invoke-OrderFlowGitOpsAzure $state @('role', 'assignment', 'delete', '--ids', $recorded.id)
}
$remaining = @(Invoke-OrderFlowGitOpsAzure $state @(
    'role', 'assignment', 'list', '--assignee-object-id', $cleanup.srePrincipalId, '--all', '--include-inherited'
))
if ($remaining.Count) { throw 'Assignments remain. Inspect ownership; never broadly delete them.' }
```

A role-delete timeout is unknown: list the exact assignment before considering
another action. Do not delete unrelated/inherited roles or sweep orphan IDs.
Retain ownership, journals and final absence evidence.

GitHub settings and valid issue credentials can remain for Azure-only cleanup.
For permanent retirement, separately review credentials, connector and
environments before removing them. The old assignment token is unused by
manual handoff; retire it only after reconciling historical tasks and checking
that it is dedicated to this demo.
