# Presenter runsheet: checkout latency in Belgium

Target: about 12 minutes live, plus alert wait. Use with
[the scenario guide](../checkout-latency-scenario.md). Commands use PowerShell
from the repository root.

```powershell
$sub = '<subscription-id>'; $envName = 'checkout01'
```

## Before the session (T-30 min)

1. Run `./scripts/Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName`.
   Continue only when `ready` is `True`. If a route is not `primary`, run `Undo`
   and wait 5 minutes.
2. Open these tabs:
   - Application Insights `appi-retailtx-checkout-<env>`: Application map and Performance.
   - Azure Monitor → Alerts, filtered to the resource group.
   - SRE Agent `sre-retailtx-checkout-<env>` portal (incident list).
   - Your mailbox (alert and Observability Agent emails).
3. Optional: stop other SRE Agents so only one agent is visible.

## Live (about 12 minutes)

| # | Say | Do |
|---|---|---|
| 1 | "Belgian stores report slow checkouts. Nothing is down." | Show Performance: BE and NL checkout duration are both in the tens of milliseconds. |
| 2 | "A routing change happens on the front end, as it does on a normal morning." | Run `Inject`. The web app restarts for about a minute. |
| 3 | "We do not jump between tools. Azure Monitor detects it." | Wait for the alert `alert-checkout-latency-<env>` (dimension `country=BE`). Tested: about 3 minutes after Inject. Use the time for the architecture slide. |
| 4 | "Ask the Observability Agent the operator's question." | Open the fired alert and start an Observability Agent investigation, or ask: *Why are checkout transactions slower in Belgium this morning?* Show the findings: BE p95 up, NL unchanged, `legacy-price-gateway` dependency, correlated change. |
| 5 | "SRE Agent picked up the same alert and owns the response." | Open the SRE incident thread (it starts about 1-2 minutes after the alert and concludes in about 4 minutes). Walk through symptom, `legacy-price-gateway` dependency, route setting with reference `CHG-1042`, root cause and impact. |
| 6 | "It proposes one fixed action and waits for a human." | The agent ends with the exact command `az webapp config appsettings set ... PRICE_ROUTE_BE=primary` and asks for approval. Reply *Approved, run the proposed rollback.* The agent submits the command as a pending action; click **Approve** on the card. |
| 7 | "Recovery is proved with fresh telemetry, not alert state." | Wait 3-5 minutes. The agent verifies BE p95 below 300 ms and writes the incident note. |

If SRE does not start automatically, open a new thread with the investigator
`retailtx-checkout-<env>` and ask the same question. If approval is unavailable,
run `Undo` and say it explicitly: "here the operator executes the proposed fix."

## After the session

1. `./scripts/Invoke-CheckoutDemo.ps1 Undo ...` (safe to repeat).
2. `./scripts/Invoke-CheckoutDemo.ps1 Down ...`, or keep it and note the
   `expiresAt` tag.

## Questions to expect

- *Is this really on-premises?* "The backend is an Azure VM playing the
  datacenter, connected privately. Real on-premises needs site-to-site
  connectivity and, for host operations, Azure Arc, as in our Arc scenarios."
- *Could the agent fix it alone?* "Yes, in autonomous mode. Here we chose Review:
  the agent investigates and proposes, a human approves."
