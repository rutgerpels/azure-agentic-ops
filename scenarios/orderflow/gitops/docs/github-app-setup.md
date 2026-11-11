# GitHub App issue publishing and separate Copilot handoff

For a supervised demo without deploying this publisher, see the
[PAT alternative](github-pat-setup.md). Both paths use manual human assignment
but has weaker issue-publication isolation and no durable publication reservation.
The App path remains the default.

The default option-2 authentication is an **installation token from your own
GitHub App**, restricted to this repository and Issues write. SRE calls the
scenario's custom MCP issue publisher, not the built-in GitHub OAuth connector.
The publisher holds the App private key; SRE receives only the publisher access
key and its two issue tools. After publication, a human reviews the issue and
assigns Copilot in GitHub. No assignment credential is stored in Actions.

This is implemented and tested offline, not live-verified. No App, credential,
connector, permission or live deployment is created by merging the change.

## Permission boundaries

| Identity | Scope and permission | Credential location |
| --- | --- | --- |
| GitHub App installation | Only this repository; Issues read/write, automatic Metadata read. No Contents, Actions or Pull requests permission | Private key in the dedicated Azure Key Vault; short-lived installation tokens in publisher memory |
| Publisher managed identity | Its dedicated vault (Secrets User), receipt container (Storage Blob Data Contributor), owned ACR (AcrPull) | Azure managed identity |
| SRE Agent | Existing Azure readers and the documented scoped monitoring exception; only `find_incident_issue` and `publish_incident_issue`, both native Ask by default | Custom MCP header credential in the SRE connector |
| Presenter | Repository access and Copilot cloud-agent entitlement; reviews the issue and deliberately assigns Copilot | Normal GitHub browser sign-in, never supplied to SRE |

Publishing or labelling an issue does not start Copilot. The presenter inspects
the evidence and existing assignees/tasks, then assigns it once. An uncertain
earlier assignment still requires reconciliation, not another click. A human
also reviews and merges the resulting tested PR.

The explicit `ConfigureSre -SreIssueWriteApproval Automatic` alternative allows
only the exact publication tool; find/read remains Ask. The App publisher's
server-side restrictions and reservation remain unchanged. This option is
independent of Copilot workflow-run approvals, which stay enabled. The selected
fresh PAT rehearsal is described separately in [the A-Z guide](rehearsal.md).

## 1. Register and install the issue-only App

In GitHub **personal Settings > Developer settings > GitHub Apps > New GitHub
App**, register a dedicated App with a unique name. Use this repository's URL
as its homepage, disable webhooks, and do not enable user authorization: this
publisher uses installation authentication only.

Set repository permission **Issues: Read and write**. Metadata read is
automatic. Leave every other repository permission unset. Install the App on
**Only select repositories > azure-agentic-ops**.

Record the numeric **App ID** (not Client ID), the installation ID from its
installation settings URL, and its bot login (`<app-slug>[bot]`). Generate and
download an App private key. Keep it outside tracked files; do not paste it in
chat, issues, command arguments or repository variables.

## 2. Bootstrap the owned publisher infrastructure

After following Up in the [A-Z guide](../../README.md), use the same local
worktree and `$statePath`/`$common` variables for that fresh environment. It must contain the updated
scripts; do not switch branches or replace the ownership manifest to obtain them.
Ensure `az login` and `gh auth status` succeed. The operator needs rights to
create the resources and their scoped role assignments.

```powershell
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$common = @{ EnvironmentName = $state.environmentName; SubscriptionId = $state.subscriptionId }
$repositoryId = gh api "repos/$($state.gitHubRepository)" --jq .id
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action ConfigurePublisher @common -PublisherStage Bootstrap -GitHubAppId '<app-id>' -GitHubInstallationId '<installation-id>' -GitHubRepositoryId $repositoryId
```

Confirm the prompt. The command creates a dedicated vault, receipt storage,
publisher identity and separate Container Apps environment in the **already
owned shared resource group**. It does not publish an issue or inject a fault.
The identifiers and deployment outputs are recorded in the ignored manifest.
This bootstrap is intentionally separate from `Up`: the App must exist first.

If a deployment response is lost, run the normal `-Action Status @common` to
observe the recorded deployment. Do not retry an unknown write or delete state.
A terminal failed ARM deployment follows the existing cleanup-only policy.

## 3. Load the two secrets securely

Read the `vaultName` from the bootstrap output. In Azure portal, grant your
operator identity **Key Vault Secrets Officer on this dedicated vault** if it
does not already have data-plane access. This is separate from the publisher's
read-only secret access. Wait for role propagation.

Create these secrets in that vault:

| Secret | Value |
| --- | --- |
| `github-app-private-key` | Complete PEM contents of the downloaded GitHub App key |
| `publisher-key` | Independently generated cryptographically random access key, at least 32 characters (for example 32 random bytes encoded as hex) |

Use your password manager to generate/store the publisher key and the Azure
portal to enter it. For the multiline PEM, use a local file upload command;
the key itself must not appear in command arguments or output:

```powershell
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$vault = $state.outputs.'publisher-bootstrap'.vaultName
# Set $appKeyPath to the downloaded PEM file's absolute path, not its contents.
az keyvault secret set --subscription $state.subscriptionId --vault-name $vault --name github-app-private-key --file $appKeyPath --query id -o tsv
```

