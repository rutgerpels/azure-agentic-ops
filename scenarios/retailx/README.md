# Retailx: hybrid checkout continuity

A synthetic hybrid retail demo with one Azure web till, one simulated
on-premises price backend, Azure Monitor and a Review-mode Azure SRE Agent.
Retailx is the hybrid-cloud scenario in the
[Azure Agentic Ops demo collection](../../README.md), primarily for customer
conversations where Azure Arc manages on-premises services.

| Incident | Customer impact | Human-approved repair |
|---|---|---|
| `latency` | Belgian checkouts wait about two seconds; Dutch checkouts stay fast. | Restore the Belgian App Service price route to `primary`. |
| `service` | The shared price service stops; both countries cannot check out. | Start the exact price service through Azure Arc. |

The web till remains reachable during the service outage, preserves the basket
and allows retry. Purchases and store data are synthetic; no real payment occurs.
The backend is an Azure-hosted hybrid simulation, not a production on-premises
deployment. Network peering is not a VPN.

## Deploy and prepare

Requirements: PowerShell 7.2+, Azure CLI with Bicep, Python 3, `ssh-keygen`,
and an account that can create resource groups and role assignments.
Run from this repository's root with the intended Azure account signed in.

```powershell
$sub = '<subscription-id>'
$envName = 'checkout01' # Fresh, neutral name; 3-12 lowercase letters/digits.

# Deploy the app, monitoring, SRE configuration and daily readiness brief.
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Up -SubscriptionId $sub -EnvironmentName $envName -WithArc -AlertEmail '<alert-recipient>'

# Verify guest-command delivery, then install the guarded service controller.
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 ProbeArc -SubscriptionId $sub -EnvironmentName $envName
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 PrepareArc -SubscriptionId $sub -EnvironmentName $envName

# Wait for fresh telemetry and continue only when ready is True.
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
```

Deployment and preparation do not inject a fault. To check deployment integrity
without running an incident, complete these steps and then run **Tear down**.
If an Arc command is pending or its outcome is unknown, use `ObserveArc` on
the same environment rather than submitting preparation again.

Omit `-WithArc` for latency only and skip `ProbeArc`/`PrepareArc`. For a fresh
latency workbook/email-alert rehearsal without agents, use `-AlertsOnly`
instead; it cannot be combined with `-WithArc`.

## Run one incident

```powershell
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName $envName -Scenario latency
# Or select -Scenario service, never both at once.
# Review and approve the SRE Agent's exact native action card.
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
```

Repair and verify one incident, settle pending cards and wait for natural alert
clearance before explicitly starting the other. Faults persist until repair or
explicit undo; there is no timed or reboot recovery.

To abandon an incident, deny pending SRE cards, let the thread settle, and run
`Undo -Scenario <service|latency>` followed by `Ready`. This is operator recovery,
not evidence that SRE performed the repair.

## Tear down

```powershell
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Down -SubscriptionId $sub -EnvironmentName $envName
```

`Down` removes the owned environment, agent, scheduled brief and tracked
external configuration/grants. Keep the gitignored `.azure\<env>\` ownership
state, and use the same checkout until cleanup completes. Unknown operations
and residuals must be reconciled, not bypassed by deleting state.
The state remains at the repository root after this reorganization; existing
`retailtx-*` resource and service names are unchanged. See the
[migration notes](../../docs/scenarios.md#retailx-migration-and-compatibility).
Deployed resources and agent runs are billable; expiry tags are not automatic
teardown. Reusable GitHub/Copilot identities have their own separate lifecycle.

## Guides and extensions

- [Scenario guide and verification boundaries](docs/checkout-latency-scenario.md).
- [Presenter runsheet](docs/presenter/checkout-latency-runsheet.md) and
  [interactive architecture](docs/presenter/checkout-architecture.html).
- [SRE to GitHub Copilot code loop](docs/checkout-code-loop.md):
  sanitized RCA issue, reviewed change to `demo/checkout`, gated deploy/reset;
  never use `main` as the demo change target.
- [Copilot cloud-agent identity](docs/copilot-cloud-agent.md).
- [Checkout delivery plan](docs/implementation-plan.md).
- [Personal Teams pilot](docs/teams-pilot.md): optional fixture-first front door
  to the Foundry assistant, with independently scoped live checkout attachment.
  Basic conversations are retained; further enrichment is paused. Live
  SRE-progress reporting remains unverified, not a supported presenter capability.
- [Foundry incident assistant](docs/incident-management-agent.md): optional,
  read-only business assistant with its own lifecycle; attaches to a checkout
  deployment for live evidence. The basic question-answering scope is retained;
  broader acceptance remains deferred, with recorded evidence limits in its doc.

The standalone foundation, disk, native guest-repair and posting/backlog proofs
are retired from the active tree. Their evidence remains in Git history and
closed issues/PRs, not as supported fallback deployments.
