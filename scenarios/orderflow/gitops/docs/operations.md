# OrderFlow GitOps operations

All lifecycle actions use one script from the repository root:

```powershell
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action <Action> `
  -EnvironmentName demo1 -SubscriptionId <subscription-id> [action parameters]
```

`-EnvironmentName` is 3-12 lowercase letters or digits. Ownership state lives in
`.azure/orderflow-gitops/<environment>/` at the repository root; keep it until
`Down` has verified cleanup. Exact parameter sets are in the script help
(`Get-Help ./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Full`).

## Actions

| Action | Extra parameters | What it does |
| --- | --- | --- |
| `Up` | `-Location`, `-AdminObjectId`, optional `-GitHubRepository owner/repo` | Creates `rg-ofgitops-<env>-shared`, `-prod` and `-test`; deploys shared resources and SRE Agent; builds the image; deploys test and prod with the same parameters as the workflows; runs both smoke jobs; prints GitHub environment variable values. The portal is public by design (synthetic data); the API and Cosmos DB stay private. |
| `ConfigureGitHub` | optional `-GitHubRepository` | Explicit opt-in. Uses `gh` to create or update environments `orderflow-test` and `orderflow-prod`, their variables and deployment branch policies, and the labels. Stores no secrets. |
| `ConfigurePublisher` | `-PublisherStage Bootstrap` with numeric `-GitHubAppId`, `-GitHubInstallationId`, `-GitHubRepositoryId`; then `-PublisherStage Deploy -PublisherImage <digest-reference>` | Creates owned publisher infrastructure, then deploys the issue-only GitHub App MCP server after the owner loads two Key Vault secrets. Uses the existing journal and unknown-outcome observation. See [App setup](github-app-setup.md). |
| `ConfigureSre` | Default App: `-SreIssueTools <find-name>,<publish-name>`; quick demo: `-SreAuthMode PAT` and the three issue tool names from [PAT setup](github-pat-setup.md) | Configures the investigator, mode-specific runbook, prod alert filter and native Ask policy. Azure write tools are denied; assignment tools are rejected. Settle old threads/cards and disconnect the previous connector before migrating. |
| `Ready` | none | Checks prod and test smoke, baseline rules on `origin/main`, no open `orderflow-fault` pull request and no active prod alert. |
| `Fault` | none | Requires `Ready`. Opens the predefined fault pull request from a short-lived `orderflow-fault/<token>` branch. Never merges. |
| `Status` | none | Shows smoke status, latest CD run, open fault and fix pull requests and incident issues. |
| `Reset` | none | Opens an `orderflow-reset` pull request restoring the baseline rules when `main` differs. Never pushes to `main`. |
| `Down` | none | Deletes the owned resource groups (env groups first, then shared) and observes absence. Remove GitHub environments and federated credentials separately ([github-settings.md](github-settings.md#cleanup)). |

Typical first run:

```powershell
$common = @{ EnvironmentName = 'demo1'; SubscriptionId = '<subscription-id>' }
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action Up @common `
  -Location swedencentral -AdminObjectId <object-id> `
  -GitHubRepository <owner>/<repo>
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action ConfigureGitHub @common
# Complete docs/github-app-setup.md before configuring the SRE tools.
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action ConfigureSre @common `
  -SreIssueTools '<connector>.find_incident_issue','<connector>.publish_incident_issue'
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action Ready @common
```

Pick a region where Container Apps workload profiles, Cosmos DB serverless and
SRE Agent are available.

## Workflows

