# Azure Agentic Ops demo repository

This repository hosts independently named demos, not a single customer project.
Start with the root README and `docs/scenarios.md`. Keep each scenario's app,
infrastructure, lifecycle scripts, tests and documentation under
`scenarios/<demo-name>/`; consult that scenario's `AGENTS.md` before editing it.
Do not create a new orchestration framework or extract hypothetical shared code.

Retailx (`scenarios/retailx/`) is the first scenario: synthetic hybrid retail
checkout using Azure Arc, Monitor and SRE Agent. Its delivery plan is
`scenarios/retailx/docs/implementation-plan.md`. Its optional Foundry assistant
is read-only, separately owned and never a prerequisite for checkout.

Shared dependencies currently live at `scripts/Azure.Common.psm1` and
`infra/azure-bootstrap-identity.bicep`; their consumers must remain compatible.
GitHub Actions must remain in `.github/workflows/`, with explicit scenario
paths. Python tool configuration and pinned development dependencies stay at
the root; scenario-specific runtime requirements stay with the application.

## Safety and compatibility

- Only the presenter injects faults. Setup/preparation stops healthy. Preserve
  bounded operations, explicit undo and owned teardown for every feature.
- Enforce human approval and action boundaries in controllers, identities and
  tool policy, not just instructions. Text assent is not native approval.
- Unknown command outcomes are observed, not automatically replayed. Require
  fresh same-run evidence; stale/missing evidence is unknown.
- Keep ignored ownership manifests until verified cleanup. Retailx retains the
  repository-root `.azure/<environment>/` location; do not move or recreate it.
- Do not rename deployed resources, service units, state schemas or identities
  to match a scenario's display name. Use neutral environment IDs and never
  commit live identifiers, credentials, customer names or operational receipts.
- Scenario-specific knowledge and `docs/agent-context/` remain reviewable.
  Distinguish documented behavior from recorded live verification.

Normal engineering changes target `main` through human-reviewed pull requests.
Retailx issues labelled `checkout-demo` are the in-demo exception: target
`demo/checkout`, never `main`, and change intended routes only in
`scenarios/retailx/infra/checkout/price-routes.json`. Preserve the deploy/reset
workflow reviewers, branch gates and immutable baseline tags.

Retired foundation/native guest, Windows disk/IIS, posting/backlog and intake
experiments are historical evidence, not supported demos. Do not restore them
as dependencies of Retailx.
