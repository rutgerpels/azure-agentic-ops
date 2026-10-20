# Configure the Azure SRE Agent from the portal

This guide builds the checkout latency demo with a **separate learning environment** where
the estate is scripted and **only the Azure SRE Agent is configured by hand** in the Azure
portal. Portal wording changes; where a label differs, use the closest match and the
[Microsoft Learn SRE Agent documentation](https://learn.microsoft.com/azure/sre-agent/).

The scenario: Belgium (BE) checkouts slow down after a routing change moves BE from the
ERP price service to the legacy gateway. A latency alert fires, the agent investigates,
asks for approval to restore the route and verifies recovery. Netherlands (NL) is the
healthy control group.

## Verified status

- Scripted estate, fault and teardown: contract-tested offline (`tests/Test-CheckoutLearn.ps1`).
- The portal steps below follow Microsoft Learn, not a live walkthrough of this environment.
  Treat labels and defaults as things to confirm while you click through.

## 1. Prerequisites

- Azure CLI signed in as a work or school account with **Owner** (or Contributor plus
  User Access Administrator) on the subscription. The agent creation assigns roles.
- A browser that can reach `*.azuresre.ai` (allow it in any proxy or firewall).
- PowerShell 7.2 or later and `ssh-keygen`.
- An email address for the alert action group (set `RETAILTX_ALERT_EMAIL`).

## 2. Deploy the environment

```powershell
./scripts/Invoke-CheckoutLearn.ps1 Up -SubscriptionId <subscription-guid> -AlertEmail <you@example.com>
```

This deploys `rg-retailtx-checkout-learn01-swedencentral` (about 10 minutes) **without** an
SRE Agent, Observability Agent or subscription-level settings. It then publishes the front
end and writes `.azure\learn01\sre-portal-values.md` with every value used below
(resource group, workspace GUID, alert rule name and the instructions to paste).

Wait about 5 minutes, then confirm a healthy baseline:

```powershell
./scripts/Invoke-CheckoutLearn.ps1 Ready -SubscriptionId <subscription-guid>
```

## 3. Create the agent

1. In the Azure portal, search for **Azure SRE Agent** and select **Create**.
2. Subscription: your subscription. Resource group: create a new one for the agent, for
   example `rg-sre-learn` (so deleting the checkout group never removes your agent).
3. Agent name: for example `sre-learn`. Region: choose one offered in the list.
4. **Choose resource groups to monitor**: select `rg-retailtx-checkout-learn01-swedencentral`
   and **Save**. Only this group is in scope.
5. Select **Create** and wait for provisioning. You become **SRE Administrator** and the
   agent receives a managed identity.

Decision to make and note: the permission level.

| Level | Behavior | Use here |
|---|---|---|
| Reader | Read access only. For a write the agent asks you to elevate (on-behalf-of) | Default. Needs a work or school SRE Administrator |
| Privileged | Contributor-style roles on resource types | Not needed |

Keep **Reader**. Step 6 gives the agent a narrow write role instead of elevating.

## 4. Review the basics

Open the agent, then **Settings > Basics**.

- Set the agent default run mode to **Review**. Review mode shows Approve/Deny for Azure
  write actions.
- Under **Settings > Incident platform**, confirm **Azure Monitor** is the platform. It
  connects by default.

## 5. Delete the quickstart response plan

The agent creates a default response plan. Delete it so it cannot route or duplicate the
latency incident:

**Builder > Incident response plans > Table view**, select the default plan, then delete.

## 6. Grant the rollback permission (recommended)

The rollback changes one App Service app setting. Give the agent identity **Website
Contributor** on the web app only:

1. Open the agent and note its managed identity (agent **Overview** or **Settings > Azure
   settings**). In Microsoft Entra ID, copy the identity's **Object ID**.
2. Open the web app in the checkout resource group (name is in the values file) >
   **Access control (IAM) > Add > Add role assignment** > **Website Contributor** >
   **Managed identity** > select the agent identity > **Review + assign**.

The values file also contains the equivalent `az role assignment create` command.

Also confirm the agent identity has Reader, Log Analytics Reader and Monitoring Reader on
the checkout resource group (created for the monitored scope in step 3). If a role is
missing, add it under the resource group's **Access control (IAM)**.

> Skipping this step is a valid experiment: with Reader level the agent asks you to
> elevate before the write. Compare the two behaviors.

## 7. Create the investigator custom agent

1. **Builder > Agent Canvas > Create > Custom agent**.
2. Name: `retailtx-checkout-learn01`.
3. Instructions: paste the block from `.azure\learn01\sre-portal-values.md`
   (source template: `docs/agent-context/checkout-learn-investigator.md`).
4. Handoff description: `Investigates Belgium checkout latency, correlates the routing
   change and proposes an approved rollback.`
5. Built-in tools: add the **Azure CLI read** and **Azure CLI write** tools
   (`RunAzCliReadCommands`, `RunAzCliWriteCommands`). Do not add terminal, shell or Python
   tools.
6. Save.

Why the instructions matter: they force log queries by workspace GUID (so no user
authorization prompt appears), allow exactly one write command and require the native
approval card before execution.

## 8. Create the response plan

**Builder > Agent Canvas > Create > Trigger > Incident response plan**.

| Field | Value |
|---|---|
| Name | `checkout-latency-learn01` |
| Severity | Include Sev 2 (the alert is Sev 2) |
| Title contains | the alert rule name from the values file (`alert-checkout-latency-learn01`) |
| Response custom agent | `retailtx-checkout-learn01` |
| Autonomy level | **Review** |
| Reinvestigation cooldown | Disable for the lesson, so a repeat run opens a fresh thread |

Use the preview step to confirm the plan matches, then **Create**.

## 9. Optional: test the agent first

Use the **Test playground** (Builder > Agent Canvas) with the custom agent and ask:
`Compare BE and NL checkout p95 over the last 30 minutes.` The answer should use
`az monitor log-analytics query --workspace <GUID>`. This confirms telemetry access before
the incident.

## 10. Run the demo

```powershell
./scripts/Invoke-CheckoutLearn.ps1 Ready -SubscriptionId <subscription-guid>
./scripts/Invoke-CheckoutLearn.ps1 Inject -SubscriptionId <subscription-guid>
```

Then, in the portal:

1. Wait 3 to 6 minutes for `alert-checkout-latency-learn01` to fire (it needs 5+ BE
   checkouts with p95 above 1 second). Check the email and **Azure Monitor > Alerts**.
2. Open the agent **Incidents** and the new thread. Watch hypothesis, evidence, conclusion.
3. Expect: BE slow on `legacy-price-gateway`, NL healthy, a recent
   `Microsoft.Web/sites/config/write` with a `CHG-` reference.
4. The agent asks to run `az webapp config appsettings set ... PRICE_ROUTE_BE=primary`.
   Review the command, then **Approve** (or **Deny** to see the refusal behavior).
5. After approval it waits for fresh telemetry, verifies BE p95 below 300 ms and writes an
   incident note.

Reset any time:

```powershell
./scripts/Invoke-CheckoutLearn.ps1 Undo -SubscriptionId <subscription-guid>
```

Then run `Ready` again after about 5 minutes. If the agent already rolled back, `Undo` is
a safe no-op that also resets the change reference.

## 11. Troubleshooting

| Symptom | Check |
|---|---|
| No incident thread | Response plan **Title contains** must be a substring of the alert name; deleted quickstart plan; cooldown; alert actually fired |
| Agent asks you to authorize a query | It used a resource ID or `--subscription`; re-check the instructions use `--workspace <GUID>` |
| Rollback fails with authorization error | Step 6 role is missing, or you must approve the elevation prompt (Reader level) |
| No approval card, text only | Confirm Review mode on the response plan and the write tool is the custom agent's `RunAzCliWriteCommands` |
| Alert does not fire | `Ready` first; fault needs about 5 minutes of BE traffic |
| `Ready` says stale telemetry | Wait 5 minutes after `Up` or `Undo` |

## 12. Teardown

```powershell
./scripts/Invoke-CheckoutLearn.ps1 Down -SubscriptionId <subscription-guid>
```

This deletes the checkout resource group and its deployment record, and fails if owned
resources remain. It does **not** remove the agent you created: delete the `sre-learn`
agent and its resource group in the portal. The environment is tagged with an expiry
(default 7 days) but nothing deletes it automatically.