| Workflow | Trigger | Azure access |
| --- | --- | --- |
| `orderflow-gitops-ci.yml` | Pull requests and pushes to `main` under `scenarios/orderflow/` | None |
| `orderflow-gitops-test.yml` (test gate) | Pull requests changing `deploy/`, gated on Copilot author or `orderflow-test-deploy` label; requires exactly `deploy/network-rules.json` | None (read-only token, no environment) |
| `orderflow-gitops-test-deploy.yml` | `workflow_run` after a successful gate; runs from `main`, re-verifies the pull request, deploys only the rules file at the tested SHA | OIDC, environment `orderflow-test` (`main` only) |
| `orderflow-gitops-cd.yml` | Push to `main` under `gitops/` or `app/`, manual dispatch on `main` | OIDC, environment `orderflow-prod` |
| `orderflow-gitops-handoff.yml` | Trusted App issues, or explicitly selected PAT-user issues with pinned ID and generation marker, opened or labelled; disabled unless `ORDERFLOW_HANDOFF_FALLBACK` is `true` | None (separate GitHub user token only) |

Deployments pass the stage `.bicepparam` file plus inline overrides; the Azure
CLI forwards inline values to `bicep build-params`. The bicepparam files also
read `ORDERFLOW_*` environment variables, which the workflows export.

CI checks the current runtime rules against the network policy and preserves
the required baseline allows. It does not require the runtime file to equal the
healthy baseline: the predefined fault and a compliant fix-forward must both
pass CI. `Ready` separately requires baseline equality before fault admission.
Never bypass the required CI check to merge a fault or repair.

The Python regression suite also runs the full offline PowerShell lifecycle
contracts in isolated copies with healthy, faulted and fix-forward runtime
rules. These tests do not alter the owning checkout or call Azure or GitHub.

The selected three-operation PAT profile uses a GitHub **MCP** connector.
Its actual prefixed operation names belong in the investigator's `mcpTools`,
not its native Azure `tools`. `ConfigureSre` and fresh SRE verification require
those names to match exactly the three selected operations on one deployed MCP
connector. Example prefixes are not portable. A native GitHub OAuth connector
is a different operation profile; do not treat its setup as interchangeable
with the MCP profile or grant broader token access to resolve a mismatch.

On 2026-11-03, the fault deployed successfully, smoke and real dependency reads
failed, and SRE automatically diagnosed the priority-300 data-tier deny. Issue
publication stopped because the investigator referenced an example connector
prefix in native tools instead of the existing connector's MCP tool bindings.
Repair only those bindings and their native Ask policy after owner approval,
then prove read access in the existing incident thread before publication.
Never recreate the fault or use direct issue creation as a substitute for the
SRE handoff.

