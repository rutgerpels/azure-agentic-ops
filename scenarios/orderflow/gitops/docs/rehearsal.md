# OrderFlow GitOps: A-Z rehearsal from a clean Azure deployment

Use this guide for **option 2, PAT authentication**, from source preparation to
cleanup. Option 1 and Retailx are not part of this deployment. Keep GitHub's
**Require approval for workflow runs** enabled. A human merges every production
change; SRE cannot repair Azure or create code/PRs.

The selected rehearsal mode is `-SreIssueWriteApproval Automatic`: only the exact
issue-publication tool runs without a native SRE card. Issue reads still require
native approval. Copilot workflow-run approvals are a different control and
remain enabled. Omit the option to retain the default `Native` publication card.

**Start early, not at audience time.** Fresh infrastructure, identity propagation,
image builds, alerts and Copilot runs take variable time. Stop at each checkpoint.
Do not run the next mutation after an unknown result.

## What is already proven, and what this rehearsal must prove

On November 4, 2026, the previous demo's human-merged fix restored production:
CD and smoke passed, the portal persisted a new synthetic order, and the original
dependency alert resolved. SRE issue publication without a write card and one
Copilot assignment also succeeded. The original issue-write approval card had
failed before its approval record existed; its underlying platform cause remains
unknown. The supported opt-in above avoids that card, not the production gates.

**The pre-merge test deployment was not proven.** Its historical run required
approval and did not execute. A later gate failed without available job logs;
that is not evidence of a particular code defect. This rehearsal is incomplete
unless the fix's exact head SHA passes the separate test deployment and smoke
**before** human merge. Green offline CI or recovered production is insufficient.

The previous `demo3` generation is consumed and retired. Preserve its ignored
ownership/journals and private recovery/cleanup receipts. Never recreate its
manifest, change its generation, or use `Reset` to rearm it.

## 1. Prepare tools, sign-in and the retained GitHub settings

Use PowerShell 7.2+, Azure CLI with Bicep, Git and GitHub CLI. You need repository
administration, Copilot entitlement for the assignment user, and an authorized
Azure operator able to deploy resources and scoped role assignments. Use only a
subscription approved for this synthetic demo.

Run from the repository root. Keep the same terminal for later blocks:

```powershell
$ErrorActionPreference = 'Stop'
$repo = 'rutgerpels/azure-agentic-ops'
git --version
if ($LASTEXITCODE -ne 0) { throw 'Git unavailable.' }
gh auth status
if ($LASTEXITCODE -ne 0) { throw 'Sign in with gh auth login first.' }
az account show --query '{subscription:id,tenant:tenantId}' -o table
if ($LASTEXITCODE -ne 0) { throw 'Sign in with az login first.' }
az bicep version
if ($LASTEXITCODE -ne 0) { throw 'Install/restore the required Bicep tooling first.' }
```

