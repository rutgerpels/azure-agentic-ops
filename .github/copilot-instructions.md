# Azure Agentic Ops demos

This repository hosts reusable, independently named demos for multiple customer
conversations. Start with `README.md` and `docs/scenarios.md`.

## Organization

- Each demo owns its app, infra, lifecycle scripts, tests and docs under
  `scenarios/<slug>/`. Read its `AGENTS.md` before editing.
- Share only proven utilities: `scripts/Azure.Common.psm1` and
  `infra/azure-bootstrap-identity.bicep`. Preserve compatibility for all consumers.
- Keep Actions in `.github/workflows/` with explicit scenario paths, Python
  tooling and development pins at the root, and runtime requirements with apps.

## Retailx

`scenarios/retailx/` demonstrates synthetic hybrid retail checkout using Azure
Arc, Monitor and SRE Agent: Belgium-only latency and a shared price-service
outage. It primarily supports hybrid-cloud conversations. The SRE-to-Copilot
code loop and separately owned, read-only Foundry assistant are optional.
See its README for deployment and `docs/implementation-plan.md` within the
scenario for scope, evidence and remaining gates.

## Guardrails

- Setup stops healthy; only the presenter injects faults. Preserve bounded
  operations, enforced native human approvals, explicit undo and owned teardown.
- Observe unknown outcomes without replay; require fresh same-run evidence.
  Preserve deployed names and repository-root `.azure/<environment>/` ownership
  state until verified cleanup. Never commit secrets, live IDs or customer data.
- Keep runbooks reviewable, distinguish documented from live-verified behavior,
  and do not restore retired experiments as supported dependencies.
- Use human-reviewed PRs to `main`. Retailx `checkout-demo` issues instead target
  `demo/checkout`, changing routes only in
  `scenarios/retailx/infra/checkout/price-routes.json`. Preserve reviewer/branch
  gates and immutable baseline tags.
