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
| `Up` | `-Location`, `-PresenterCidr`, `-AdminObjectId`, optional `-GitHubRepository owner/repo` | Creates `rg-ofgitops-<env>-shared`, `-prod` and `-test`; deploys shared resources and SRE Agent; builds the image; deploys test and prod with the same parameters as the workflows; runs both smoke jobs; prints GitHub environment variable values (no secrets). |
| `ConfigureGitHub` | optional `-GitHubRepository` | Explicit opt-in. Uses `gh` to create or update environments `orderflow-test` and `orderflow-prod`, their variables and deployment branch policies, and the labels. Never stores secrets. |
| `ConfigureSre` | `-SreIssueTools <names>`, `-SreAssignTool <name>` | Configures subagent `orderflow-gitops-investigator` from [runbook.md](runbook.md), the prod alert incident filter and the tool policy (GitHub issue and Copilot assignment tools `Ask`; Azure write tools `Deny`). |
| `Ready` | none | Checks prod and test smoke, baseline rules on `origin/main`, no open `orderflow-fault` pull request and no active prod alert. |
| `Fault` | none | Requires `Ready`. Opens the predefined fault pull request from a short-lived `orderflow-fault/<token>` branch. Never merges. |
| `Status` | none | Shows smoke status, latest CD run, open fault and fix pull requests and incident issues. |
| `Reset` | none | Opens an `orderflow-reset` pull request restoring the baseline rules when `main` differs. Never pushes to `main`. |
| `Down` | none | Deletes the owned resource groups (env groups first, then shared) and observes absence. Remove GitHub environments and federated credentials separately ([github-settings.md](github-settings.md#cleanup)). |

Typical first run:

```powershell
$common = @{ EnvironmentName = 'demo1'; SubscriptionId = '<subscription-id>' }
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action Up @common `
  -Location swedencentral -PresenterCidr 203.0.113.10/32 -AdminObjectId <object-id> `
  -GitHubRepository <owner>/<repo>
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action ConfigureGitHub @common
./scenarios/orderflow/gitops/scripts/Invoke-OrderFlowGitOps.ps1 -Action ConfigureSre @common `
  -SreIssueTools <issue-tool-names> -SreAssignTool <assign-tool-name>
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
| `orderflow-gitops-handoff.yml` | Issues opened or labelled; disabled unless `ORDERFLOW_HANDOFF_FALLBACK` is `true` | None (GitHub user token only) |

Deployments pass the stage `.bicepparam` file plus inline overrides; the Azure
CLI forwards inline values to `bicep build-params`. The bicepparam files also
read `ORDERFLOW_*` environment variables, which the workflows export.

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

Run `Down` when the demo is no longer needed.

## Verification status

Documented means supported by vendor documentation or offline tests. Nothing is
live-verified in Azure yet.

| Behaviour | Status |
| --- | --- |
| Offline tests, rule check, `az bicep build` and `build-params` | Verified offline |
| Inline parameter overrides with a `.bicepparam` file | Documented (Azure CLI source), not live-verified |
| Container Apps egress fails for Cosmos DB under `DenyInternetOutbound` with the baseline allows | Not live-verified |
| `AllowAzureCosmosDb` restores the dependency while keeping the deny | Not live-verified |
| OIDC login for `orderflow-test` from the `workflow_run` deployment on `main` | Documented, not live-verified |
| `workflow_run` deployment fires after the gate (file must be on `main`) | Documented, not live-verified |
| Portal inbound uses the external environment's public IP in the managed resource group, so the subnet NSG needs no inbound rule ([firewall integration](https://learn.microsoft.com/azure/container-apps/firewall-integration)) | Documented, not live-verified |
| Smoke job start and execution polling | Not live-verified |
| Dependency alert and SRE Agent incident trigger | Not live-verified |
| SRE connector tool names and Copilot assignment through the connector | Not live-verified |
| Fallback handoff workflow assignment | Documented, not live-verified |
| Actions on Copilot pull requests (approval setting) | Documented, not live-verified |
| Copilot reacts to `@copilot` comments from `github-actions[bot]` | Unverified |
| `gh pr ready` with `GITHUB_TOKEN` on a Copilot draft pull request | Not live-verified |
| Copilot pull request author `Copilot` (type `Bot`) | Observed in this repository on an earlier pull request |
