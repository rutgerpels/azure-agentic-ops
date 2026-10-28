# Foundry incident-management agent: implementation plan

Implements the browser-based direction of
[#45](https://github.com/rutgerpels/azure-agentic-ops/issues/45).
The remaining checkout release work in #44 stays parked.

**Status:** resumed from the parked state on user direction. The Azure platform,
agent bootstrap and readiness are verified, and all ten real-model evaluation
cases pass in Azure against fixtures. Live checkout binding passed one
presenter-triggered `service` incident (baseline, fault and post-repair); see
[Execution evidence](#execution-evidence). Interactive browser acceptance and
push notification to staff remain open.

The optional [personal Teams pilot](teams-pilot.md) adds a separate authenticated
channel host while reusing this runner. Its personal fixture walkthrough is
user-reported complete; the independent live attachment extension still requires
review, deployment approval and live Teams acceptance.

## Outcome and agentic value

A read-only retail incident-management assistant answers business questions
using evidence, rather than just forwarding or paraphrasing an alert.

The demonstration starts with:

> Which BE/NL stores opening in the next hour need attention, and why?

A follow-up asks:

> Has the situation recovered? Check again rather than repeating the earlier answer.

The agent must select bounded evidence tools, combine current operational
evidence with synthetic store context, explain its conclusions and limitations,
and retrieve new evidence on follow-up. Tool traces must demonstrate actual
Foundry execution. A canned notification or a prompt containing a complete
prewritten answer does not pass.

SRE retains technical investigation and approved remediation. This assistant
does not become a second infrastructure operator.

## Scope

- One Foundry prompt agent and model deployment in the authorized demo tenant.
- A small browser chat and server-side Foundry client.
- Narrow function tools executed by the backend. Remote MCP is not required
  for this slice: the same fixed-query boundary can be exposed through MCP
  later if justified.
- Deterministic evidence, opening-hours, exposure and prioritization logic.
- Explicit source, owner/run binding, observation time and freshness.
- Private Azure traces and a repeatable evaluation set.
- Owned setup, readiness, reset and teardown with a non-secret receipt.

The base browser slice includes no Teams. The separately opted-in
[Teams pilot](teams-pilot.md) is personal-scope and defaults to fixtures.
`TeamsAttach`, `TeamsObserve` and `TeamsDetach` provide an independent, explicitly
authorized live-evidence lifecycle without changing the browser attachment.
No runtime Microsoft Graph integration, Copilot Studio, external-tenant configuration,
SRE chat/command execution, remediation, incident-state writes, contacts, revenue estimates,
vector search, or arbitrary KQL/shell tools are included.

## Browser deployment decision

**User-directed:** the browser and backend run in Azure, with Entra sign-in
in the authorized demo tenant. Do not run a local application or use a local
rehearsal as acceptance. Exercise the deployed application and real Foundry
agent in Azure.

Use a dedicated hosting identity and tenant application registration. Keep
Azure credentials server-side, restrict admission to the intended demo
operator, and include the registration and any credentials in owned lifecycle
and cleanup controls. No Microsoft/home-tenant changes are authorized.

Foundry access must require Entra authentication; local key authentication is
not the access model. Internet reachability must not be confused with anonymous
access or with a fully private network profile.

The implemented platform uses Linux App Service, a separate secretless browser
sign-in identity, and a system-assigned runtime identity. Foundry has key
authentication disabled and accepts only the union of the enabled browser and
Teams hosts' published `possibleOutboundIpAddresses`, not just their smaller
current `outboundIpAddresses` lists. Readiness requires that exact union, rejects
additional addresses or network rules, and fails closed if either enabled host
does not publish a valid, nonempty IPv4 pool. Deployment has no fallback to
current addresses or unrestricted access. This is selected-network access over an authenticated public endpoint,
not Private Link. The runtime's permanent project role permits Responses calls,
not agent configuration or infrastructure management. A temporary project-only
bootstrap grant is removed before readiness.

The possible pool includes addresses across App Service pricing tiers and can
grow over time; its addresses are shared infrastructure, not proof of an app's
identity. Keep managed-identity authorization as a separate boundary. See
[App Service inbound/outbound IP addresses](https://learn.microsoft.com/en-us/azure/app-service/overview-inbound-outbound-ips).
The pool-based correction is source-implemented, not live-verified until a
human-reviewed deployment and a fresh successful model/tool turn. A readiness
receipt alone does not establish inference success. Do not replay an earlier
unknown-outcome turn to test it.

### Deferred private Foundry connectivity

User-directed follow-up, not part of the allowlist correction: integrate the
enabled app hosts with a VNet, deploy an owned Foundry private endpoint and
private DNS, validate the pinned named-agent endpoint through that path, and
disable Foundry public access only after private-path acceptance. Preserve the
Teams-reachable bot ingress and existing identity/approval boundaries. App
Service VNet integration is outbound connectivity, not private inbound access;
Basic supports it. See
[App Service VNet integration](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration).
Plan setup, DNS/routing readiness, both-channel inference acceptance, rollback
and owned teardown together. This work is neither deployed nor live-verified;
do not treat it as a supported private-network profile yet.

### Pinned reasoning deployment

The reasoning deployment pins `gpt-5-mini`, version `2025-08-07`, using
`DataZoneStandard` in Sweden Central. Regional model support and sufficient
unallocated quota were checked before deployment. The application uses the
current `azure-ai-projects` 2.9.0 SDK rather than the earlier authentication-only
SRE/Foundry spike.

## Tool and evidence contract

### Business-facing answers

The audience is non-technical business colleagues and store staff, not engineers
or helpdesk personnel. Default answers address "Is something wrong?", "Could it
affect my checkout?" and "When will it be fixed?" in 2-4 short sentences, at most
90 words/900 characters of generated explanation, plus one short application
notice when needed.
Lead with the answer, not a diagnostic report. Do not show evidence IDs, raw
timestamps, tool names, technical field names or a menu of investigations by
default. Explain attention levels in ordinary language without changing their
deterministic meaning; list all stores only when useful or requested.

The server allows one bounded presentation correction within the existing
four-round/120-second turn limit. It rejects persistently oversized or diagnostic
default answers rather than truncating away uncertainty or presenting a stock
success response. It does not replay tools just to rewrite an answer. Explicit
requests for technical details, evidence references or measurements can receive
longer replies; "use fresh evidence" alone does not opt in, and an earlier
technical question does not change later turns' default voice.

For an explicitly country-scoped question that omits its required evidence,
the existing single evidence correction uses Responses
`tool_choice: {type: allowed_tools, mode: required}` with only the relevant
read-only functions. The model still chooses between eligible tools. The server
rejects calls outside that subset, releases the requirement after the tool call,
and does not extend the four-round/120-second budget. Historical country mentions
alone do not enable this protocol constraint. Unknown tool results remain valid
evidence of uncertainty, not grounds for claiming healthy operation.
See the [Foundry Responses reference](https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject#components).

Example: "The latest checkout checks look normal in Belgium. That doesn't rule
out an intermittent problem at your location." If asked about a fix time, say
that no reliable estimate is available, but do not append that sentence to every
incident answer. Health and impact tools independently read checkout health and
the matching SRE investigation; they still do not supply a repair ETA.
Health and impact tools include measured country-level
checkout speed, separately from failures and service availability. Successful
but slow requests are degraded, not normal. A reported delay prompts a fresh
health check; failed request counts cannot establish slowness, and a normal
sample cannot disprove an intermittent delay at a particular store.

The latency correction requires human review, a newly bootstrapped and pinned
owned prompt-agent version, publication to both hosts and fresh cloud/model
acceptance. Publishing Python alone against the older prompt is insufficient.
Until that rollout, the deployed assistant cannot measure slowness and its
"checks look normal" reply during a latency fault is not valid live acceptance.
The server allows one bounded rewrite when measured slowness is omitted; it
fails closed on persistent denial without replaying tools or extending the
existing turn budget.

The server's allowed countries are a permission boundary, not the user's chosen
location. A vague request such as "Which stores in the region need attention?"
must first clarify Belgium, the Netherlands or both, without querying tools.
An explicit follow-up may retain countries identified in earlier user messages.
The turn context must not unconditionally demand tools before that clarification.
A repair-time follow-up such as "How long until it's fixed?" retains those
previously explicit countries and still needs fresh evidence, even though no
repair estimate is available. It must not be mistaken for a new ambiguous region.

Full structured evidence remains in the runner result and the browser's
collapsed **Technical evidence** section. Teams stores a bounded private
provenance receipt (tool, evidence ID, source, observation/query times and status);
ordinary messages and `/status` do not automatically append that metadata.
`/status` can repeat a saved technical answer if one was explicitly requested,
and continues to label it as historical, not fresh evidence. An explicitly
technical question can display the current turn's evidence. Fixture replies
retain a short synthetic demo notice; live replies using store context identify
it as demo data without repeating the full engineering disclaimer.

The human-reviewed business-answer and country-clarification updates were
published to both backends with the matching owned prompt-agent version; both
packages passed 119 cloud unit tests. On 27 October 2026 a distinct 13-case model
evaluation completed with 10 passing cases. Country clarification and reported
slowness passed. Two safe captured answers were falsely rejected because the
checks missed "can't prove" recovery wording and a typographic apostrophe in
missing-evidence uncertainty. The repair-time follow-up failed closed because
the model did not retrieve the required current evidence.

The follow-up context and checker corrections were human-reviewed and published
in PR #72. Both cloud packages passed 121 unit tests and matched the reviewed
agent/evaluator source hashes. A distinct fresh model run passed 11 of 13 cases,
including the repair-time follow-up, country clarification and recovery wording.
The unavailable-data case failed closed because the required impact evidence was
missing. A safe refusal was falsely rejected because its curly apostrophe and
nonbreaking hyphen did not match the refusal checker.

PR #73 subsequently published the protocol-level evidence correction and shared
answer normalization to both hosts: 125 cloud tests per host and a distinct
13-case real-Foundry fixture run passed. Those fixtures did not include measured
slow-success evidence. The presenter-led latency rehearsal on 27 October exposed
the gap: the live reader counted failures but omitted duration. The expanded
15-case fixture evaluation now covers measured slow successes, normal speed and
repair-time uncertainty during slowness. After human review and merge, PR #74
was published to both hosts with a new pinned prompt-agent version. Both hosts
passed 138 cloud unit tests, and a distinct real-Foundry fixture run passed all
15 cases. A separate read-only live observation acknowledged slower successful
checkouts in Belgium, normal speed in the Netherlands and no reliable repair
time. This verifies the backend answer, not an actual user conversation through
Teams; that business-facing acceptance remains pending. The Teams host required
an explicit start after its successful deployment left it stopped; deployment
was not replayed. Historical unknown and failed jobs are retained and are not
replayed.
No broader access or proactive notifications are authorized by these changes.

### Bounded observations

Use a small allowlist covering checkout health, store context and impact.
The agent may choose those tools and bounded country/time parameters; it
cannot choose a subscription, workspace, owner, query or command.

The server binds live queries to an explicitly supplied owned checkout
manifest and exact workspace. Its telemetry identity gets read access only
on that workspace; the model gets no infrastructure write permissions.
Do not adopt an arbitrary existing workspace or silently fall back to fixtures.

### Independent SRE progress check

**Source implementation, not live acceptance.** Each operational health/impact
call also obtains a new, bounded `sreProgress` observation. No new model tool or
extra model round trip is required. Opening-hours-only requests do not read SRE.
Replies explain checkout conditions and SRE status independently, including
after checkout checks return to normal:

| Observed SRE state | Business meaning |
|---|---|
| `investigating` | The correlated thread currently reports running investigation. |
| `awaiting-approval` | A native human decision is pending; no claim that repair executed. |
| `executing` | An action is pending/running, not proof it succeeded. |
| `idle` | No active thread work observed; this alone does not mean finished. |
| `reported-complete` | The latest dated assistant message explicitly reports investigation complete, the thread is idle, and no action remains unsettled. Not verified customer recovery. |
| `not-found` | The matched alert has no SRE incident yet; not proof nobody is working. |
| Unknown/unavailable | Progress cannot be confirmed; checkout observations remain separately usable. |

For example: "Checkout checks are failing in Belgium and the Netherlands. SRE
is investigating the matching incident, but there is no reported cause yet."
After normal-looking checks: "The latest checks look normal. SRE reports its
investigation complete and says the shared price service was stopped; these
checks do not by themselves confirm full customer recovery."
These are examples, not current incident observations.

The GET-only reader revalidates the exact owned SRE resource and its endpoint
before sending a separate `https://azuresre.dev` token. Alert discovery is
restricted to the attached workspace, the two recorded checkout rule IDs and
the checkout deployment generation. Service alerts must not predate the current
controller-recorded fault. Multiple eligible occurrences, incomplete pagination,
linkage mismatch, unrecognized schemas, failed authorization and transport
errors cannot establish progress. Resolved service alerts are considered only
within 30 minutes of their start and must match the controller-recorded fault.
Latency telemetry has no authoritative fault-occurrence token: only a currently
fired latency alert is eligible. A resolved latency investigation is not reused
for a later slowdown, even if it is recent. After latency alert clearance, or for
a longer resolved service incident, SRE follow-up remains unknown until a
separately reviewed correlation contract is extended.

Each SRE read has a cancellable 20-second overall budget including managed-identity
token acquisition, five-second HTTP waits, no retries or redirects, bounded
response bytes, at most 100 discovered alerts and at most 200 thread messages.
It uses a dedicated asynchronous system-assigned managed-identity credential,
closes its transports on completion/cancellation, and leaves no background
token-acquisition task running. See the [asynchronous managed-identity credential reference](https://learn.microsoft.com/python/api/azure-identity/azure.identity.aio.managedidentitycredential?view=azure-python).
Raw thread text, commands, identities and resource IDs
never cross into the business agent. Only explicit latest assistant conclusions
matching the supported price-service/Belgian legacy-route cause vocabulary
produce a canned, attributed **SRE-reported** cause; other causes remain
unconfirmed. Reduced incident references and scenario kinds keep concurrent
service and latency observations separate; aggregate completion requires every
relevant incident to report completion, and causes cannot cross incident kinds.
Missing or differently shaped dated assistant messages leave
completion and cause unconfirmed. A user message cannot establish either.

Answer guards distinguish an explanation of unavailable evidence from an asserted
incident cause and normalize typographic apostrophes in uncertainty statements.
Explaining that stores are flagged for investigation because operational evidence
is missing or untrusted is a priority explanation, not an SRE-reported cause.
This exception does not admit a technical cause or extra causal clause.
Likewise, "SRE hasn't reported a confirmed cause" is uncertainty, not a cause
claim; other claims in the same sentence are still checked.
An explicit "because recovery isn't proven, we can't assume the issue is fully
resolved" caveat is also uncertainty; adding a technical explanation still fails
the cause guard.
Reported causes retain their exact supported wording and SRE attribution in the
same sentence. An unsupported operational claim uses the existing single answer
rewrite, shared with presentation and SRE corrections; a repeated unsupported
claim fails closed without another tool call or a larger turn budget.
Fixture recovery checks recognize explicit caveats such as "doesn't guarantee
resolution" and "recovery hasn't been independently proven"; those caveats do
not establish live recovery.

The native preview message format (`author.role`, `text`, `timeStamp`) is
normalized alongside the fixture message format. Only an exact `SREAgent`
author's completed plain-text message may report a conclusion. A newer user,
reasoning, incomplete, tool or attachment message hides older conclusions;
ambiguous timestamp ties and mixed message schemas do not establish one.
Raw identity metadata and message text still do not enter the business agent.

The fixture CLI evaluator retains bounded, identifier-redacted answer drafts
in its existing private evaluation receipt, including drafts rejected by the
answer guards. This capture is opt-in and fixture-only, not enabled by browser
or Teams turns, and is absent from compact results and logs. It adds no model
rounds or retries. Follow-up cases retain their explicit synthetic user scope
even when an earlier case fails, without fabricating a successful assistant reply.

New `Attach`/`TeamsAttach` bindings record the owned agent endpoint/resource,
alert rules and checkout generation. They add a per-host owned custom role
with only `Microsoft.App/agents/read`, `threads/read` and
`incidentManagement/read`, assigned at the exact SRE agent. This intentionally
does not grant SRE Administrator/Standard User or the broader built-in Reader
role. Existing workspace-scoped Log Analytics Reader remains separate.
Readiness verifies the exact custom role and assignment. Detach/Down removes
both external assignments and the owned custom role, retaining ownership state
until absence is independently checked. Browser and Teams bindings remain
independent; ordinary Up preserves both.

Existing telemetry-only bindings keep working, but report SRE progress as
unavailable. After human review/merge, obtain separate deployment/access
approval, publish a newly bootstrapped pinned prompt version to both enabled
hosts, then explicitly detach/reattach the selected host to opt into SRE reads.
Do not silently expand an old attachment. Run the cloud fixture evaluation and
fresh actual-channel checks for investigation, approval wait, normal telemetry
while SRE remains busy, explicit SRE conclusion/cause and denied SRE access.
The preview incident/thread/message schemas and scoped alert discovery must be
verified with that deployed runtime identity; presenter access and offline
fixtures do not prove them. No live permissions, resources or incident state
were changed for this source implementation.

Store maps and opening hours are clearly labeled synthetic demo data.
Time zones, date boundaries, opening calculations, failure interpretation
and priority rules run in code, not in model arithmetic.

The map uses the checkout POS simulator's eight synthetic identifiers so that
observed checkout failures can join to opening context:

| Belgium | Netherlands | Synthetic daily local hours |
|---|---|---|
| `BE-101` | `NL-401` | 07:00-22:00 |
| `BE-102` | `NL-402` | 08:00-20:00 |
| `BE-205` | `NL-517` | 09:00-21:00 |
| `BE-310` | `NL-620` | 07:00-22:00 |

These schedules are demo assignments, not verified retailer opening hours.
Interrupted/recovering fixtures use `BE-101` and `NL-401` for direct failures;
other stores can be exposed without observed store-level failures. An offline
cross-app inventory contract guards against identifier drift without a runtime
dependency between the independently packaged applications. This correction
requires backend deployment after review; it does not update an existing
deployment or establish new live acceptance.

Fixture evidence older than 180 seconds, missing observations, unhealthy source
connections and ownership mismatch cannot produce a healthy or recovered
conclusion. Distinguish observed affected stores from other stores exposed
to the same dependency. A healthy baseline is not proof that a particular
recorded incident recovered.

Live evidence is bound to the attached checkout's owner token, not to a fault
run. The newest owned Arc service observation must be at most 300 seconds old
(allowing Log Analytics ingestion delay), and checkout requests are sampled from
the last five minutes. The service controller's marker is reported as
`serviceIncidentPhase` (`no-fault-recorded`, `fault-active`, `recovering` or
`recovered`) without exposing its run or actor. A `recovered` phase records a
repair; it is not verified customer recovery, and `recoveryProven` stays false.
Missing, stale, malformed or unowned observations return an explicit unknown.

Country speed is computed directly from successful `POST /checkout`
`AppRequests.DurationMs` samples in the same fixed resource and five-minute
window, for POS/web channels only. Failed fast requests never qualify as normal
speed. The country p95 is not an average of store percentiles. At least five
finite, nonnegative successful durations and a fresh successful observation are
required; p95 at or above 500 ms is slow, matching the demo readiness baseline,
not a contractual SLA or a change to the Azure Monitor alert threshold.
`successfulCheckoutLatency` exposes status, sample count, p95, time, window,
threshold and explicit unknown reason. Insufficient/missing/stale/invalid
measurements cannot produce normal speed or overall healthy checkout status.
Known failures or an unhealthy service still establish degradation when speed
is unknown. This is measured server request duration, not total human queue time.
See [AppRequests](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apprequests)
and [Kusto percentile](https://learn.microsoft.com/en-us/kusto/query/percentiles-aggregation-function?view=azure-monitor).

Measured country slowness gives open/opening synthetic stores P2 attention and
closed stores P3, explicitly as country evidence, not proof of measured delays
at every store. Direct observed failures retain their existing priority;
slowness alone establishes neither shared-dependency failure nor store outage.

Fixtures are an explicitly selected test mode, never a live-data fallback.
Healthy, slow, interrupted, recovering and stale fixture states remain identifiable
in structured tool results and evaluation receipts. Final replies explain the
supported condition in plain language and identify demo data without printing
internal fixture-state names. A synthetic fault does not constitute
verification of an actual checkout service outage.
The slow fixture has successful Belgian checkouts around two seconds, normal
Dutch speed and no failures or shared-dependency outage.

## Implementation sequence

1. Inspect current Foundry/hosting APIs and verify tooling.
2. Implement deterministic tools and negative tests for execution in Azure.
3. Implement bounded Foundry function-call execution, conversation isolation,
   browser protections, explicit failures and private Azure trace capture.
4. Add owned Foundry infrastructure and lifecycle commands. Verify tenant,
   region, model availability, ownership tags and cleanup before provisioning.
5. Create the real agent and run the evaluation set against real model calls.
6. Verify browser interaction, fresh follow-up calls, refusal/unknown behavior,
   reset and teardown. Recreate only if retaining a working demo is intentional
   and its ownership and informational retention intent are recorded.
7. Attach a separately owned checkout deployment for live telemetry acceptance.
   Do not claim a fixture evaluation proves this integration or an Arc repair.
8. Record verified boundaries, update #45 and open a PR for human review.

## Acceptance

| Gate | Required evidence |
|---|---|
| Agentic behavior | Real model-selected tool calls; different questions retrieve appropriate evidence rather than canned answers. |
| Follow-up | Recovery questions retrieve a new observation, not a cached previous answer. |
| Correctness | Opening/time-zone boundaries, priority rules, observed versus exposed stores, healthy and stale cases pass deterministic tests. |
| Safety | Ownership/scope mismatch, arbitrary tools/arguments, write requests, unbounded input and cross-conversation access are rejected. |
| Honesty | Synthetic data is labeled; stale or unavailable evidence is unknown; no fabricated loss/recovery claims. |
| Browser | Actual browser-to-backend-to-Foundry interaction; no Azure tokens in browser content or public logs. |
| Lifecycle | Repeatable owned setup/readiness/reset/down; independent residual check and retained receipts. |
| Live integration | Exact owned workspace query and fresh checkout evidence; reported separately from fixtures. |

## Documentation sources

- [Foundry agent configuration and consumer access](https://learn.microsoft.com/azure/foundry/agents/how-to/configure-agent)
- [Pinned SDK 2.9.0 agent endpoint and version-selection example](https://github.com/Azure/azure-sdk-for-python/blob/azure-ai-projects_2.9.0/sdk/ai/azure-ai-projects/samples/agents/sample_agent_basic.py)
- [Foundry consumer role and project-scoped access](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)
- [Foundry custom tool function calling](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/function-calling)
- [Foundry agent identities](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)
- [App Service Entra sign-in, including secretless federation](https://learn.microsoft.com/azure/app-service/configure-authentication-provider-aad)
- [Configure an application to trust a managed identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)
- [Azure SRE Agent API reference (preview endpoints and separate token audience)](https://learn.microsoft.com/azure/sre-agent/api-reference)
- [Azure SRE Agent roles and read-only data actions](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/management-and-governance#sre-agent-reader)
- [Custom Azure roles via REST](https://learn.microsoft.com/azure/role-based-access-control/custom-roles-rest)

## Operator commands

Use the authorized demo subscription and tenant values; do not change the
Microsoft/home tenant. These commands do not start a local web application.

```powershell
$subscriptionId = '<authorized-demo-subscription-guid>'
$tenantId = '<authorized-demo-tenant-guid>'

.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Preflight -SubscriptionId $subscriptionId -TenantId $tenantId
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Up -SubscriptionId $subscriptionId -TenantId $tenantId
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Ready -SubscriptionId $subscriptionId -TenantId $tenantId
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Verify -SubscriptionId $subscriptionId -TenantId $tenantId
```

`Up` prints the deployed browser URL after readiness. Sign in with the assigned
demo-tenant operator, not an unassigned account. App Service enforces tenant and
operator admission before application requests. No client secret, Teams license
or browser-side Azure credential is needed.
Publication runs the deterministic tests inside the Azure application container
before granting bootstrap access or configuring the agent. A failing or empty
suite stops setup.

The runtime uses the named agent's Responses endpoint, not the general project
inference endpoint. Bootstrap configures the Responses protocol with a single
100-percent version-selection rule and verifies the returned version before
pinning it in the ownership receipt. Reusing a matching owned definition also
reconciles this endpoint configuration. The permanent application role is
project-scoped **Foundry Agent Consumer**; agent-management permission exists
only during the separately recorded bootstrap grant. The SDK's agent endpoint
feature is explicitly enabled. Conversations remain stateless with `store=False`;
no hosted container or managed Copilot harness is introduced.

Only `/health/live` is anonymous: it returns a constant liveness result without
configuration or evidence. App Service uses it for startup and health checks;
all browser and business API routes still require operator authentication.
Readiness checks actual backend liveness, not just a sign-in redirect.

`Verify` executes the deterministic tests and real Foundry evaluations inside
the Azure application container. Temporary startup jobs write private receipts
on its owned shared volume; they are not public web endpoints. Normal startup
is restored afterwards. Jobs run alongside the web process so model evaluations
do not block App Service startup. Each job has a one-time claim to avoid
automatically repeating a possibly completed operation after a container restart.
Publication and observation have explicit deadlines;
a timeout is not proof that a deployment or command never ran.
Verification restarts the application and can clear active in-memory conversations;
run it before a browser rehearsal.

Managed-identity token acquisition has a 5-second connection timeout, a
30-second read timeout and one retry. Agent management retains a separate
35-second read timeout without retries. Failed management commands record
sanitized stage, timing, error-type and stack-frame metadata in private job
stderr, never exception bodies, credentials or HTTP headers.

For the clearly labeled synthetic demonstration:

1. Select the interrupted fixture and ask which BE/NL stores need attention.
2. Inspect the tool evidence trail: actual tool names, observation times and
   evidence identifiers must accompany the answer.
3. Select the healthy fixture and ask for a fresh recovery check.
4. Select stale evidence and confirm that the agent reports uncertainty.
5. Reset the conversation before another run.

These fixture controls do not stop, restart or repair the checkout estate.
For a real incident, first attach and verify a separately owned checkout
deployment. The presenter must trigger any real showcased fault, as required
by the [delivery plan](implementation-plan.md#presenter-triggered-live-incidents).
An assistant/test runner must not inject it on the presenter's behalf.

### Live checkout evidence

Attach requires an owned checkout deployment in the same subscription with Arc
and its service controller installed (`Up -WithArc`, `ProbeArc`, `PrepareArc`,
`Ready`):

```powershell
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Attach -SubscriptionId $subscriptionId -TenantId $tenantId -CheckoutEnvironmentName checkout01
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Observe -SubscriptionId $subscriptionId -TenantId $tenantId
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Detach -SubscriptionId $subscriptionId -TenantId $tenantId
```

`Attach` validates the checkout ownership manifest and resource-group owner tag,
records a role-assignment name before creating it, grants the runtime identity
**Log Analytics Reader** on that checkout workspace only, switches the app to
`live` and runs one `livecheck` job. New grants can take minutes to apply; rerun
`Observe` if evidence is still unknown. The browser fixture selector is disabled
in live mode. Redeploying with `Up` carries the recorded binding forward.

`Observe` reads BE/NL health and asks the real agent once in Azure. Its receipt
(`incident-livecheck.json`) records evidence status, freshness, phase, counts,
tool names and `recoveryProven`; the answer text stays in the private job receipt.
It observes; it never declares recovery or repairs anything.

`Detach` returns the app to fixtures, then removes the verified grant. `Down`
also removes that grant, because it lives outside the assistant's resource
group. Detach the assistant before tearing down the attached checkout
deployment. `Verify` always evaluates the agent against fixtures, whichever
mode is attached.

Reset the whole assistant or remove its owned resources with:

```powershell
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Reset -SubscriptionId $subscriptionId -TenantId $tenantId
.\scenarios\retailx\scripts\Invoke-IncidentAgent.ps1 Down -SubscriptionId $subscriptionId -TenantId $tenantId
```

`Reset` rotates the evidence-run identifier and clears in-memory browser sessions
by restarting the app; it does not undo a separate live checkout fault.
`Down` removes the owned Azure group, Entra application and service principal.
Ownership is checked before mutation; neither same-name resources nor arbitrary
workspaces are adopted.

The template explicitly owns and tags Application Insights' default
[smart-detection action group](https://learn.microsoft.com/azure/templates/microsoft.insights/2023-01-01/actiongroups)
and [failure-anomaly alert](https://learn.microsoft.com/azure/templates/microsoft.alertsmanagement/2021-04-01/smartdetectoralertrules).
Readiness and teardown both reject unowned resources, including monitoring
dependencies; teardown does not exempt resources merely because they resemble
provider-generated defaults.

The non-secret ownership, readiness, verification and residual receipts stay in
the ignored `.azure\<environment>\` directory. Keep them until cleanup is
independently confirmed. Before archiving a disposable worktree, preserve these
files in a private durable location. Restore the ownership manifest under
`.azure\<environment>\` in the checkout used for `Down`; do not reconstruct
ownership from resource names. Provider soft-delete and telemetry retention can remain
after active resources are deleted: `Down` reports this rather than claiming a
purge.

`RetentionDays`, the manifest's `expiresAtUtc` and the `expiresAt` resource tag
are informational retention metadata, not an enforced environment deadline.
A past timestamp must not block browser or Teams readiness, publication,
verification or continued demo use. Do not add a separate publication-helper
expiry gate. There is no automatic shutdown, deletion or billing cutoff:
the presenter explicitly pauses or tears down the owned demo when finished.
Ownership, same-run evidence freshness, session expiry, human approvals and
unknown-outcome/no-replay controls remain enforced.

## Execution evidence

The machine's existing azd was incompatible with the current Foundry extension.
A checksum-verified, task-local compatible CLI completed the required dependency
preflight without replacing the shared global installation.

Azure provisioning has created the model, restricted Foundry project,
Entra-authenticated hosting and secretless sign-in federation. The same
manifest was safely reused for another provisioning pass.
Remote application builds, constant backend liveness, agent creation/version
reuse and all platform readiness checks have passed. The temporary agent
configuration grant is removed; the web runtime retains only project-scoped
Foundry Responses access.

The latest Azure application-container run passed all 61 deterministic tests
with zero failures or errors, including the private-diagnostic regressions.
The first real-model run
attempted all ten cases but every Responses call was rejected. Owned Application
Insights dependency telemetry independently confirms HTTP 403 responses, rather
than inference timeouts. This is not a successful agentic-behavior proof.
Network and permission changes require the actual denial evidence.

Real-agent evaluations, tool-event ingestion, interactive browser acceptance,
reset and repeated lifecycle acceptance remain open. No local application or tests have
been run. The browser's demo-tenant sign-in page is reachable; completing sign-in
requires the assigned operator.

The first environment was removed at the operator's overnight shutdown request.
Azure and browser Entra residual checks passed after explicitly verifying and
removing two untagged, provider-generated monitoring dependencies. Its private
cloud receipts were archived before deletion. The template now declares those
dependencies with ownership tags; fresh-deployment acceptance of this fix remains
separate from that manually assisted cleanup proof.

A fresh Azure deployment passed platform readiness with both monitoring
dependencies owned. Its subsequent unassisted teardown passed without manual
resource deletion; independent checks confirmed the resource group, browser
application and browser service principal were absent.
The authorized single-request network control still returned an empty HTTP 403
with the IP restriction temporarily removed. The exact original selected-IP
policy was restored and verified, with API keys still disabled. This control did
not establish the IP allowlist as the cause; real-model acceptance remains blocked.

A separate actual-caller control temporarily restored the project-scoped
bootstrap role after a ten-minute propagation wait. The same request progressed
from the empty HTTP 403 to a structured HTTP 400; the temporary grant was removed.
This is evidence of a caller-permission boundary, not successful inference. The
implementation now follows the pinned SDK's named-agent endpoint and consumer-role
contract. A fresh Azure deployment configured and verified the fixed-version
Responses endpoint, passed 61 deterministic tests and readiness, and removed the
temporary bootstrap grant. All ten real-model cases then returned HTTP 400 with
the safe diagnostic parameter `reasoning`. The effort setting already belongs
to the immutable
[agent definition](https://github.com/Azure/azure-sdk-for-python/blob/azure-ai-projects_2.9.0/sdk/ai/azure-ai-projects/azure/ai/projects/models/_models.py#L16429);
the redundant request-level override is removed while
retaining stateless storage, encrypted reasoning replay, output-token and time
bounds. Fresh inference acceptance of this request correction remains pending.

A bounded in-Azure Responses contract probe (`Probe`) then isolated the remaining
HTTP 400: the named-agent endpoint rejects `developer`-role input items. Server
context (scope, fixture/live mode and time) now travels as a labeled prefix on
the user message, with the agent instructions unchanged. Prompt Shields block
write-request and injection prompts with an HTTP 400 `content_filter`; the
runtime returns a fixed read-only refusal and does not replay the blocked
prompt. One bounded server correction round requests evidence when an answer
omits a required current-evidence tool, and still fails closed.
After republishing, `Verify` passed in Azure: deterministic tests, and all ten
real-model evaluation cases, against fixtures. This proves agent behavior on
synthetic evidence, not live checkout integration.

Live acceptance then attached the assistant to a separately owned checkout
deployment (`Up -WithArc`, `ProbeArc`, `PrepareArc`, `Ready`). The first
`livecheck` after `Attach` reported `live_query_failed` while the new Log
Analytics grant propagated; `Observe` minutes later succeeded. Each `Observe`
takes about ten minutes because the cloud job restarts the app.

| Checkout state | Evidence | Agent answer |
|---|---|---|
| Healthy, before fault | `known`, about 130 s old; phase `no-fault-recorded`; BE/NL healthy, no failed checkouts | Healthy; no recovery claim |
| `Inject -Scenario service` | `known`, about 110 s old; phase `fault-active`; BE/NL degraded with failed and successful checkouts; shared dependency exposed | Active fault in both countries; observed failed stores separated from merely exposed stores; no outage, payment or loss claim |
| After the presenter approved the SRE Arc repair card | `known`, about 130 s old; phase `recovered`; service healthy; BE/NL still degraded because the five-minute window held pre-repair failures | Controller-recorded recovery is not proven recovery; no resolution claim |

All four `livecheck` assertions passed in each state, and `recoveryProven`
stayed false. The operator `Undo` fallback was correctly refused while the SRE
incident thread was unsettled. The POS simulator's failing store identifiers do
not overlap the synthetic opening map, so store priorities remain exposure-only.
This covers one incident; it does not establish repeated-run reliability.
