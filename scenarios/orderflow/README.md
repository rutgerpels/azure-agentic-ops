# OrderFlow: the show must go on

**A concert merch shop. An urgent security change. A broken customer journey.
Two agents, with a human in control.**

Fans of the fictional band **The Static** choose a tour shirt, poster or tote
and get a collection pass. An overly broad network-hardening change leaves the
storefront online but cuts off its order database. The audience sees ordering
stop, SRE investigate, a human hand the issue to Copilot, and a tested PR restore
the ability to order.

All merchandise, prices and collection arrangements are synthetic. No payment,
inventory reservation or physical pickup takes place. Catalog reads and orders
use a real private Cosmos DB dependency; failures and stored confirmations are
not scripted UI states. **An unknown order is looked up, never replayed.**

## Choose your recovery path

| Option | What the audience sees | Guide |
| --- | --- | --- |
| **2. GitOps (this A-Z walkthrough)** | Human security PR merge → outage → SRE issue → **human assigns Copilot** → tested fix PR → human merge → recovery | Continue below |
| **1. Direct repair** | Presenter changes an NSG; SRE requests native human approval before restoring its narrowly scoped rule | [Option 1 deployment and demo](docs/direct-repair.md) |

Both use the merch app but have independent resources, identities and ownership
state. Do not mix their lifecycle commands. OrderFlow adapts upstream
[Scenario C: Compliance Drift](docs/upstream.md); Retailx is a separate demo.

## Your route through the demo

