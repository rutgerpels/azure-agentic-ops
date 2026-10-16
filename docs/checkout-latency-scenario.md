# Checkout latency in Belgium (hybrid scenario)

> Status: **implemented; verification in progress.** See
> [Verification](#verification) for what has been run in Azure.

A small, disposable hybrid demo for the question:

> *Why are checkout transactions slower in Belgium this morning?*

Stores in Belgium (BE) and the Netherlands (NL) call a checkout front end in
Azure. Every checkout looks up the price on a simulated on-premises datacenter
host. A logged routing change sends Belgian price lookups to a slow legacy
gateway. Checkouts still succeed, but take seconds instead of milliseconds. NL
is the healthy control group.

The scenario reuses the operating model proven by earlier RetailTx fixtures
(Review mode, human approval, fixed action, evidence-based verification) and
adds the Azure Copilot Observability Agent. It is intentionally simpler than
the Arc profiles: the datacenter host is a plain Azure VM tagged `site=dc1`.
It shows the cloud-to-on-premises dependency story, not Arc management.

## Architecture

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
| `erp-price-service` | dc1 VM, port 8080 | Normal ERP price lookup. |
| `legacy-price-gateway` | dc1 VM, port 8081 | Legacy price validation. Slow by design. |
| `pos-sim` | dc1 VM | One BE and one NL checkout about every 3 seconds. |
| Application Insights + Log Analytics | Azure | Requests carry `retail.country`, `retail.store` and `retail.price_route`. Dependency targets are `erp-price-service` or `legacy-price-gateway`. A startup trace records the route table and change reference. |
| Alert `alert-checkout-latency-<env>` | Azure Monitor | Log alert on the workspace `AppRequests` table, evaluated every minute: checkout p95 above 1 s with at least 5 requests in 5 minutes, split by country. Emails the action group. |
| Observability Agent | Azure Monitor (West Europe) | Monitors Application Insights and the Log Analytics workspace. Built in autonomous mode: alert-driven issue creation and investigation with email to the action group. The presenter can also start an investigation on demand. Read-only. |
| SRE Agent | Sweden Central | Review mode. A response plan routes the alert to the custom investigator `retailtx-checkout-<env>`. The action identity can only write the checkout web app (Website Contributor on that site). |

The App Service reaches the dc1 VM through regional VNet integration and VNet
peering. Peering stands in for site-to-site connectivity; it is not a VPN.
The VM has no public IP; its outbound traffic (pos-sim, packages) uses a NAT
gateway. The backend NSG only accepts ports 8080-8081 from the App Service
integration subnet.

## Fault and remediation

| Step | Mechanism |
|---|---|
| Fault | `chaos/checkout_latency.py --inject` sets `PRICE_ROUTE_BE=legacy` and `ROUTE_CHANGE_REF=CHG-1042` on the web app. This is a real configuration change recorded in the Activity Log (`Microsoft.Web/sites/config/write`). Manual lifetime: no timer, no auto-recovery. |
| Signal | BE checkout p95 rises above 1 s; NL stays fast. BE dependencies switch to `legacy-price-gateway`. The alert fires for `country=BE`. |
| Proposed action | SRE Agent proposes exactly `az webapp config appsettings set ... --settings PRICE_ROUTE_BE=primary` and waits for approval. |
| Approval | A human approves the pending action in the SRE Agent portal. |
| Verification | The investigator checks fresh BE p95 below 300 ms with at least 5 requests over 3 minutes, `erp-price-service` as the BE dependency, and NL unchanged. An alert clearing alone is not proof. |
| Manual undo | `chaos/checkout_latency.py --undo` (or `Invoke-CheckoutDemo.ps1 Undo`) restores `primary` and `baseline`. |

The app setting change restarts the web app for roughly a minute. Expect a
short gap in telemetry after both the fault and the rollback.

## Lifecycle

Requirements: PowerShell 7.2+, Azure CLI with Bicep, Python 3, `ssh-keygen`,
and an account that can create resource groups and role assignments.

```powershell
$sub = '<subscription-id>'
./scripts/Invoke-CheckoutDemo.ps1 Up     -SubscriptionId $sub -EnvironmentName checkout01 -AlertEmail '<alert-recipient>'
./scripts/Invoke-CheckoutDemo.ps1 Ready  -SubscriptionId $sub -EnvironmentName checkout01
./scripts/Invoke-CheckoutDemo.ps1 Inject -SubscriptionId $sub -EnvironmentName checkout01
./scripts/Invoke-CheckoutDemo.ps1 Undo   -SubscriptionId $sub -EnvironmentName checkout01
./scripts/Invoke-CheckoutDemo.ps1 Down   -SubscriptionId $sub -EnvironmentName checkout01
```

- **Up** deploys [`infra/checkout/main.bicep`](../infra/checkout/main.bicep),
  publishes the front end, creates the SRE investigator and the Review-mode
  response plan, and records non-secret state in `.azure/<env>/` (gitignored,
  including the break-glass SSH key). Re-running Up restores the baseline route.
- **Ready** requires fresh BE and NL telemetry with p95 below 500 ms, both
  routes on `primary`, the alert enabled, the SRE Agent Running in Review mode,
  and the response plan enabled. It warns when other SRE Agents are running.
- **Down** removes the subscription-scope Observability Agent reader grant and
  the subscription default Azure Monitor workspace setting (only when this
  environment created it and it still points to its own workspace), deletes the
  resource group and deployment records, and removes local state.

The resource group is tagged `demo=retailtx`, `environmentId`,
`profile=checkout-latency`, `managedBy=invoke-checkoutdemo` and `expiresAt`.
There is no automatic expiry; run Down after the session.

### Shortcuts and limits (demo, not production)

- Public endpoints for the web app, Application Insights, Log Analytics and the
  SRE Agent. No private endpoints or VNet-injected agent.
- Application Insights uses its connection string (local authentication).
- The SRE action identity has Website Contributor on one web app. Review mode
  and the investigator instructions keep it to one proposed command; the role
  itself would allow other changes to that web app.
- The Observability Agent and the subscription default Azure Monitor workspace
  setting are preview resources. Only one default setting can exist per
  subscription; Up leaves an existing, unowned setting unchanged.
- Observability Agent autonomous issue creation is built but not verified here.

## Verification

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
| Observability Agent on-demand investigation | Not yet verified. |
| Observability Agent autonomous mode and alert email | Built, not yet verified. |

See the [presenter runsheet](presenter/checkout-latency-runsheet.md).
