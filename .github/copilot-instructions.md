# RetailTx checkout continuity

This repository demonstrates two incidents on the same synthetic hybrid retail
checkout: Belgium-only latency and a shared Arc-managed price-service outage.
The README is the deployment entry point; `docs/implementation-plan.md` records
scope, remaining gates and parked extensions.

## Supported scope

- `app/checkout/frontend`: FastAPI web till on Azure App Service.
- `app/checkout/onprem`: primary/legacy price backends and BE/NL POS simulator
  on one private Azure VM representing an on-premises datacenter.
- `infra/checkout`: Bicep for the app, Arc, Monitor, workbook and SRE.
  `infra/azure-bootstrap-identity.bicep` is a required shared dependency.
- `scripts/Invoke-CheckoutDemo.ps1` and `scripts/checkout`: owned deployment,
  readiness, independent fault selection, operator undo and teardown.
- `scripts/Azure.Common.psm1`: shared Azure CLI, identity, state and payload helpers.
- `docs/agent-context/runbooks`: reviewed service-recovery and readiness knowledge.
- `tests/checkout` and `tests/Test-Checkout*.ps1`: retained offline contracts.

The SRE-to-GitHub-to-Copilot code loop is a supported optional checkout extension.
Issues labelled `checkout-demo` are demo work: target `demo/checkout`, never
`main`, and change intended routes only in `infra/checkout/price-routes.json`.
The real checkout-deploy and checkout-demo-reset workflows retain their human
reviewer and branch gates. Immutable baseline tags must never be moved.

The Foundry checkout incident assistant is unfinished and parked in draft PR #54
and issue #45. Preserve it without merging it into the core demo, resuming
development, provisioning it, or claiming working live integration.

Standalone Stage 0, native VM/guest proofs, Windows disk/IIS incidents, Service
Bus posting/backlog, and GitHub-to-SRE intake/probe experiments are retired.
Do not reintroduce those scenarios or make checkout depend on their history.

## Behavior and safety

- Only the presenter injects a fault. Deployment/preparation stops healthy.
- Select `latency` or `service` explicitly; never inject the next automatically.
  Recover, settle pending actions, verify fresh health and wait for natural
  Monitor clearance before admitting another incident.
- Fault lifetime is manual, including across reboot. Keep admission deadlines,
  bounded waits, allocation limits, ownership/source checks and explicit undo.
  The service observer reports health; it is not a recovery watchdog.
- SRE investigates and requests an exact native human approval card. Text assent
  is not approval. Review mode alone does not gate every external tool.
- Enforce action boundaries in the controller, scoped identities and tool policy,
  not just prose. Preserve current-owner/run/original-actor binding, source
  attestation, no-replay guards and independent Azure action attribution.
- Arc manages guest operations. Do not substitute native Compute Run Command
  for the Arc service repair or introduce another guest-command transport.
- Unknown command outcomes are observed, not automatically replayed. Delayed
  result visibility is not evidence that an action never executed.
- Require fresh same-run service and BE/NL customer evidence before declaring
  recovery. Report stale/missing evidence as unknown. Failed fast requests are
  not healthy checkout latency, and interrupted purchases are not lost revenue.
- Every deployment feature needs owned setup/readiness/reset/teardown behavior.
  Preserve non-secret ignored ownership manifests until verified cleanup ends.
  No budgets or automatic expiry are implemented.
- Azure-hosted on-premises infrastructure is an evaluation simulation; peering
  is not a VPN. Distinguish proposed, documented and live-verified behavior.

## Conventions

Keep the README short; detail belongs in `docs/`. Use stable component names and
neutral environment IDs such as `checkout01`; do not put stages or milestones in
new resource names. Preserve existing ownership and names rather than recreating
live resources for naming consistency.

Never commit live identifiers, credentials, customer/person/account names or raw
operational receipts. Use synthetic data and generic placeholders. Keep
`docs/agent-context/` changes reviewable.

Tests dot-source every `scripts/checkout/*.ps1` as a helper library. Executable
scripts with mandatory parameter blocks belong in `scripts/`, not that folder.
Use existing pinned dependencies and commands documented in the delivery plan.
Normal engineering changes target `main` through a human-reviewed PR; the
`checkout-demo` branch exception above applies only to the in-demo code loop.
