# OrderFlow GitOps GitHub settings

Settings the presenter applies once per repository. `ConfigureGitHub` can create
the environments, variables, branch policies and labels; everything else is
manual. Statements marked **documented** cite GitHub documentation (checked
when this file was written); **observed** means seen in this repository;
**unverified** means no documentation or live test confirms it.

## Environments

Create `orderflow-test` and `orderflow-prod` with these variables (values printed
by `Up`; none are secrets). Do not add required reviewers: the human pull request
review is the production gate.

| Variable | `orderflow-test` | `orderflow-prod` |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | client ID of `id-ofg-deploy-test` | client ID of `id-ofg-deploy-prod` |
| `AZURE_TENANT_ID` | tenant ID | tenant ID |
| `AZURE_SUBSCRIPTION_ID` | subscription ID | subscription ID |
| `ORDERFLOW_RESOURCE_GROUP` | `rg-ofgitops-<env>-test` | `rg-ofgitops-<env>-prod` |
| `ORDERFLOW_SHARED_RG` | `rg-ofgitops-<env>-shared` | `rg-ofgitops-<env>-shared` |
| `ORDERFLOW_SUFFIX` | 13-character suffix | same |
| `ORDERFLOW_PRESENTER_CIDR` | presenter IPv4 CIDR | same |
| `ORDERFLOW_OWNER_TOKEN` | owner token | same |
| `ORDERFLOW_ENVIRONMENT_NAME` | lifecycle environment name | same |

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
| `orderflow-incident` | Issue created by SRE Agent; fallback handoff trigger |
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
A repository admin can turn this off under **Settings > Copilot > Cloud agent**
by disabling **Require approval for workflow runs**.

With approval on, Copilot pull requests need this click before the gate (and
CI) run; the test deployment then follows automatically. The approval no longer
guards credentials: the gate has no environment or OIDC token, and the test
identity is only used by `orderflow-gitops-test-deploy.yml` from `main`.
Recommendation: keep approval on for the first runs and click **Approve and run
workflows**; turning it off removes a demo click without exposing the test
identity, but still lets Copilot-authored workflow edits run with read-only
`GITHUB_TOKEN` permissions.

## SRE Agent GitHub connector

Create the connector in the SRE Agent portal with a fine-grained personal access
token for this repository only. List the connector tool names after creation and
pass them to `ConfigureSre` (`-SreIssueTools`, `-SreAssignTool`).

| Purpose | Fine-grained permissions |
| --- | --- |
| Search, create and comment on issues | Metadata read, Issues read and write, Contents read |
| Also assign the Copilot coding agent | Metadata read; Actions, Contents, Issues and Pull requests read and write |

Assigning Copilot needs a user token (personal access token, OAuth or GitHub App
user-to-server token); `GITHUB_TOKEN` and app installation tokens are not
supported. The account must have a Copilot license with the cloud agent
available. Source:
[use the cloud agent via the API](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-via-the-api)
(public preview). REST call:

```http
POST /repos/<owner>/<repo>/issues/<number>/assignees
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28

{"assignees": ["copilot-swe-agent[bot]"],
 "agent_assignment": {"target_repo": "<owner>/<repo>", "base_branch": "main",
                      "custom_instructions": "", "custom_agent": "", "model": ""}}
```

Whether the connector exposes an assignment tool that sends `agent_assignment`
is **unverified**. If it does not, use the fallback.

## Fallback handoff

`orderflow-gitops-handoff.yml` assigns Copilot when the connector cannot. It
runs only when all are true: repository variable `ORDERFLOW_HANDOFF_FALLBACK` is
`true`, the issue has label `orderflow-incident`, the issue author equals
repository variable `ORDERFLOW_SRE_GITHUB_LOGIN`, and Copilot is not already
assigned.

| Setting | Scope | Value |
| --- | --- | --- |
| `ORDERFLOW_HANDOFF_FALLBACK` | Repository variable | `true` to enable; unset by default |
| `ORDERFLOW_SRE_GITHUB_LOGIN` | Repository variable | Login of the connector account |
| `ORDERFLOW_COPILOT_ASSIGN_TOKEN` | Repository secret | User fine-grained token with the assignment permissions above |

Copilot then works as the token owner. Rotate and delete the token after the
demo.

## Branch ruleset on `main`

- Require a pull request with at least one human approval.
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
- Do not store client secrets; use OIDC only.
- Do not give the SRE connector token pull request write or push rights unless
  you need Copilot assignment, and never admin rights.
- Do not use `pull_request_target` for these workflows.
- Do not enable the fallback handoff and the connector assignment at the same
  time.

## Cleanup

After `Down`, delete the two environments, the labels if unused, the fallback
variables and secret, and the connector token. The federated credentials are
deleted with the shared resource group.
