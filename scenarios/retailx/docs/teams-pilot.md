# Retailx personal Teams pilot

**Fixture-first pilot; live attachment is a separate opt-in.** This optional extension
adds a personal Teams conversation to the existing read-only Foundry assistant.
Its Azure resources, managed identities and Teams installation require a
separate deployment approval. No VM, desktop Teams client or runtime Microsoft
Graph permission is needed.

The personal synthetic walkthrough and later live checkout conversation have
been completed based on user-reported Teams results. That does not satisfy the
broader browser/teardown gates. The business-facing response experience is now
source-implemented; updated prompt/backend deployment and real-model
acceptance are separate gates, not established by offline tests.

## High-level architecture

```mermaid
flowchart LR
    User["Demo user<br/>Teams in the browser"]
    Bot["Azure Bot<br/>Teams channel"]
    Host["Teams-only app<br/>Verify channel token<br/>Allow one tenant and member"]
    Runner["Existing agent runner<br/>Bounded read-only tools"]
    Foundry["Microsoft Foundry<br/>Pinned agent and model<br/>Chooses evidence tools"]
    Evidence["Evidence tools<br/>Impact and freshness checks"]
    Fixtures["Default: synthetic checkout fixtures"]
    Live["Optional: owned checkout workspace<br/>Fixed read-only telemetry queries"]
    Stores["Always synthetic<br/>Store map and opening hours"]
    Browser["Existing browser app<br/>Separate Entra sign-in"]
    User <-->|Personal chat| Bot
    Bot <-->|Authenticated messages| Host
    Host <--> Runner
    Browser <--> Runner
    Runner <--> Foundry
    Runner --> Evidence
    Evidence --> Fixtures
    Evidence --> Live
    Evidence --> Stores
```

Think of Teams as a **new front door**, not a new AI engine. Azure Bot carries
the messages. A separate app checks who sent them, then reuses the existing
agent runner. Foundry chooses from the allowed tools; application code executes
them and checks freshness. The answer returns to the same personal chat as a short, plain-language reply,
with one relevant demo-data notice rather than a diagnostic banner and
observation dump. Technical evidence is shown only on explicit request.

The runner is shared **source code**, not an unauthenticated browser API call.
The browser and Teams processes keep their own authorization and conversations.
The browser can retain its separately approved live checkout attachment; the
Teams pilot defaults to fixtures with no checkout workspace role. Its optional
live attachment is independent of the browser attachment.

SRE Agent and its native human-approved repairs stay outside this assistant.
There is no repair path, arbitrary KQL/shell tool, incident write, revenue
estimate, group/channel support or proactive staff notification.

## What the first pilot should demonstrate

| Question or action | Expected result |
|---|---|
| `/help` | Read-only boundaries and available commands; no model call. |
| Ask which BE/NL stores opening soon need attention | Real Foundry reasoning selects bounded tools and combines synthetic checkout/store evidence. |
| `/fixture interrupted`, then ask about impact | Clearly synthetic affected/exposed stores and limitations. The command changes no infrastructure. |
| `/fixture slow`, then ask about slower Belgian checkouts | Measured synthetic Belgian slowness despite successful requests; Dutch speed stays normal. No invented fix time or store outage. |
| Ask to check again | A new Foundry turn and fresh tool reads, not replay of the earlier answer. |
| `/fixture stale` or `/fixture unavailable` | Explicit unknown; no invented health or recovery. |
| `/fixture recovering` | Do not claim customer recovery without the required evidence. |
| `/status` | Last question's receipt, optionally its saved answer, labeled **not a fresh observation**. No model call or delivery retry. |
| `/reset` | Clear history and select healthy synthetic evidence; no real recovery action. |
| Duplicate delivery or process restart | Never repeat the original inference automatically. An uncertain outcome stays uncertain. |

Changing fixtures clears conversational history, so it does not by itself
demonstrate a single incident's recovery. No fixture proves a real checkout
incident or a Teams conversation actually worked.

## Deployment and ownership

Use the existing `Invoke-IncidentAgent.ps1` entry point with explicit authorized
subscription, tenant and environment values. The worktree must hold that
environment's own `.azure\<environment>\incident-agent-ownership.json`; do not
copy/adopt another checkout's state or resources by name.

1. Obtain human review and merge of the source PR. Confirm the exact Azure
   resources, identities, member object ID, tenant custom-app policy and
   cleanup ownership before authorizing deployment. Recorded retention dates
   are informational and do not block deployment or readiness.
2. Establish the separately owned browser/Foundry environment with `Up` if
   needed. It must have a pinned, endpoint-confirmed agent version.
3. Run `TeamsUp -TeamsUserObjectId <member-object-guid>` for that same owned
   environment. The account must be an enabled tenant **Member** with Teams
   licensing; the operator supplies its immutable object ID privately.
4. Run `TeamsReady` and `TeamsVerify` in Azure. They check the deployed boundary
   and run the existing cloud fixture evaluations; neither proves user chat.
5. After tenant policy approval, upload the generated private
   `.azure\<environment>\retailx-teams-personal.zip` as the bound demo member.
   Install in personal scope only; do not publish to the tenant catalog.