On 2026-11-04, both native read approvals succeeded and a complete 19-issue
inventory was verified. The Azure SRE Agent client restored subscription-level
Monitoring Contributor around the first approval, which the original
reader-only guard rejected. The owner explicitly accepted the platform's
[documented monitoring default](https://sre.azure.com/docs/concepts/permissions).
The guard now permits only that built-in role at the owned subscription,
alongside the existing readers; it neither grants the role nor accepts other
non-reader roles/scopes. Native Ask, denied Azure write tools and the ban on
NSG/infrastructure repair remain unchanged. This is not a strictly read-only
RBAC identity. Incident publication, Copilot handoff and recovery still require
their own live evidence.

The first supervised PAT issue-create request subsequently stopped before a
native approval card existed: SRE reported, "An error occurred while creating
the approval record. The tool was blocked for safety." No publication approval
was granted; complete read-only GitHub reconciliation found no incident for
the generation. The subsequent approved List Issues reconciliation likewise
found no incident. The cause of the approval-record error has not been
established.

The owner then explicitly authorized one diagnostic retry without the issue-write
card. After fresh complete-body deduplication and verification that the previous
write had been cancelled before approval, only the exact MCP `issue_write` tool
was temporarily allowed; read tools retained Ask and Azure writes remained
denied. SRE created [incident #95](https://github.com/rutgerpels/azure-agentic-ops/issues/95)
at 14:12:56 UTC on 2026-11-04 without a card. Actions assigned Copilot once;
the second event-triggered handoff run observed the existing assignment and did
not submit another. Copilot opened [draft fix #96](https://github.com/rutgerpels/azure-agentic-ops/pull/96).
Test deployment, human merge and production recovery were not yet verified.

The original policy/investigator were restored and verified after this one-off
experiment; `ConfigureSre` still defaults to Ask. The generic tool-level allowance
was not method-scoped or server-enforced create-only. This proves automatic issue
publication and assignment for this run, not the cause or repair of the failed
approval-record creation. No PAT scope, production rule or deployment was changed.
Never retry an unknown write outcome; this attempt required explicit owner
authorization and evidence of the prior request's non-execution.

## Costs

Both environments are always on. Main cost drivers (check current prices in the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/)):

- **Container Apps, Consumption profile**: per vCPU-second and GiB-second; each
  stage keeps the portal and API at one replica, so they bill continuously. The
  smoke job bills only while running.
- **Log Analytics**: per GB ingested (one workspace per stage) plus retention.
- **Cosmos DB serverless**: per request unit and storage; demo traffic is small.
- **Azure Container Registry Basic**: fixed daily rate plus storage.
- **Azure SRE Agent**: billed per agent usage; see the SRE Agent pricing page.
- **GitHub**: Actions minutes and Copilot coding agent premium requests.
- **Issue publisher**: a separate Container Apps environment and one publisher
  replica, Key Vault operations and private Blob receipts. These are in the
  owned shared group, outside the fault's network path.

Run `Down` when the demo is no longer needed.

## Verification status

Documented means supported by vendor documentation or offline tests. Live
observations below apply only to the stated deployment/run; they do not prove
the complete fault-to-recovery flow.

| Behaviour | Status |
| --- | --- |
| Offline tests, rule check, `az bicep build` and `build-params` | Verified offline |
| Fresh test/prod smoke through Ready, and a real portal order | Observed on demo3 on 2026-11-03; private ownership/rehearsal receipts retained |
| Healthy production CD using GitHub OIDC, deployment and in-network smoke | Observed on 2026-11-03 after an explicitly approved migration of the existing federated subjects to GitHub's immutable ID-bound format; does not establish test-workflow OIDC or fault recovery |
| Inline parameter overrides with a `.bicepparam` file | Documented (Azure CLI source), not live-verified |
| Container Apps traffic to the Cosmos DB private endpoint fails under `DenyVnetToDataTier` with the baseline allows | Observed on demo3 after the human-merged fault on 2026-11-03; dependency reads and in-network smoke failed |
| `AllowAppsToCosmosPrivateEndpoint` restores the dependency while keeping the deny | Not live-verified |
| OIDC login for `orderflow-test` from the `workflow_run` deployment on `main` | Documented, not live-verified |
| `workflow_run` deployment fires after the gate (file must be on `main`) | Documented, not live-verified |
| Portal inbound uses the external environment's public IP in the managed resource group, so the subnet NSG needs no inbound rule ([firewall integration](https://learn.microsoft.com/azure/container-apps/firewall-integration)) | Documented, not live-verified |
| Smoke job start and execution polling | Observed during healthy Ready and production CD on demo3 on 2026-11-03; does not establish recovery |
| Dependency alert and SRE Agent incident trigger | Observed on demo3 on 2026-11-03; SRE diagnosed the NSG regression; alert recovery remains unverified |
| Custom MCP App publisher, exact SRE tool names and native issue approval | Implemented with offline tests; not live-verified |
| PAT MCP read connectivity and issue creation | Native reads succeeded on 2026-11-04; approval-gated create failed before its card. One explicitly authorized automatic retry created #95; original policy restored afterward |
| Standard handoff workflow assignment using the separate user token | Observed on #95 on 2026-11-04; one assignment intent and Copilot draft #96; second event run submitted no duplicate assignment |
| Actions on Copilot pull requests (approval setting) | Documented, not live-verified |
| Copilot reacts to `@copilot` comments from `github-actions[bot]` | Unverified |
| `gh pr ready` with `GITHUB_TOKEN` on a Copilot draft pull request | Not live-verified |
| Copilot pull request author `Copilot` (type `Bot`) | Observed in this repository on an earlier pull request |
