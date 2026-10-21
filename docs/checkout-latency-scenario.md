# Checkout continuity: Arc service outage and Belgium latency

> Status: **human-approved SRE-to-Arc service repair verified, 2026-10-16.**
> Both countries recovered after the approved service start. The presenter then
> reported a successful latency rehearsal in the same deployment. Reverse-order
> sequencing and the revised nonblocking CLI submission still need rehearsal.
> The checkout fixture was torn down after rehearsal. See
> [Verification](#verification) for the evidence boundaries.
>
> **2026-10-18:** a fresh Arc-profile dry-run independently verified the latency
> alert, native human approval, SRE identity's rollback and fresh recovery.
> Corrected approval guidance passed a second incident without steering.
> A subsequent fresh run verified the native-approved SRE GitHub issue, actual
> Copilot cloud-agent PR, human review/merge, gated drift Check/Apply, and
> populated reset without changing `main`. The issue draft and first code
> revision required review corrections. Post-reset readiness passed; the
> temporary fixture was torn down and residuals independently checked.
> One-time identity setup is retained. See
> [checkout code loop](checkout-code-loop.md) for evidence and remaining gates.

A small, disposable hybrid demo with two independently selected incidents:

> *Why can customers not check out? Or why are Belgian checkouts slow?*

Stores in Belgium (BE) and the Netherlands (NL) call a checkout front end in
Azure. Every checkout looks up the price on a simulated on-premises datacenter
host. A logged routing change sends Belgian price lookups to a slow legacy
gateway. Checkouts still succeed, but take seconds instead of milliseconds. NL
is the healthy control group.

With `Up -WithArc`, the **same backend VM** also hosts an Arc-managed service
incident: stopping the real primary price service makes checkout return HTTP
503 in both countries. The till remains reachable, shows **Not paid**, preserves
the basket and offers **Try again**. These are simulated purchases, not real
payments. There is no extra VM or separate front-end deployment.

| Selected scenario | Customer experience | Proposed SRE repair |
|---|---|---|
| `service` | Both BE and NL cannot verify prices; checkout fails. | Start the exact primary price service through Arc Run Command after human approval. |
| `latency` | BE still checks out, but waits about 2 seconds; NL stays fast. | Restore `PRICE_ROUTE_BE=primary` on App Service after human approval. |

Run either one first. Repair it, clear any pending action cards, wait for fresh
healthy evidence and natural alert clearance, then explicitly select the other.
No step injects the next fault automatically. Without `-WithArc`, a fresh
deployment retains the latency-only profile; an existing deployment cannot
switch guest management in place.

### Deployment propagation and failures

`Up` deploys the estate once, saves its outputs, then deploys the latency alert
separately. Azure Monitor can briefly reject a newly provisioned or restored
Log Analytics workspace with `BadRequest: The workspace could not be found`,
even after ARM reports workspace success. Only that exact failure on the
expected latency alert is retried automatically, up to six attempts with
15 seconds between attempts. Each alert deployment has a 120-second timeout
and each failure-inspection request a 30-second timeout. Each attempt persists
a unique deployment receipt before submission; retries require a terminal
failed parent and no unsettled child operations from that same attempt.
Historical failures cannot authorize a replay. Query validation remains enabled.
The estate and Arc bootstrap are never replayed by this retry loop.

Other failures stop immediately. Timeouts have an unknown Azure outcome and
are not retried automatically. On exhaustion or failure, ownership state is
retained and the error identifies the alert's deployment-operation command.
`Down` checks that this deployment is terminal before deleting owned resources.
Do not remove the manifest to bypass a failure; inspect the deployment first.
This addresses the observed propagation failure, not a guarantee against all
Azure deployment failures. Fresh-environment live acceptance remains required.
The diagnostic path uses Azure's documented
[deployment operations](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-history);
the alert retains the existing
[scheduled-query rule schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2023-03-15-preview/scheduledqueryrules).

## Dashboard rehearsal without agents

For a latency-only rehearsal that uses Azure Monitor alerts but **no SRE
investigation, remediation or scheduled brief**, create a fresh environment
with `-AlertsOnly`:

```powershell
$sub = '<subscription-id>'
$envName = 'checkout01'
.\scripts\Invoke-CheckoutDemo.ps1 Up -SubscriptionId $sub -EnvironmentName $envName -AlertsOnly
.\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
```

Supply `-AlertEmail` or `RETAILTX_ALERT_EMAIL` as usual. This mode omits both
SRE Agent and the autonomous Observability Agent, their identities and grants,
the subscription Monitor setting, and scheduled readiness automation. It retains
the application, load generator, telemetry, email action group and latency alert.
It avoids agent runs, not ordinary infrastructure and telemetry charges.
`-WithArc` and the service-stop scenario are not supported in this mode.
The existing agent-led deployment remains the default when the switch is omitted
on a fresh environment.

The choice is stored in the ownership manifest: subsequent `Up`, `Ready`,
`Inject`, `Undo` and `Down` reuse it without repeating the switch. Do not turn an
existing agent environment into alerts-only with an incremental deployment:
omitting agent resources would not delete them. Use its owned `Down` first,
then create the chosen mode. Likewise, changing back requires `Down` and a
fresh deployment. No lifecycle command stops or modifies unrelated agents.

All new checkout deployments include the **RetailTx &lt;environment&gt;:
checkout health** workbook, under the Log Analytics workspace's **Workbooks**.
`Up` and `Ready` return its `workbookId`. The workbook shows the last hour:
successful checkout p95 by country, price dependency p95 by country/backend,
checkout success rate and observed request volume, in one-minute buckets.
The dependency panel joins `OperationId` to checkout requests to obtain country;
it does not assume that dependency spans carry request attributes.
A separate table marks missing, thin or stale recent evidence as unknown.
Percentiles/rates have gaps below five observed samples per bucket. Counts are
observed telemetry, not authoritative sales totals.

Open the workbook and web till, then run the latency demo manually:

```powershell
.\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName $envName -Scenario latency
# Show slow BE checkout, unchanged NL, the charts, and the Azure Monitor alert.
.\scripts\Invoke-CheckoutDemo.ps1 Undo -SubscriptionId $sub -EnvironmentName $envName -Scenario latency
.\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
```

Refresh the workbook while presenting. Allow for ingestion delay and the short
App Service restart on route changes. The fault raises BE latency to a higher
level, not a gradual ramp; NL is the control. The alert does not reset the fault.
Wait for fresh post-reset samples and natural alert clearance before reusing it.
Alerts-only `Ready` checks email-only routing and absence of local autonomous
agents, and blocks injection if another subscription SRE Agent is active or not
confirmed stopped, because overlapping intake could still start investigations.
It does not change that agent or claim to isolate unrelated external automation.

The workbook and alerts-only lifecycle are repository implementations; live
portal rendering, query results and an alerts-only deploy/demo/reset/teardown
cycle still require rehearsal. No existing fixture was changed for this addition.
The workbook uses the supported
[programmatic workbook deployment](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-automate)
model, not a new agent integration.

## Architecture

An interactive version with explanations per component and an incident
walkthrough is in
[presenter/checkout-architecture.html](presenter/checkout-architecture.html).

```text
pos-sim (dc1 VM, BE + NL stores) --HTTPS--> checkout-web (App Service, Azure)
                                                 | private VNet peering
                                                 v
                          dc1 VM: erp-price-service :8080   (~30 ms)
                                  legacy-price-gateway :8081 (~1.4-2.2 s)
```

| Component | Where | Role |
|---|---|---|
| `checkout-web` | App Service B1 (Linux, Python) | Checkout API. Per-country route from app settings `PRICE_ROUTE_BE` / `PRICE_ROUTE_NL` (`primary` or `legacy`) and `ROUTE_CHANGE_REF`. |
| Web till | Same App Service, `https://<web app>/` | Customer-facing self-checkout page. Paying sends one `POST /checkout` per basket line with `channel=web` and shows the wait time on a receipt. Browser telemetry (page view, AJAX timings, `till-checkout` event) goes to the same Application Insights. |
| `erp-price-service` | dc1 VM, port 8080 | Normal ERP price lookup. |
| Azure Arc | Same dc1 VM, with `-WithArc` | Connected Machine agent, Arc-managed Azure Monitor Agent, service observations and guest Run Command. The Compute resource remains the backing hardware; it is not the repair channel. |
| `legacy-price-gateway` | dc1 VM, port 8081 | Legacy price validation. Slow by design. |
| `pos-sim` | dc1 VM | One BE and one NL checkout about every 3 seconds. |
| Application Insights + Log Analytics | Azure | Requests carry `retail.country`, `retail.store`, `retail.price_route` and `retail.channel` (`pos` or `web`). Dependency targets are `erp-price-service` or `legacy-price-gateway`. A startup trace records the route table and change reference. |
| Alert `alert-checkout-latency-<env>` | Azure Monitor | Successful checkout p95 above 1 s with at least 5 requests in 5 minutes, split by country. Evaluated every minute. |
| Alert `alert-checkout-service-<env>` | Azure Monitor, Arc profile | At least 5 checkout requests and at least 20% failures in 5 minutes. One shared incident; investigate impact by country. |
| Observability Agent | Azure Monitor (West Europe) | Monitors Application Insights and the Log Analytics workspace. Built in autonomous mode: alert-driven issue creation and investigation with email to the action group. The presenter can also start an investigation on demand. Read-only. |
| SRE Agent | Sweden Central | One agent, separate workspace-scoped Review response plans: `retailtx-checkout-<env>` and `retailtx-checkout-<env>-service`. Explicit CLI tool and approval policies, site-scoped Website Contributor, and (Arc profile) an exact-machine guest-command grant plus subscription Monitoring Contributor. |

The App Service reaches the dc1 VM through regional VNet integration and VNet
peering. Peering stands in for site-to-site connectivity; it is not a VPN.
The VM has no public IP; its outbound traffic (pos-sim, packages) uses a NAT
gateway. The backend NSG only accepts ports 8080-8081 from the App Service
integration subnet.

## Fault and remediation

### Service unavailable

`Inject -Scenario service` admits a unique run only from the common healthy
baseline and stops `retailtx-price-primary.service` through Arc. A protected,
owner-bound controller records intent before the stop. The fault has **manual
lifetime**, including across reboot: the boot guard preserves the stop and the
30-second observer only reports health. Neither is a recovery watchdog.

The service investigator correlates failed requests, the shared dependency,
Arc connectivity and fresh service observations. Its proposed Arc command
contains the current run and original actor. A real human approval card must
precede execution. The controller rejects stale/replayed repairs and validates
protected sources; Azure Activity Log establishes the actual action identity.
Fresh same-run service health and successful BE **and** NL checkouts establish
recovery. The browser can retry the retained basket.

The operator fallback is `Undo -Scenario service`, after denying pending SRE
cards and allowing the thread to settle. It is explicitly an operator reset,
not evidence that SRE performed the repair.

#### Service-stop demo: step by step

Use this walkthrough after `Up -WithArc`, `ProbeArc` and `PrepareArc` have
completed. **Preparation stops at the healthy baseline. Only the presenter
runs step 3 when ready to start the live incident.** These instructions do
not require the GitHub code loop or Foundry assistant.

1. **Load the prepared environment and check readiness.** Open PowerShell in
   the repository root and read the existing ownership manifest:

   ```powershell
   $envName = 'checkout01'
   $state = Get-Content ".azure\$envName\checkout-state.json" -Raw | ConvertFrom-Json
   $sub = $state.subscriptionId
   $checkoutUrl = $state.outputs.webAppUrl
   .\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
   ```

   Continue only when `ready` is `True` with no blockers. Both routes must be
   `primary`, the price service healthy, and Arc Connected. Leave any
   unresolved action cards or commands settled before starting.

2. **Show the healthy customer experience.** Open `$checkoutUrl` in the
   browser. Select store `BE-101`, add items and pay. Repeat with `NL-401`.
   Both should succeed quickly. In the Azure portal, keep the deployment's
   Application Insights, Azure Monitor Alerts, Arc machine and SRE Agent
   available in separate tabs.

   Say: "Both countries use the same on-premises price service. The website
   runs in Azure; the backend is managed through Arc."

3. **Start the service-stop incident, once.** Only when the live demonstration
   should begin, run:

   ```powershell
   .\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName $envName -Scenario service
   ```

   This stops `retailtx-price-primary.service` through Arc, not the VM or
   App Service. The fault persists until explicit repair. Do not run the
   latency injection or repeat this command. If the command outcome is
   UNKNOWN, observe the same operation:

   ```powershell
   .\scripts\Invoke-CheckoutDemo.ps1 ObserveArc -SubscriptionId $sub -EnvironmentName $envName
   ```

   Do not continue as if the stop were confirmed until its result is known.

4. **Show the business impact.** Attempt checkout at BE and NL. The page
   remains reachable, but price verification fails and the till shows
   **Not paid**. Keep one failed basket open for the recovery step; do not
   refresh it away.

   Say: "The server and website are up, but customers in both countries
   cannot complete this simulated checkout. This is a shared application
   dependency failure, not a VM-down incident."

5. **Follow detection into SRE.** In Azure Monitor Alerts, look for
   `alert-checkout-service-checkout01` (substitute your environment suffix).
   Open the corresponding service incident in the deployed SRE Agent. Allow
   time for telemetry, alert evaluation and investigation; the first
   rehearsal reached a repair card in about 3 minutes 37 seconds, not a
   guaranteed deadline. Do not create a competing incident while automatic
   intake may still be arriving.

   Show SRE correlating failed BE/NL checkouts with `erp-price-service`,
   an Arc host that is still Connected, and a fresh stopped-service
   observation for the current run. The Observability Agent is optional,
   not an extra approval or handoff required before SRE.

6. **Review and approve the proposed repair.** Wait for the native SRE action
   card. Check that it targets the exact Arc backend and uses the guarded
   service controller to start the primary price service, with the current
   fault run and original actor. It must not restart the VM, change routes
   or target another machine. If the action does not match, do not approve it.

   Approve only that action through the human approval card. Do not choose
   allow-for-thread or switch the agent out of Review mode.

   Say: "The agent has identified the failed service and proposed a scoped
   repair. A human reviews the action before it executes."

7. **Demonstrate and verify recovery.** On the retained basket, click
   **Try again**, then confirm a successful checkout in the other country.
   Follow SRE's fresh same-run healthy service observation and successful
   BE and NL checkout evidence. Check the action identity in Azure Activity
   Log and show the incident note.

   A cleared alert or a successful tool message alone is not recovery proof.
   If command output lags or reports failure, let SRE inspect fresh evidence;
   do not approve a replacement action merely because output is delayed.
   Say "verification pending" when evidence is still missing.

8. **Return to a clean baseline.** Let the alert resolve naturally and wait
   for the SRE thread and pending actions to settle, then run:

   ```powershell
   .\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
   ```

   Continue to another incident only when `ready` is `True` with no blockers.
   The latency scenario does not start automatically.

#### Operator fallback if SRE repair cannot complete

Deny pending repair cards and wait for the SRE thread to settle. Resolve any
pending presenter Arc command with `ObserveArc`; never submit a replacement
for an unknown operation. Then explicitly reset the recorded service fault:

```powershell
.\scripts\Invoke-CheckoutDemo.ps1 Undo -SubscriptionId $sub -EnvironmentName $envName -Scenario service
.\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName $envName
```

If Ready reports stale telemetry or unresolved alerts, wait for fresh evidence
and check again; do not weaken its gates. Tell the audience that the operator
performed the reset, not SRE. If an operation remains unknown, stop and use the
documented lifecycle recovery rather than direct service or VM commands.

### Belgium latency

| Step | Mechanism |
|---|---|
| Fault | `Inject -Scenario latency` sets `PRICE_ROUTE_BE=legacy` and a unique `ROUTE_CHANGE_REF=CHG-<run>` on the web app. This is a real Activity Log configuration change. Manual lifetime: no timer, no auto-recovery. |
| Signal | BE checkout p95 rises above 1 s; NL stays fast. BE dependencies switch to `legacy-price-gateway`. The alert fires for `country=BE`. |
| Proposed action | SRE Agent proposes exactly `az webapp config appsettings set ... --settings PRICE_ROUTE_BE=primary` and waits for approval. |
| Approval | A human approves the pending action in the SRE Agent portal. |
| Verification | The investigator checks fresh BE p95 below 300 ms with at least 5 requests over 3 minutes, `erp-price-service` as the BE dependency, and NL unchanged. An alert clearing alone is not proof. |
| Manual undo | `Undo -Scenario latency` restores `primary` and `baseline` for the recorded fault. Deny pending SRE cards and wait for the thread to settle first. |

The app setting change restarts the web app for roughly a minute. Expect a
short gap in telemetry after both the fault and the rollback.

## Lifecycle

Requirements: PowerShell 7.2+, Azure CLI with Bicep, Python 3, `ssh-keygen`,
and an account that can create resource groups and role assignments.

```powershell
$sub = '<subscription-id>'
.\scripts\Invoke-CheckoutDemo.ps1 Up -SubscriptionId $sub -EnvironmentName checkout01 -WithArc -AlertEmail '<alert-recipient>'
.\scripts\Invoke-CheckoutDemo.ps1 ProbeArc -SubscriptionId $sub -EnvironmentName checkout01
.\scripts\Invoke-CheckoutDemo.ps1 PrepareArc -SubscriptionId $sub -EnvironmentName checkout01
.\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName checkout01
.\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName checkout01 -Scenario service
# Human approves the SRE action; then wait and run Ready.
# Alternatively, deny pending cards and use the matching operator Undo.
.\scripts\Invoke-CheckoutDemo.ps1 Undo -SubscriptionId $sub -EnvironmentName checkout01 -Scenario service
.\scripts\Invoke-CheckoutDemo.ps1 Ready -SubscriptionId $sub -EnvironmentName checkout01
.\scripts\Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName checkout01 -Scenario latency
.\scripts\Invoke-CheckoutDemo.ps1 Undo -SubscriptionId $sub -EnvironmentName checkout01 -Scenario latency
.\scripts\Invoke-CheckoutDemo.ps1 Down -SubscriptionId $sub -EnvironmentName checkout01
```

- **Up** deploys [`infra/checkout/main.bicep`](../infra/checkout/main.bicep),
  publishes the front end, creates the SRE investigator and the Review-mode
  response plan, and records non-secret state in `.azure/<env>/` (gitignored,
  including the break-glass SSH key). Re-running Up is blocked during a fault
  or unknown Arc operation. In Arc mode it removes the temporary onboarding
  identity after registration and applies Arc monitoring/command permissions.
- **ProbeArc** is a read-only delivery/posture gate, not remediation.
  **PrepareArc** installs the immutable controller only after that gate passes.
  Skipping preparation fails Ready. These explicit steps keep an enrollment
  success from being mistaken for proven guest command delivery.
  Both commands report `succeeded=True` for the completed setup step,
  `preparationComplete`, and `nextAction`; readiness is explicitly **not
  evaluated**. Run the separate `Ready` command, wait for fresh telemetry, and
  proceed only when it returns `ready=True`. Preparation success is not a
  healthy-environment assertion.
  Raw guest stdout/stderr remain in the gitignored manifest's command receipt,
  not an ambiguous `error` output field. For example, `systemctl` may write
  `Created symlink ...` to stderr while exiting successfully; the script
  requires successful execution and exit code zero before reporting success.
  Repeated `PrepareArc` reuses the recorded controller installation without
  submitting another guest command (`alreadyPrepared=True`); immutable source
  changes require a fresh environment rather than an in-place replacement.
  An existing unknown command still blocks reuse. Use `ObserveArc` to read
  **that same command**, never rerun preparation or delete its journal to
  bypass it. Observing a successful probe or installation also records the
  completed setup flag, so the original caller need not be replayed.
- **Ready** requires fresh BE and NL telemetry with p95 below 500 ms, both
  routes on `primary`, the alert enabled, the SRE Agent Running in Review mode,
  correct response plans, investigator instructions, explicit CLI-only tools
  and approval policy, including the live action identity's owner and principal.
  Both ARM settings and the running app must report primary routes. Fault
  retirement uses only checkout samples newer than the observed rollback or
  same-run service recovery, never pre-fault samples. Arc mode also requires fresh healthy service evidence,
  a Connected Arc host, no native VM extensions and no pending Arc command.
  Prior checkout alerts in this deployment generation must resolve and their
  SRE threads/actions must settle. Retained alerts from a deleted generation
  with the same resource names are excluded by the recorded creation boundary.
  Ready retires a fault only after the common baseline is verified.
  It warns when other SRE Agents are running.
  A DNS, connection/TLS failure or timeout reaching the checkout health endpoint
  from the operator's machine reports `ready=False` with a connectivity blocker.
  Independent telemetry checks still run, but cannot replace the missing live
  health check. No new fault is injected and an existing fault is not retired.
  Check connectivity and rerun `Ready`; do not rebuild or change routes solely
  because of a temporary hostname-resolution failure.
- **Down** removes the subscription-scope Observability Agent reader grant and
  the subscription default Azure Monitor workspace setting (only when this
  environment created it and it still points to its own workspace), deletes the
  resource group and deployment records, and removes the ownership manifest.
  Arc mode also removes its exact custom command role and subscription SRE
  monitoring grant. Failed deletion retains state for retry; partial deployment
  outputs are recovered before scope-external cleanup. Normal Azure soft-delete
  and data-retention behavior still applies.
  Deployment-history deletion is asynchronous: `Down` submits one deletion per
  owned subscription record, then checks for absence up to twelve times,
  five seconds apart (plus the existing bounded HTTP request timeouts).
  It does not resubmit deletion while waiting. API errors or exhausted
  verification retain the manifest; a later `Down` resumes the remaining work.
  See Azure's [deployment-history deletion API](https://learn.microsoft.com/en-us/rest/api/resources/deployments/delete-at-subscription-scope).

Down refuses nonterminal deployments. Missing outputs are not evidence that
no grant was created: it also reconciles exact subscription grants using the
owned identity, role and scope through
[Role Assignments - List For Subscription](https://learn.microsoft.com/en-us/rest/api/authorization/role-assignments/list-for-subscription?view=rest-authorization-2022-04-01).

The Python compatibility entry point `chaos\checkout_latency.py` delegates to
this same lifecycle and accepts `--scenario service|latency`; latency remains
the default. Do not bypass the lifecycle with direct fault writes. The local
operation lock serializes one presenter workspace; it is **not a distributed
multi-operator lock**. Use one presenter, one owned state directory and no
parallel fault consoles. Preserve that manifest for reset and teardown.

Every Arc PUT is journaled before submission and sent once. If observation
times out, use `ObserveArc` to read the same command. UNKNOWN is not failure
and must never cause a replacement command. An expired admission that never
created a guest marker may require teardown rather than a fabricated reset.

The resource group is tagged `demo=retailtx`, `environmentId`,
`profile=checkout-latency`, `managedBy=invoke-checkoutdemo` and `expiresAt`.
There is no automatic expiry; run Down after the session.

The declared routes live in `infra/checkout/price-routes.json`. The optional
GitHub follow-up (`ConfigureFollowUp`), gated route deploy and demo branch reset
are described in [checkout-code-loop.md](checkout-code-loop.md).

### Readiness brief (scheduled SRE automation)

A daily SRE Agent scheduled task shows how automation keeps the workload
healthy *before* customers notice. Every day at 05:00 UTC, the read-only
custom agent `<custom-agent>-readiness` checks the checkout chain. It reports
one line `READINESS: GREEN|AMBER|RED`, an evidence table and at most three
recommended next steps.

| Check | Evidence |
|---|---|
| Checkout health per country | `AppRequests` p95, failures and volume: last hour against the previous 23 hours. Fewer than 5 checkouts is never rated healthy. |
| Price dependency | `AppDependencies` target per country (`erp-price-service` or `legacy-price-gateway`). |
| Route drift | The live `PRICE_ROUTE_BE`, `PRICE_ROUTE_NL` and `ROUTE_CHANGE_REF` app settings compared with the declared `primary`/`primary`/`baseline`. |
| Alerting coverage | The checkout alert rules are enabled. |
| Arc host (Arc profile only) | Arc connection status and the latest price-service observation in `Syslog`. |

- **Guardrails:** the agent has only `RunAzCliReadCommands`, and the task runs in
  Review mode. The instructions forbid write tools and approval requests, and
  treat log content as data. The brief recommends; repair stays with the
  incident flow and its human approval.
- **Setup:** Up, PrepareArc and ConfigureFollowUp configure the agent and task
  as part of SRE configuration. For an environment deployed before this
  feature, run `ConfigureReadiness` once (refused during an active fault).
- **Ready** blocks when the agent or task is missing or drifted: extra tools,
  changed instructions, schedule or prompt, not in Review mode, paused, or
  repeatedly failing.
- **Teardown:** Down deletes the resource group, which removes the SRE Agent
  with its custom agents and scheduled tasks.
- **Demo moment:** inject `latency`, then run the brief on demand in SRE chat
  with `/agent <custom-agent>-readiness`. Expect RED for BE route drift and
  latency, with NL as the healthy control. Undo, wait for fresh samples and
  run it again for GREEN.
- **Cost:** every run consumes SRE Agent active units (AAUs). Pause or remove
  the task when the environment is retained without use.

```powershell
.\scripts\Invoke-CheckoutDemo.ps1 ConfigureReadiness -SubscriptionId $sub -EnvironmentName checkout01
```

The task uses the v2 scheduled-task API (`/api/v2/extendedAgent/scheduledtasks/{name}`)
following Microsoft's [SRE Agent samples](https://github.com/microsoft/sre-agent).
See [scheduled tasks](https://learn.microsoft.com/en-us/azure/sre-agent/scheduled-tasks).

### Shortcuts and limits (demo, not production)

- Public endpoints for the web app, Application Insights, Log Analytics and the
  SRE Agent. No private endpoints or VNet-injected agent.
- Application Insights uses its connection string (local authentication). The
  web till exposes it to the browser through `/api/config`, as browser
  telemetry requires; it permits ingestion only.
- The SRE action identity has Website Contributor on one web app. Review mode
  and the investigator instructions keep it to one proposed command; the role
  itself would allow other changes to that web app.
- Arc Run Command grants **guest scripting on one machine**, not service-only
  RBAC. The controller constrains calls sent through it; it cannot prevent an
  identity with Run Command permission from submitting a different script.
  Subscription Monitoring Contributor is broader monitoring authority, not a
  claim of resource-group-only access.
- Arc-on-Azure follows Microsoft's
  [evaluation-only pattern](https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine):
  no native VM extensions, disabled Azure guest agent, blocked Azure IMDS.
  The backend is still Azure-hosted; a real datacenter needs its own onboarding,
  connectivity and action validation. Do not add native VM Run Command as a
  fallback once the host has switched to Arc management.
- [Arc Run Command](https://learn.microsoft.com/en-us/azure/azure-arc/servers/run-command)
  is a preview surface. Guest execution status differs from provisioning status.
  The [SRE Review-mode policy](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes)
  is paired with explicit CLI approval and alternate-tool deny rules; merely
  selecting Review is not a universal external-tool security boundary.
- The Observability Agent and the subscription default Azure Monitor workspace
  setting are preview resources. Only one default setting can exist per
  subscription; Up leaves an existing, unowned setting unchanged.
- Observability Agent autonomous issue creation is built but not verified here.

## Verification

The historical latency evidence below remains valid for its original plain-VM
deployment. It is not acceptance of the new combined Arc profile.

| Combined-profile gate | Result |
|---|---|
| Local contracts | Both scenario orders, overlap/wrong-undo refusal, no automatic next fault, unknown command retention, policy drift and pending approval guards covered by `tests\Test-CheckoutDemo.ps1`; controller and HTTP failure contracts covered by focused pytest tests. |
| Arc enrollment and read-only delivery (2026-10-16) | Connected Machine agent registered on the existing backend role; native VM agent provisioning disabled and no native extensions. A normalized-LF Arc command verified bootstrap completion, disabled guest agent and healthy primary service. |
| Bootstrap correction | Initial Linux bootstrap failed on Windows CRLF; Bicep now normalizes the shell source before encoding. Arc scripts also normalize LF, and the probe requires an explicit success marker with no stderr. |
| Arc controller and healthy telemetry | Installed successfully through Arc; fresh owner-bound healthy service receipts reached Log Analytics. Live checks passed exact Arc grants, action identity, investigator/tool configuration and Review policies. |
| Browser failure and retry | Local headless Edge with the actual backend stopped: BE and NL show Not paid; the retained basket succeeds after the backend restarts. Existing slow-success presentation still works. |
| Live service fault (2026-10-16) | Arc stopped the real primary service at 14:24:21Z. Both BE and NL `/checkout` returned HTTP 503, while `/health` remained HTTP 200 with both routes `primary`. The latency fault was not injected. |
| Human approval and SRE-to-Arc repair | Native card created 14:27:58Z, human approved 14:28:22Z without allow-for-thread. Azure recorded the bound SRE action identity's write at 14:28:30Z; the same-run controller recovered the service at 14:28:41Z (about 19 seconds after approval, 4 minutes 20 seconds after the stop). Arc exit 0, fresh healthy receipt, original actor/run, `recoveryReason=repair` and `recoveredBy` all matched. |
| Customer recovery and incident note | Fresh post-recovery telemetry: BE 98 samples, 0 failures, p95 169 ms; NL 99 samples, 0 failures, p95 161 ms. Direct web-channel checkouts returned HTTP 200 for both countries. SRE independently verified recovery and wrote its thread conclusion; no external ITSM integration was configured. |
| Return to shared baseline | After natural alert clearance and reviewed guidance readback, Ready passed with no blockers: both routes primary, BE p95 111 ms (n=95), NL p95 140 ms (n=97), healthy service and settled SRE actions. The lifecycle retired the verified fault without injecting another. |
| Subsequent latency rehearsal (2026-10-16) | The presenter explicitly selected latency after the service rehearsal and reported success. The manifest recorded a separate latency run. Before teardown, ARM settings and live app routes were both primary and the Arc service was healthy. The SRE Agent had been stopped; its configuration endpoints returned 404 and there were insufficient samples after the newly established recovery boundary for Ready to pass. The final latency approval/thread evidence was not independently captured, so this is presenter-confirmed service-then-latency sequencing, not another fully evidenced end-to-end acceptance. |
| CLI reporting limitation and correction | The approved write tool reported Failed after about 121 seconds with extension/preview warnings, despite successful guest execution and Azure audit. It was not replayed. The proposed command now uses the documented `--no-wait --only-show-errors` flags to avoid long-running CLI polling; this revised submission form needs its next live rehearsal. |
| Live teardown (2026-10-16) | Down completed at 15:32Z. Independent checks at 15:33Z confirmed the resource group absent, zero active owner-tagged resources, no Arc command grant/custom role, no owned subscription grants or default Monitor setting, and no remaining owned subscription deployment records. The first pass preserved the manifest while one ARM deployment-record deletion propagated; an idempotent retry completed and removed the manifest only after verification. The unrelated application environment was not changed. Normal Azure soft-delete/data-retention behavior was not purged. |
| Fresh latency/code-loop dry-run (2026-10-18) | Fresh Arc deployment, read-only delivery probe, controller preparation, scoped identities, latency alert, action-only human approval and identity-audited rollback passed. Corrected guidance requested the second incident's native card and verified recovery without steering. Ready retired both faults after natural alert clearance. Human-approved GitHub OIDC route write and PAT-backed reset to `checkout-v2` passed, with `main` unchanged. Issue creation and Copilot PR remain blocked by the unconfigured SRE GitHub connector; see [checkout code loop](checkout-code-loop.md) for evidence and limits. |
| Technical dry-run teardown (2026-10-18) | Down deleted the fixture and retained its manifest during deployment-record deletion propagation; an idempotent retry completed. Independent checks found no group, owner-tagged active resources, Arc command role, subscription grants, owned Monitor setting, deployment records or remaining deploy/Copilot role assignments. Existing one-time identity/GitHub configuration is retained; normal soft-delete/data retention was not purged. |
| Readiness brief | Implemented and covered by mocked contracts in `tests\Test-CheckoutDemo.ps1` (rendering, write bodies, Review mode, read-only tools, drift blockers). 2026-10-19: `ConfigureReadiness` on a live Arc-profile deployment created the custom agent and v2 scheduled task; read-back showed `status=Active`, `agentMode=Review`, cron `0 5 * * *` and the read-only tool only. A scheduled run and on-demand RED/GREEN briefs are **not yet verified**. |
| Remaining live gates | Reverse-order service/latency sequencing, reboot persistence, three fresh full deployment/demo/reset/teardown cycles and revised nonblocking Arc service submission remain unverified. The new latency-only incidents do not establish these combined-profile gates. Local contracts do not substitute for live evidence. |

The nonblocking option is documented in
[az connectedmachine run-command create](https://learn.microsoft.com/en-us/cli/azure/connectedmachine/run-command?view=azure-cli-latest#az-connectedmachine-run-command-create).
Submission, guest execution, customer recovery and natural alert clearance are
separate observations. A CLI/tool error alone is not permission to repeat a write.

| Check | Result |
|---|---|
| Local smoke test (front end + both backends) | BE on `legacy`: 1.7 s lookup; NL on `primary`: 50 ms; invalid country rejected (HTTP 422). |
| Azure deployment (2026-10-15, `checkout01`, Sweden Central) | Up succeeded: Bicep, front-end zip deploy, SRE investigator and response plan. The first attempt failed because one-minute log alerts cannot query the Application Insights `requests` table; the alert now queries the workspace `AppRequests` table. |
| Healthy baseline (Ready) | Passed: BE p95 98 ms (n=95), NL p95 99 ms (n=98). Dependency target `erp-price-service`. |
| Fault and alert | Inject at 19:12:36Z; alert fired for the workspace at 19:15:37Z (about 3 minutes). Email delivery not checked by the developer. |
| SRE incident, investigation and proposal | Incident created at 19:17Z. About 4 minutes later the investigator reported: BE p95 about 2 s on `legacy-price-gateway`, NL unaffected on `primary`, reference `CHG-1042`, no failed checkouts. It proposed exactly the rollback command. It could not retrieve the change actor or time from the Activity Log. |
| Review-mode gate | Development test: after a chat approval, the agent submitted the exact `az webapp config appsettings set ... PRICE_ROUTE_BE=primary` as a `RunAzCliWriteCommands` action with status Pending. The portal approval card was not clicked; Undo restored the route instead. |
| Undo and recovery | Passed: Ready again with BE p95 98 ms and NL p95 99 ms after about 7 minutes. |
| Human click on the approval card and agent-verified recovery | Passed (presenter rehearsal 2026-10-16): incident thread at 09:11Z; after the presenter approved the card, the agent's managed identity set `PRICE_ROUTE_BE=primary` at 09:34:43Z, verified BE recovery with fresh telemetry and wrote the incident note. The note named the earlier 08:18Z route change rather than the 09:00Z re-injection, because both carried `CHG-1042`; run `Undo` and wait between attempts. |
| SRE log queries without authorization prompts | Fixed 2026-10-16: queries with the workspace resource ID and `--subscription` triggered on-behalf-of prompts despite Log Analytics Reader. The instructions now require `--workspace <customer GUID>`; a test thread ran that form under the managed identity without a prompt. |
| Web till (end-user view) | Passed 2026-10-16 in headless Edge on `checkout01`: baseline basket of 3 lines paid in 0.1 s. About 2.5 minutes after Inject: BE receipt "Paid in 2.3 s. The customer had to wait." No CSP or console errors. Workspace received `AppPageViews` (Web till), `AppEvents` `till-checkout` (`durationMs` measurement 128 then 2259) and `AppRequests` with `retail.channel=web`. |
| Observability Agent on-demand investigation | Not yet verified. |
| Observability Agent autonomous mode and alert email | Built, not yet verified. |

See the [presenter runsheet](presenter/checkout-latency-runsheet.md).
