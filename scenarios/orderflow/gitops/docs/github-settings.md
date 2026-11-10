# OrderFlow GitOps GitHub settings

Settings the presenter applies once per repository. `ConfigureGitHub` can create
the environments, variables, branch policies and labels; everything else is
manual. Statements marked **documented** cite GitHub documentation (checked
when this file was written); **observed** means seen in this repository;
**unverified** means no documentation or live test confirms it.

## Environments

Create `orderflow-test` and `orderflow-prod` with these variables (values printed
by `Up`). Do not add required reviewers: the human pull request
review is the production gate.

| Variable | `orderflow-test` | `orderflow-prod` |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | client ID of `id-ofg-deploy-test` | client ID of `id-ofg-deploy-prod` |
| `AZURE_TENANT_ID` | tenant ID | tenant ID |
| `AZURE_SUBSCRIPTION_ID` | subscription ID | subscription ID |
| `ORDERFLOW_RESOURCE_GROUP` | `rg-ofgitops-<env>-test` | `rg-ofgitops-<env>-prod` |
| `ORDERFLOW_SHARED_RG` | `rg-ofgitops-<env>-shared` | `rg-ofgitops-<env>-shared` |
| `ORDERFLOW_SUFFIX` | 13-character suffix | same |
| `ORDERFLOW_OWNER_TOKEN` | owner token | same |
| `ORDERFLOW_ENVIRONMENT_NAME` | lifecycle environment name | same |

No Azure deployment secrets are needed: Azure sign-in uses OIDC, and the portal
is public by design (synthetic data only; the API and Cosmos DB stay private).
Issue publishing requires its own scoped credential. Manual Copilot assignment
uses the presenter's GitHub sign-in, not an assignment secret.

Deployment branch and tag policies (selected branches):

| Environment | Allowed refs | Why |
| --- | --- | --- |
| `orderflow-prod` | `main` | CD runs only on `main`. |
| `orderflow-test` | `main` | The test deployment runs on `workflow_run`, which always runs from the default branch with `GITHUB_REF=refs/heads/main`. Pull request refs never get the test identity. |

Branch policies match `GITHUB_REF` (documented:
[Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)).
`workflow_run` runs the workflow file from the default branch with
`GITHUB_REF` set to the default branch, and only fires once that file exists on
the default branch (documented:
[events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)).
Merge `orderflow-gitops-test-deploy.yml` to `main` before the demo. The gate runs
from the pull request, so a pull request can alter it; the deploy workflow
therefore repeats every check itself and never trusts the gate result alone.

### Test deployment design

| Workflow | Trigger | Privileges | Does |
| --- | --- | --- | --- |
| `orderflow-gitops-test.yml` ("OrderFlow GitOps test gate") | `pull_request` touching `deploy/` | `contents: read`, `pull-requests: read`; no environment, no OIDC | Checks author (`Copilot` bot) or label, compares the event base and head SHAs, requires exactly one modified file `deploy/network-rules.json`, runs `check_rules.py` against the base commit baseline |
| `orderflow-gitops-test-deploy.yml` | `workflow_run` of the gate, conclusion `success` | `orderflow-test` environment, OIDC; separate report job comments and marks ready | Re-finds the open pull request by head SHA, re-checks author or label and the single-file scope against `main`, checks out `main`, overlays only the rules file fetched by SHA through the contents API, deploys and runs the smoke job |

No pull request code (workflows, Python, Bicep or parameter files) runs with
the test identity. A pull request that edits a workflow to request
`orderflow-test` is rejected by the `main`-only branch policy.

## OIDC federation

`shared.bicep` creates federated credentials on the deploy identities with
issuer `https://token.actions.githubusercontent.com` and audience
`api://AzureADTokenExchange`:

```text
repo:<owner>/<repo>:environment:orderflow-test
repo:<owner>/<repo>:environment:orderflow-prod
```

