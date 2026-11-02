# Quick-demo PAT setup with automatic Copilot handoff

Use this alternative when you want to skip registering an App and deploying
the custom publisher. **The [GitHub App setup](github-app-setup.md) remains the
default and stronger isolation option.** Option 1 is unchanged.

The flow remains: healthy portal, human-merged fault PR, visible disruption,
SRE analysis and approved incident issue, automatic Actions assignment to
Copilot, tested fix PR, human merge and production recovery.

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

Use the updated scripts in the worktree that owns
`.azure/orderflow-gitops/demo3/ownership.json`. Merge the implementation PR
before enabling the new handoff on `main`. Do not replace ownership state.

```powershell
$state = Get-Content .\.azure\orderflow-gitops\demo3\ownership.json -Raw | ConvertFrom-Json
$common = @{ EnvironmentName = 'demo3'; SubscriptionId = $state.subscriptionId }
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action ConfigureGitHub @common
```

This sets the existing deployment environments/variables and incident label.
Azure deployment still uses OIDC; PAT authentication does not replace it.
Keep the handoff disabled while changing modes:

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $state.gitHubRepository --body false
```

Settle old SRE threads, pending cards and existing Copilot tasks before switching.
Disconnect the old App publisher connector or any other broad GitHub connector.
Changing authentication does not rearm a consumed generation.

## 2. Create the SRE issue-only PAT

GitHub personal **Settings > Developer settings > Personal access tokens >
Fine-grained tokens > Generate new token**:

| Setting | Value |
| --- | --- |
| Resource owner | Owner of `rutgerpels/azure-agentic-ops` |
| Repository access | Only select repositories: `azure-agentic-ops` |
| Repository permission: Issues | Read and write |
| Repository permission: Metadata | Read-only (automatic) |
| All other permissions | No access |
| Expiration | Short-lived; enough for the planned rehearsal |

Store it securely. Never put it in chat, Git, ownership JSON, a script argument
or a repository variable. **Do not grant Contents, Pull requests or Actions
permissions to this SRE token.** Do not substitute a classic broad `repo` token.

## 3. Connect SRE and select only the issue tools

In `demo3`, open **Build + setup > Extensions > Connectors > Add connector >
GitHub OAuth connector**, select **PAT**, and enter the issue-only token in its
credential field. The connector's name can still contain "OAuth" in PAT mode.
Confirm Connected.

From the tool catalog, select only:

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

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 `
    -Action ConfigureSre @common -SreAuthMode PAT `
    -SreIssueTools 'githubissuescon_list_issues','githubissuescon_issue_read','githubissuescon_issue_write'
```

This selects the PAT-specific issue procedure and native Ask policy. It never
takes the PAT as a parameter. Omission of `-SreAuthMode` still means `GitHubApp`.
Do not pass `-SreAssignTool`.

## 4. Configure the separate automatic assignment

Use a **second** short-lived fine-grained user PAT for Actions. Its owner needs
Copilot cloud agent availability and repository access. Restrict it to this
repository, with Metadata read and **Actions, Contents, Issues and Pull requests
read/write**, as required by GitHub's Copilot assignment API. These broader
permissions must never be given to the SRE connector.

Store the assignment token interactively:

```powershell
gh secret set ORDERFLOW_COPILOT_ASSIGN_TOKEN --repo $state.gitHubRepository
```

Pin both identities (they can be the same person, but use distinct tokens):

```powershell
# Replace the example logins, never these values with tokens.
$sreLogin = '<issue-PAT-owner-login>'
$assignmentLogin = '<assignment-PAT-owner-login>'
$sreUserId = gh api "users/$sreLogin" --jq .id
$assignmentUserId = gh api "users/$assignmentLogin" --jq .id

gh variable set ORDERFLOW_SRE_AUTH_MODE --repo $state.gitHubRepository --body PAT
gh variable set ORDERFLOW_SRE_GITHUB_LOGIN --repo $state.gitHubRepository --body $sreLogin
gh variable set ORDERFLOW_SRE_GITHUB_USER_ID --repo $state.gitHubRepository --body $sreUserId
gh variable set ORDERFLOW_SRE_GENERATION --repo $state.gitHubRepository --body $state.ownerToken
gh variable set ORDERFLOW_HANDOFF_USER_ID --repo $state.gitHubRepository --body $assignmentUserId
```

The workflow checks the fresh issue's author login, numeric ID, User type,
incident label, open state, generation marker and existing assignees.
App mode continues to trust only the configured Bot login. Unknown modes fail
closed. The assignment token owner must match the pinned handoff user ID.

## 5. Verify reads, then enable and rehearse

Ask SRE to list issues in this repository only. Inspect and approve the native
**read** card. Verify both issue states, bodies and pagination without creating
a throwaway incident. No live write is needed for this connection check.

Only after that succeeds and the updated workflow is on `main`:

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $state.gitHubRepository --body true
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action Ready @common
```

Ready checks PAT handoff configuration without requiring a deployed publisher.
It cannot validate the connector token scope, expiry or Copilot entitlement.
During a separately authorized rehearsal, show healthy requests, run `Fault`,
inspect and merge the predefined fault PR, and observe real user disruption.

For SRE's one incident publication, inspect the native card for **method=create**,
the exact repository, `labels=["orderflow-incident"]`, no assignees and body line:

```text
<!-- orderflow-incident-key:<ownerToken from this generation> -->
```

The generated instructions substitute the real generation. **Do not approve
updates, another repository, assignment, or a second create.** If the first
write fails/times out, reconcile using GitHub reads and the previous approval
card; do not approve a retry in the same or another thread.

The approved publication can immediately start Copilot through Actions without
a second SRE card. Keep **Require approval for workflow runs** on initially,
approve workflows on Copilot's PR when requested, observe test deployment/smoke,
and human-review/merge the fix before checking production recovery.

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
