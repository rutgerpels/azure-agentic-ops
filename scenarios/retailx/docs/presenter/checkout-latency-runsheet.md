# Presenter runsheet: one checkout platform, two incidents

Use with [the scenario guide](../checkout-latency-scenario.md) and
[the interactive architecture diagram](checkout-architecture.html). If asked
whether the Observability Agent can feed the SRE Agent, use
[the hand-off diagram](observability-sre-handoff.html).
Commands use PowerShell from the repository root.

**Acceptance status:** the earlier latency rehearsal passed with a human
approval. Human-approved service repair through Arc also passed on 2026-10-16:
the service recovered about 19 seconds after approval and both countries
resumed successful checkouts. The presenter subsequently reported successful
latency recovery in the same deployment; that final approval/thread evidence
was not independently captured. Reverse-order sequencing and the revised
nonblocking service submission still need their next rehearsal. The checkout
fixture was then torn down with no active owned resources or external grants
remaining; deploy it again before the next rehearsal.

```powershell
$sub = '<subscription-id>'
$envName = 'checkout01'
```

## Dashboard-only rehearsal

To show latency and alerts without spending credits on investigations, use the
[fresh `Up -AlertsOnly` profile](../checkout-latency-scenario.md#dashboard-rehearsal-without-agents),
without `-WithArc`. This profile provisions no SRE or autonomous Observability
Agent, response plans or readiness tasks. The agent-led sections below do not
apply to it.

Open the Log Analytics workspace's **Workbooks**, then **RetailTx
&lt;environment&gt;: checkout health**, alongside the web till and Azure Monitor
Alerts. Run `Ready`, then explicitly `Inject -Scenario latency`. Refresh to show
BE p95 increasing while NL stays fast, the price dependency, success rate and
sample volume. Allow for telemetry delay and the app restart; gaps are not
healthy evidence. Reset explicitly with `Undo -Scenario latency`, then wait for
fresh recovery samples, natural alert clearance and `Ready`. There is no agent
repair or timed recovery. Use the normal owned `Down` after the rehearsal.
Portal rendering and this alerts-only lifecycle still need live rehearsal.

## Prepare, without an audience

1. Deploy the combined profile with `Up -WithArc`, then `ProbeArc` and
   `PrepareArc`, following the scenario guide. Keep its `.azure` ownership
   manifest. Do not add a second VM or re-enable the native Azure guest agent.
2. If the backing VM was deallocated, start it with `az vm start`. This is
   hardware lifecycle, not the incident repair. Arc should reconnect and the
   service observer should resume. A retained manual fault does not clear on
   boot.
3. Run the shared readiness gate:

   ```powershell
   .\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
   ```

   Continue only when `ready` is `True`: both primary routes, fresh successful
   BE/NL checkouts, healthy Arc service, correct Review plans/tools/policy, no
   unsettled command or action card, and previous alerts naturally resolved.
   Missing or stale telemetry is unknown, not healthy.
4. Open the web till, Application Insights, Azure Monitor Alerts, the Arc
   machine and the SRE Agent portal. The Observability Agent is optional;
   it is not a required handoff before SRE.
5. Use one presenter console and one current SRE incident thread. Verify the
   human approver can reach the native action card. Never approve through an
   automation API or select allow-for-thread.

## Choose either incident

The order is a presentation choice. Neither command starts the other fault.
Do not run the two injections together.

### A. Shared price service unavailable

For the copy-and-paste commands, browser actions, approval checks and reset,
follow the numbered
[service-stop walkthrough](../checkout-latency-scenario.md#service-stop-demo-step-by-step).
The table below is the short presentation reference. Preparation does not
include fault injection; the presenter explicitly starts the incident.

| Step | Presenter action | Story and expected evidence |
|---|---|---|
| Baseline | Pay at BE and NL tills. | Both countries use the same fast price service. |
| Inject | `.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName $envName -Scenario service` | A unique owner-bound Arc operation stops the actual primary price service. The fault persists until explicit repair/reset. |
| Customer impact | Try a basket in each country. | The page is still available, but checkout says **Not paid** and cannot verify prices. Keep a failed basket for the retry. |
| Detect | Open `alert-checkout-service-<env>`. | A shared failure-rate alert, not a VM-down alert. In the first rehearsal the native repair card was ready about 3 minutes 37 seconds after the service stopped. |
| Investigate | Follow the service incident in SRE. | Both countries fail on `erp-price-service`; the host is Connected, but its primary service is stopped. The latest service receipt binds the current run and original actor. |
| Approve | Review and approve the single native action card. | The readable command calls the guarded service controller through **Arc Run Command**. It does not restart the VM or change app routes. |
| Recover | Click **Try again** on the retained basket; follow SRE verification. | Fresh same-run service health, successful BE and NL checkouts and the SRE action identity establish recovery. SRE writes the incident note. |
| Ready again | Wait for natural alert clearance and run `Ready`. | Only now may the presenter explicitly select the other fault. |

Talk track: "The checkout page and the server are up, but the customer cannot
complete checkout. Arc lets the operations team inspect and manage the guest
service without treating a VM restart as the repair. The human approves the
proposed action; customer success, service health and the audit trail show
whether it worked."

### B. Belgium-only latency

| Step | Presenter action | Story and expected evidence |
|---|---|---|
| Baseline | Pay at `BE-101` and `NL-401`. | Both check out in roughly 0.1 seconds in the earlier rehearsal. |
| Inject | `.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName $envName -Scenario latency` | Only BE moves to the legacy gateway, with a new change reference. App Service briefly restarts. |
| Customer impact | After the restart, pay in each country. | BE takes about 2 seconds; NL stays fast. Both succeed. |
| Detect | Open `alert-checkout-latency-<env>`, `country=BE`. | Previously observed about 3 minutes after injection; telemetry and alert warm-up are separate from browser timing. |
| Investigate | Follow the latency incident in SRE. | Slow successful BE requests, `legacy-price-gateway`, unchanged NL and the current `ROUTE_CHANGE_REF`. No shared service repair is appropriate. |
| Approve | Review and approve the rollback card. | SRE restores only `PRICE_ROUTE_BE=primary`. |
| Recover | Pay in BE again; inspect fresh telemetry and incident note. | BE p95 below 300 ms over 3 minutes with sufficient requests; NL unchanged. |
| Ready again | Wait for clearance and run `Ready`. | No further incident starts until explicitly selected. |

Talk track: "This time nothing is down. One country takes a different backend
route, so customers wait. Same deployment, different evidence, different repair.
Arc remains available for host management, but a cloud configuration rollback
is the correct action."

### Optional: the morning readiness brief

Shows prevention: a scheduled, read-only SRE automation rates checkout
readiness before the stores open. Configuration is verified live; the brief's
output is not yet verified, so rehearse first.

| Step | Presenter action | Expected evidence |
|---|---|---|
| Show the automation | Open the SRE Agent scheduled tasks; show `<custom-agent>-readiness` (05:00 UTC, Review) and its read-only tool. | One schedule, one read-only agent; no write tools. |
| Run on demand during the latency fault | In SRE chat: `/agent <custom-agent>-readiness`. | `READINESS: RED`, BE route drift to `legacy` and high p95; NL healthy. |
| Run again after Ready | Repeat the command. | `READINESS: GREEN` with fresh samples, or AMBER when evidence is thin. |

Talk track: "Nobody had to remember to check. Every morning the agent gathers
the same evidence and tells the team green, amber or red. It recommends; humans
still approve any change."

## If the demonstration does not follow the expected path

- **Arc submission has an unknown result:** use `ObserveArc` to read the same
  command. Do not resend or create a second command. Delayed output is not proof
  that the guest action did not run.
- **SRE action output fails or lags:** let the agent query fresh service and
  checkout evidence. Say "verification pending" if evidence is missing. Do not
  reapprove a replacement command. The first repair succeeded even though the
  write tool reported Failed; the revised command submits with `--no-wait`.
- **Need operator recovery:** deny pending cards and wait for the SRE thread
  to settle, then run the matching `Undo -Scenario service` or
  `Undo -Scenario latency`. Say explicitly that the operator performed this
  reset; it is not an SRE-repair success.
- **No SRE incident:** investigate response-plan/intake readiness; do not
  create competing threads while the original may still be arriving.
- **Agent requests extra Azure authorization:** stop and investigate its
  command form or permissions. Permission consent is not repair approval.
  Log queries must use the workspace customer GUID.
- **The next injection is refused:** read the Ready blockers. Do not force
  the route, erase the manifest, disable an alert or bypass pending cards.

## After the session

Reset the recorded active scenario if retaining the environment, then verify
the common baseline. Otherwise remove the owned environment:

```powershell
.\scenarios\retailx\scripts\Invoke-CheckoutDemo.ps1 Down -SubscriptionId $sub -EnvironmentName $envName
```

Retention tags do not automatically stop or delete resources.

## Questions to expect

- *Is this really on-premises?* "It is an Azure-hosted hybrid simulation using
  Microsoft's evaluation-only Arc pattern. Azure owns the backing VM; Arc
  manages its guest. Real on-premises needs separate onboarding, connectivity
  and action validation."
- *Are BE and NL different Azure regions?* "No. They identify stores and
  business telemetry. Both use the same cloud app, network and backend host."
- *Can the agent execute anything on the server?* "The underlying Arc grant
  allows guest scripting on this one machine. Our approved path uses a
  current-run guarded controller and explicit tool policies. It is not a
  production service-only RBAC boundary."