6. Rehearse the table above in Teams. Keep a private, same-run receipt of the
   actual Foundry tool selections, fresh follow-up, stale/unknown handling and
   unauthorized/group-scope rejection. Do not record passwords or raw chats.

For example (replace every placeholder; do not save live values in source):

```powershell
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 TeamsUp `
    -SubscriptionId <subscription-guid> -TenantId <tenant-guid> `
    -EnvironmentName assist01 -TeamsUserObjectId <member-object-guid>
```

The subscription owner must have registered `Microsoft.BotService`; the script
does not silently register providers or broaden tenant policy. `-WhatIf`
declines mutations. Actual provisioning performs template validation and ARM
what-if first and retains a private preview.

| Owned component | Purpose and boundary |
|---|---|
| Separate Python 3.12 App Service, same owned B1 plan/RG | Teams endpoint only; browser Easy Auth exclusions remain unchanged. |
| Azure Bot and its Teams channel | Channel transport to the exact Teams app endpoint. |
| Dedicated bot user-assigned managed identity | Secretless bot authentication; no Azure resource roles. No extra bot app registration or Graph runtime permissions. |
| Teams host system-assigned identity | Foundry Agent Consumer at the exact existing project; optionally Log Analytics Reader at one explicitly attached checkout workspace. Never contributor/admin. |
| Foundry outbound-IP allowlist | Exact union of browser and enabled Teams hosts; key authentication remains disabled. This is not Private Link. |
| Existing root ownership manifest | Persists opt-in, member/package IDs and resource bindings; ordinary `Up` preserves the optional Teams surface. |
| Generated personal app ZIP | Contains private environment identifiers; never commit or publish it. |

`TeamsPackage` regenerates the same personal app identity. Ordinary `Reset`
rotates the shared evidence run and restarts both enabled apps; previous
Teams history/receipts are not admitted in the new run. `/reset` is only a
conversation reset. First setup defaults to healthy fixtures; subsequent `Up`
preserves the configured mode. Neither operation injects a fault.

## Optional live checkout evidence

Review and merge the source change before authorizing deployment or permission
changes. A live rehearsal also needs a separately owned, healthy Retailx checkout
environment with Arc service observations and checkout requests reaching its
workspace. Do not adopt another environment by resource name.

The lifecycle exposes three explicit operator actions:

| Action | Behavior |
|---|---|
| `TeamsAttach -CheckoutEnvironmentName checkout01` | Verify owned source bindings, stop the old Teams host, record and grant workspace-scoped Log Analytics Reader to its system identity, configure live evidence, then start/check the host. Does not run a model turn. |
| `TeamsObserve` | Perform a new Azure-hosted telemetry read and Foundry turn, saving a private receipt. This is not a Teams-chat acceptance test. |
| `TeamsDetach` | Stop the host, select fixtures, clear runtime source settings, remove and independently verify absence of the exact external grant, then start/check the host. |

For example, after approval and deployment (all identifiers are placeholders):