Jobs that reference an environment get an environment-based subject regardless
of the ref, so the environment branch policies are what restrict the identities.
Pull requests from forks receive no OIDC token or secrets; the gate and the
deploy workflow also require the head repository to be this repository.

## Labels

| Label | Used by |
| --- | --- |
| `orderflow-fault` | Predefined fault pull request (`Fault`) |
| `orderflow-incident` | Issue created by SRE Agent; human review and manual assignment |
| `orderflow-test-deploy` | Lets a non-Copilot pull request use the test deployment |
| `orderflow-reset` | Baseline restore pull request (`Reset`) |

Only grant write access to people allowed to apply `orderflow-test-deploy`.

## Copilot coding agent

- Enable the Copilot cloud agent for the repository
  ([configure settings](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/configuring-agent-settings)).
- Instructions: Copilot reads `AGENTS.md` files and uses the nearest one in the
  directory tree, plus `.github/copilot-instructions.md` and
  `.github/instructions/**/*.instructions.md` (documented:
  [repository custom instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions)).
  Option 2 rules are in [../AGENTS.md](../AGENTS.md).
- Branches: Copilot creates branches prefixed `copilot/` (documented:
  [risks and mitigations](https://docs.github.com/en/copilot/concepts/security-governance-and-network-settings/risks-and-mitigations)).
- Author: Copilot pull requests show REST `user.login` `Copilot` with `type`
  `Bot` (observed in this repository; not stated in the docs). The test gate uses
  both values.
- Copilot cannot mark its pull request ready, approve or merge; the person who
  asked Copilot cannot approve its pull request (documented: risks and
  mitigations). The test deployment workflow marks the pull request ready after
  a passing smoke job. Whether `gh pr ready` with `GITHUB_TOKEN` works on a
  Copilot pull request is **unverified**.
- Copilot is triggered by comments from users with write access (documented).
  Whether it acts on `@copilot` comments from `github-actions[bot]` is
  **unverified**; the presenter comments manually if it does not.

### Actions on Copilot pull requests

By default, workflows do not run on Copilot pushes until someone with write
access clicks **Approve and run workflows** (documented:
[configure settings](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/configuring-agent-settings),
[review Copilot output](https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/review-copilot-output)).
Keep **Require approval for workflow runs** enabled under
**Settings > Copilot > Cloud agent**. The warning about unreviewed agent code,
repository write access and Actions secrets is valid; do not remove the control
merely to reduce demo clicks.

Copilot PR CI and the unprivileged test gate need approval when requested.
The separate `orderflow-gitops-test-deploy.yml` run may also request approval:
inspect it in Actions, not only the PR checks. It runs trusted `main`, overlays
only the rules file and uses the test identity there. This separation is not a
reason to waive GitHub's review control. Require successful deployment, smoke
and report for the current PR head before human merge.

This setting is independent of `ConfigureSre -SreIssueWriteApproval Automatic`,
which omits only the SRE issue-publication card. Azure repair remains denied,
read cards remain, and human production merges are unchanged.

## SRE Agent GitHub App publisher

For an explicitly selected quick-demo alternative, use
[PAT setup](github-pat-setup.md). It publishes as a pinned User through the
built-in connector, not through the App publisher, and has weaker publication
guarantees. App remains the default; do not leave both connectors active.

Follow [GitHub App setup](github-app-setup.md) for the complete owner procedure.
Default authentication is a dedicated GitHub App installation with only Issues
read/write and Metadata read, installed only on this repository. A scenario-owned
custom MCP server generates short-lived installation tokens and exposes only
`find_incident_issue` and `publish_incident_issue`; SRE cannot select a different
repository, label, assignee or arbitrary GitHub operation.

Run `ConfigurePublisher` Bootstrap, securely load the two dedicated Key Vault
secrets, build the image, then run Deploy with its immutable digest. Register
the resulting `/mcp` endpoint in SRE with custom header `x-orderflow-key`.
Configure only the two exact discovered tool names with `-SreIssueTools`.
`-SreAssignTool` is retired and rejected. Do not retain the old broad connector.

## Copilot handoff

**Manual by design.** SRE publishes one unassigned issue and stops. The presenter
reviews the evidence and proposal, checks for an existing session/assignee and
selects **Assignees → Copilot** once. Choose this repository and main if prompted.
See [GitHub's documented issue-assignment flow](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-github)
and [README step 9](../../README.md#9-pause-review-and-manually-assign-copilot).

The presenter needs repository access and Copilot cloud-agent entitlement.
No token creation, assignment API call or new repository secret is required.
Leave the issue unassigned while explaining it to the audience. No other
automation should react to its publication/label by starting an agent.

### Migrating from the automatic demo

Set repository variable `ORDERFLOW_HANDOFF_FALLBACK` to exactly `false` before
publishing another issue. The updated source removes
`orderflow-gitops-handoff.yml`; leaving the false switch during migration
prevents the old main workflow from assigning. Inspect already admitted
workflow runs and Copilot sessions: the switch does not cancel them.

Re-run ConfigureSre with the same exact issue tools and chosen publication mode
only after actions settle. It records `handoffMode=manual` and tells SRE to stop
after publication. Do not edit the manifest or replay an unknown issue create.
Ready rejects enabled or ambiguous legacy flags and incomplete variable reads.

`ORDERFLOW_COPILOT_ASSIGN_TOKEN`, `ORDERFLOW_HANDOFF_USER_ID`,
`ORDERFLOW_SRE_GITHUB_LOGIN`, `ORDERFLOW_SRE_AUTH_MODE`,
`ORDERFLOW_SRE_GITHUB_USER_ID` and `ORDERFLOW_SRE_GENERATION` are no longer used
for assignment. After reconciling historical tasks, retire the dedicated old
assignment token/secret if unused elsewhere. Never delete its old intent
comments to bypass an uncertain outcome. Do not revoke the SRE issue token.

## Branch ruleset on `main`

- Require a pull request. Require a human approval where an independent reviewer
  is available; this repository currently uses zero required approvals because
  GitHub does not allow authors to approve their own PRs. Human inspection and
  merge remain the presenter gate.
- Require status check `orderflow-gitops-ci` (job name in
  `orderflow-gitops-ci.yml`).
- Block force pushes and deletions.
- Keep the default extra approval for unattributed Copilot pull requests
  (documented: risks and mitigations).

Do not require the gate or the test deployment on `main`: they run only for
deployment-folder pull requests and would block other changes.

## What not to do

- Do not add `refs/pull/*/merge`, `copilot/*` or any other ref besides `main` to
  the `orderflow-test` branch policy; that would let a same-repository pull
  request add a workflow that obtains the test identity.
- Do not add `environment:`, `id-token: write` or Azure steps to the gate, and
  do not check out or run pull request code in the test deployment workflow.
- Do not add required reviewers or wait timers to `orderflow-prod`; review
  happens on the pull request.
- Do not store Azure deployment client secrets; use OIDC.
- Do not give the SRE publisher App Contents, Actions or Pull requests
  permissions. Do not give its private key or the handoff user token to SRE.
- Do not use `pull_request_target` for these workflows.
- Do not add a connector assignment tool or recreate automatic issue pickup.

## Cleanup

For an Azure-only rehearsal reset, retain GitHub settings, secrets and valid
tokens, then refresh Azure-bound variables/generation during the next setup.
Verify owned/provider-managed group absence and the recorded subscription-level
monitoring assignment separately; see [A-Z cleanup](rehearsal.md#12-reset-source-for-next-time-and-tear-down-the-owned-azure-generation).

For permanent integration retirement, disable handoff and settle native actions before `Down`. After verified
cleanup, delete the two environments, labels if unused, handoff variables and
secret, disconnect the MCP connector and retire the App installation/keys.
The publisher and federated credentials are deleted with the shared resource
group; Key Vault soft-delete retention is not purged. See
[App cleanup](github-app-setup.md#7-readiness-demo-and-cleanup).