The lifecycle checks enabled secret metadata only; it never reads secret values.
Container Apps resolves the secrets with the publisher identity. Remove the
downloaded key securely after storing your recoverable copy according to your
credential policy. Never reuse the Copilot assignment token as `publisher-key`.

## 4. Build and deploy the publisher

Build only the scenario-owned publisher directory, never the repository root
or a directory holding the downloaded private key. Its Docker ignore file
excludes secrets and unrelated files.

```powershell
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$acr = $state.outputs.shared.acrName
$server = $state.outputs.shared.acrLoginServer
$tag = "publisher-$((git rev-parse --short=12 HEAD).Trim())"
az acr build --subscription $state.subscriptionId --registry $acr --image "orderflow-issue-publisher:$tag" --file Dockerfile --no-logs .\scenarios\orderflow\gitops\publisher
```

Only continue when that build succeeds. If the response is lost, inspect its
ACR run and image tag before starting another build. Then resolve its digest
and deploy the immutable reference:

```powershell
$digest = az acr repository show --subscription $state.subscriptionId --name $acr --image "orderflow-issue-publisher:$tag" --query digest -o tsv
$image = "$server/orderflow-issue-publisher@$digest"
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action ConfigurePublisher @common -PublisherStage Deploy -PublisherImage $image
```

The output includes `publisherUrl`, ending in `/mcp`. The service is HTTPS
reachable but authenticated; Blob anonymous access and shared-key access are
disabled. The vault/storage endpoints are network-public with identity-based
access, not private endpoints. This is independent of the demo's private
application/Cosmos network and remains available during the NSG fault.

## 5. Register the custom MCP connector

In the new owned agent at **sre.azure.com > Build + setup > Extensions > Connectors**:

1. Disconnect/remove any previous broad GitHub connector after settling its
   threads and approval cards. Do not leave an alternate write path available.
2. Add **MCP Server**, using the deployed `publisherUrl` and Streamable HTTP
   transport. This is not the built-in GitHub OAuth connector.
3. Configure custom header `x-orderflow-key` with the vault's `publisher-key`
   value, entered securely in the portal.
4. Confirm Connected. Select only `find_incident_issue` and
   `publish_incident_issue`. Record their exact connector-prefixed identifiers.

Do not grant SRE access to Key Vault or a generic GitHub API tool. Custom MCP
transport/authentication and the discovered tool names must be verified in
your tenant; offline tests are not proof of portal interoperability.

Configure SRE with the exact two discovered names:

```powershell
.\scenarios\orderflow\gitops\scripts\Invoke-OrderFlowGitOps.ps1 -Action ConfigureSre @common -SreIssueTools '<connector>.find_incident_issue','<connector>.publish_incident_issue'
```

The previous `-SreAssignTool` parameter is rejected with a migration message.
Do not use a dummy assignment tool. Existing assignment-enabled manifests must
be explicitly reconfigured with settled threads; they fail readiness.

## 6. Verify publication reads and prepare the human handoff

Do not create a second PAT or enable an assignment workflow. Keep the legacy
switch disabled while migrating from older source:

```powershell
gh variable set ORDERFLOW_HANDOFF_FALLBACK --repo $state.gitHubRepository --body false
if ($LASTEXITCODE -ne 0) { throw 'Could not disable legacy automatic assignment.' }
```

Settle already admitted runs and inspect old assignment intents/tasks. The
presenter needs Copilot access in GitHub, not an assignment token in Actions.

Before any issue publication, confirm the `orderflow-incident` label exists
(`ConfigureGitHub` creates it). Then ask SRE to call only `find_incident_issue`
with the deployment generation key from its configured instructions. Inspect
the native approval card and approve only the read. This exercises the App
token and repository lookup without creating an issue.

After that read succeeds, verify the installed App's bot login, then return to
[README readiness](../../README.md#6-verify-the-healthy-start). Keep automation off.

For the first write, during the authorized fault rehearsal, approve exactly one
evidence-backed issue. Verify its author is the expected App bot, its incident
label is present, and repeated reads return that same issue. Pause for a human
to review it and [manually assign Copilot](../../README.md#9-pause-review-and-manually-assign-copilot).
The publisher admits only the configured generation key and records a durable
reservation before its single GitHub create request. Pending/unknown results
are observed, never replayed; do not invent another key, delete receipts or
re-create closed issues. Do not spend this generation on a throwaway test issue.

Do not relabel an issue to trigger an old workflow or remove an old assignment
intent. If the assignment outcome is unknown, observe the existing task.

## 7. Readiness, demo and cleanup

Run `-Action Ready @common` before `Fault`. For the SRE path it also checks
publisher deployment and disabled legacy automatic handoff. It cannot prove
the presenter's Copilot entitlement; inspect the assignment UI without
submitting a test task. Keep the selected issue-publication policy, workflow
approvals, exact-head test evidence and human merge gates.

`Down` removes the publisher with the owned shared group; vault soft-delete
retention remains Azure-managed. First settle SRE actions and disable the
handoff. Revoke/delete the assignment PAT and secret, remove the handoff
variables, disconnect the MCP connector, and uninstall/delete the dedicated App
or revoke its keys when retiring it. Preserve ignored ownership/journal receipts
until Azure cleanup is verified. Do not purge shared vaults or unrelated Apps.

## References

- [GitHub App installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
- [Generating installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [Manual Copilot issue assignment](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-github)
- [SRE custom MCP connector](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connector)
- [Container Apps Key Vault secret references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
