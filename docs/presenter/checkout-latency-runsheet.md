# Presenter runsheet: checkout latency in Belgium

Target: about 12 minutes live, plus alert wait. Use with
[the scenario guide](../checkout-latency-scenario.md). Commands use PowerShell
from the repository root.

```powershell
$sub = '<subscription-id>'; $envName = 'checkout01'
```

## Before the session (T-30 min)

1. Start the datacenter VM. A subscription policy may deallocate it overnight;
   without it there is no store traffic.

   ```powershell
   az vm start -g "rg-retailtx-checkout-$envName-swedencentral" -n "vm-rtx-erp-$envName" --subscription $sub
   ```

2. Wait about 4 minutes, then run
   `./scripts/Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName`.
   Continue only when `ready` is `True`, both routes are `primary`, and BE and
   NL p95 are around 100 ms. If a route is not `primary`, run `Undo` and wait
   5 minutes.
3. Open these tabs, all in resource group `rg-retailtx-checkout-<env>-swedencentral`:
   - Application Insights `appi-retailtx-checkout-<env>`: Application map and Performance.
   - Azure Monitor → Alerts, filtered to the resource group.
   - Observability Agent `oba-retailtx-checkout-<env>` (Azure Monitor).
   - SRE Agent `sre-retailtx-checkout-<env>` portal (incident list).
   - Your mailbox (alert and Observability Agent emails).
4. Optional: stop other SRE Agents so only one agent is visible. Ignore older
   SRE threads; use only the new incident thread.

## Step-by-step rehearsal

Timings are from the tested run; T is the moment you start step 2.

| Step | When | Command or action | Check | Expected |
|---|---|---|---|---|
| 1. Baseline | T-1 min | Open Performance in Application Insights. | Application Insights | BE and NL checkout duration about 100 ms. |
| 2. Inject | T+0 | `./scripts/Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName $envName` | Terminal | BE routed to `legacy-price-gateway` with change `CHG-1042`; web app restarts for about 1 minute. |
| 3. Alert | about T+3 | Wait; present the architecture slide. | Azure Monitor → Alerts | `alert-checkout-latency-<env>` fired with `country=BE`. |
| 4. Observability Agent | T+3 to T+7 | Open the fired alert and start an investigation, or ask *Why are checkout transactions slower in Belgium this morning?* | Observability Agent | BE p95 up, NL unchanged, `legacy-price-gateway` dependency, correlated change. |
| 5. SRE Agent investigation | T+4 to T+8 | Open the new incident thread. | SRE Agent incident list | Symptom BE only, dependency `legacy-price-gateway`, setting `PRICE_ROUTE_BE` with `CHG-1042`, no failures, proposed `az webapp config appsettings set ... PRICE_ROUTE_BE=primary`. |
| 6. Approve | about T+9 | Reply *Approved, run the proposed rollback.*, then click **Approve** on the pending action card. | SRE Agent thread | Action moves from pending to running/completed. |
| 7. Recovery | T+12 to T+14 | Wait 3-5 minutes; optionally rerun `Ready`. | SRE Agent thread; terminal | Agent confirms BE p95 below 300 ms with fresh telemetry and writes the incident note; `Ready` shows `ready : True`. |
| 8. Reset | after the run | `./scripts/Invoke-CheckoutDemo.ps1 Undo -SubscriptionId $sub -EnvironmentName $envName` | Terminal | Both routes `primary`. Wait about 5 minutes before the next `Inject`. |

Fallbacks:

- No SRE incident thread within 5 minutes of the alert: open a new thread with
  the investigator `retailtx-checkout-<env>` and ask the same question.
- Approval card does not work: run `Undo` and say "here the operator executes
  the proposed fix."
- `Ready` reports no fresh telemetry: the VM is probably deallocated; start it
  and wait 4 minutes.

## Live talk track (about 12 minutes)

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
