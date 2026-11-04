# OrderFlow option 2: detailed PAT owner setup

Follow this guide for **Option 2 (GitOps): remaining owner steps for the selected
PAT setup**. It configures the existing demo, not a new Azure deployment.
No GitHub App registration or custom publisher deployment is required for this
path. **The [GitHub App setup](github-app-setup.md) remains the implementation's
default and stronger isolation option**; explicitly select PAT as shown below.
Option 1 is unchanged.

The PAT implementation was merged in
[PR #87](https://github.com/rutgerpels/azure-agentic-ops/pull/87) on November 3,
2026. Use the merged scripts and workflows. Merging the implementation does
not configure tokens, the SRE connector or the repository's live settings.

The flow remains: healthy portal, human-merged fault PR, visible disruption,
SRE analysis and approved incident issue, automatic Actions assignment to
Copilot, tested fix PR, human merge and production recovery.

## Before you start

This walkthrough uses `demo3`, whose infrastructure was preserved during the
old-environment cleanup. Its SRE Agent was deliberately paused. Do not assume
it is running now, and do not redeploy it just to configure authentication.
For a different owned environment, change `$environmentName` below.

| Prerequisite | How to check |
| --- | --- |
| Repository administration access | You can open repository Settings and manage Actions environments, variables and secrets. |
| Authorized Azure operator | Your account can inspect the owned deployment and configure its SRE Agent; the connector requires an SRE Administrator or Standard User and a Running agent. |
| Copilot-enabled assignment user | The owner of the assignment PAT has repository access and Copilot cloud agent available. Token permissions do not grant that entitlement. |
| Local tooling | PowerShell 7.2 or later, Git, GitHub CLI and Azure CLI are available in the same terminal. |
| Existing ownership state | The original owning checkout contains `.azure\orderflow-gitops\demo3\ownership.json`. Another clone will not automatically have this ignored file. |
| Unused deployment generation | No previous fault was recorded for this generation. Reset does not make a consumed generation eligible again. |

Run all PowerShell blocks from the **repository root in the owning checkout**,
in the same terminal. Later blocks reuse `$state`, `$repo` and `$common`.
Do not run `Up`, `Fault`, `Reset`, `Down` or start an agent merely while reading
this guide. Those are separate, explicit operational decisions.

After each native `gh`, `git` or `az` command, check that it succeeded before
continuing. `$ErrorActionPreference = 'Stop'` alone does not turn every native
nonzero exit code into a PowerShell exception. Never proceed after a permission,
transport or unknown-outcome error.

### Which identity does what?

| Credential | Where you put it | Purpose | Never use it for |
| --- | --- | --- | --- |
| SRE issue PAT | SRE GitHub connector credential field | List/read issues and publish one supervised incident issue | Code, branches, PRs, Actions or Copilot assignment |
| Assignment PAT | Repository Actions secret `ORDERFLOW_COPILOT_ASSIGN_TOKEN` | Actions assigns Copilot after an eligible SRE issue | SRE connector authentication or Azure deployment |
| Azure deployment identities | Existing GitHub environment variables and OIDC federation | Deploy the reviewed rules to test/prod | GitHub issue publishing |
| Your local Azure/GitHub sign-in | Azure CLI and GitHub CLI | Owner configuration actions | Proof that either of the two PATs works |

The same person can own both PATs, but **create two different tokens** with
different permissions. Keep their names and expiration dates in your private
credential manager so you do not paste the broader token into SRE.

### Setup sequence

| Step | Outcome before moving on |
| --- | --- |
| 1. Prepare ownership, GitHub environments and policies | Correct demo selected; handoff disabled; both deployment environments restricted to `main` |
| 2. Create SRE PAT | Repository-only Issues read/write token stored privately |
| 3. Resume when authorized and configure SRE | Connected PAT connector; exactly three issue tools; verified native Ask policy |
| 4. Configure assignment PAT and identity pins | Repository secret present; explicit PAT mode; correct user IDs and generation |
| 5. Verify reads and rehearse | Read-only connector proof, successful Ready, then separately approved fault/fix flow |
| 6. Rotate or retire | Uncertain operations settled; credentials and owned resources retired safely |

## What you skip, and what you give up

No App ID, installation ID, PEM key, publisher vault/storage, image build or
`ConfigurePublisher` action is needed. The built-in GitHub connector publishes
as the **PAT owner (a User), not an App bot**.

This is a supervised quick-demo alternative, not equivalent to the App publisher:

- The issue-only PAT is repository-scoped but can create **and update** issues.
  Generic `issue_write` is not a server-enforced create-only tool. Native Ask
  approval and inspecting arguments are mandatory; never approve all future calls.
- The connector has no scenario-owned durable publication reservation. Its
  internal retry behaviour is not verified. A marker and complete issue listing
  help find prior issues, but do not prevent concurrent or uncertain creates.
  Use one investigation thread, approve at most one create per generation and
  stop after any unknown outcome. Never retry because an issue is not visible yet.
- PAT identity does not distinguish an SRE-created issue from a manually created
  issue by the same person. Any open issue by that pinned user with the exact
  incident label and generation marker can trigger Copilot. The marker is not a
  secret or an authentication mechanism.
- Actions retains its separate durable assignment intent: an unknown assignment
  is never automatically replayed for that issue. This does not deduplicate two
  distinct issues. Retain the App path if stronger publication guarantees matter.

Implemented/offline-tested is not live-verified. The tool names below came from
the presenter's `githubissuescon` catalog; confirm their argument schemas in
your tenant before approving writes. Do not broaden permissions if a connection
check expects code access: code access is not part of this demo identity.

## 1. Prepare the existing demo environment

### 1.1 Confirm tools and owner sign-in

```powershell
$PSVersionTable.PSVersion
git --version
gh --version
az version
gh auth status
az account show --query '{subscription:name,tenant:tenantId}' --output table
```

If sign-in is needed, use `gh auth login` and `az login` interactively.
Do not use `gh auth token` to print a credential. Existing `GH_TOKEN` or
`GITHUB_TOKEN` environment variables can override GitHub CLI's saved account;
if the reported identity is unexpected, resolve that locally before continuing.
Do not export either demo PAT as the general-purpose CLI token.

### 1.2 Load and inspect the original ownership state

```powershell
$environmentName = 'demo3'
$statePath = ".\.azure\orderflow-gitops\$environmentName\ownership.json"
if (-not (Test-Path -LiteralPath $statePath)) {
    throw 'Ownership state is missing. Return to the original owning checkout; do not create replacement state.'
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$repo = $state.gitHubRepository
$common = @{ EnvironmentName = $environmentName; SubscriptionId = $state.subscriptionId }
if ($repo -ne 'rutgerpels/azure-agentic-ops' -or $state.phase -ne 'provisioned') {
    throw 'Unexpected repository or deployment phase. Inspect the original ownership state before configuring.'
}
if ($state.pendingOperation) {
    throw 'A prior operation needs observation with Status before setup can continue.'
}
if (@($state.faults).Count -gt 0) {
    throw 'This generation already recorded a fault. Authentication changes and Reset do not rearm it.'
}
az account set --subscription $state.subscriptionId
if ($LASTEXITCODE -ne 0) { throw 'Could not select the owned subscription.' }
```

Do not print or upload the entire manifest. Its identifiers are private operator
state, not material for an issue or a public screenshot. A missing group or
agent is not an invitation to reconstruct state or adopt another deployment.

Check the installed source and existing deployment without replaying writes:

```powershell
git fetch origin main --quiet
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the current main branch.' }
git --no-pager diff origin/main -- scenarios/orderflow/gitops/scripts .github/workflows/orderflow-gitops-handoff.yml
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Status @common
```

The source comparison should show no unreviewed script/handoff differences.
Do not blindly pull or switch branches in a dirty owning worktree; preserve
local work and ownership files when updating to reviewed source.
`Status` can reconcile an existing journal by observation. It is not a fresh
health check or proof of the SRE Agent's power state. If it reports pending or
unavailable evidence, stop and resolve that before setup.

### 1.3 Disable handoff before changing either identity

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body false
if ($LASTEXITCODE -ne 0) { throw 'Could not disable Copilot handoff.' }
```

This prevents future eligible events from starting new assignments. It does
not cancel an already running workflow, Copilot task or SRE approval card.
Inspect Actions and any open incident issues, settle old threads/cards/tasks,
and disconnect the old App publisher or broad GitHub connector before switching.
Do not leave both write paths active.

### 1.4 Populate deployment environments and labels

The following command **changes GitHub configuration** using your owner login.
It creates/updates the two deployment environments, their variables, the `main`
branch policies and scenario labels. It does not create either PAT:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action ConfigureGitHub @common
```

This sets the existing deployment environments/variables and incident label.
Azure deployment still uses OIDC; PAT authentication does not replace it.
Expected output includes "GitHub environments, variables, branch policies and
labels configured." Check **Settings > Environments** for `orderflow-test` and
`orderflow-prod`, and compare their values to
[the deployment-variable table](github-settings.md#environments).

```powershell
gh variable list --repo $repo --env orderflow-test
gh variable list --repo $repo --env orderflow-prod
gh api "repos/$repo/environments/orderflow-test/deployment-branch-policies" --jq '.branch_policies[] | {name,type}'
gh api "repos/$repo/environments/orderflow-prod/deployment-branch-policies" --jq '.branch_policies[] | {name,type}'
```

For **both** environments, deployment branches/tags must be selected branches
with only the branch `main`. No tags, `copilot/*` or `refs/pull/*/merge` are
allowed. The script adds the required policy but **does not remove previously
configured extra policies**. An owner must review and remove those in Settings.
Do not assume a successful ConfigureGitHub call cleaned up old access.

Keep required reviewers and wait timers off for these two deployment
environments; the human PR review/merge is the production gate.
Inspect existing protection rules manually rather than assuming the script
removed them. This design does not use Option 1's `orderflow-publish` environment
or its optional self-hosted runner.

### 1.5 Check Actions, main protection and Copilot availability

In repository **Settings > Actions > General**, allow Actions and the pinned
actions used by the OrderFlow workflows. Keep the default Actions token
permissions read-only; workflows declare the individual permissions they need.
See [GitHub settings](github-settings.md) for the OIDC and test-deployment
boundaries.

Under **Settings > Rules > Rulesets** (or the existing branch-protection UI),
verify `main` requires a PR, blocks force pushes/deletion and requires
`orderflow-gitops-ci`. Human review/merge remains mandatory. In a single-author
repository, zero required approvals avoids demanding an impossible self-approval;
use independent review when available. Do not make the deployment-folder-only
test workflows required for every unrelated PR.

```powershell
gh workflow list --repo $repo --all
```

Verify these workflow files exist on `main` and are active:

| File | Display name |
| --- | --- |
| `orderflow-gitops-ci.yml` | OrderFlow GitOps CI |
| `orderflow-gitops-handoff.yml` | OrderFlow GitOps Copilot handoff |
| `orderflow-gitops-test.yml` | OrderFlow GitOps test gate |
| `orderflow-gitops-test-deploy.yml` | OrderFlow GitOps test deployment |
| `orderflow-gitops-cd.yml` | OrderFlow GitOps CD |

The test deployment is triggered by `workflow_run` from `main`; adding a workflow
only on a feature branch is insufficient. Verify the displayed names against
the current workflow files if GitHub changes their presentation.

As the **assignment-token owner**, check Copilot cloud agent is available for
this repository. You can inspect an existing non-incident issue's assignee
picker for Copilot without saving an assignment. This checks the signed-in user,
not a token stored in Actions. Do not create/assign a test incident to check
entitlement.

For workflow approval, open **Settings > Copilot > Cloud agent**, and keep
**Require approval for workflow runs** enabled. If that menu is absent, verify
repository administration access and the account/organization's Copilot policy.
Do not assume a missing toggle means the agent is enabled or that PAT scopes
will enable it. GitHub documents this menu and the PR's **Approve and run
workflows** button in
[Configuring settings for GitHub Copilot in the cloud](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/configuring-agent-settings).

## 2. Create the SRE issue-only PAT

Sign in to GitHub as the intended **issue publisher**, then open your personal
avatar menu, **Settings > Developer settings > Personal access tokens >
Fine-grained tokens > Generate new token**. This is personal Settings, not
the repository's Settings page.

Use a recognizable private token name such as `orderflow-sre-issues-demo3`.
Names do not control access; the following permissions do:

| Setting | Value |
| --- | --- |
| Resource owner | Owner of `rutgerpels/azure-agentic-ops` |
| Repository access | Only select repositories: `azure-agentic-ops` |
| Repository permission: Issues | Read and write |
| Repository permission: Metadata | Read-only (automatic) |
| All other permissions | No access |
| Expiration | Short-lived; enough for the planned rehearsal |

Select **Generate token**, copy it once into your credential manager, and record
which login created it. If GitHub requires resource-owner approval, wait until
the token is approved; a pending token is not ready for the connector.

Store it securely. Never put it in chat, Git, ownership JSON, a script argument
or a repository variable. **Do not grant Contents, Pull requests or Actions
permissions to this SRE token.** Do not substitute a classic broad `repo` token.

## 3. Connect SRE and select only the issue tools

### 3.1 Resume only the owned SRE Agent when you are ready

The connector setup requires a **Running** agent, as documented in
[Microsoft's connector setup](https://learn.microsoft.com/en-us/azure/sre-agent/setup-github-connector).
Open the Azure portal, select the subscription recorded in the manifest, then
the shared resource group in `$state.resourceGroups.shared`. Identify the owned
SRE Agent; its deployed resource name is not necessarily `demo3`.

If it is Stopped, deliberately use its supported start/resume action when you
want to begin configuration. If the portal offers no such control, use the
documented [SRE Agent API reference](https://learn.microsoft.com/en-us/azure/sre-agent/api-reference)
with separately authorized operator scope; do not redeploy as a substitute.
Wait for Running with successful provisioning before connecting.

Starting the agent is an Azure state change and can increase usage. It does not
change the already-running portal/API, and stopping SRE later does not eliminate
all infrastructure or always-on charges. This guide does not start it for you.

### 3.2 Add the GitHub MCP connector

In the owned agent, open **Builder > Connectors > Add connector**, select the
**MCP** tab and **GitHub MCP**. Older UI versions may call Builder
**Build + setup > Extensions**. Use the issue-only PAT in the connector's
protected credential field, never the assignment PAT.

This profile requires an **MCP** connector, not the **GitHub OAuth** connector
under Code Repository. The native OAuth/PAT connector exposes a different set
of operations and is not interchangeable with the three tools below.
An earlier version of this guide incorrectly directed users to that connector.

If configuring a generic remote MCP connector instead, GitHub documents the
Streamable-HTTP URL `https://api.githubcopilot.com/mcp/` with Bearer PAT
authentication. Use the wizard's protected authentication field; do not put
credentials in a URL or a checked-in configuration file. See
[SRE Agent connectors](https://sre.azure.com/docs/concepts/connectors) and the
[GitHub remote MCP server](https://github.com/github/github-mcp-server#remote-github-mcp-server).

Connect and select exactly the operations in step 3.3. If an existing MCP
connector already has that exact profile, reuse it rather than creating a
duplicate. Never change a connector while an incident tool call or approval
is pending.

### 3.3 Inspect the actual tools and schemas

From the connector's tool catalog, select only:

```text
githubissuescon_list_issues
githubissuescon_issue_read
githubissuescon_issue_write
```

Leave everything else unselected, especially `assign_copilot_to_issue`,
`create_pull_request_with_copilot`, file/branch/PR tools and comment tools.
`search_issues` is not used for deduplication: semantic results are not a
complete issue inventory.

Verify the selected schemas support:

- `list_issues`: owner, repo, perPage, after; omission of state includes open and
  closed issues; complete bodies and pagination information.
- `issue_read`: `method=get`, owner, repo, issue_number.
- `issue_write`: `method=create`, owner, repo, title, body, labels; assignees are
  optional and must be omitted.

If these differ, stop and adapt the reviewed profile, not the live arguments
by trial and error. Exact connector prefixes may differ; all three tools must
share the same prefix and exact operation names.

The `githubissuescon_` prefix above is only an example. Record the three
**actual full names** from your deployed connector in this PowerShell array,
replacing each placeholder before running step 3.4:

```powershell
$sreIssueTools = @(
    '<actual-connector-prefix>_list_issues'
    '<actual-connector-prefix>_issue_read'
    '<actual-connector-prefix>_issue_write'
)
```

**Stop point:** the connector status alone does not prove that the listed tools
accept these parameters, inventory both issue states or paginate completely.
If the schema is incompatible, retain handoff disabled and resolve it through
a reviewed profile change. Do not add Contents/PR permissions or switch to a
classic token to get past a connection check.

### 3.4 Apply the PAT-specific SRE configuration

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action ConfigureSre @common -SreAuthMode PAT `
    -SreIssueTools $sreIssueTools
```

This selects the PAT-specific issue procedure and native Ask policy. It never
takes the PAT as a parameter. Omission of `-SreAuthMode` still means `GitHubApp`.
Do not pass `-SreAssignTool`.

The script verifies those exact names against one deployed MCP connector,
binds them to the investigator's `mcpTools`, and keeps its native `tools`
limited to Azure reads. It rejects an example prefix that does not match the
deployed connector; do not bypass that check or broaden token permissions.

**Azure RBAC exception:** Reader-level Azure SRE Agent also preconfigures
subscription-level Monitoring Contributor and may restore it during approval.
It permits monitoring changes, so do not describe the identity as strictly
RBAC read-only. `ConfigureSre` and fresh checks accept only that built-in role
at the subscription recorded in ownership state, in addition to reader roles.
They still reject Contributor, Network Contributor and every other non-reader
role/scope. This check grants no roles; Azure write tools remain denied and
the NSG fix must go through the GitHub issue/PR path. See
[Microsoft's preconfigured roles](https://sre.azure.com/docs/concepts/permissions).
Do not repeatedly remove this documented default or use a blanket permission
exception to get past verification.

Expected output: **SRE Agent configured and verified**. The configured
investigator is `orderflow-gitops-investigator`, with a Review-mode response
plan `orderflow-gitops-response`. Inspect them in SRE's agent/response-plan
configuration; UI labels can vary.

The three GitHub tools belong to the native **Ask** policy. There are no
permission overrides that automatically allow writes. Azure repair, shells
and assignment tools remain outside this investigator's permitted path.
See [the PAT runbook](runbook-pat.md) for the instructions the script generates.

On a configuration timeout, run `Status` to observe the recorded operation
before deciding the next step. Do not clear the journal, grant broader roles
or blindly rerun ConfigureSre.

## 4. Configure the separate automatic assignment

### 4.1 Create the second token

Use a **second** short-lived fine-grained user PAT for Actions. Its owner needs
Copilot cloud agent availability and repository access. Restrict it to this
repository, with Metadata read and **Actions, Contents, Issues and Pull requests
read/write**, as required by GitHub's Copilot assignment API. These broader
permissions must never be given to the SRE connector.

Use the same personal token-creation page as step 2, signed in as the intended
assignment user. A distinct name such as `orderflow-copilot-handoff-demo3` helps
avoid mixing the tokens.

| Repository permission | Assignment PAT |
| --- | --- |
| Metadata | Read-only (automatic) |
| Actions | Read and write |
| Contents | Read and write |
| Issues | Read and write |
| Pull requests | Read and write |
| Repository access | Only `azure-agentic-ops` |
| All other permissions | No access |

These permissions come from
[GitHub's Copilot assignment API documentation](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-via-the-api).
GitHub App installation tokens and `GITHUB_TOKEN` are not substitutes.
Do not grant these broader scopes to the issue publisher.

### 4.2 Store it as a repository Actions secret

In **repository Settings > Secrets and variables > Actions > Secrets**, select
**New repository secret**. Set Name to `ORDERFLOW_COPILOT_ASSIGN_TOKEN` and paste
the **assignment** token into Secret.

Alternatively, in an interactive terminal, run:

```powershell
gh secret set ORDERFLOW_COPILOT_ASSIGN_TOKEN --repo $repo
if ($LASTEXITCODE -ne 0) { throw 'Could not store the assignment secret.' }
```

Paste into the hidden prompt, not into a `--body` argument. The command's
repository scope is intentional: do not add `--env`. The handoff job does not
reference `orderflow-test` or `orderflow-prod` and cannot read an environment-only
secret. Never store the assignment token under Variables.

```powershell
gh secret list --repo $repo
```

Expected: the secret name appears. GitHub does not let you retrieve its value.
Presence alone does not prove the pasted token's owner, permissions or expiry.
The interactive behavior is documented in
[GitHub CLI: gh secret set](https://cli.github.com/manual/gh_secret_set).

### 4.3 Pin the publisher, assignment user and deployment generation

Pin both identities (they can be the same person, but use distinct tokens):

```powershell
# Replace the example logins, never these values with tokens.
$sreLogin = '<issue-PAT-owner-login>'
$assignmentLogin = '<assignment-PAT-owner-login>'
if ($sreLogin.StartsWith('<') -or $assignmentLogin.StartsWith('<')) {
    throw 'Replace the two login placeholders with the actual PAT owners.'
}
$sreUserId = gh api "users/$sreLogin" --jq .id
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the issue publisher.' }
$assignmentUserId = gh api "users/$assignmentLogin" --jq .id
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the assignment user.' }
if ($sreUserId -notmatch '^[1-9][0-9]*$' -or $assignmentUserId -notmatch '^[1-9][0-9]*$') {
    throw 'Expected numeric GitHub user IDs, not App IDs or GraphQL node IDs.'
}

$handoffVariables = [ordered]@{
    ORDERFLOW_SRE_AUTH_MODE = 'PAT'
    ORDERFLOW_SRE_GITHUB_LOGIN = $sreLogin
    ORDERFLOW_SRE_GITHUB_USER_ID = $sreUserId
    ORDERFLOW_SRE_GENERATION = $state.ownerToken
    ORDERFLOW_HANDOFF_USER_ID = $assignmentUserId
}
foreach ($entry in $handoffVariables.GetEnumerator()) {
    gh variable set $entry.Key --repo $repo --body ([string]$entry.Value)
    if ($LASTEXITCODE -ne 0) { throw "Could not set $($entry.Key). Keep handoff disabled." }
}
```

Do not substitute `$state.ownerToken` with a newly generated UUID. It is the
current deployment's generation, not a PAT value or a marker you can change to
retry an earlier incident.

You can instead add these under **repository Settings > Secrets and variables >
Actions > Variables > New repository variable**. Copy the values derived above
locally, never into the public setup issue.

| Repository variable | Expected value |
| --- | --- |
| `ORDERFLOW_HANDOFF_FALLBACK` | Still `false` during setup; exactly lowercase `true` when enabled |
| `ORDERFLOW_SRE_AUTH_MODE` | Exactly `PAT` |
| `ORDERFLOW_SRE_GITHUB_LOGIN` | Actual issue-PAT owner's user login, not `<app-slug>[bot]` |
| `ORDERFLOW_SRE_GITHUB_USER_ID` | That issue publisher's numeric GitHub user ID |
| `ORDERFLOW_SRE_GENERATION` | Current `$state.ownerToken` |
| `ORDERFLOW_HANDOFF_USER_ID` | Numeric user ID of the assignment-PAT owner |

Inspect the saved names/values privately:

```powershell
gh variable list --repo $repo
```

The workflow checks the fresh issue's author login, numeric ID, User type,
incident label, open state, generation marker and existing assignees.
App mode continues to trust only the configured Bot login. Unknown modes fail
closed. The assignment token owner must match the pinned handoff user ID.

## 5. Verify reads, then enable and rehearse

### 5.1 Prove read-only connector access

Use the configured investigator in one SRE investigation thread. A suitable
connection-check prompt is:

```text
Use only the configured issue tools to list issues in rutgerpels/azure-agentic-ops.
Include open and closed issues and paginate completely. Read the returned issue
bodies. Do not create or update issues, assign anyone, or change code.
Report whether the inventory was complete; do not claim success after an error.
```

Inspect and approve only the native
**read** card. Verify both issue states, bodies and pagination without creating
a throwaway incident. No live write is needed for this connection check.

Expected: the operation names match the configured connector; the repository
arguments are correct; the result includes bodies and complete pagination.
An SRE narrative saying "connected" without a successful tool result is not
proof. This read checks the SRE PAT, not the assignment secret.

### 5.2 Enable the separate handoff and run Ready

**Approval boundary:** setting the following variable to `true` authorizes
Actions to assign Copilot automatically after an eligible incident issue is
published. It can also react to a subsequent label event on an existing eligible
issue. Inspect old issues/tasks first; merely changing the variable does not
dispatch a workflow or safely reconcile an older assignment.

Only after the read check succeeds, the identities are pinned and the reviewed
workflow is active on `main`:

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body true
if ($LASTEXITCODE -ne 0) { throw 'Could not enable Copilot handoff.' }
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Ready @common
```

Ready checks PAT handoff configuration without requiring a deployed publisher.
It also starts fresh smoke executions in test and prod, checks the baseline on
`origin/main`, checks that no fault was recorded/opened and no prod alert is
active, and re-verifies the SRE policy/response plan/Monitor intake. This is a
live health check, not just a configuration listing.

Expected: Ready succeeds with fresh smoke success in both stages and
`sreVerified=True`. A warning that ConfigureSre was not run covers only the
CI/CD path and is **not** success for this SRE-to-Copilot demo.
Ready cannot validate the connector token scope, expiry or Copilot entitlement.
If Ready fails, keep the fault unmerged. Disable handoff while correcting
identity/connector settings; do not weaken its checks.

### 5.3 Show healthy user experience, then inject the reviewed fault

Open the production portal URL from the existing deployment outputs:

```powershell
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$state.outputs.prod.portalUrl
```

Display that URL in a browser, submit a synthetic order and verify actual
success. Do not infer healthy orders solely from a deployment's Succeeded state.

When the presenter explicitly chooses to start the incident:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Fault @common
```

Fault opens a predefined PR; **it never merges it**. Inspect its diff and ensure
only `scenarios/orderflow/gitops/deploy/network-rules.json` changes. Review the
NSG deny and CI results, then human-merge the fault PR through GitHub.
CD applies it to production. The production smoke failure/CD failure is
expected evidence for this injected fault, not a reason to rerun deployment.
Submit a fresh synthetic order and show the real error while the portal remains
reachable. Keep request IDs for unknown outcomes; never replay a timed-out order.

### 5.4 Approve exactly one evidence-backed SRE incident issue

For SRE's one incident publication, inspect the native card for **method=create**,
the exact repository, `labels=["orderflow-incident"]`, no assignees and body line:

```text
<!-- orderflow-incident-key:<ownerToken from this generation> -->
```

The generated instructions substitute the real generation. **Do not approve
updates, another repository, assignment, or a second create.** If the first
write fails/times out, reconcile using GitHub reads and the previous approval
card; do not approve a retry in the same or another thread.

The card must propose analysis and a fix supported by the current alert/change,
not a claim that SRE already repaired Azure. In this option SRE uses Azure read
tools, accepts only the documented monitoring-role exception, and does not
repair the NSG or create a fix PR. The subsequent GitHub user author is the
issue PAT owner, not an App bot.

### 5.5 Follow assignment, test deployment and human release

The approved publication can immediately start Copilot through Actions without
a second SRE card. Keep **Require approval for workflow runs** on initially,
approve workflows on Copilot's PR when requested, observe test deployment/smoke,
and human-review/merge the fix before checking production recovery.

Open repository **Actions** and follow this chain:

| Stage | Expected evidence |
| --- | --- |
| OrderFlow GitOps Copilot handoff | Trusted User/label/generation accepted; one assignment attempt; Copilot appears as assignee |
| Copilot fix PR | Proposed change only in `deploy/network-rules.json`, with incident evidence and a fix-forward rule |
| OrderFlow GitOps test gate | Approved workflow run validates the exact rules-file-only PR scope |
| Test deployment | `main` workflow overlays only the proposed rules file, deploys test using OIDC and reports a fresh passing smoke result |
| Human review/merge | Presenter reviews the tested change and merges the fix, not the agent |
| OrderFlow GitOps CD | Production deploy and fresh smoke succeed; a new real order succeeds visibly |

The automated deployment/report is intended to mark a passing fix PR ready.
That behavior is not yet live-verified for Copilot PRs; if the report fails,
inspect the actual test result and report error. A ready badge or green CI alone
is not proof that the in-network test deployment passed.

Read-only CLI inspection is also available:

```powershell
gh run list --repo $repo --workflow orderflow-gitops-handoff.yml --limit 5
gh run list --repo $repo --workflow orderflow-gitops-test-deploy.yml --limit 5
gh run list --repo $repo --workflow orderflow-gitops-cd.yml --limit 5
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Status @common
```

Use `gh run view <run-id> --repo $repo --log-failed` for failed-step logs; replace
the placeholder with the actual run ID. Keep logs private if they contain live
identifiers. Do not use **Re-run jobs**, re-label an issue, delete the assignment
intent comment or manually assign Copilot to recover an unknown assignment.
See [GitHub CLI: gh run view](https://cli.github.com/manual/gh_run_view).

### Completion checklist

- [ ] Correct owned environment selected; no consumed fault generation or pending writes.
- [ ] Both GitHub deployment environments have the recorded variables and only `main` allowed.
- [ ] SRE is Running, PAT connector read works, and ConfigureSre verified the three-tool Ask profile.
- [ ] Assignment secret is repository-scoped; both user identity pins and the generation match.
- [ ] Handoff is enabled deliberately and Ready verifies the full SRE path plus fresh health.
- [ ] Human-merged fault causes a visible real request failure.
- [ ] One approved incident issue triggers one Copilot assignment and a rules-only fix PR.
- [ ] In-network test smoke passes before human merge; production smoke and a new order recover.

Record results privately and update the applicable acceptance items in
[#81](https://github.com/rutgerpels/azure-agentic-ops/issues/81) without including
IDs, credentials or raw receipts. Guide completion or implementation merge
alone does not satisfy live acceptance.

## Troubleshooting without bypassing the gates

| Symptom | Check and safe next action |
| --- | --- |
| Ownership file missing or a different repository/phase | Return to the original owning checkout. Do not fabricate a manifest or rerun Up against existing resources. |
| SRE portal/connector unavailable | Verify the owned agent is Running with successful provisioning and your SRE role. A Stopped agent is not a connector-authentication failure. |
| PAT connector disconnected or 401/403 | Check the issue token's owner, repository selection, expiry and approval status. Keep its scope Issues-only; resolve incompatibility instead of adding code/PR access. |
| ConfigureSre asks for App publisher tools | The explicit `-SreAuthMode PAT` flag was omitted or the actual connector prefix/schema differs. Verify the three names; do not add an assignment tool. |
| ConfigureSre refuses pending/unsafe configuration | Observe recorded operations with Status; settle old cards and inspect native policies/roles/hooks. Do not clear receipts or remove safety checks. |
| Ready demands publisher deployment | Local SRE state is still App mode. Complete the explicit PAT configuration after settling old operations, not ConfigurePublisher. |
| Ready says this generation already recorded a fault | It is deliberately single-use. Reset does not rearm it; a new owned deployment is a separate scope decision. |
| Copilot settings/picker entry absent | Verify the assignment user's entitlement, repository access and organization policy; admin visibility and PAT permissions are separate checks. |
| Handoff job skipped or issue deemed ineligible | Inspect exact `PAT`/`true` values, User login/ID, label, open state, standalone generation marker and existing assignees. Inspect existing tasks before any change that could emit a new event. |
| Assignment token owner changed | Check who created the secret's token. Disable handoff and reconcile earlier intents before deliberately changing owner pins. |
| Assignment request failed or timed out after intent | Read assignees, Copilot tasks and the existing intent comment. Do not rerun, remove the comment or issue a replacement assignment. |
| Copilot PR workflows awaiting approval | Human-inspect the diff and click Approve and run workflows on the PR. Keep the initial approval policy enabled. |
| Test deployment lacks variables or OIDC login fails | Compare environment variables with the original manifest and main-only branch policies/federation. Never add PR refs or Azure secrets as a workaround. |
| Fix PR green but no successful test-deploy smoke | Verify the workflow is active on main and inspect its run/report. Do not merge based only on offline CI or a ready badge. |

## 6. Rotation, migration and cleanup

Rotate each token independently for the same owner. If changing either owner,
disable the handoff and reconcile old SRE approval cards, assignment intents
and Copilot tasks before deliberately changing identity pins. Never change a pin
or remove a receipt to bypass an unknown outcome.

Reset restores baseline health but does not permit another fault in the same
generation. For another rehearsal, provision a fresh owned environment and
update the generation pin only after retiring the old one.

Disable handoff, settle actions, disconnect the PAT connector and revoke the
SRE token. Revoke the assignment token, remove its secret and the handoff
variables when retiring the demo. Use the existing owned `Down` lifecycle and
retain ownership/journals until cleanup is verified. If an App publisher was
previously provisioned, its resources remain owned and must also be cleaned up;
switching modes does not delete them.

To return to App mode, follow [App setup](github-app-setup.md), disconnect the
PAT connector, restore the App bot login, set `ORDERFLOW_SRE_AUTH_MODE=GitHubApp`,
remove the PAT author/generation variables and explicitly rerun ConfigureSre
with the two App tools. Do not retain both write paths.

## References

- [Microsoft: Set up GitHub connector (OAuth or PAT)](https://learn.microsoft.com/en-us/azure/sre-agent/setup-github-connector)
- [Microsoft: GitHub connector permissions and authentication](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
- [GitHub: Manage fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [GitHub: Assign Copilot via the API](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-via-the-api)
