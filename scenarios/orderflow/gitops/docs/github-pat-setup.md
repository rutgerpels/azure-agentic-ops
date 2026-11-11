# OrderFlow option 2: issue-only PAT setup

Start with the [OrderFlow A-Z README](../../README.md). This is the detailed
connector reference, not a second deployment procedure. **SRE publishes the
issue; a human reviews it and manually assigns Copilot.** No assignment PAT,
user-ID pins or automatic handoff workflow is required.

The [GitHub App publisher](github-app-setup.md) remains the default and stronger
isolation option. PAT is an explicit supervised demo alternative: it lacks a
durable publication reservation and the generic issue-write permission is not
server-enforced create-only.

## 1. Prepare ownership and the manual handoff

Use the original owning checkout after healthy Up, in the same terminal as
the README. `$statePath`, `$common` and `$repo` must refer to that environment.
Never fabricate state or use a retired generation.

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $repo --body false
if ($LASTEXITCODE -ne 0) { throw 'Could not disable legacy automatic assignment.' }
```

Settle previously admitted handoff runs, SRE requests and Copilot tasks. A false
switch does not cancel them. Do not use relabeling, deleted intent comments or a
second manual assignment to recover an unknown old task. The source retires
`orderflow-gitops-handoff.yml`; legacy secrets/pins are not used by the new path.

Keep both deployment environments main-only, OIDC, protected main and
**Require approval for workflow runs**. See [settings](github-settings.md).
The presenter needs repository access and Copilot cloud-agent entitlement;
verify its issue-assignee entry without submitting a test assignment.

## 2. Create the SRE issue-only PAT

As the intended issue publisher, open personal **Settings > Developer settings >
Personal access tokens > Fine-grained tokens > Generate new token**.

| Setting | Value |
| --- | --- |
| Resource owner | Owner of this demo repository |
| Repository access | Only this repository |
| Issues | Read and write |
| Metadata | Read-only |
| Every other permission | No access |
| Expiration | Short-lived, covering the planned rehearsal |

Store it in your credential manager. Wait for any required owner approval.
Never paste it into chat, Git, ownership JSON, CLI arguments or repository
variables. Do not grant Contents, Actions, Pull requests or assignment access.
Your local CLI sign-in is not evidence that the SRE token works.

## 3. Connect and configure the owned SRE Agent

The owned SRE Agent must be Running. In **Builder > Connectors > Add connector**,
choose **MCP > GitHub MCP**, not GitHub OAuth under Code Repository. Older UI
versions may use Build + setup > Extensions. Enter the PAT only in the protected
credential field. Reuse an existing exact-profile connector rather than adding
a duplicate; never change connectors during a pending call.

Select only these operations, using their actual common prefix:

| Operation | Required schema |
| --- | --- |
| `list_issues` | owner, repo, perPage, cursor pagination; inventory both open and closed issues |
| `issue_read` | method=get, owner, repo, issue_number; obtain complete body |
| `issue_write` | method=create, owner, repo, title, body, labels; omit assignees |

Listing body fields does not prove completeness: detect truncation and read
individual issues. If complete bodies or pagination cannot be obtained, stop;
never infer absence from semantic search or the first page.

```powershell
$sreIssueTools = @(
    '<actual-prefix>_list_issues'
    '<actual-prefix>_issue_read'
    '<actual-prefix>_issue_write'
)
if ($sreIssueTools -match '<') { throw 'Use the actual deployed tool names.' }
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action ConfigureSre @common -SreAuthMode PAT `
    -SreIssueTools $sreIssueTools -SreIssueWriteApproval Automatic
```

Omit `Automatic` to retain the default native issue-write card. Both modes
retain native read approvals and deny Azure writes, shells and assignment
tools. The generic `issue_write` can update issues as well as create them;
instructions prohibit updates, require deduplication and one first attempt.
Automatic publication does **not** start Copilot.

The script checks the exact deployed MCP profile, Review mode, existing role
boundary, settled threads and no thread overrides. Reader-level SRE may have
the platform's subscription-level Monitoring Contributor default; only the
documented exact scoped exception is accepted. Never add Contributor or Network
Contributor to fix a query or connector error.

Expected output: **SRE Agent configured and verified**. The configured
investigator is `orderflow-gitops-investigator`, with a Review-mode response
plan `orderflow-gitops-response`. Inspect them in SRE's agent/response-plan
configuration; UI labels can vary.

For old workflow-handoff state, reconfigure with the same exact issue tools and
publication policy after disabling automation and settling actions. The script
records `handoffMode=manual`; do not hand-edit ownership. A saved definition
update does not prove an existing conversation adopted it. No restart or
publication retry is authorized by a migration.

## 4. Prove reads, then return to the rehearsal

Ask the selected investigator in one connection-check thread:

```text
List open and closed issues in the configured repository using only the issue
tools. Paginate completely and inspect full bodies, using issue_read wherever
listing bodies are truncated. Do not create/update issues, mention or assign
Copilot, or change code. Report errors and any incomplete evidence.
```

Approve only bounded read cards, inspect actual tool results and settle the
thread. Do not create a throwaway incident. Return to
[README step 6](../../README.md#6-verify-the-healthy-start).

During the incident SRE must publish exactly one issue with no assignees and
the standalone generation marker from its generated runbook. Before confirming
first publication, reconcile any earlier approvals, unknown writes or parallel
investigations. Never retry because the issue is not yet visible.

When it exists, pause and review it, then use
[manual assignment](../../README.md#9-pause-review-and-manually-assign-copilot).
Keep workflow approvals, exact-head test deployment/smoke and human production
merge. A green offline check is not a successful test deployment.

## 5. Troubleshooting

| Symptom | Safe next action |
| --- | --- |
| MCP disconnected or 401/403 | Check token owner, selected repository, expiration and approval; retain issue-only scope |
| Wrong connector names | Use deployed prefixes/schemas, not example names or native OAuth operations |
| Ready rejects legacy handoff | Disable old automatic assignment, settle tasks and reconfigure SRE; do not edit state |
| Issue has no assignee | Expected human pause; review and deliberately assign |
| Copilot picker absent | Check the presenter's repository access and Copilot policy/entitlement, not PAT scope |
| Publication/assignment outcome unknown | Observe the original issue, approvals and task; do not retry |
| Test workflow awaits approval | Inspect and approve that run; do not merge yet |

## 6. Rotation, migration and cleanup

Rotate the issue token in its protected connector field only after settling
requests. Preserve publication receipts and the generation marker. The old
assignment token/secret and publisher/assignment identity pins are unused;
retire only the dedicated old credential after inspecting historical runs and
confirming no other integration depends on it. Do not reuse it for SRE.

For Azure-only retirement use [owned cleanup](cleanup.md). Retain GitHub settings
and still-valid issue credentials if rehearsing again; refresh new Azure-bound
variables. Permanent integration retirement additionally removes the connector
and revokes the issue PAT after all operations settle.

References: [SRE connector setup](https://learn.microsoft.com/en-us/azure/sre-agent/setup-github-connector),
[GitHub MCP server](https://github.com/github/github-mcp-server#remote-github-mcp-server),
[manual Copilot assignment](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-github).
