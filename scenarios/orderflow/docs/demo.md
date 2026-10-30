# Presenting and accepting OrderFlow

Open the portal beside the native SRE Agent UI. The portal reports customer
requests, not agent progress. Neither surface invents the other's state.

1. Run `Ready`. Wait for any startup alert to clear naturally; no existing
   active alert or pending SRE action may carry into fault admission.
   Load the catalogue and submit a synthetic order successfully.
   Explain that "portal online" and "order dependency healthy" are different.
2. Explicitly run `Fault`, then `Observe`. The portal stays open while real
   requests fail. Point out measured latency, timestamps and stale data.
3. Wait for the symptom alert and the owned Review-mode investigator. Azure
   Monitor ingestion/evaluation and SRE intake are not instantaneous; do not
   promise a fixed recovery duration.
4. Inspect the agent's evidence: failing requests, recent configuration change,
   actual NSG mismatch. Check the exact native approval card before approving.
   If no card appears, stop; textual assent is not a substitute.
5. After approved execution, watch fresh dependency requests recover. Submit
   a new order and use its request ID:

```powershell
& $script Verify -EnvironmentName $environment -SubscriptionId $subscription `
    -OrderRequestId '<new-confirmed-order-request-guid>'
```

If an order timed out, use its observation action, not another POST.
An unresolved order remains unknown, even when later probes succeed.
If the presenter uses `Undo`, label recovery "presenter fallback," not SRE.

## Acceptance evidence

Keep raw receipts private alongside ownership state. Record only sanitized
summaries in this repository.

| Gate | Required evidence |
|---|---|
| Healthy baseline | Real Cosmos-backed reads and confirmed synthetic order |
| Real degradation | Owned deny rule is Succeeded; fresh portal requests return dependency failures |
| Intake | Symptom alert and linked SRE incident, not merely a chat created by the presenter |
| Investigation | Telemetry and Azure Activity establish the actual changed rule |
| Native approval | Exact approval record predates exact repair execution |
| Attribution | Azure Activity caller matches the owned SRE action identity |
| Customer recovery | Restored baseline, three fresh probes and post-fault order receipt |
| Teardown | Independent group absence, owned custom role absence, retained receipt |

Offline tests prove contracts, not these Azure gates. No live gate is claimed
by the initial import. The permission setup in the
[GitHub guide](github-settings.md) is a prerequisite only for optional portal
publication; local cloud rehearsal still requires authorized Azure scope.
