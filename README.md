# Azure Agentic Ops demos

Reusable, named demos of Azure agentic operations for different customer
conversations. Each scenario owns its application, infrastructure, lifecycle,
tests and presenter material; only proven common utilities are shared.

## Scenarios

| Demo | Best fit | Start here |
|---|---|---|
| **Retailx** | Hybrid-cloud retail checkout with Azure Arc, Monitor and SRE Agent | [Deploy and present Retailx](scenarios/retailx/README.md) |
| **OrderFlow** | Visible order-service disruption from configuration drift, with approved SRE Agent repair | [Deploy and present OrderFlow](scenarios/orderflow/README.md) |

Retailx includes independent checkout latency and shared price-service incidents,
plus optional SRE-to-Copilot and read-only Foundry assistant extensions. Its
[delivery plan](scenarios/retailx/docs/implementation-plan.md) distinguishes
implemented capabilities, recorded live evidence and remaining acceptance gates.

## Repository layout

```text
scenarios/<demo-name>/  App, infra, scripts, tests, docs and scenario README
infra/                 Shared bootstrap identity module
scripts/               Shared Azure CLI, identity and ownership-state helpers
tests/                 Shared utility and repository-layout contracts
docs/                  Cross-scenario contributor guidance
.github/               Repository policy and GitHub Actions entry points
```

Choose a scenario first, then follow its README from the repository root.
See [scenario organization and contribution](docs/scenarios.md) before adding
another demo or changing shared tooling.

Only a presenter starts an incident. Deployment stops healthy; remediation
requires the scenario's explicit human approval gates. Demos incur Azure costs:
keep ignored ownership state until verified teardown completes. No automatic
expiry or budget enforcement is implemented.
