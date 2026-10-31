# OrderFlow GitOps agent instructions

These instructions apply to contributors and to the Copilot coding agent working
under `scenarios/orderflow/gitops/`. Read [README.md](README.md) first.

## Incident issues (`orderflow-incident`)

The SRE Agent opens an issue labelled `orderflow-incident` after a production
smoke failure or alert. When you are assigned such an issue:

1. Read the issue evidence: alert window, failing dependency, the merged commit or
   CD run that changed `scenarios/orderflow/gitops/deploy/network-rules.json`, and
   the proposed rule change.
2. Change **only** `scenarios/orderflow/gitops/deploy/network-rules.json`. Never
   edit `deploy/baseline/`, `deploy/*.bicepparam` or any other file under
   `deploy/`, nor `faults/`, `infra/`, `container/`, `tools/`, `scripts/`,
   `tests/`, `scenarios/orderflow/app/` or `.github/workflows/`. The test
   deployment refuses any pull request whose diff is not exactly a modification
   of that one file, and it deploys only that file on top of `main`.
3. Prefer a fix-forward that keeps the egress hardening. For a blocked Cosmos DB
   dependency, add an outbound allow such as `AllowAzureCosmosDb` (destination
   service tag `AzureCosmosDB`, port `443`, protocol `Tcp`, source `VirtualNetwork`,
   a free priority below the deny, for example `180`) and keep
   `DenyInternetOutbound`. Reverting the deny is acceptable only when the issue
   recommends it.
4. Validate offline:

   ```bash
   python scenarios/orderflow/gitops/tools/check_rules.py scenarios/orderflow/gitops/deploy/network-rules.json
   python -m pytest scenarios/orderflow/gitops/tests
   ```

5. Open the pull request against `main`. In the description include `Fixes #<issue>`,
   the evidence you relied on, the exact rule change and the test plan (offline
   checks above plus the automatic test deployment and smoke job).
6. Do not mark the pull request ready yourself. The `orderflow-gitops-test` gate
   checks the change, then `orderflow-gitops-test-deploy` deploys it to the test
   environment, runs the in-network smoke job and marks it ready only after
   success. If it comments that the test failed, revise only the rules file. A
   human reviews and merges; CD then deploys production.

Never run Azure CLI, PowerShell lifecycle actions or any other command against
Azure. Never change GitHub settings, labels, environments or secrets.

## Contributors

- Keep `deploy/network-rules.json` as the only reviewed runtime surface for the
  fault, fix and reset pull requests. Short-lived branches only; merge to `main`
  through human review.
- Keep workflow actions pinned to full commit SHAs, `persist-credentials: false`,
  least-privilege permissions and untrusted pull request text out of `run:`
  scripts. `tests/test_gitops_workflows.py` enforces these invariants.
- Setup stops healthy; only the presenter injects the fault with
  `Invoke-OrderFlowGitOps.ps1 -Action Fault`. Do not commit live IDs, secrets or
  customer data.
- Distinguish documented behaviour from live-verified behaviour in the docs.
