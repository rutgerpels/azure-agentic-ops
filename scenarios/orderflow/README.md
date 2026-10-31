# OrderFlow

Configuration drift with visible customer impact: a synthetic order desk stays
open while an NSG change breaks its private order API. Azure SRE Agent diagnoses
the evidence and requests native human approval before restoring the baseline.

This is an adaptation of Microsoft SRE Agent **Scenario C: Compliance Drift**,
not a verbatim import. See [provenance](docs/upstream.md).

## Options

| Option | Flow | Start here |
|---|---|---|
| **1. Direct repair** | Presenter injects NSG drift; SRE Agent restores the rule after native approval | This page |
| **2. GitOps** | A fault PR adds an NSG deny in Bicep; SRE Agent files an issue for the Copilot coding agent, which fixes it; Actions test the fix in a test environment before human merge and CD | [OrderFlow GitOps](gitops/README.md) |

The options are independent: separate resources, state and identities. The rest
of this page describes option 1.

## Architecture

```text
Presenter browser -> HTTPS App Service portal (presenter IPv4 CIDR only)
                          |
                          | VNet integration; new TCP connection per request
                          v
                    NSG -> private Linux VM order API -> Cosmos DB
                          ^
                          |
                 SRE Agent: read evidence, request native approval,
                 restore only the pre-existing API access rule
```

The VM has no public IP. A NAT gateway provides explicit outbound connectivity
for installation. Cosmos uses managed identity, disables keys and restricts
network access to the VM subnet. App Service and SCM are restricted to the same
presenter CIDR. No real payment, customer information or inventory accounting.

## Start here

- [Deployment, operation and teardown](docs/operations.md)
- [Exact GitHub settings for testing](docs/github-settings.md)
- [Demo script and acceptance gates](docs/demo.md)
- [Agent investigation runbook](docs/runbook.md)

Run all lifecycle commands from the repository root. State belongs under
`.azure/orderflow/<environment>/`; never reuse Retailx's state or resources.
Only the presenter injects a fault. A deployment permits one fault generation;
use a fresh environment for another rehearsal.

## Validation status

The import includes offline application and lifecycle contracts and Bicep
compilation. Azure deployment, region/SKU availability, native approval,
incident intake and real SRE recovery require an authorized live rehearsal.
Do not treat a successful local test or portal publication as cloud acceptance.

Azure resources remain billable until verified teardown: App Service, VM/disk,
NAT/public IP, Cosmos DB, telemetry and SRE Agent. No budget or automatic expiry
is implemented. SRE provider deletion failures must remain explicit and owned.