| Phase | Do this | Move on only when |
| --- | --- | --- |
| Prepare | [1. Tools](#1-tools-and-access), [2. Source](#2-prepare-reviewed-source-and-a-healthy-baseline), [3. Deploy](#3-deploy-a-fresh-healthy-environment) | Test and production smoke pass |
| Connect | [4. GitHub](#4-configure-github-and-verify-oidc), [5. SRE](#5-connect-sre-to-github-issues), [6. Ready](#6-verify-the-healthy-start) | Exact issue tools verified, automatic assignment off, a real order confirmed |
| Present | [7. Security change](#7-present-the-urgent-security-change), [8. Investigation](#8-let-sre-investigate-and-publish-the-issue), [9. Human handoff](#9-pause-review-and-manually-assign-copilot) | Audience has seen the issue before an agent starts |
| Recover | [10. Test](#10-prove-the-fix-in-test), [11. Release](#11-human-merge-and-prove-recovery) | Exact-head test passes, fresh production order succeeds, original alert resolves |
| Retire | [12. Cleanup](#12-reset-and-clean-up) | Owned resource absence verified; ownership receipts retained |

Prepare well before presenting: infrastructure, identity propagation, alerts and
agent execution have variable latency. No fixed ten-minute recovery is promised.
Keep tabs open for the shop, PRs, Issues, Actions, SRE and the production NSG.

### Who approves what?

| Decision | Owner |
| --- | --- |
| Deploy the demo / merge the staged security change | Presenter |
| Bounded GitHub issue reads | Native SRE read cards |
| Publish the incident issue | Automatic only when explicitly selected below; Native is the default |
| **Start Copilot on the issue** | **Presenter, manually in GitHub** |
| Run workflows on Copilot code | Human: retain **Require approval for workflow runs** |
| Release the tested fix to production | Human PR review and merge |

Issue publication is not assignment and is not production repair. No assignment
PAT or automatic handoff workflow is required. Do not enable another automation
that assigns agents on the incident label.

## 1. Tools and access

Use the repository root in an owning checkout, PowerShell 7.2+, Python 3.11+,
Azure CLI with Bicep, Git and GitHub CLI. You need an approved Azure subscription and permission
to provision the demo and its scoped identities, repository administration for
setup, and Copilot cloud-agent access for the presenter. Use synthetic data only.

```powershell
$ErrorActionPreference = 'Stop'
$repo = 'rutgerpels/azure-agentic-ops'
git --version
if ($LASTEXITCODE -ne 0) { throw 'Git unavailable.' }
$python = if (Get-Command python -CommandType Application -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
& $python -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
if ($LASTEXITCODE -ne 0) { throw 'Restore Python 3.11+ on PATH before provisioning.' }
& $python .\scenarios\orderflow\gitops\tools\image_tag.py
if ($LASTEXITCODE -ne 0) { throw 'Image inputs could not be hashed; stop before provisioning.' }
gh auth status
if ($LASTEXITCODE -ne 0) { throw 'Sign in using gh auth login.' }
az account show --query '{subscription:id,tenant:tenantId}' -o table
if ($LASTEXITCODE -ne 0) { throw 'Sign in using az login.' }
az bicep version
if ($LASTEXITCODE -ne 0) { throw 'Restore Bicep tooling before continuing.' }
```

Keep the same terminal for later blocks. Do not print tokens or ownership files
publicly. `$ErrorActionPreference` alone does not catch native CLI failures:
check exit codes as shown. The Python check uses the lifecycle's interpreter
selection (`python`, otherwise `python3`) and hashes local image inputs without
contacting Azure. It does not need the application's Python dependencies.

## 2. Prepare reviewed source and a healthy baseline

Keep main protected and work on a dedicated feature branch/session based on
reviewed main. Source/docs merges under OrderFlow trigger production CD, so pause
CD during preparatory changes when the target is absent or not ready. This does
not remove workflow approval or PR review policies.

```powershell
gh workflow disable orderflow-gitops-cd.yml --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Could not pause production CD.' }
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body false
if ($LASTEXITCODE -ne 0) { throw 'Could not disable legacy automatic assignment.' }
gh run list --repo $repo --limit 15
```

Settle already admitted deployments, SRE actions and agent tasks; a disabled
switch does not cancel them. Do not rerun old approvals against new identities.
The source removes `orderflow-gitops-handoff.yml`; retain the false variable
during migration so older main revisions cannot auto-assign.

Merge the reviewed demo source before provisioning. Compare runtime rules with
the immutable baseline. A prior recovery can be healthy while still containing
the deny plus a narrow allow; that is **not** the required fresh baseline.

```powershell
git --no-pager diff --no-index -- `
    scenarios/orderflow/gitops/deploy/baseline/network-rules.json `
    scenarios/orderflow/gitops/deploy/network-rules.json
```

Exit 1 here means the files differ. If they differ, on your feature branch copy
the baseline to the runtime file, review that one-file diff, commit/push and open
a reset PR:

```powershell
Copy-Item .\scenarios\orderflow\gitops\deploy\baseline\network-rules.json `
    .\scenarios\orderflow\gitops\deploy\network-rules.json
git --no-pager diff -- scenarios/orderflow/gitops/deploy/network-rules.json
git add -- scenarios/orderflow/gitops/deploy/network-rules.json
if ($LASTEXITCODE -ne 0) { throw 'Staging failed.' }
git commit -m 'fix(orderflow): restore healthy rehearsal baseline'
if ($LASTEXITCODE -ne 0) { throw 'Commit failed.' }
git push -u origin HEAD
if ($LASTEXITCODE -ne 0) { throw 'Inspect push outcome before retrying.' }
gh pr create --repo $repo --base main --title 'Restore OrderFlow rehearsal baseline' `
    --body 'Restore only the runtime rules from the healthy baseline. CD is paused during preparation. Human review and merge required.'
if ($LASTEXITCODE -ne 0) { throw 'Inspect existing PRs before retrying.' }
```

Human-review and merge; never edit the baseline itself. Then use a clean
dedicated feature session based on that reviewed main. Do not discard dirty work
or move/delete ignored ownership to make a check pass.

## 3. Deploy a fresh healthy environment

```powershell
git fetch origin main
if ($LASTEXITCODE -ne 0) { throw 'Fetch failed.' }
git status --short
git diff --quiet HEAD origin/main -- scenarios/orderflow .github/workflows
if ($LASTEXITCODE -ne 0) { throw 'Use reviewed main source before provisioning.' }
$subscriptionId = Read-Host 'Approved Azure subscription ID'
$environmentName = Read-Host 'Unused environment name (3-12 lowercase letters/digits, starting with a letter)'
$common = @{ SubscriptionId = $subscriptionId; EnvironmentName = $environmentName }
$statePath = Join-Path (Get-Location) ".azure\orderflow-gitops\$environmentName\ownership.json"
if (Test-Path -LiteralPath $statePath) { throw 'Already owned: choose a fresh name, never overwrite state.' }
$adminObjectId = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the Azure operator.' }
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action Up @common -Location swedencentral -SreLocation swedencentral `
    -AdminObjectId $adminObjectId -GitHubRepository $repo
```

Review the confirmation. The region is an example used in earlier rehearsals,
not a capacity guarantee. Up provisions shared resources, independent test/prod
networks, private Cosmos endpoints, public storefronts and SRE. It stops healthy:
both in-network smoke jobs must succeed. It does not inject a fault.

```powershell
Import-Module .\scenarios\orderflow\gitops\scripts\OrderFlowGitOps.psm1 -Force
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
if ($state.phase -cne 'provisioned' -or $state.pendingOperation -or @($state.faults).Count) {
    throw 'Expected a fresh, provisioned, unused generation.'
}
$portal = Get-OrderFlowGitOpsOutput $state 'prod' 'portalUrl'
$portal
```

**Checkpoint:** both smoke jobs succeeded and the store URL loads. On timeout
run `-Action Status @common` to observe the original operation, not a second Up.
Resume only if Status proves the earlier stage settled and permits it.

The merch catalog uses new document IDs and does not overwrite old equipment
documents. Historical receipts remain readable. Use a fresh environment for a
new rehearsal; do not treat an app upgrade as permission to rearm an old fault.

## 4. Configure GitHub and verify OIDC

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action ConfigureGitHub @common
```

Review the environment variables and policies in **Settings > Environments**:
`orderflow-test` and `orderflow-prod` must allow only **main**, with distinct
deployment identities. The privileged test workflow uses trusted main and
overlays only the proposed rules JSON; never grant PR branches Azure identity.
No Azure client secret is needed.

Keep default Actions token permissions read-only, human PR review/merge, and
**Settings > Copilot > Cloud agent > Require approval for workflow runs**.
Check the four `orderflow-gitops-{ci,test,test-deploy,cd}.yml` files are on main.
The deployment-folder test workflows are not required checks for unrelated PRs.
See the exact [settings and permission boundaries](gitops/docs/github-settings.md).

**Federation checkpoint:** the templates use name-based subjects. This repository
previously emitted immutable-ID-bound subjects. For this same repository/claim
configuration, update only the two new credentials to that verified format:

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
    if ($LASTEXITCODE -ne 0) { throw "Inspect $stage federation; stop." }
    $actual = az identity federated-credential show --subscription $subscriptionId `
        --resource-group $state.resourceGroups.shared `
        --identity-name "id-ofg-deploy-$stage" --name "github-orderflow-$stage" `
        --query subject --output tsv
    if ($LASTEXITCODE -ne 0 -or $actual -cne $subject) { throw "$stage trust not verified." }
}
```

For another repository or changed claim template, use its actual documented
subject, not this example. Keep the GitHub issuer and `api://AzureADTokenExchange`
audience. Do not broaden trust to solve an OIDC mismatch. A shared-template
redeployment can restore defaults; reverify afterward.

## 5. Connect SRE to GitHub issues

This walkthrough selects **PAT** for simpler demo setup. The stronger,
default **GitHub App publisher** is a supported alternative with durable
publication reservations: follow [App setup](gitops/docs/github-app-setup.md)
instead for this step. Do not leave both publishing paths connected.

Create a short-lived fine-grained PAT restricted to this repository with only
**Issues read/write and Metadata read**. Store it privately. In the new Running
SRE Agent, open **Builder > Connectors > Add connector > MCP > GitHub MCP**.
Use its protected credential field, not a shell argument. Do not select the
native GitHub OAuth/Code Repository connector.

Select exactly `list_issues`, `issue_read`, `issue_write`; record their actual
prefixed names. No assignment, PR, code or shell tools.

```powershell
$sreIssueTools = @(
    '<actual-prefix>_list_issues'
    '<actual-prefix>_issue_read'
    '<actual-prefix>_issue_write'
)
if ($sreIssueTools -match '<') { throw 'Replace placeholders with the actual connector tools.' }
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action ConfigureSre @common -SreAuthMode PAT `
    -SreIssueTools $sreIssueTools -SreIssueWriteApproval Automatic
```

**Checkpoint:** SRE configured and verified. Only exact issue publication is
automatically allowed; reads still ask, Azure writes/shells remain denied.
The configured handoff is **manual**. Omit `Automatic` to retain the default
native issue-write approval card. A previous native-card platform failure is
not a reason to grant broader Azure permissions.

The PAT tool can update as well as create issues; instructions prohibit updates
and require complete-body deduplication and one first publication attempt.
Never replay an unknown write or start a parallel investigation. See
[PAT setup and constraints](gitops/docs/github-pat-setup.md).

In one read-only connection-check thread, ask SRE to list open and closed issues,
paginate, and read complete bodies using `issue_read` where listings are
truncated. Approve bounded read cards. Verify actual tool output, not merely
“connected.” Do not create a test incident. Settle this thread before Ready.

## 6. Verify the healthy start

Do not enable legacy automatic assignment. No assignment token or identity pins
are needed. Check you can see Copilot in GitHub's issue-assignment interface
without submitting a test assignment.

```powershell
gh workflow enable orderflow-gitops-cd.yml --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Could not resume CD.' }
gh workflow run orderflow-gitops-cd.yml --repo $repo --ref main
if ($LASTEXITCODE -ne 0) { throw 'Inspect Actions for the admitted run; do not redispatch blindly.' }
gh run list --repo $repo --workflow orderflow-gitops-cd.yml --limit 5
```

Wait for this new healthy CD run to pass deployment **and** smoke, then:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Ready @common
```

**Checkpoint:** fresh test/prod smoke pass, `sreVerified=True`, healthy baseline,
no active dependency alert or earlier fault. A CI/CD-only warning is not full
SRE readiness. Ready cannot prove the presenter's Copilot entitlement.

Open the store, choose the tour tee and **Confirm demo order**. Show the
“You're on the list” collection pass and privately record its request ID.
Expand **Behind the show** to distinguish storefront-process health from a
successful order-service/database read.

Presenter line: *“I'm buying a souvenir before leaving the show. The collection
pass is backed by an actual saved order—not a green animation.”*

## 7. Present the urgent security change

Presenter line: *“Before the next sales window, security wants us to restrict
lateral access to the customer-order data tier. Let's release that change.”*

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Fault @common
```

The PR is titled **Security hardening: restrict lateral access to OrderFlow
customer-order data**. Review its one-file diff and required CI, then
**human-merge**. It adds `DenyVnetToDataTier` at priority 300. Fault never merges.

**Presenter disclosure:** this is a staged regression in a fictional urgent
security request, not a real vulnerability. The broad deny deliberately omits
the app's private Cosmos exception. Keep the demo label and rehearsal note:
the narrative should feel realistic, not conceal the risk from reviewers.

CD applies the deny, then fails its in-network smoke. This is expected only if
deployment succeeded first. An OIDC/build/template failure is not the incident.
The smoke is a release check, not the catalyst: failed real dependency probes
produce telemetry and the Monitor alert.

Show **“Merch ordering is paused”**, stale merchandise and disabled checkout
while the page remains reachable. If an order was in flight, show its unknown
outcome and receipt lookup; never click-submit it again.

## 8. Let SRE investigate and publish the issue

Wait for the exact dependency alert; evaluation/ingestion can take minutes.
SRE correlates the effective NSG, Activity Log and failed dependency reads.
Approve only bounded read cards. For query errors, use
[SRE troubleshooting](gitops/docs/operations.md#alert-lookup-troubleshooting);
a misleading OBO prompt is not proof of missing RBAC.

If SRE asks whether this is the first publication, reconcile all earlier
threads/cards, writes and full issue bodies before confirming. With selected
Automatic publication there is no issue-write card. SRE creates one
`orderflow-incident` issue containing evidence, root cause, a rules-only proposal,
validation plan and rollback. It must not assign or mention Copilot.

**Checkpoint: the issue exists and no agent has started.** Pause here so the
audience can read the diagnosis and suggested change. If an agent starts
immediately, stop and inspect legacy handoff runs or other repository automations.

## 9. Pause, review and manually assign Copilot

Presenter line: *“SRE has proposed a fix, but it doesn't choose what enters our
development backlog. I review this evidence and now delegate the change.”*

1. Open the incident issue. Confirm it belongs to this generation, review the
   evidence and proposal, and check its assignees and existing Copilot sessions.
   Never start a second task after an uncertain earlier assignment.
2. Use GitHub's **Assign to Copilot** action or **Assignees → Copilot**. Choose
   this repository and **main** if prompted. UI labels vary; see
   [GitHub's issue-assignment instructions](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-github).
3. If an instructions field is offered, provide the following scope (also
   enforced by the scenario's `AGENTS.md`). Submit **once** and observe the
   linked session/assignee and resulting draft PR.

```text
Analyze this incident and SRE's proposed fix. Follow
scenarios/orderflow/gitops/AGENTS.md. Change only
scenarios/orderflow/gitops/deploy/network-rules.json.
Prefer a narrow fix-forward that keeps data-tier segmentation.
Run offline checks and open a draft PR targeting main, referencing this issue.
Do not deploy Azure, mark ready, approve or merge. The separate test workflow
must prove the exact PR head before a human releases it.
```

No separate assignment PAT or Actions secret is needed for this UI action.
Automatic **issue publication** remains independent of this manual handoff.

## 10. Prove the fix in test

Inspect Copilot's draft PR. Only the runtime rules file may change, normally
adding priority-200 TCP/443 `AllowAppsToCosmosPrivateEndpoint` to `DataSubnet`
while retaining the priority-300 deny.

1. Approve the Copilot PR's workflows when prompted, after reviewing its diff.
2. Check **Actions > OrderFlow GitOps test deployment** separately; approve that
   run too if requested. The unprivileged test gate is not the deployment.
3. Require the current head SHA's test deployment, in-network smoke
   **Succeeded**, and report link. The report marks the PR ready only after
   success. A changed head needs new evidence.

```powershell
gh run list --repo $repo --workflow orderflow-gitops-test.yml --limit 5
gh run list --repo $repo --workflow orderflow-gitops-test-deploy.yml --limit 5
```

Stop on skipped, cancelled, failed, `action_required` or missing evidence.
Do not manually mark ready or merge based only on green offline CI.

## 11. Human-merge and prove recovery

Human-review and merge only after the exact-head test passes. Watch new
production CD through successful deployment **and smoke**. Refresh the store's
collection, reconcile any unknown order, then place a **distinct new order**.
An old collection pass or SRE's success claim is not recovery evidence.

Independently read the new pass:

```powershell
Invoke-RestMethod -Uri "$($portal.TrimEnd('/'))/api/health" -TimeoutSec 20
Invoke-RestMethod -Uri "$($portal.TrimEnd('/'))/api/products" -TimeoutSec 20
$recoveryRequestId = Read-Host 'Request ID of the new recovery order'
if (-not ($recoveryRequestId -as [guid])) { throw 'Expected an order UUID.' }
$receipt = Invoke-RestMethod `
    -Uri "$($portal.TrimEnd('/'))/api/orders/$recoveryRequestId" -TimeoutSec 20
if ($receipt.request_id -cne $recoveryRequestId -or
    $receipt.status -cne 'confirmed' -or $receipt.synthetic -ne $true) {
    throw 'New recovery receipt not confirmed.'
}
```

Verify the narrow NSG allow precedes the retained deny, and wait for the
**original** dependency alert to resolve. Its window can lag recovered orders.
An empty filtered query is not proof of resolution.

Presenter line: *“We've preserved the security boundary, tested the exception,
and released it through human review. Fans can order again.”*

Record healthy start, human change merge, visible outage, SRE issue, deliberate
assignment, exact-head test, human fix merge, production smoke, new saved order
and resolved original alert. Keep raw/live identifiers private. User-reported
demo completion is valuable feedback, not a substitute for missing receipts.

## 12. Reset and clean up

If desired while provisioned, `Reset` opens a human-reviewed baseline PR:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Reset @common
```

Wait for its healthy CD after human merge. Reset does **not** rearm this
generation. The next fault rehearsal requires a fresh owned environment.

Settle SRE cards/threads, Copilot tasks, deployment approvals and unknown
operations. Pause CD before removing its targets; keep automatic assignment off.
Inventory the two provider-managed infrastructure groups and the exact
subscription-level SRE monitoring grant before the identities disappear.
Then run Down and verify absence, using the complete
[owned-cleanup commands](gitops/docs/cleanup.md).

Down deletes SRE before its identity, then prod/test, then shared. Group deletion
does not remove the platform subscription-level role assignment. Remove only
the recorded, exactly matched grant after verifying group absence; never sweep
unrelated roles or groups. Retain `.azure\orderflow-gitops\<environment>\` and
private receipts after teardown.

GitHub environments and valid issue credentials can remain for another
rehearsal; refresh their Azure-bound values next time. Legacy assignment secrets
and pins are unused: after reconciling old runs, retire that dedicated token
and secret if no other integration uses them. Do not revoke the issue-only PAT.

## Quick troubleshooting and supporting material

| Symptom | Safe next action |
| --- | --- |
| Up/configuration times out | Observe the original operation with Status; retain ownership and journal |
| Healthy CD fails login | Compare exact environment subject/issuer/audience; do not trust PR refs |
| Fault CD fails smoke after deploy | Expected disruption; do not rerun/rollback to make it green |
| SRE asks for permission on a wrong alert lookup | Inspect actual error/type; cancel incorrect OBO request, continue in the same incident |
| Issue has no agent | Expected pause: review, then manually assign |
| Assignment outcome is unclear | Inspect issue/session before any second assignment |
| Test PR looks green, deployment missing | Check the separate deployment run and approval; do not merge |
| Service healthy but ordering disabled | Refresh stale collection; reconcile an unknown order first |
| Ready rejects earlier fault | Fresh generation required; Reset is not rearming |

- [Technical architecture and boundaries](gitops/README.md)
- [Short presenter run sheet](gitops/docs/demo.md)
- [Lifecycle reference, costs and verification history](gitops/docs/operations.md)
- [GitHub settings](gitops/docs/github-settings.md)
- [PAT setup](gitops/docs/github-pat-setup.md) / [App publisher alternative](gitops/docs/github-app-setup.md)
- [Option 1 operations](docs/operations.md) / [Option 1 presenter guide](docs/demo.md)

The test and production environments are always on. Container Apps, Cosmos,
logs, ACR and SRE remain billable until verified teardown; no automatic expiry
or budget enforcement exists.