In repository **Settings > Copilot > Cloud agent > Policies**, leave
**Require approval for workflow runs** enabled. Retain the existing human-review
branch rules, read-only default Actions permissions, secrets and environment
protection. See [GitHub's agent policy documentation](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/configuring-agent-settings).

Before any preparatory source PR is merged, temporarily pause only production
CD. Source/docs merges under this scenario otherwise deploy against the deleted
Azure environment using retained variables. This is a temporary workflow pause,
not removal of any security or review setting:

```powershell
gh workflow disable orderflow-gitops-cd.yml --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Could not pause production CD.' }
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body false
if ($LASTEXITCODE -ne 0) { throw 'Could not disable handoff during setup.' }
```

Check Actions for any already-running deployment; disabling a workflow does
not cancel an admitted run. Observe/settle existing runs before new setup.
Do not approve or rerun old `demo3` test deployments against a fresh environment.

## 2. Human-review the source and restore the healthy baseline on main

Review and merge the existing source correction
[PR #94](https://github.com/rutgerpels/azure-agentic-ops/pull/94), including this
guide and automatic publication mode. This is a human action. Keep CD paused
until step 6.

The previous fix-forward on `main` contains both the deny and its narrower allow.
It is healthy, but **not the starting baseline required by Up/Ready/Fault**.
Do not delete the baseline or weaken those checks.

Open a clean, dedicated feature session/branch based on the updated `main`.
Never work directly on `main`. If runtime rules already equal the baseline,
skip the following reset PR. Otherwise prepare exactly this one-file reset:

```powershell
Copy-Item -LiteralPath .\scenarios\orderflow\gitops\deploy\baseline\network-rules.json `
    -Destination .\scenarios\orderflow\gitops\deploy\network-rules.json
git --no-pager diff -- scenarios/orderflow/gitops/deploy/network-rules.json
git add -- scenarios/orderflow/gitops/deploy/network-rules.json
if ($LASTEXITCODE -ne 0) { throw 'Could not stage baseline restoration.' }
git commit -m 'fix(orderflow-gitops): restore baseline for fresh rehearsal'
if ($LASTEXITCODE -ne 0) { throw 'Could not commit baseline restoration.' }
git push -u origin HEAD
if ($LASTEXITCODE -ne 0) { throw 'Inspect push outcome before any retry.' }
gh pr create --repo $repo --base main --label orderflow-reset `
    --title 'Reset OrderFlow network rules to baseline' `
    --body 'Restore only the runtime rules from the immutable healthy baseline for a fresh rehearsal. Production CD is paused while Azure is absent. Human review and merge required.'
if ($LASTEXITCODE -ne 0) { throw 'Inspect existing PRs before any retry.' }
```

Check that this PR changes **only** the runtime rules file, wait for required CI,
then human-review and merge. Do not approve a fault or fix as a substitute.
After retirement, the old manifest's `Reset` action is deliberately unavailable;
that is why this preparatory PR does not reuse it.

## 3. Choose a fresh environment and create Azure healthy

Open a fresh, clean feature session from the now-reviewed `main`. Do not copy
old ownership into it. Reinitialize `$repo` and `$ErrorActionPreference` from
step 1 if using a new terminal. Confirm there are no uncommitted changes and
that your scenario source matches the fetched `main` before provisioning:

```powershell
git status --short
git fetch origin main
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch reviewed main.' }
git diff --quiet HEAD origin/main -- scenarios/orderflow .github/workflows
if ($LASTEXITCODE -ne 0) { throw 'Use the reviewed current main source in a dedicated feature session.' }

$subscriptionId = Read-Host 'Approved Azure subscription ID'
$environmentName = 'demo4'
$common = @{ SubscriptionId = $subscriptionId; EnvironmentName = $environmentName }
$statePath = Join-Path (Get-Location) ".azure\orderflow-gitops\$environmentName\ownership.json"
if (Test-Path -LiteralPath $statePath) { throw 'Choose an unused environment name; do not overwrite ownership.' }
$adminObjectId = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve your Entra user object ID.' }

.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action Up @common -Location swedencentral -SreLocation swedencentral `
    -AdminObjectId $adminObjectId -GitHubRepository $repo
```

Review the explicit deployment confirmation. Use a supported authorized region;
`swedencentral` was used in the prior rehearsal, not a capacity guarantee.
Use another new 3-12-character lowercase name if `demo4` is already owned.

**Checkpoint:** `Up` ends Healthy, test and prod smoke are `Succeeded`, and the
public portal URL is printed. The API/Cosmos DB remain private. Load the new
manifest without printing it publicly:

```powershell
Import-Module .\scenarios\orderflow\gitops\scripts\OrderFlowGitOps.psm1 -Force
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
if ($state.phase -cne 'provisioned' -or $state.pendingOperation -or @($state.faults).Count) {
    throw 'Expected a fresh, provisioned, unused generation.'
}
$portal = Get-OrderFlowGitOpsOutput $state 'prod' 'portalUrl'
$portal
```

On a timeout or unknown operation, run `-Action Status @common` and observe the
original operation. Do not delete state, adopt resources, or replay deployment.
Resume `Up` only when Status proves the prior stage settled and permits it.

## 4. Refresh Azure-bound variables and exact OIDC trust

Retained GitHub settings still point at the old identities. New resources have
new client IDs, owner generation and endpoints:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action ConfigureGitHub @common
```

Review this configuration action. Verify `orderflow-test` and `orderflow-prod`
remain restricted to **main**, with separate deployment client IDs. Keep PR
review as the production gate; do not add PR branches to Azure federation.

**Important:** `shared.bicep` defaults to the older name-only GitHub subject.
This repository's prior live OIDC token used immutable owner/repository IDs.
For the same repository/claim configuration, update only the two newly created
federated credentials to that observed format:

```powershell
$metadata = gh api "repos/$repo" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve repository identity.' }
foreach ($stage in @('test', 'prod')) {
    $subject = 'repo:{0}@{1}/{2}@{3}:environment:orderflow-{4}' -f `
        $metadata.owner.login, $metadata.owner.id, $metadata.name, $metadata.id, $stage
    az identity federated-credential update --subscription $subscriptionId `
        --resource-group $state.resourceGroups.shared `
        --identity-name "id-ofg-deploy-$stage" --name "github-orderflow-$stage" `
        --subject $subject --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "Inspect $stage federation; do not continue." }
    $actual = az identity federated-credential show --subscription $subscriptionId `
        --resource-group $state.resourceGroups.shared `
        --identity-name "id-ofg-deploy-$stage" --name "github-orderflow-$stage" `
        --query subject --output tsv
    if ($LASTEXITCODE -ne 0 -or $actual -cne $subject) { throw "$stage subject was not verified." }
}
```

This is not a universal GitHub default. For another repository or changed OIDC
claim template, use its actual documented/token subject, not a guessed format.
Issuer stays `https://token.actions.githubusercontent.com`; audience stays
`api://AzureADTokenExchange`. Do not change the repository claim template or
grant broader trust to fix an Azure mismatch. See
[Azure CLI federated-credential update](https://learn.microsoft.com/en-us/cli/azure/identity/federated-credential#az-identity-federated-credential-update).
A later explicit shared-template redeployment can restore its defaults; verify
these subjects again after such a change.

## 5. Recreate the issue connector and select automatic publication

The old connector disappeared with the old SRE Agent. In the **new owned agent**,
verify Running, then open **Builder > Connectors > Add connector > MCP > GitHub
MCP**. Do not select the native GitHub OAuth/Code Repository connector.

Reuse a still-valid issue PAT from your credential manager, or create a
replacement using [PAT setup step 2](github-pat-setup.md#2-create-the-sre-issue-only-pat).
It must select only this repository, **Issues read/write and Metadata read**.
Never use the broader assignment PAT here. Enter credentials only in the
protected connector field, not in command arguments or public evidence.

Select exactly `list_issues`, `issue_read`, `issue_write`. Record the actual full
prefixed names; do not copy the example `githubissuescon` prefix:

```powershell
$sreIssueTools = @(
    '<actual-prefix>_list_issues'
    '<actual-prefix>_issue_read'
    '<actual-prefix>_issue_write'
)
if ($sreIssueTools -match '<') { throw 'Replace all three names from the deployed MCP catalog.' }
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action ConfigureSre @common -SreAuthMode PAT `
    -SreIssueTools $sreIssueTools -SreIssueWriteApproval Automatic
```

**Checkpoint:** SRE configured and verified. Only exact issue-write is Allow;
list/read are Ask; Azure writes, shells and Python remain Deny. The selected
mode is recorded in ownership and checked again before Ready/Fault. No policy
hooks or thread-level overrides are introduced. To choose the old publication
card instead, explicitly use `Native`; its earlier platform failure remains
unexplained. Never switch modes during a pending/unknown publication.

The generic PAT tool can update issues as well as create them; automatic mode
does not make it server-enforced create-only. Instructions prohibit updates,
limit publication to one first attempt, and require complete-body deduplication
over both issue states. Keep one incident thread. If a prior write, approval or
parallel investigator may exist, stop and reconcile instead of retrying.
Use the App publisher if durable publication reservation is required.

SRE's platform Monitoring Contributor exception remains limited to the exact
built-in role at the owned subscription. It is not strictly RBAC read-only.
No NSG repair role or Azure write tool is granted by this setup.

## 6. Re-pin handoff, prove reads and establish healthy CD

Keep the existing repository secret `ORDERFLOW_COPILOT_ASSIGN_TOKEN` if its
distinct user PAT is still valid. It needs Copilot entitlement and the
repository-only permissions in
[PAT setup step 4](github-pat-setup.md#4-configure-the-separate-automatic-assignment):
Metadata read; Actions, Contents, Issues and Pull requests read/write.
If replacing it, use the protected prompt:

```powershell
gh secret set ORDERFLOW_COPILOT_ASSIGN_TOKEN --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Inspect secret configuration before proceeding.' }
```

Skip that command if the existing secret is valid. Its presence does not prove
expiry or token owner. Pin the actual GitHub usernames, not PAT strings:

```powershell
$sreLogin = Read-Host 'GitHub username of the issue PAT owner'
$assignmentLogin = Read-Host 'GitHub username of the assignment PAT owner'
$sreUserId = gh api "users/$sreLogin" --jq .id
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve issue publisher.' }
$assignmentUserId = gh api "users/$assignmentLogin" --jq .id
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve assignment user.' }
$handoffVariables = [ordered]@{
    ORDERFLOW_SRE_AUTH_MODE = 'PAT'
    ORDERFLOW_SRE_GITHUB_LOGIN = $sreLogin
    ORDERFLOW_SRE_GITHUB_USER_ID = $sreUserId
    ORDERFLOW_HANDOFF_USER_ID = $assignmentUserId
    ORDERFLOW_SRE_GENERATION = $state.ownerToken
}
foreach ($entry in $handoffVariables.GetEnumerator()) {
    gh variable set $entry.Key --repo $repo --body ([string]$entry.Value)
    if ($LASTEXITCODE -ne 0) { throw "Could not set $($entry.Key); keep handoff disabled." }
}
```

The same person may own both tokens, but they must be different tokens with
different permissions. Do not reuse the previous generation pin.

In one connection-check SRE thread, select the configured investigator and ask:

```text
Use only the configured issue tools to list issues in rutgerpels/azure-agentic-ops.
Include open and closed issues, complete bodies and all pages. Do not create or
update issues, assign anyone, or change code. Report errors and completeness.
```

Approve only the actual read cards after checking their arguments. Different
read calls may require separate cards; this is not the removed write card.
Verify tool results, not just SRE's narrative. Do not publish a test incident.
Wait for this thread and its actions to settle.

Enable the freshly pinned handoff and resume CD:

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body true
if ($LASTEXITCODE -ne 0) { throw 'Could not enable handoff.' }
gh workflow enable orderflow-gitops-cd.yml --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Could not resume production CD.' }
gh workflow run orderflow-gitops-cd.yml --repo $repo --ref main
if ($LASTEXITCODE -ne 0) { throw 'Inspect Actions for the admitted run; do not blindly dispatch again.' }
gh run list --repo $repo --workflow orderflow-gitops-cd.yml --limit 5
```

Open the **new** healthy CD run and wait for login, deploy and smoke success.
Do not rerun an old fault CD. With these new identities, a healthy production
run proves only prod OIDC; the later test deployment must prove test OIDC.

## 7. Admit the demo only when Ready and a real order succeed

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Ready @common
```

**Checkpoint:** Ready succeeds with fresh test/prod smoke and `sreVerified=True`.
A warning that ConfigureSre was not run is only a CI/CD rehearsal, not success
for this full demo. Baseline on main, no prior fault/open fault PR, no active
dependency alert, correct handoff and fresh SRE policy checks must all pass.

Open `$portal` in a browser. Place one synthetic order, observe its confirmed
receipt and record its request ID privately. The UI supplies the required origin
and `x-orderflow-request` header. A raw POST without that header is correctly
rejected and does not prove a dependency fault.

Prepare tabs: healthy portal, Actions, PRs, Issues, the owned SRE Agent and the
production NSG. Do not introduce any fault before this checkpoint.

## 8. Open and human-merge the predefined fault

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Fault @common
```

Inspect the printed PR. It must change only
`scenarios/orderflow/gitops/deploy/network-rules.json`, adding the predefined
priority-300 `DenyVnetToDataTier`. Wait for required CI, then **human-review and
merge**. Fault never merges for you.

Watch the new main CD: deployment applies the deny, then the in-network smoke
fails. This red smoke/CD result is expected **only after successful fault
deployment**. An OIDC/template failure is not fault injection.

Refresh the portal and show catalog/order dependency errors while the page
itself stays reachable. Record fresh UTC times/status codes. An uncertain
order must be looked up by request ID; do not resubmit it.

## 9. Observe SRE diagnosis, one issue and one Copilot assignment

Wait for the owned dependency alert and SRE incident. Inspect its NSG, Activity
Log and Cosmos dependency evidence. Approve only bounded read cards if asked.
If it asks for first-publication confirmation, first verify no earlier create,
unknown write or parallel investigator exists for this generation.

In the selected Automatic mode, **there is no issue-write approval card**.
SRE should publish one issue with the current standalone generation marker,
`orderflow-incident` label, evidence, proposed rules-only fix and validation/
rollback plan. No assignees are sent by SRE. The author is the pinned PAT user.
Keep live identifiers and raw receipts out of public comments.

Watch `OrderFlow GitOps Copilot handoff`. Verify one assignment intent and
Copilot as assignee, then its draft fix PR. A second opened/labelled event may
run the workflow, but must not submit another assignment.
Do not manually assign, re-label, delete intent comments or replay an uncertain
assignment. Reconcile observed assignees/tasks first.

## 10. Approve workflows and prove the exact fix in test before merge

Human-inspect the fix PR. It must modify exactly the one runtime rules file,
normally adding priority-200 TCP/443 `AllowAppsToCosmosPrivateEndpoint` to
`DataSubnet` while preserving the priority-300 deny. No scripts, workflow,
baseline or application changes are eligible for this test path.

Keep **Require approval for workflow runs** enabled:

1. On the Copilot PR, use **Approve and run workflows** when requested, after
   checking the actual diff/head. Wait for GitOps CI, OrderFlow validation and
   `OrderFlow GitOps test gate` for that head.
2. Open **Actions > OrderFlow GitOps test deployment** separately. If GitHub
   requests another workflow-run approval there, inspect and approve that run
   too. Approval of PR CI did not prove this privileged workflow executed.
3. Verify `Re-verify pull request` admits the open PR at its current head SHA.
   The workflow checks out trusted main, overlays only that rules file, logs in
   through `orderflow-test`, deploys test and runs fresh in-network smoke.
4. Require the report/comment to show that **same head SHA**, smoke
   `Succeeded` and its deployment-run link. Confirm `Report and mark ready`
   succeeds. If the head changes, wait for its own new test evidence.

```powershell
gh run list --repo $repo --workflow orderflow-gitops-test.yml --limit 5
gh run list --repo $repo --workflow orderflow-gitops-test-deploy.yml --limit 5
```

**Stop here if deployment is `action_required`, skipped, cancelled, failed or
has no matching report.** Do not manually mark ready or merge based on green
offline checks. A successful resolve job with no deploy job is not a test.
The deployment/report and automatic ready transition still need this live proof.

## 11. Human-merge, then independently verify recovery

Only after step 10 passes, human-review and merge the fix PR. Watch its new main
production CD through successful deployment **and smoke**.

Refresh the browser: health/catalog must succeed, and a distinct new synthetic
order must return a real confirmed receipt. Record/read that request ID
independently. Do not count an old receipt or an agent's success claim.
Inspect the effective NSG: the narrow allow precedes the retained deny.

Wait for the original scenario dependency alert to resolve; its evaluation
window can lag working requests. Match the exact rule/incident, not an unrelated
Smart Detector alert. Verify the resolved record and its UTC timestamp. An
empty filtered alert query is not proof of resolution.

**Completion evidence:** healthy start; human fault merge; actual disruption;
SRE evidence and one issue; one assignment; exact-head pre-merge test smoke;
human fix merge; successful production CD/smoke; new persisted browser order;
original dependency alert resolved. Keep detailed receipts privately and
summarize the result in the existing [setup item #81](https://github.com/rutgerpels/azure-agentic-ops/issues/81).
Do not mark acceptance complete if any link was skipped.

## 12. Reset source for next time and tear down the owned Azure generation

While this generation is still provisioned, `Reset` can open a baseline PR:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Reset @common
```

If needed, human-review and merge it, then wait for its healthy CD to finish.
Reset does not allow another fault in this generation. For the next rehearsal,
retire this environment and use a new name/generation.

Before Down, settle SRE threads/cards, all deployments, Copilot tasks and any
unknown operations. Do not leave executable old test-deployment approvals for
a future identity generation. Record the two managed environment infrastructure
group names and the SRE identity's subscription-level monitoring assignment
privately before the identities disappear:

```powershell
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$managedGroups = @()
foreach ($stage in @('prod', 'test')) {
    $managedGroup = az containerapp env show --subscription $subscriptionId `
        --resource-group $state.resourceGroups[$stage] --name "cae-ofg-$stage" `
        --query properties.infrastructureResourceGroup --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $managedGroup) { throw "Could not inventory $stage managed infrastructure." }
    $managedGroups += $managedGroup
}
$srePrincipalId = Get-OrderFlowGitOpsOutput $state 'sre' 'srePrincipalId'
$roles = az role assignment list --subscription $subscriptionId `
    --assignee-object-id $srePrincipalId --all --include-inherited --output json |
    ConvertFrom-Json -AsHashtable
if ($LASTEXITCODE -ne 0) { throw 'Could not inventory SRE roles before teardown.' }
$scope = "/subscriptions/$subscriptionId"
$monitoringDefinition = "$scope/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
$monitoringRoles = @($roles | Where-Object {
    $_.principalId -ieq $srePrincipalId -and $_.scope -ieq $scope -and
    $_.roleDefinitionId -ieq $monitoringDefinition
})
$cleanupPath = Join-Path (Split-Path $statePath -Parent) 'cleanup-inventory.json'
@{ groups = @($state.resourceGroups.Values) + $managedGroups
   srePrincipalId = $srePrincipalId; monitoringRoles = $monitoringRoles } |
    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cleanupPath

.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Down @common
```

Down deletes the owned SRE Agent first while its identity still exists, then
prod/test groups, then shared. It observes absence rather than replaying
deletions. Keep `.azure\orderflow-gitops\<environment>\` even after removal.

Verify the three owned groups **and both provider-managed groups** are absent.
The group-scoped Down action does not remove the platform's subscription-level
Monitoring Contributor assignment. The authorized operator can remove only
the recorded, exactly matched assignment after verifying group absence:

```powershell
$cleanup = Get-Content -LiteralPath $cleanupPath -Raw | ConvertFrom-Json -AsHashtable
foreach ($group in $cleanup.groups) {
    $exists = Invoke-OrderFlowGitOpsAzure $state @('group', 'exists', '--name', $group)
    if ($exists) { throw "Group still exists: $group. Observe its original deletion first." }
}
$remaining = @(Invoke-OrderFlowGitOpsAzure $state @(
    'role', 'assignment', 'list', '--assignee-object-id', $cleanup.srePrincipalId,
    '--all', '--include-inherited'
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
    'role', 'assignment', 'list', '--assignee-object-id', $cleanup.srePrincipalId,
    '--all', '--include-inherited'
))
if ($remaining.Count) { throw 'Role assignments remain. Inspect scope/ownership; do not broadly delete them.' }
```

Inspect the IDs privately before authorizing removal. If a role-delete command
times out, stop and list the exact assignment to observe its outcome, never
blindly rerun deletion. Do not remove unrelated/inherited roles or search-and-
delete all orphan identities. Keep the inventory and final absence evidence.

For an overnight Azure-only reset, retain GitHub secrets/settings and still-valid
PATs as requested; refresh identity variables and the generation on next setup.
Do not delete GitHub environments or revoke retained tokens as a side effect.
If retiring the integration permanently instead, use the explicit credential
retirement steps in [PAT setup](github-pat-setup.md#6-rotation-migration-and-cleanup).
Pause CD before any further scenario source merge while Azure is absent.

## Troubleshooting checkpoints

| Symptom | Safe response |
| --- | --- |
| Up refuses local baseline or Ready refuses main baseline | Complete the human-reviewed one-file baseline PR; do not edit the baseline or bypass admission. |
| ConfigureSre reports a tool-profile mismatch | Use the new connector's actual three MCP names and schemas, not an example prefix or native OAuth connector. |
| Unexpected SRE role/scope | Inspect it. Only readers and the exact platform monitoring exception are accepted; never add Contributor/Network Contributor to repair setup. |
| Native issue-write approval fails before its card | Automatic publication is selected during settled configuration for a fresh generation. Never switch policy and retry a pending/unknown write. |
| OIDC login mismatch | Compare the actual token subject with the exact existing FIC; do not grant PR refs, use wildcards or add a client secret. |
| Gate green, deployment `action_required` | Open the separate test-deployment run and complete its human workflow approval. Do not merge yet. |
| Deployment skipped or no report | Inspect resolve notices, current PR head/open state, eligibility, main-only environment and image availability. |
| Missing image in test deployment | Healthy main CD must publish the image first. Never build/run untrusted PR application code with Azure credentials. |
| Failed run has no jobs/logs | Inspect the run's check/approval details in GitHub; do not invent a failed deployment or replay a closed PR's run. |
| SRE publication/assignment/order outcome unknown | Observe the original request, issue, task or receipt. Never replay it because the expected result is not visible yet. |
| Down stops or times out | Preserve ownership and observe Status/the recorded deletion. Never delete the shared identity first or broadly delete similarly named resources. |
