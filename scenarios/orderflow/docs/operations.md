# OrderFlow operations

## Provision once

Use PowerShell 7.2+, Azure CLI/Bicep and a Python 3.11 validation environment.
Sign in to the intended subscription. Choose a new environment identifier.
Run from the repository root with your own non-secret values:

```powershell
$subscription = '<subscription-guid>'
$environment = 'orders01'
$presenter = '<presenter-object-guid>'
$cidr = '<presenter-public-ip>/32'
$publicKey = '<absolute-path-to-ssh-public-key>'
$script = '.\scenarios\orderflow\scripts\Invoke-OrderFlow.ps1'

& $script Up -EnvironmentName $environment -SubscriptionId $subscription `
    -Location eastus2 -PresenterCidr $cidr -SshPublicKeyPath $publicKey `
    -AdminObjectId $presenter
& $script ConfigureSre -EnvironmentName $environment -SubscriptionId $subscription
& $script Ready -EnvironmentName $environment -SubscriptionId $subscription
```

`Up` records ownership before creating resources, deploys Bicep, publishes the
portal and checks real dependency health. VM cloud-init installs the pinned
runtime and seeds only synthetic products through Cosmos data-plane access.
Startup and identity propagation can take time: a failed health check is not
permission to inject a fault. Rerun `Ready` once startup has settled.

The portal URL and owned resource IDs are in
`.azure/orderflow/<environment>/ownership.json`. Keep this directory private,
ignored and backed up. Do not commit its state, public-key material or raw
operational receipts. Do not share one environment between concurrent operators.
No lifecycle workflow copies ownership state into public Actions artifacts.

## Lifecycle boundaries

| Action | Behavior |
|---|---|
| `Up` | New generation only; refuses existing state/resources |
| `Publish` | Publishes only original app/infra digest after a completed provisioning observation |
| `ConfigureSre` | Applies owned investigator, exact Review response plan and approval policy |
| `Ready` | Checks fresh health, exact baseline and SRE readiness without fault injection |
| `Fault` | Once per generation; changes only owned rule access/description |
| `Observe` | Reads rule and fresh health; saves bounded observations, never replays a write |
| `Undo` | Explicit presenter fallback, never attributed to SRE |
| `Verify` | Baseline plus fresh successful probes and a new confirmed order |
| `Down` | Settled agent, owned inventory, exact custom-role removal and one group deletion request |

Commands that mutate support `-WhatIf` and confirmation. `-Confirm:$false`
belongs only in an explicitly authorized invocation; it is not SRE approval.

## Unknown outcomes and partial setup

The lifecycle records a pending operation **before** mutation. A CLI timeout
does not prove that Azure stopped working.

- If deployment is pending, `Observe` reads that exact deployment and records
  outputs only after `Succeeded`. Then explicitly `Publish`.
- If group creation lost its response, `Observe` verifies the exact ownership
  tags and admits cleanup only. It never silently continues provisioning.
- For terminal `Failed`/`Canceled` deployments, `Observe` first checks all
  deployment operations are terminal and discovers only matching owned partial
  resources and the exact repair role. It admits `Down` only, never a replay.
- If an SRE configuration PUT loses its response, `Observe` compares the exact
  journaled payload with the provider. Only after that stage matches can
  `ConfigureSre` continue; completed matching stages are not rewritten.
- If a fault/undo is pending, `Observe` checks the exact generation-bound rule,
  its terminal state and propagation, including after a lost response. It never
  issues the mutation again. A mismatch remains unknown, not permission to retry.
- A publication timeout requires operator inspection of the original Azure operation.
  Preserve state and receipts. Do not clear the pending flag to make a retry
  pass. Resolve the original operation before a reviewed recovery change.
- A failed/in-progress deployment is not replayed with `Up`; inspect the
  deployment operations and use owned cleanup after terminal failure.

The one-fault limit prevents a delayed approval from an old incident repairing
a new fault. Use a fresh environment for the next rehearsal. Do not add a
generic Reset loop that quietly reuses stale approvals.

## Teardown

Reject any unneeded pending approval in the native SRE UI and wait for active
execution to settle. Then:

```powershell
& $script Down -EnvironmentName $environment -SubscriptionId $subscription
& $script Observe -EnvironmentName $environment -SubscriptionId $subscription
```

`Down` refuses unowned inventory and does not retry unknown deletion. It removes
the exact custom-role assignment/definition before requesting group removal.
Cleanup is three explicit stages: assignment deletion, role-definition deletion,
then group deletion. After each `Down`, run `Observe` to verify absence; repeat
`Down` only when instructed to advance to the next distinct stage. This is not
a retry of the previous deletion.
Keep the manifest until `Observe` verifies group absence. The manifest is
retained as a retired receipt rather than automatically deleted.

SRE Agent deletion can fail at the provider. A Failed provisioning state is not
proof that the agent is stopped or free. Inspect the provider outcome; never
recreate resources, broaden permissions or repeatedly delete automatically.
See the existing separate Retailx cleanup issue
[#80](https://github.com/rutgerpels/azure-agentic-ops/issues/80) for context; it
does not authorize this scenario to touch those resources.

## References and limits

- [NSG connection semantics](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview):
  rules apply to new connections; the application deliberately avoids reuse.
- [SRE tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies):
  allow overrides Ask and hooks can override policy; readiness rejects hooks
  and permission overrides. Never approve "allow for thread."
- [SRE API reference](https://learn.microsoft.com/azure/sre-agent/api-reference):
  separate data-plane audience and evolving API schemas.

SRE ARM uses `2026-01-01`, matching this repository's current integration.
Some public API documentation still describes older preview versions. Data
plane schemas, empty-list envelopes, exact-rule RBAC acceptance and alert
intake must be live-verified. Unsupported responses fail closed rather than
being treated as an empty list or a successful setup.
