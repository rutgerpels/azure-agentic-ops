# GitHub settings for testing OrderFlow

No GitHub connector, PAT, Copilot assignment, demo branch reset or Retailx
environment is required by SRE Agent. It repairs an Azure NSG, not source code.
Do not reuse `checkout-deploy`, `checkout-demo-reset` or their identities.

## Offline PR checks

Enable GitHub Actions and allow these pinned actions: `actions/checkout`,
`actions/setup-python`, and (only for publication) `azure/login`.
`OrderFlow validation / offline` runs on GitHub-hosted Ubuntu without Azure
credentials. Keep workflow token permissions read-only.

After the check has run once, add it as a required check in the `main` branch
ruleset, alongside existing checks. Require a human PR approval; do not allow
the coding agent to approve or merge its own import.

## Optional reviewer-gated portal publication

Local `Up` already publishes the portal. The optional GitHub workflow publishes
that **same source generation** again; it does not provision infrastructure,
configure SRE, inject faults, undo or tear down. Do not run it during a demo.

Create the environment **`orderflow-publish`** in Settings > Environments:

| Setting | Required value |
|---|---|
| Required reviewers | At least one named human reviewer |
| Prevent self-review | Enable when a second human can review; otherwise document the single-presenter exception |
| Administrator bypass | Disable |
| Deployment branches | Selected branches: `main`; temporarily add the exact reviewed feature branch for pre-merge testing |

Use an isolated, preferably ephemeral self-hosted runner with label `orderflow`,
PowerShell 7.2+, Azure CLI, Python 3.11 and archive support. Its public egress IP
must fall inside the deployment's `PresenterCidr`, because SCM has the same
restriction as the portal. Do not widen SCM to all GitHub IP ranges or run
untrusted pull-request jobs on this runner. Restrict its runner group to the
publication workflow where the GitHub plan supports that control.

Configure these **environment variables** (not committed values):

| Variable | Source/value |
|---|---|
| `AZURE_CLIENT_ID` | Dedicated publication identity's application/client ID |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription used by local `Up` |
| `ORDERFLOW_RESOURCE_GROUP` | `resourceGroup` from the owned manifest |
| `ORDERFLOW_WEBAPP_NAME` | `outputs.webAppName` from the manifest |
| `ORDERFLOW_OWNER_TOKEN` | `ownerToken` from the manifest; ownership marker, not a credential |
| `ORDERFLOW_SOURCE_HASH` | `sourceHash` from the manifest |
| `ORDERFLOW_APPROVED_SHA` | Exact 40-character Git commit reviewed for publication |

For pre-merge testing only, add a **repository variable**
`ORDERFLOW_TEST_REF` containing the exact `refs/heads/<reviewed-feature-branch>`.
This is repository-scoped because the job's admission expression runs before
environment variables are available. Delete it and remove the temporary
environment branch permission after testing.

In Entra, create a dedicated workload identity with a GitHub federated
credential:

```text
Issuer:   https://token.actions.githubusercontent.com
Subject:  repo:rutgerpels/azure-agentic-ops:environment:orderflow-publish
Audience: api://AzureADTokenExchange
```

An authorized Azure operator grants **Website Contributor on the single owned
portal resource only**. This role is broader than ZIP publication, but it does
not grant subscription/RG, VM, NSG or SRE rights. Do not use Owner or Contributor
at subscription or resource-group scope. No client secret or publish profile
is needed. The workflow explicitly requests `id-token: write`.

First merge the workflow definition to `main` so GitHub exposes manual dispatch,
or use an already-reviewed default-branch workflow version. A workflow file
only on a feature branch may not appear in the Actions dispatch menu.
Then select the approved ref and approve the environment deployment.

If publication times out, inspect the exact App Service deployment before any
manual rerun. Do not infer failure from missing output and automatically replay.

## Separate Azure prerequisites

These are not GitHub settings:

- A presenter with permission to provision resources, the RG-scoped custom
  repair role and role assignments in the dedicated demo scope.
- Registered providers for Compute, Network, Web, DocumentDB, Insights,
  OperationalInsights, ManagedIdentity and App; a region offering the selected
  VM SKU, App Service and SRE Agent.
- A narrow presenter CIDR, an SSH public key and the presenter's object ID for
  the agent-scoped SRE Agent Administrator assignment.
- Working Azure Monitor intake in the owned SRE Agent. `ConfigureSre` and
  `Ready` refuse to admit a fault if this is unavailable.

No settings are changed by the import. Revoke the publication identity's
resource assignment, remove its federation and retire the environment/runner
when the demo is retired; these external GitHub/Entra objects are not owned by
the Azure resource-group teardown.