```powershell
$pilot = @{
    SubscriptionId = '<subscription-guid>'
    TenantId = '<tenant-guid>'
    EnvironmentName = 'assist01'
}
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 TeamsAttach @pilot `
    -CheckoutEnvironmentName checkout01
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 TeamsObserve @pilot
# After the rehearsal, remove only the Teams attachment:
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 TeamsDetach @pilot
```

Attach never grants the bot transport identity access. The reader scope is one
recorded workspace, not the checkout resource group or subscription. Browser
settings, its identity and its reader grant remain untouched. Ordinary `Up`
preserves each front door's own binding.

Chat cannot choose a workspace or switch modes. In live mode `/fixture` is
disabled; `/reset` clears conversation history but keeps the live attachment.
Each attachment transition rotates a private receipt namespace, so `/status`
cannot return a saved fixture result as a live observation, or vice versa.
Activity claims and active-operation locks remain in a stable namespace across
these transitions, so a redelivered old activity cannot trigger new inference.
The lifecycle verifies that the old host is stopped before changing bindings.
It also restores the fixed server startup before starting, rather than resuming
an interrupted management-job wrapper.
If cleanup is interrupted, retain ownership state and retry `TeamsDetach`;
a remaining grant must not silently re-enable live evidence during `Up`.
A verified missing host or incident group does not prevent removal of its
recorded external grant; cleanup never recreates those missing resources.

Live tools reuse the existing fixed, owner/resource-bound Log Analytics queries:
the latest Arc service observation and recent BE/NL checkout request samples.
Live freshness allows up to 300 seconds of ingestion lag; missing, stale,
wrong-owner or failed queries are **unknown**, never synthetic fallback.
The store map and opening hours remain synthetic in both modes. Checkout
failures are observations, not proof of a store outage, failed payment or lost
revenue.

The telemetry stream is not pinned to a particular presenter fault run.
`recoveryProven` remains false, including after a healthy observation or a
controller `recovered` marker. Do not represent this as verified customer
recovery or same-presenter-run recovery proof.

For live acceptance, first obtain a usable `TeamsObserve` receipt, then ask in
personal Teams: **“Which stores in both Belgium (BE) and the Netherlands (NL)
need attention, and why?”** Only the presenter may inject and undo the supported
checkout fault through its own lifecycle. Ask for a fresh assessment after each
change, allowing for ingestion lag; check `/status` separately to confirm it
does not retrieve new evidence. Keep actual tool/provenance receipts private.
`TeamsVerify` still runs fixture evaluations even on an attached host and does
not replace this rehearsal.

## Runtime limits and failure behavior

The Microsoft 365 Agents SDK verifies channel JWT signatures. The application
then requires the commercial channel issuer, exact bot audience, tenant,
member object ID, bot recipient and personal scope. It accepts only recent
messages and allowlisted commercial Teams service URLs. Files, cards, invokes
and arbitrary payloads cannot reach the agent. A single bounded Teams
`text/html` presentation attachment is ignored; only the plain `text` is used,
and its HTML is never rendered or fetched.

Only the constant `/health/live` is anonymous. The Teams host does not use the
browser's cookies or CSRF exemptions, nor does it expose the browser UI.
Content is plain text. Telemetry contains bounded event metadata, not prompts,
identities, token values or raw upstream exceptions. Teams runs Azure Monitor
in logs-only mode: SDK spans/metrics and live metrics are disabled because
SDK spans can contain conversation IDs and exception details. Its default
traceback/raw-error chat callback is replaced with the sanitized failure path.

Incoming requests get a short acknowledgement; a tracked background task uses
the existing bounded runner and sends its delayed answer to the originating
conversation. The SDK calls this continuation delivery; it is not unsolicited
proactive staff messaging. If inference or delivery is interrupted, `/status`
reports saved evidence or uncertainty, without rerunning inference or delivery.
`delivered` means the channel accepted the reply, not that the user read it.

Owned App Service `/home/data` files hold atomic activity claims, one active
operation, bounded conversation history and receipts. Restart never resumes
work. A stale active claim requires explicit `/reset` after four minutes.
The plan and app must remain **one instance and one worker**; scale-out and
production/high-availability delivery guarantees are not implemented.
The first slice allows at most six new activities/minute, eight conversation
sessions and eight model turns/session. History retains at most four turns
with bounded answer excerpts; every follow-up still fetches new evidence.
Sessions expire after 30 minutes. Receipt cleanup is opportunistic on accepted
traffic after one hour; old run namespaces remain private until owned app/RG
teardown. These are not guaranteed data-erasure timers.

No automatic model/delivery retries, queue, Graph conversation inventory,
file upload or multitenant access is added here.
Model/SDK transport timeouts do not establish that an upstream request never
executed.

## Cleanup and longer-term path

`TeamsDown` stops the Teams host, removes its exact external checkout reader
grant if attached, then removes its project runtime grant, bot, host
and managed identity, checks their absence, restores the browser-only Foundry
allowlist and keeps the browser environment. Full `Down` removes the owned
incident RG (including Teams) and the existing browser registration.
Full `Down` also removes the independently recorded Teams checkout reader
before deleting the incident group. Neither operation deletes the separately
owned checkout deployment or changes the demo user's account or Teams license.
Detach both front doors before checkout `Down`; browser `Detach` alone does
not remove a Teams reader.

**Uninstall the personal app in Teams separately.** Without broad Graph
inventory permission, neither lifecycle claims to remove tenant/catalog/client
installations. Azure/Entra provider-retained or soft-deleted data may remain;
cleanup is not a purge claim. Keep ownership and residual receipts.
After an interrupted first Teams provision with no recorded output bindings,
inspect the owned deployment and use full `Down` if scoped cleanup cannot
establish those bindings; never adopt a same-name bot.

Live deployment and the presenter-controlled rehearsal remain separate gates
before any staff rollout or proactive notifications.

## Privacy

This is an internal synthetic-data pilot, not a customer service. Do not send
customer data, personal data, credentials or operational secrets. Prompts and
bounded answer history are processed by the authorized Foundry endpoint and
the private app; Teams retains messages under tenant policy. Generated
packages and ownership/receipt files contain private environment identifiers.
The app does not request runtime Graph permissions or log prompt content.

## Terms of use

Use only in the explicitly authorized demo tenant and personal scope. Outputs
are illustrative and require human judgment. They are not production incident
instructions, evidence of real recovery, or authorization to change resources.
Tenant custom-app controls and native SRE human approvals must not be bypassed.

## Authoritative references

- [Microsoft 365 Agents SDK overview](https://learn.microsoft.com/microsoft-365/agents-sdk/agents-sdk-overview)
- [Official Python Agents SDK source](https://github.com/microsoft/Agents-for-python)
- [Azure Bot resource schema and managed identity fields](https://learn.microsoft.com/azure/templates/microsoft.botservice/2022-09-15/botservices)
- [Teams app manifest schema](https://learn.microsoft.com/microsoftteams/platform/resources/schema/manifest-schema)

The implementation pins the hosting and MSAL Agents packages to `1.9.0`.
Context7 was quota-blocked during implementation; the SDK interfaces and
identity configuration were checked against official source and the installed
pinned packages instead. Engineering tests are not cloud deployment or Teams
acceptance evidence.
