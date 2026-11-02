# OrderFlow GitOps demo run sheet

Presenter guide for option 2. Timings are planning estimates, not measured
runs. Commands are in [operations.md](operations.md).

## Before the audience joins

| When | Action | Expected |
| --- | --- | --- |
| T-60 min | `Up` (first time) or `Status` | Shared, test and prod deployed; both smoke jobs `Succeeded` |
| T-30 min | `ConfigureGitHub` and `ConfigureSre` already done once | Environments, labels and SRE subagent present |
| T-15 min | `Ready` | Passes: baseline rules on `main`, no open fault PR, no active alert |
| T-10 min | Open tabs | Prod portal, Actions, Pull requests, Issues, SRE Agent chat, Azure portal NSG `nsg-ofg-prod` |

## Live run

| Clock | Step | Show |
| --- | --- | --- |
| 0:00 | Healthy | Place an order in the prod portal; receipt appears. Latest CD run green. |
| 0:03 | Fault | Run `Fault`. Open the pull request "Segment OrderFlow data tier: deny lateral VNet access to the data subnet". Point out it looks like reasonable hardening and CI passes. |
| 0:06 | Merge | Merge the fault pull request (presenter, human review). |
| 0:07-0:15 | CD fails | CD deploys prod; the smoke job step fails with a red run. Place an order: the portal shows the dependency error. |
| 0:15- 0:25 | Alert and SRE | The dependency alert fires (scheduled query; minutes of delay). SRE Agent investigates the deployed NSG and dependency evidence, proposes a fix and asks to publish the `orderflow-incident` issue as the GitHub App. Approve the native card. The separately enabled Actions workflow assigns Copilot automatically; no second SRE assignment card is expected. |
| 0:25-0:40 | Copilot draft PR | Copilot opens a draft pull request changing only `deploy/network-rules.json` (for example `AllowAppsToCosmosPrivateEndpoint`). If workflow runs need approval, click **Approve and run workflows** (this starts the unprivileged gate; it does not release credentials). |
| 0:40-0:50 | Test deploy | The `orderflow-gitops-test` gate passes, then `orderflow-gitops-test-deploy` (from `main`) deploys the rules file to test, runs the smoke job, comments the result and marks the pull request ready. |
| 0:50 | Human merge | Review the diff and the test evidence; approve and merge. |
| 0:51-1:00 | Recovery | CD deploys prod; smoke passes. Place an order; receipt appears. The alert resolves after its evaluation window. |
| After | Reset | Run `Reset` and merge the reset pull request if the fix differs from baseline to restore the baseline. This does not rearm the generation: deploy a fresh owned environment for another fault rehearsal. |

## Talking points

- Every production change, including the fault, went through a pull request and CD.
- SRE Agent stays read-only in Azure; its only write is an App-authored issue
  behind native approval. The separate Actions handoff assigns Copilot without
  a second SRE approval card.
- The fix is proven in an always-on test environment before review.
- A human remains the merge gate; Copilot cannot approve or merge its own pull
  request.

## Fallbacks

| Problem | Action |
| --- | --- |
| Issue exists but Copilot is not assigned | Inspect the handoff workflow, App-author variable and separate user-token permission/expiry (see [App setup](github-app-setup.md)). SRE must not assign Copilot or obtain the handoff token. Observe uncertain assignment outcomes before any manual retry. |
| Copilot workflow runs wait for approval | Click **Approve and run workflows** on the pull request. |
| Test gate skipped or failed | Check the gate job: author must be Copilot or the pull request must carry `orderflow-test-deploy`, and the diff must be exactly a modification of `deploy/network-rules.json`. |
| Gate passed but no test deployment | `orderflow-gitops-test-deploy.yml` must exist on `main`, and `orderflow-test` must allow branch `main`. Check its `resolve` job notices (pull request head moved, not open, or scope changed). |
| Copilot does not react to the failure comment | Comment `@copilot` yourself with the evidence (bot comments are an unverified trigger). |
| Alert is slow | Show the failed CD run and the portal error; start the SRE conversation from the failed run. |
