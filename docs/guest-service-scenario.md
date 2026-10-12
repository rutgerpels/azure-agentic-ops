# Native Azure VM guest-service feasibility

**Live-demo initiation:** the presenter explicitly runs the non-canary `Fault`;
preparation automation or an assistant stops before that command, even after a
readiness confirmation. Monitor detection/incident creation remains automatic.
New faults persist until explicit repair/reset/teardown. Apply the
[global live-demo rule](implementation-plan.md#presenter-triggered-live-incidents).

**Scope:** a stopped application service inside a running native Azure VM,
not VM start and not the Arc-managed host. Service Bus work remains parked.
This first gate proves a small guest fixture and the Azure VM Agent command
transport before adding a human-approved SRE repair. Azure Monitor intake
uses public HTTPS by default for fresh fixtures. Public ingestion/query and
automatic alert-to-thread routing are live-verified; the complete
human-approved incident has not passed acceptance. The fresh `demo33` test
verified actual human-approved guest recovery and eventual Azure action success,
but SRE reported a failed CLI result and needed a recovery-note correction;
see [the result-return boundary](#human-approved-monitored-repair-result-return-boundary).
Approval-free autonomy remains out of scope.

## Current manual-lifetime contract (2026-10-11)

Fresh fixtures use configuration version 2 and `faultLifetime=Manual`.
The recovery timer is disabled/inactive; an owned durable fault marker prevents
the worker starting automatically on a new boot. The read-only observer stays
enabled. No elapsed deadline, reboot or observer silently repairs an active,
partially injected or interrupted-repair run. Explicit repair/reset uses the
exact owner/run and protected sources. Human-approved SRE repair also binds the
original fault actor and refuses a recovered or replaced run.

An interrupted manual repair can be reset only after fresh exact guest
`failedCommand` evidence confirms that the validated handler finished and
released its exclusive controller lock. The observer cannot read that terminal
receipt while the handler is active. It is journaled as `guest-failed`, never
recovery; only explicit exact-run Reset/Down follows, not repair replay.
A missing terminal receipt remains unknown and blocked. Teardown is the escape
path when remote execution cannot be settled safely.

`FaultDurationSeconds` is rejected for new faults. `-Canary` is an optional
manual test fault that needs explicit repair/reset, not a required timer test.
Cycle/reboot testing verifies that the same fault remains stopped after the
new boot, then explicitly repairs it. Old manifests/proofs remain timed
history, not retroactively accepted manual tests.

Local controller/approval/lifecycle checks pass; native live persistence passed
in `demo35` below. The human-approved async end-to-end incident remains open.
The alert accepts fresh
exact manual-lifetime evidence without a deadline, while preserving old
deadline interpretation for legacy observations. Source, scope, freshness,
single-card human approval, no-retry and bounded Azure audit checks remain.

### Documented SRE permission baseline (2026-10-12)

The owner selected explicit provisioning and lifecycle ownership of Microsoft's
[Agent permissions in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/permissions)
baseline. These roles are documented as always assigned, even at Reader access
level. New `Up -WithSreExecution` deployments provision them for the disposable
**action UAMI**, rather than relying on later portal provisioning:

| Role | Exact scope |
| --- | --- |
| Reader | Owned guest resource group |
| Log Analytics Reader | Owned guest resource group |
| Monitoring Reader | Owned guest resource group |
| Monitoring Contributor | Authorized subscription |

This is **not resource-group-only isolation or a read-only agent**. Monitoring
Contributor includes subscription-wide reads and monitoring/workspace writes,
shared-key operations and deployment operations; it is not merely alert
acknowledgment. It does not itself grant VM Run Command or RBAC assignment writes.
Use a demo subscription where that monitoring boundary is acceptable;
`managedResources` is not an RBAC isolation boundary. All scenario authentication
remains Entra-based: do not use shared keys because a role can access them.

The separate custom role still grants only Action Run Command on the exact
disposable VM. Its controller/source/owner/current-run binding, Review mode,
real single-action human approval, denied alternative channels and no-OBO
repair policy are unchanged. Network Contributor on the exact SRE subnet and
explicit workspace readers remain separately recorded. The retained foundation
identity and its guest-write boundary are not changed.

The three new assignment IDs are generated once and saved as deployment intent
before Azure writes, passed to Bicep, and checked against deployment outputs.
Readiness requires their exact IDs, principal, definitions, scopes and no
conditional drift, including inherited grants; additional or missing grants
still fail. Both approval modes recheck those live permissions before proposal
submission and approval-ready output. NativeCompleted uses the read-only
`Inspect` operation, not a new guest diagnostic command or cached permissions;
AsyncAudit uses its existing operator Telemetry preflight. Both require an explicit,
fresh fixture-bound successful inspection result; skipping or declining a check
cannot create a proposal or approval-ready receipt. Read-only inspection does not
require mutation confirmation; guest-command telemetry retains its confirmation.
Reset does not replace these IDs. Down inventories and revalidates exact bindings before
deleting assignments by ID, including subscription scope, then verifies absence.
It waits for owned deployment intents to become terminal before deleting,
refreshes group ownership after that wait and independently verifies group absence,
checks every recorded baseline ID even if initially missing, and rechecks roles
after group deletion. Unknown deployment admission or a late assignment blocks
an absence claim instead of being silently adopted/deleted. It can find the
recorded subscription grant after the UAMI/group disappears; group deletion
alone is not sufficient cleanup.

Legacy fixtures are **not silently migrated**. Their original manifest remains
usable for guarded teardown, not new incident readiness. An unrecorded
product-created assignment must be resolved with explicit ownership/cleanup
authorization; it is not adopted because its role name matches. Do not rehash
the frozen live fixture to bypass source drift. The existing `demo36` fault,
assignment and resources are retained without mutation by this implementation.
Lease expiry is tag-only, not automatic recovery or deletion.

The staged `demo36` experiment found no subscription grant after deployment,
Review configuration, onboarding, a read-only VM question, monitoring setup,
fault injection or automatic incident creation. Opening the incident preceded
the first observed Monitoring Contributor assignment: Started `08:38:55Z`,
Succeeded `08:38:57Z` on 2026-10-12, before any repair proposal or approval.
The audit used delegated operator context through the SRE application, not
managed-identity self-authorization. Four distinct grants were observed across
the earlier fixtures and this experiment; these are not four proven
self-elevation incidents. The precise initiating portal/backend request is
unknown. Presence of this documented role alone is not unauthorized elevation:
the earlier custom deployment omitted a supported baseline and its stricter
absence guard rejected late provisioning.

Local deployment/lifecycle changes do not establish a new accepted live
incident. Fresh correctly declared baseline, human-approved repair and SRE's
independent recovery check remain the live gate in
[issue #25](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/25).
User-directed reusable skill implementation is now In Progress in
[issue #26](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/26).

### Opt-in native recovery skill (repository implementation, 2026-10-12)

The [native `guest-service-recovery` skill](agent-context/skills/guest-service-recovery/SKILL.md)
replaces operator proposal construction **only when explicitly selected**.
Normal `Connect` keeps the existing proof route. On a fresh, healthy monitored
execution fixture, select the new route before arming:

```powershell
.\scripts\Invoke-GuestService.ps1 Connect -SubscriptionId $subscription -EnvironmentName $environment -WithRecoverySkill
.\scripts\Invoke-GuestService.ps1 SkillCheck -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Arm -SubscriptionId $subscription -EnvironmentName $environment
```

Do not run these implementation commands against a frozen live fixture or
rehash its manifest to bypass artifact drift. A previously connected fixture
is not silently migrated. The parent/operator handles separately authorized
native upload and configuration for the retained environment; this repository
change performs no deployment, live reset, fault, proposal or Azure write.

The skill's frontmatter declares only built-in CLI read/write tools. The exact
owned investigator enables this skill with `enableSkills=true`,
`allowedSkills=["guest-service-recovery"]`, `addSystemSkills=false` and the same
explicit tool list. The response plan and platform remain Review; global
policies still ask for write/Run Command approval and deny terminal, shell and
`ExecutePythonCode`. A short `GuestRecoveryBinding` JSON reference supplies
subscription, VM, workspace, owner, action principal and selected transport.
It contains **no current or historical run/original-actor values**. SRE obtains
those independently from fresh LAW observations.

After the presenter explicitly triggers the fault, the Monitor incident routes
to the skill-enabled investigator. SRE investigates and builds the readable
controller wrapper, presents the actual `RunAzCliWriteCommands` card, and waits
for one human approval. No `Invoke-GuestServiceApproval.ps1 Propose` message is
required; that operation rejects skill-configured fixtures to avoid duplicate
proposals. The old approval proof harness is for the default route, not a claim
of skill-flow acceptance. The wrapper sends base64 **JSON request data** to the
unchanged controller API; it never hides an encoded executable script.
No controller, guest source, service unit or protected source-hash changes
are part of this feature.

Native async completion proves submission, not repair. SRE must independently
query fresh exact-run/original-actor Manual observations: active/healthy,
`recovered`, reason `repair`, `recoveredBy` matching the configured action
principal. It separately checks Azure audit using one `correlationId`, not
matching `operationId`, within a fixed 30-minute window. Unavailable evidence
remains unknown; failed output does not authorize replay. A neutral human
follow-up may initiate the same independent check without supplying an answer.
Neither skill instructions nor VM-scoped Run Command RBAC enforce service-only
scripts; the controller's checks apply when its API is used.

Lifecycle intent stores the owner-marked skill description, exact content/tools,
investigator and fixture identity before PUT. It refuses collisions, preserves
uncertain intent without automatic resubmission, and independently reads back
configuration even when create returns an empty response. `SkillCheck`, `Arm`
and real-fault readiness recheck live content, tool/skill binding, Review plan
and approval policy. `Reset` preserves the skill configuration, requires a
settled incident/card, terminal correlated Azure operations and later fresh
guest observation before mutating a previously submitted run. Pending/unknown
execution requires reconciliation or explicit `Down`, never replay.
After observed natural alert clearance, explicit exact-run Reset permits the
next presenter-triggered incident. Operator `Repair` is blocked in this route.
`Down` validates all recorded skill/investigator/plan surfaces before deleting
only those exact names, independently confirms absence and then continues
normal resource teardown. Repeated removal does not resubmit DELETE. Unrelated
skills are not adopted or deleted.

**Status:** locally implemented/tested configuration and wrapper contracts,
not live incident acceptance. Native API lifecycle/upload and human-approved
skill activation, action and SRE recovery reporting need their own live proof.
Issue #25 stays open; #26 is In Progress, not Done.

Sources: [Skills in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/skills),
[Create a skill](https://learn.microsoft.com/en-us/azure/sre-agent/create-skill),
and Microsoft's [native skill REST implementation](https://github.com/microsoft/mcp/blob/6ef5a3dd7e914f108293fa2aea42fe8dbad36be4/tools/Azure.Mcp.Tools.SreAgent/src/Services/SreAgentService.cs).
The implementation uses `PUT /api/v2/extendedAgent/skills/{name}` with
`type=Skill` and `properties.skillContent`, `description`, `tools`; listing and
exact deletion use the same collection. Unknown/incomplete response shapes
fail readiness rather than becoming an empty success result.
The current Microsoft [configuration sample](https://github.com/microsoft/sre-agent/blob/25a42306d298c4d28f11dd11ef9bb93cb0393be8/labs/zava-aks-postgres/scripts/_sre-config.ps1)
also specifies `additionalFiles=[]` and `sourcePluginInstallation=null`.
This self-contained skill requires those values at readback; unexpected files
or plugin provenance block readiness and deletion rather than being silently
accepted as owned content.

**Current native integration blocker:** the live session isolated HTTP 400 to the
first skill PUT, not investigator setup: root JSON conversion expected
`List<string>` and reported `request` required. Subsequent readback showed no
skill and an unchanged investigator. The deployed portal client independently
uses the same envelope/route but first enables native mode on `meta_agent`.
Repository upload/readiness therefore requires an explicit Boolean
`meta_agent.properties.enableVanillaMode=true` before any skill intent or PUT.
It only reads that prerequisite; it does not change the product-managed main
agent or assume mode alone fixes the observed HTTP 400.

The native MCP create attempt was cancelled at the tool-permission
prompt. No result or mutation is claimed for that cancelled attempt; do not
retry it or replace it with another write channel without renewed explicit
authorization. Native mode/runtime schema resolution and live acceptance stay
blocked outside this repository-only task. The draft PR preserves the tested
repository work, not a live upload success.

### Outcome-based demo acceptance

The user clarified on 2026-10-11 that a successful demo requires SRE to execute
the exact human-approved repair with the declared documented baseline and
VM-scoped action permission, without untracked permission drift,
then independently check fresh same-run service evidence and accurately report
the result. The check may happen automatically or after a neutral human
follow-up. Conversation wording and timing need not be identical on every run.
Automatic post-action confirmation remains an improvement target, not a blocker.

A valid follow-up is: "Is the issue resolved? Check the current service health
and report the evidence. Do not repeat the repair." It supplies no recovery
answer, audit result or corrective RCA. SRE must query the evidence itself;
stale, unhealthy or missing evidence requires an explicit pending/unknown/failure
answer rather than reassurance. A local Verify receipt is not an SRE check.
Service recovery and natural Monitor alert clearance remain separate outcomes.

The SRE-generated NSG seen in `demo34` is now handled consistently by readiness
and teardown **only** when its exact owned ID, location/tags, empty custom-rule
set, no NICs and sole mutual SRE-subnet attachment validate. An arbitrary or
modified NSG still fails. This prevents rebuilding for that already verified
platform-created resource without accepting general network drift.

The startup guard uses systemd's documented negated
[ConditionPathExists](https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml).
The condition prevents startup; it does not stop an already running service.
The explicit controller stop remains the real fault action.

### Historical persistence and async repair (`demo35`), acceptance incomplete

One fresh Public/Operator fixture used frozen source `131b7ed`, without a
watchdog canary or repeated rebuild. Independent SRE readiness queried the
healthy Manual receipt and running VM, then the developer harness triggered
one real stopped-service fault. This is a development test, not a live
presenter rehearsal.

| Gate | Evidence (UTC, 2026-10-11) |
| --- | --- |
| Exact fault | Run `29010052-f9e9-43f1-8081-6f3d9a0c94d6`, stopped at `19:23:31.797455`; Manual, no deadline |
| Real Monitor incident | Fired; thread `ff763446-c31e-4ced-89eb-e5a4b85f11da`; independent SRE diagnosis distinguished running VM from stopped service |
| Real reboot persistence | One operator-controlled VM restart; boot changed from `831f40e1-...` to `07f63c7e-...`; fresh `19:28:44.996482` receipt confirmed same stopped/unhealthy fault, recovery timer disabled/inactive |
| Past former ten-minute limit | `19:34:56.762602` receipt, 11.42 minutes after stop, still same stopped/unhealthy fault and new boot; no automatic repair |
| Human card | Exact AsyncAudit proposal in the original incident thread; guarded inspection at `19:39:21` found policy approval `79e4501e-d0df-497f-87ab-b7e65e3a4998` Pending, single-action scope, no thread allowance |
| Human decision | Exact single-action card Approved at `19:46:27.1171537` |
| Native async submission | Exact unchanged `--no-wait` command started `19:46:27.2925569`, Completed without error `19:46:31.1559119` (3.86 seconds); this is submission, not recovery |
| Guest recovery | Same run/original actor; recovered at `19:46:41.437917`, `recoveryReason=repair`, `recoveredBy` matched the SRE action principal (`889c464d-...`); 14.32 seconds after human approval |
| Azure completion | Unique correlation `97043b23-00ad-43c0-9039-b410e91a4feb`; Started `19:46:30.7242277`, Accepted `19:46:30.9898541`, Succeeded `19:46:53.3941675`; no command replay |
| Independent local verification | Fresh active/healthy same-run receipt and matching Azure audit produced `VerifiedWithoutFollowup`; no corrective SRE message was supplied |
| SRE outcome | Thread remained Idle with its stale “approval pending / recovery not checked” conclusion after Approved card and Completed execution; independent uncorrected post-action note absent |

**The original permission guard rejected this run.** Four expected scoped grants
were initially observed, but subscription-wide Monitoring Contributor
assignment `92f49a87-9c98-4c24-a825-09af6560f2e5` appeared on the action identity
at `19:44:46.582508`, during the approval interval. The guard stopped
acceptance. The owner explicitly authorized removal of only that assignment;
exact deletion and restoration of the four-grant scoped inventory were
independently verified. Later deletion is not proof of scoped-only execution.
The precise portal gesture is not established. The documented-baseline
correction above supersedes the assumption that this role must be absent.
This was unrecorded provisioning under the old deployment, not evidence that
the action identity authorized itself. It is not a new declared-baseline proof.

The run also failed the earlier, stricter unprompted-conclusion criterion.
Under the clarified demo acceptance above, a neutral human follow-up is allowed;
none was attempted before teardown, so prompted SRE verification is not proven
for this run. The change does not retroactively accept scoped-only execution
or turn the local recovery receipt into an agent conclusion.

The asynchronous approach solved the old long-running native-tool result
problem in this attempt and actual human-approved guest recovery is proven.
It did **not** establish explicitly owned baseline provisioning or automatic SRE
post-action continuation. Natural Monitor resolution was observed separately,
without acknowledgment or forced closure. Explicit owned Reset ran only after
preserving the SRE recovery evidence. Down and repeated Down returned deleted
state. Independent read-only checks at `20:15:03Z` confirmed the resource group,
owner-tagged resources, exact custom action role, all action-principal grants
and active/soft-deleted workspace absent. The final checker initially used an
empty role field; reading the original saved role identity completed verification
without replaying teardown. The retained Arc/private foundation was not modified.
Do not replay the repair or start another full incident cycle to hide the
remaining permission and recovery-verification gates.

[Baseline and recovery validation](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/25)
records the declared-baseline live gate and optional automatic-continuation target.
This does not prove new Windows/broker live behavior, a presenter rehearsal or
retail recovery.

## Monitor transport decision (2026-10-10)

**User-directed baseline:** proceed with public HTTPS Azure Monitor ingestion
and queries, retaining managed identities, Entra RBAC, disabled local
authentication and the same Monitor-triggered incident/approval gates. A
read-only policy review found no assigned LAW/DCE public-access prohibition,
including inherited management-group assignments. The storage and Key Vault
public-access restrictions are resource-type specific.

**Implemented baseline, public connectivity verified:** the commands below create
an owned LAW with public ingestion/query and disabled local authentication.
No DCE is required for public Syslog; no AMPLS, Monitor private endpoint,
private DNS links or guest/agent peering is created. The transport is immutable
for a fixture. Existing manifests without a transport remain Private; they are
not silently migrated. Do not enable public access on the retained foundation.
Each fresh fixture must prove current AMA ingestion and actual SRE query access
before any real fault or approval. The first public proof below required
investigator guidance; connectivity success is not autonomous diagnosis acceptance.

AMPLS investigation and a full-private Monitor profile are deferred in
[the optional private-profile backlog](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/20).
The failed comparisons below remain evidence, not a root-cause fix. Private
transport is a later customer-policy/profile gate, not a prerequisite for the
baseline operational story in this subscription.

The same public Monitor baseline is intended for **future fresh Arc profiles**
after the native path is verified. Keep the retained working Arc host,
workspace/private endpoints and attested manifests unchanged until an explicit
replacement/migration is implemented. Deferring Monitor AMPLS does not remove
Azure Arc, AMA or Azure Monitor, change the Arc control-plane Private Link Scope,
or authorize changes to other services' private-endpoint requirements.

## Azure Monitor intake (implemented, live acceptance pending)

Create a **fresh** fixture with both `-WithSreExecution` and `-WithMonitoring`.
Do not retrofit source-attested proof fixtures or reuse their approval receipts.
The opt-in provisions a system identity, AMA/DCR Syslog collection,
an initially disabled stateful alert and an exact-VM Review response plan.
The shared SRE Agent is not reconfigured or granted guest-write authority.

An independent thirty-second observer reads the attested service/localhost
health and emits bounded `RetailTxGuest` JSON in local0/Info Syslog. It does not
repair anything or write the fault state. New recovery timers are disabled.
The alert selects the **latest source
observation**, not ingestion arrival order, for the exact VM and owner, and
requires a fresh active non-canary stopped-service fault under its lifetime contract.
Missing telemetry is unknown, not a healthy result or a fabricated service-down
incident. A manual canary deliberately does not trigger this alert.

The VM still has no public VM IP or inbound SSH, and retains explicit NAT
egress and outbound HTTPS rules. Public query/ingestion DNS must resolve to
global IPv4 addresses; private resolution never falls back to public or vice
versa. The selected transport and both endpoint address sets are recorded.
The retained workspace, DCE and AMPLS stay unchanged and are never deleted.
Query-only workspace grants for the VM, alert and isolated
agent identities are recorded before creation, validated and removed on Down.
Readiness queries default to the VM system identity via an explicitly
operator-run diagnostic command; they are not SRE guest execution. The explicit
[direct-incident mode](#direct-incident-rehearsal-with-operator-law-reads) instead
reads LAW using the operator CLI identity, without a guest diagnostic.

```powershell
$subscription = '<subscription-guid>'
$environment = 'demo01' # Select an unused neutral environment.
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName $environment -WithSreExecution -WithMonitoring -MonitorReadMode Operator
.\scripts\Invoke-GuestService.ps1 Monitor -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Connect -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Arm -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Incident -SubscriptionId $subscription -EnvironmentName $environment
```

Wait for the **automatically created** investigation identified by Incident;
do not use `Invoke-GuestServiceSre.ps1 Investigate` or create a substitute thread.
After it becomes idle, collect a fresh Status receipt and supply the existing
exact-command proposal adapter with that incident's thread ID:

```powershell
.\scripts\Invoke-GuestService.ps1 Status -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestServiceApproval.ps1 Propose -SubscriptionId $subscription -EnvironmentName $environment -IncidentThreadId '<verified-incident-thread-guid>'
.\scripts\Invoke-GuestServiceApproval.ps1 Read -SubscriptionId $subscription -EnvironmentName $environment
# Only after Read verifies an exact, unexpired card may a human approve it.
# If Read rejects an altered/stale card, reject/cancel it in SRE; never approve it.
.\scripts\Invoke-GuestServiceApproval.ps1 Verify -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Incident -SubscriptionId $subscription -EnvironmentName $environment
# After Monitor is Resolved, reset and archive this run's approval receipts.
.\scripts\Invoke-GuestService.ps1 Reset -SubscriptionId $subscription -EnvironmentName $environment -RunId '<current-run-guid>'
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
```

The operator adapter supplies the exact proposal **in the alert-created thread**;
it does not initiate investigation or approve execution. A stale/wrong-run
thread, altered command or recovered/expired fault is rejected. Approval is
still human-only and VM-scoped privileged scripting, not a service-only enforced
permission. Before another real fault, fresh healthy telemetry and resolution
of the previous alert are required. Reset can restore the service while alert
clearance remains pending; it reports that incomplete reset explicitly.

**Live gates remain:** independent same-run SRE fault diagnosis without corrective
messages; an exact, unexpired repair card and human-approved execution in that
same thread; independent action-identity audit and fresh same-run repair recovery;
repeatable monitored reset/reboot/teardown. Public AMA
ingestion, authenticated query access and automatic routing have individual
evidence below, not complete incident acceptance. None is inferred from
local tests, Bicep compilation or the older demo23/demo25 evidence. If
SRE reads fail, report the boundary rather than enable terminals or broaden
permissions. Measure alert latency, application recovery, SRE confirmation and
automatic clearance separately. The incident remains unacknowledged by design.

References: [AMA installation and identity](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage),
[Syslog collection](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection-syslog),
[AMA network configuration](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration),
[Monitor private-link configuration](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure)
and [DCE requirements](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-endpoint-overview).

### First public Monitor proof: connectivity passes, repair blocked

**2026-10-11, `demo28`:** fresh deployment and monitoring configuration succeeded
with an owned LAW, public ingestion/query enabled and local authentication
disabled. The seventeen-resource inventory contained no DCE, AMPLS, Monitor
private endpoint/DNS resources or guest/agent peerings. The retained Arc/private
foundation was not changed.

All timestamps below are UTC. Fresh AMA Syslog observations and VM-system-identity
queries passed the unchanged three-minute source-time gate after ingestion
warm-up; missing/stale results were rejected. Query/ingestion DNS resolved to
global IPv4 addresses. The sixty-second canary started at `09:32:19` and recovered
independently at `09:33:24`, with `recoveredBy=watchdog`.

The SRE built-in `RunAzCliReadCommands` query returned authenticated Syslog
evidence after an explicit tool-discovery correction. The agent initially
claimed that zero connectors meant no query tool; that claim was incorrect.
[Built-in Log Analytics queries do not require a connector](https://learn.microsoft.com/azure/sre-agent/connectors).
Terminal, shell and Python execution remained denied; identities and permissions
were not widened.

| Evidence | Result |
| --- | --- |
| Real non-canary fault | Run `1baccb11-90f1-43b1-9444-043b8228a199`, started `09:48:19`, deadline `09:58:19` |
| Actual Monitor alert | Fired at `09:50:09`, alert `9f8a4811-d445-8a18-558e-d76999950033` |
| Automatic SRE investigation | Thread `deaf7e64-47f7-4f07-a1b7-75ce206df1b3`, not the separate healthy readiness thread |
| Independent fault diagnosis | **Not accepted:** needed tool guidance, then used case-sensitive ARM-ID equality and wrong JSON field paths; reported UNKNOWN |
| Repair proposal | Operator adapter supplied an exact command in the automatic incident; SRE changed `/opt/retailtx-guest/controller.py` to `/opt/retailtx-gust/controller.py` in the encoded payload |
| Approval boundary | Exact-command validation rejected card `18b7b428-7ec6-4bde-a9c4-57056b6c4a85`; no approval or native repair execution was submitted |
| Independent recovery | Watchdog restored that exact real run at `09:58:25`; Status verified active/healthy service and `recoveryReason=deadline` |
| Recovery in LAW | Operator-authenticated query returned same-run recovered Syslog with source time `10:03:32`; this is not an SRE repair |
| Natural Monitor clearance | Resolved at `10:09:11`, about 10 minutes 46 seconds after watchdog recovery; no acknowledgement or forced resolution |

The subsequent VM-identity telemetry diagnostic timed out after 180 seconds.
Its query outcome remains unknown, not proof of nonexecution or a LAW outage;
the separate read-only operator query reconciled actual ingested recovery.
The card was still Pending with no native execution at the last pre-cleanup
inspection. No human was available for rejection or repair, and no additional
fault/repair rehearsal was attempted. Human-approved recovery,
action-identity repair audit and an accepted incident RCA remain open.

Two Down calls verified absence at `10:20:25` and `10:20:56`, including the
owned workspace in both active/recoverable inventories, recorded grants,
custom role, fixture group and owned tagged residuals. The VM and isolated
agent were deleted; the stale card was not approved or represented as human
rejection. No portal action remains on this removed fixture. Monitored Reset
and a second incident cycle were not attempted.

Local corrections to investigator guidance and empty-query diagnostics do not
retroactively validate this failed diagnosis/proposal. A fresh monitored
human-approved rehearsal is required before claiming the full operational loop.
The investigator now names the built-in read tool, supplies the case-insensitive
owner/VM query and nested marker schema, and stops before a proposal without
fresh fault evidence. Empty aggregate receipts fail with an explicit
no-observation diagnostic, never a healthy fallback. Exact encoded-command
comparison, Review and human-only approval remain unchanged. These corrections
were made only after fixture absence; their live effectiveness is not yet verified.

### Fresh public rehearsal: blocked before the real incident

**2026-10-11, `demo29`:** a fresh fixture on the corrected implementation
deployed successfully. Monitoring remained disabled for real incidents.
Its seventeen-resource inventory contained no private Monitor resources.
The sixty-second canary, run `6a0ce64b-d756-4417-ab1a-f893a0d15e1b`, started
at `10:56:44 UTC`; the watchdog recovered it at `10:57:47 UTC`. Operator
Status verified the exact recovered run, active/healthy service and watchdog.

The next VM-system-identity telemetry diagnostic timed out after its
180-second local wait. A subsequent read-only attempt failed. Activity Log
showed the initial diagnostic Started / Accepted at `11:01:05 UTC`, without
a completion event in the inspected receipt. The result is **unknown**, not
proof that the query never ran or a confirmed network/authentication failure.
No new command transport, identity, grant or readiness exemption was added.

A separate operator-authenticated LAW query at `11:04:34 UTC` returned fresh
healthy Syslog for that owner and canary run, source time `11:03:51 UTC`.
This verifies actual ingestion, not the missing VM-identity query result or
SRE readiness. The readiness gate was not bypassed: Connect, a real fault,
automatic investigation and repair approval were not attempted. The improved
investigator instructions therefore remain live-unverified. No hands-on
portal action was needed.

Two Down calls verified full owned-fixture absence at `11:17:42 UTC` and
`11:18:24 UTC`, including the workspace in active/recoverable inventories,
recorded grants, custom role, group and owned tagged residuals. The retained
Arc/private foundation was unchanged. No incident or approval card remains
from this canary-only fixture.

The [Action Run Command documentation](https://learn.microsoft.com/azure/virtual-machines/linux/run-command)
states that scripts execute one at a time, cannot be cancelled, and need
outbound connectivity to return results; delayed/missing results alone do not
establish nonexecution. The transport boundary needs reconciliation before
another incident rehearsal, not repeated faults while the operator waits.

### Native command diagnostics without SRE

The public monitor-only profile separates command delivery/result return from
DNS, VM-system-identity acquisition and LAW query execution. It deploys no SRE
Agent, agent VNet or action role and grants the retained identity no new access.
The existing foundation manifest/identity is read for tenant and ownership
validation only; the retained Arc/private estate is not modified.
Fault, Repair, Connect, Arm and Incident are rejected in this diagnostic mode.
The owned alert remains disabled.

```powershell
$subscription = 'de4195ac-92da-4cbd-b738-eacaf06e49d9'
$environment = 'demo30' # Fresh disposable environment; never reuse a live manifest.
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName $environment -WithMonitoring
.\scripts\Invoke-GuestService.ps1 Probe -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Monitor -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment
# If local observation expires, resume the saved operation; never replay submission.
.\scripts\Invoke-GuestService.ps1 Command -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
```

Probe and Telemetry use the same native **Action Run Command** API and operator
identity as before, not a different guest transport. They persist intent before
POST and the actual returned tracking headers immediately. Command only reads
that saved operation; it never submits a replacement. A lost initial response
without a handle blocks further commands until disposal. Tracking URLs must
be HTTPS ARM Compute operations in the exact subscription/region; redirects
are disabled. Retry-After is respected across bounded polling and resumption.
Provider success without actual command output is not readiness success.
Unknown diagnostics also block the older guest-command path.

Per-command operation metadata and returned output are retained under
`.azure\<environment>\guest-native-read-<commandId>*`. Metadata includes safe
HTTP/error codes, request IDs and timestamps, not access tokens or unrestricted
service error bodies. Azure's opaque signed operation-query values are preserved
only in these ignored local records, never printed in public lifecycle summaries
or copied into source, PRs or reports. Returned query output identifies the last started and
completed DNS/identity/LAW stages; it does not reveal the token. The query is
bounded by a 120-second guest timeout. No output means the guest stage is unknown,
not that DNS, identity or LAW failed.

Require a verified tiny Probe and **three sequential fresh, exact-owner,
VM-system-identity telemetry results**, with no unresolved operations and an
independent operator LAW cross-check, before resuming SRE incident rehearsals.
AMA warm-up is not a reason to accept empty/stale receipts. Local contracts and
live diagnostic evidence are separate from the still-unaccepted human-approved
incident.

The first small fixture (`demo30`, 2026-10-11) returned native HTTP 202.
Its actual ARM tracking URLs contained provider-generated `p/t/c/s/h` query
fields absent from the simplified REST example. The initial strict allow-list
rejected those headers before polling; this was a client contract gap, not proof
of command-delivery failure. No replacement POST, Monitor setup, fault or SRE
action was submitted. The fixture was removed and absence verified twice before
adding synthetic signed-header tests and support for the observed query shape.
The full opaque URL is retained unchanged; host/subscription/region/operation
and query-shape constraints remain enforced.

**Fresh corrected diagnostic (`demo31`, 2026-10-11): delivery became
observable, but repeated readiness remains blocked.** No SRE Agent, fault,
repair or approval was involved.

| Check | Observed evidence | Boundary |
| --- | --- | --- |
| Tiny native Probe | Submitted `12:21:41 UTC`, actual output verified `12:22:08 UTC`; HTTP 202 -> status Succeeded -> result HTTP 200 | Exact owner/VM output returned in about 27 seconds |
| Public Monitor | Thirteen owned resources; no SRE, UAMI, agent VNet, DCE, AMPLS or Monitor private endpoint/DNS; alert disabled | VM and alert received exact workspace-scoped Log Analytics Reader grants; retained identity received none |
| First VM-identity query | Submitted `12:28:05 UTC`, output returned `12:28:31 UTC`; DNS stages completed in 22/11 ms and identity in 248 ms; LAW returned HTTP 403 `InsufficientAccessError` | The query did run; this is a returned authorization error, not a command timeout or DNS failure |
| Independent ingestion | First warm-up samples empty; fresh healthy exact-owner Syslog observed at `12:31:25 UTC`, source `12:28:51 UTC` | Actual AMA ingestion works; it does not prove VM query authorization |
| Subsequent VM query | Submitted `12:32:20 UTC`; operation `57184cb3-7e94-463e-b25f-af0fd9886d69` still `InProgress` at `12:47:24 UTC` | Initial bounded wait and two GET-only resumptions returned no guest output; no replacement POST |
| One native restart diagnostic | Restart Started/Accepted `12:40:10–11 UTC`; local 180-second wait expired; inspected Activity Log had no completion | Restart/reboot outcome unverified; no second restart, no repair claim |
| Parallel readback | Fresh healthy Syslog continued, source `12:42:41 UTC`; VM running, guest agent Ready, AMA succeeded, MDE transitioning | Guest health/ingestion do not establish native command completion; MDE status is not a proven cause |
| Teardown | Down verified absence `12:53:35 UTC` and `12:54:02 UTC`; active/recoverable LAW absent, recorded grants removed, zero owned tagged residuals | Complete disposal; retained Arc/private estate unchanged |

The initial 403 may involve authorization propagation, but the cause was not
confirmed and permissions were not widened. The later missing result has no
returned stage evidence: it must not be described as a LAW, DNS or identity
failure. **Zero of the required three successful VM telemetry cycles were
verified.** The tooling exposes this boundary and prevents blind replay; it
does not yet make native command readiness reliable or unblock SRE rehearsal.
Operation/output, Activity Log, grant, warm-up and twice-verified teardown
receipts remain under the ignored `.azure\demo31\` evidence directory.

Sources: [Action Run Command REST API](https://learn.microsoft.com/en-us/rest/api/compute/virtual-machines/run-command?view=rest-compute-2025-04-01)
and [ARM asynchronous operations](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/async-operations).

### Direct incident rehearsal with operator LAW reads

The user-authorized alternative tests the actual bounded service incident rather
than requiring a VM-side LAW diagnostic first. Select the read source explicitly
on a **fresh** public SRE fixture:

```powershell
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName $environment -WithSreExecution -WithMonitoring -MonitorReadMode Operator
```

This immutable mode makes Telemetry, Connect, Arm, real-fault readiness and
Monitor reset query LAW directly using the authenticated operator CLI identity.
After Monitor configuration, Status also uses that path and saves the fresh
receipt for the exact repair proposal; before configuration it retains the
bootstrap readback. Unknown write intents reconcile only from their exact
run/actor/admission/duration/canary evidence, never by submitting a replacement.
It does not claim VM query authorization or VM endpoint DNS proof. Actual Syslog
observations must still be fresh, exact-owner/VM/current-run, guarded by the
independent watchdog and healthy before arming. Empty/stale/foreign observations
remain errors. There is no automatic identity switch; legacy/default fixtures
still use `VmIdentity`, and outstanding native diagnostic outcomes remain blocked.

The actual SRE Agent must independently query LAW through its built-in read tool.
The operator read is not substituted for SRE diagnosis. Configure the same
Review response plan and exact-command approval policy, verify the safety canary,
then verify the healthy boundary. During development/testing the assistant may
inject one bounded real fault without asking the user to execute or reconfirm
it. For a live demo, stop before injection: the presenter explicitly runs
`Fault`, and readiness confirmation alone is not the trigger. In either case,
pause for the human when SRE remediation requires their involvement. The human
reviews/approves only the byte-for-byte validated current-run repair card in the
automatically created Monitor incident. Never approve an altered, expired or
widened card.

Approved recovery verification in this mode uses fresh same-run LAW evidence
plus the existing exact native execution and action-identity Activity Log audit,
without submitting a new guest Status command. The SRE card must still be
completed, and evidence must identify `recoveryReason=repair` and the exact SRE
principal before watchdog expiry. Delayed results, mere healthy telemetry,
operator repair or watchdog recovery are not SRE acceptance. The native fault/
repair command channel is unchanged and may still fail; this mode removes an
unnecessary diagnostic dependency, not the unresolved transport risk.

**2026-10-11 preparation, `demo32`:** fresh public SRE fixture deployment and
Monitor configuration passed. Direct operator LAW readiness worked without a
guest query command. The safety canary stopped the service at 13:33:26 UTC,
expired at 13:34:26 UTC and independently recovered at 13:34:31 UTC with
`recoveredBy=watchdog`, `recoveryReason=deadline` and exact-run watchdog proof.
Healthy same-run recovery was verified through LAW. The observation harness
initially checked the wrong recovery-reason value; no canary was replayed and
the saved actual evidence confirmed the correct actor/reason pair.

Connect established an initially disabled Review response plan. A **separate
healthy readiness thread**, not the incident, successfully executed the exact
case-insensitive built-in `RunAzCliReadCommands` LAW query at 13:45:26-13:45:34
UTC. It returned a fresh 13:43:51 UTC service observation, healthy/active true,
watchdog flags true and recovered marker. No corrective message, connector,
terminal, Python or guest diagnostic was needed for this SRE read.

Ingestion sometimes exceeded the three-minute freshness limit; those samples
were rejected instead of widening the limit. The real alert remains disabled
pending human availability. No non-canary fault, Monitor incident, repair
proposal or approval has been attempted in this fixture. This is preparation
evidence, not completed incident acceptance.

**Real incident outcome, same fixture:** after explicit human readiness, the
real service fault started at 14:37:33 UTC with a 14:47:33 UTC watchdog deadline.
The native operator CLI timed out, but fresh independent exact-run LAW evidence
proved the fault actually ran; it was never resubmitted. Monitor fired at
14:39:00 UTC and automatically created the SRE incident. Without corrective
messages or a substitute thread, SRE completed the exact LAW query and VM
instance-view read, correctly reported a running VM/stopped service and the
fresh non-canary run/deadline/watchdog evidence, then stopped for the operator's
proposal and human approval.

The local proposal prerequisite failed: persisted intent deserialized to local
`DateTime`, while Kusto receipt timestamps deserialized to UTC `DateTime`.
Representation equality rejected the same admission instant. No repair
proposal, card or approval was created, and no guard was bypassed. Watchdog
recovery occurred at 14:47:35 UTC and was independently verified through fresh
14:47:56 UTC same-run healthy observations with actor `watchdog`/reason
`deadline`. This is **diagnosis acceptance, not SRE repair**. The Monitor alert
was still Fired at the final pre-teardown check; natural clearance was not
verified.

Teardown initially rejected an unrecorded subscription-wide Monitoring
Contributor assignment added to the disposable action identity during the
incident window. After the human explicitly authorized removing that exact
grant, its absence was verified and Down passed twice, including owned
workspace/grant/residual checks. The retained estate was unchanged.

Only after disposal, admission checks were corrected to compare
`DateTimeOffset` instants, retaining full precision and rejecting genuinely
different/missing/invalid timestamps. Operator LAW receipts now reuse the
existing timestamp-preserving guest JSON parser; marker bounds use typed casts
instead of culture-sensitive string reparsing. Local regressions exercise
persisted offset intent versus UTC-Z LAW JSON, typed values and one-tick
differences. At the end of `demo32`, a fresh human-approved repair rehearsal
was still required; that run did not establish post-fix live repair.

### Human-approved monitored repair: result-return boundary

**2026-10-11, `demo33`: actual approved repair, not complete incident acceptance.**
This was an authorized assistant-triggered development test, not a
presenter-triggered live demo. A fresh Public/SRE/Operator fixture deployed from
the merged timestamp fix. Independent canary deadline recovery and a separate
healthy SRE built-in LAW read passed before the real fault. No mandatory
VM-side LAW diagnostic, alternate execution transport or retained-estate change
was introduced.

All times below are UTC. The real non-canary fault was submitted once and its
native result returned. Monitor created the actual incident; SRE independently
read fresh same-run Syslog and VM instance view, correctly diagnosed a stopped
service in a running VM and stopped for the proposal. The exact proposal and
pending policy card passed the adapter. The human approved the single action
in the SRE portal, with scope `none`, no allow-for-thread and no OBO execution.
The readiness reply was not treated as approval.

| Evidence | Actual observation |
| --- | --- |
| Fault and deadline | Service stopped at `15:57:28`; watchdog deadline `16:07:28` |
| Actual Monitor alert | Fired at `16:00:06`, about 2m39s after the service stop |
| Human portal approval | `16:05:07.2085719`, before the exact native execution started |
| Guest recovery | `16:05:20.800653`, same run, `recoveryReason=repair`, `recoveredBy` the isolated SRE action principal |
| Recovery timing | About 13.6s after approval; 7m53s after the fault, before watchdog expiry |
| SRE native result | Marked `Failed` at `16:07:08`, about 121s after starting; output/error contained only the ignored-`--subscription` warning |
| Eventual Azure action audit | One matching principal/correlation `runCommand/action` reached `Succeeded` at `16:15:24`, about 10m14s after acceptance |
| Natural Monitor clearance | `Resolved` at `16:18:05`, about 12m45s after guest recovery; alert state remained `New` |
| Reset and teardown | Exact-run Reset archived approval evidence and returned healthy; Down passed twice, with independent absence/zero owned residuals at `16:33:17` |

The **guest action ran despite the failed SRE result return**. Fresh independently
ingested observations attribute recovery to the SRE principal, not the
watchdog, and the eventual successful Azure audit has the same action
correlation. Nevertheless, strict Verify rejected the failed SRE execution;
it was not relaxed to accept healthy telemetry or a late audit as a completed
native-tool result. No repair or fault was replayed.

SRE initially claimed that no approval card had been created and no repair
occurred. Both claims contradicted saved approval/execution records and guest
evidence. One explicitly labelled operator corrective message caused SRE to
query LAW independently again and correct its note at `16:13:58`. That follow-up
is not autonomous recovery-conclusion acceptance. The completed Azure audit
arrived later than the correction; the corrected note accurately left that
audit unverified at the time.

An unrecorded subscription-wide Monitoring Contributor grant appeared on the
disposable action identity at `16:04:59`, before approval. It was absent from
the saved pre-incident inventory and prevented the normal telemetry/teardown
guards from passing. Read-only LAW diagnostics were explicitly labelled
diagnostics, not guarded lifecycle acceptance. After explicit human permission,
only that exact grant was revalidated, removed and verified absent; guarded
health collection resumed. This run therefore does not prove execution with
only the intended scoped grants. The retained Arc/private estate was untouched.

**Remaining gate:** reproduce correct native result completion and an
independent, evidence-backed SRE recovery conclusion on a fresh fixture with
the explicitly recorded documented baseline and VM-scoped action grant. A neutral
human verification question is
allowed under the clarified demo acceptance; supplying the recovery answer
is not. The visible warning does not establish the
cause of the delayed return or the failed SRE status. The
[CLI reference](https://learn.microsoft.com/en-us/cli/azure/vm/run-command#az-vm-run-command-invoke)
documents complete `--ids` as an alternative to other resource-ID arguments
and `--no-wait` as returning without completion; neither suppressing the warning
nor accepting an asynchronous submission would by itself close this gate.
There is no documented SRE per-tool timeout correction established here. Do
not retry an unknown/failed repair merely because its result was missing.
This remains a small fixture proof, not retail/business recovery or a
customer-repeatable release.

### Approved async submission and independent verification

**Implemented for new Operator-mode proposals; live acceptance remains open.**
The user authorized this change on 2026-10-11. The live flow is unchanged:
presenter triggers the fault, Monitor creates the incident, SRE investigates,
the operator supplies the exact proposal, a human approves it, and SRE verifies
and records recovery. Development/test faults may be assistant-triggered.

New proposals on explicit `MonitorReadMode Operator` fixtures add the documented
`--no-wait` option to the same native Action Run Command. The payload, exact VM,
action identity, owner, current run, lifetime, Review policy and human approval
boundary are unchanged. This avoids keeping the submission tool open while
Azure completes its long-running operation. It is **not** a documented SRE
timeout fix, an alternative guest transport, or proof of completed repair.
Legacy/VmIdentity proposals and saved synchronous runs retain their original
native-completion/audit gates; `demo33` is not retroactively accepted.

The adapter and investigator distinguish these evidence boundaries:

| Boundary | Required evidence |
| --- | --- |
| Authorization | One exact single-action human Approved card before native execution; no allow-for-thread, permission expansion or OBO execution |
| Submission | Exactly one native `RunAzCliWriteCommands` execution Completed without error, with the unchanged approved command |
| Azure operation | Exact VM and managed-identity caller/claim; one correlation with Started/Accepted from native start through submission completion plus two minutes, then one Succeeded event within 30 minutes of native start |
| Guest recovery | Fresh exact-owner/service/run/original-actor/lifetime evidence, non-canary, active/healthy, repair attribution to the SRE identity and recovery within the approved operation; new Manual runs have no deadline and require disabled/inactive recovery timer; legacy runs retain pre-expiry recovery |
| SRE conclusion | Independent built-in LAW requery and evidence-backed note in the actual incident, automatically or after a neutral human verification question, without supplying the recovery answer; natural Monitor clearance is separate |

`Read` checks lifecycle/source/grant ownership using operator LAW reads and saves
`guest-approval-operation.json`, binding the first observed correlation to the
approval, native execution, VM, principal and run. Later reads cannot switch
correlations or slide the 30-minute event window. The full bounded Activity Log
query rejects a possibly truncated result rather than assuming uniqueness.
No operation handle is invented from a VM or correlation ID. Missing admission,
conflicting identities/correlations, failed/canceled operations and missing
completion remain unaccepted; neither `--no-wait` nor healthy telemetry alone
passes Verify. The 30-minute window is a bounded test observation policy, not
a promised Azure completion SLA or a fault-lifetime limit.

After approval SRE must independently requery LAW **even when native output is
failed or missing**. It reports human approval, native submission, observed
guest recovery and Azure completion separately. A missing tool result does not
prove that no action occurred. If the guest recovered but the audit is pending,
report that distinction instead of success or a false "no repair" conclusion.
Prefer automatic continuation, but a neutral human follow-up may initiate this
read-only check and still meet demo acceptance.
Never retry the repair or create another approval card for an unknown result.
An expired observation window does not cancel an already submitted Azure action.

Async `Verify` saves an operator-only acceptance record without posting a
recovery/correction message to SRE. Capture the agent's independent query and
note, plus any neutral human follow-up, before reset/teardown; a local Verified
record does not prove the agent wrote a correct note. Reset archives
operation/audit records along with proposal/approval
evidence, and still requires natural Monitor clearance.

### Async attempt and disposal (`demo34`, 2026-10-11)

The fresh Public/Operator fixture produced a real Monitor-created incident,
independent correct SRE diagnosis and the exact pending AsyncAudit policy
card. Freshness subsequently failed during guarded `Read`; the operator was
explicitly told not to approve. No human approval or native SRE repair ran.
The historical watchdog recovered the fault, and Monitor naturally resolved
the alert. This is not async submission/completion acceptance.

`Read` had saved a safe-looking pending-card receipt before its later
telemetry prerequisite failed. It now marks each inspection unverified and
persists the pending inspection receipt only after all relevant guards pass.
A byte-exact card inspection alone is not approval readiness.

The explicit Reset command's result remained unknown and was not replayed.
Teardown initially rejected a newly generated SRE-subnet NSG. Read-only
inspection found the exact owned NSG attached only to the exact SRE subnet,
with no custom rules or NIC associations. Teardown now accepts only that
exact empty, owned, mutually attached resource; incident readiness is not
broadened to accept network drift. Guarded Down and repeated Down recorded
disposal at 18:25:42Z; an independent group/owner-resource/custom-role absence
check confirmed it. The old pending approval was disposed with its agent.

The user subsequently selected manual fault lifetime for **all implemented
demo scenarios**, with no timed or reboot recovery. That cross-scenario
change is locally implemented; live acceptance remains open. See the
[delivery contract](implementation-plan.md#user-directed-fault-lifetime-change-2026-10-11).
The next live acceptance attempt must use the new coherent lifetime contract,
not extend or reuse this disposed run's deadline or approval.

**Permission workflow boundary:** read-only Activity Log and client-identity
lookup traced the extra `demo33` Monitoring Contributor grant to the operator's
delegated identity through the **Azure SRE Agent application**, not the action
managed identity or harness deployment. The exact UI gesture is not established.
The current [Agent permissions documentation](https://learn.microsoft.com/en-us/azure/sre-agent/permissions)
lists subscription-level Monitoring Contributor among the always-assigned roles.
The historical fixture omitted it; the absence guard was stricter than the
supported baseline, not proof of unauthorized managed-identity elevation.
New fixtures explicitly provision and track it as described above, while keeping
natural alert clearance separate from service recovery. At rehearsal approval, approve only the
already validated exact repair card; do not run scope/permission onboarding,
add subscriptions/resource groups, change access level or select allow-for-thread.
If the portal requires a permission grant, stop rather than widening access.
The lifecycle inventory still rejects every unrecorded grant.

Sources: [Azure CLI Run Command reference](https://learn.microsoft.com/en-us/cli/azure/vm/run-command#az-vm-run-command-invoke)
defines `--no-wait` as not waiting for the long-running operation;
[Azure Activity Log event schema](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log-schema)
documents caller/claims, event timestamps and correlation IDs. The actual
`demo33` Started/Accepted/Succeeded events share a correlation ID but have
different operation IDs, so completion must not be correlated by operation ID.
No fresh successful async incident is claimed until its complete declared-baseline,
VM-scoped action,
approval/submission/audit/recovery/conclusion/reset/teardown gate passes.

### First monitored live attempt: readiness blocked

**2026-10-10, `demo26`: no incident acceptance.** The native VM and isolated
SRE Agent deployed successfully. Bootstrap confirmed the service healthy and
the watchdog enabled/active. The monitoring deployment completed with AMA,
the DCR, an approved AMPLS endpoint and the disabled service-down alert.

The observer produced fresh `RetailTxGuest` JSON locally; AMA received the
expected local0/Info configuration and workspace destination. However, both
private query hostnames (`api.loganalytics.io` and `api.loganalytics.azure.com`)
returned HTTP 403 with `InsufficientAccessError` /
`PrivateLinkValidationFailedError`. AMA also logged HTTP 403 for Syslog uploads.
Query DNS resolved to the endpoint's `10.89.0.11`, and the workspace ingestion
hostname resolved to `10.89.0.6`. ARM readback confirmed the workspace and DCE
were attached to the exact AMPLS, and the endpoint connection was Approved /
Succeeded. These checks do **not** establish why service-side validation
rejected the private requests; the root cause remains unresolved.

No fault, canary, SRE response plan, repair proposal or approval was attempted.
Public query/ingestion stayed disabled and no permission broadening was used.
A later operator-only network diagnostic did not return before its local CLI
process was stopped; that is an unknown command result, not proof of
non-execution. It was not a fault or repair command.

The first guarded Down also rejected legitimate resources missing from its
inventory: the ten owned private-DNS VNet links and the untagged platform
`MDE.Linux` extension. Cleanup now validates each link's exact owned VNet,
disabled registration and ownership, and accepts only the exact untagged
Defender publisher/type on the owned VM, alongside the existing policy
extension. Foreign links, tagged/altered platform extensions and duplicate
extension IDs remain rejected. Telemetry queries now persist their raw
operator diagnostic result even when no valid receipt is returned.

**Cleanup verified:** the corrected Down completed at `19:20:45Z`; a second
Down at `19:21:36Z` confirmed the group absent and zero owned residuals.
Independent readback found no owner-tagged resources and only the retained
foundation's endpoint connection on the AMPLS. The fixture's external workspace
grants and custom action role were removed; retained monitoring resources and
the shared SRE configuration were not changed.

At the time, continuation required a fresh private query receipt. That private
gate failed and is now deferred; the user-authorized public baseline requires
a new owned fixture, not relaxed validation or changes to this retired fixture.

### Isolated private-monitoring diagnostic

For the user-authorized comparison with a fresh monitoring foundation, add
`-WithIsolatedMonitoring` to **Up only**, alongside `-WithMonitoring` and
`-WithSreExecution` and `-MonitorTransport Private`. The selection is immutable
for that fixture. The existing `-WithIsolatedMonitoring` switch also implies
Private when transport is omitted; an explicit Public combination is rejected. This creates
an owned LAW, DCE and AMPLS in the disposable fixture group rather than attaching
its endpoint to the retained foundation:

```powershell
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName $environment -WithSreExecution -WithMonitoring -MonitorTransport Private -WithIsolatedMonitoring
.\scripts\Invoke-GuestService.ps1 Monitor -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment
# This diagnostic does not require a fault, response plan or repair approval.
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
```

The diagnostic and legacy shared-foundation private modes retain private-only
query/ingestion and Entra authentication. `-MonitorTransport Private` without
isolation selects the original retained foundation, not the public default.
The diagnostic checks relevant subscription-wide DNS zones and links for
duplicate or foreign Monitor namespaces attached to either fixture VNet;
Unrelated zones linked elsewhere are allowed. Existing deployment-target links
are ownership-checked even when they currently point to another VNet. A complete
ten-link topology is required after deployment. Inspect the saved DNS topology
and actual query/ingestion results rather than inferring correctness from a
private address alone. A successful isolated query would narrow the comparison,
not establish the root cause of the earlier shared-path rejection.

**Destructive cleanup boundary:** isolated Down validates the owned AMPLS
bindings, disconnects its workspace/DCE and **permanently deletes** the exact
fixture-owned workspace instead of retaining it in soft deletion. This applies
to both owned public and isolated private workspaces; retained foundation monitoring
is never purged. Down verifies absence from active and recoverable workspace
inventories. A partial creation intent must be cleaned up with Down, not
replayed or adopted. Local receipts remain after teardown.

**2026-10-10, `demo27`: isolated comparison also blocked.** The fresh private
LAW/DCE/AMPLS and AMA/DCR/disabled-alert deployment succeeded. A post-deployment
subscription-wide topology check found exactly ten owned DNS links: one link
for each of the five required namespaces on each fixture VNet, with no duplicate
or foreign same-namespace links. Query resolved to the owned endpoint NIC's
`10.89.0.11`, and this new workspace's ODS hostname to `10.89.0.6`. The workspace
backlink matched its new AMPLS scope ID; the endpoint was Approved / Succeeded.
Public query/ingestion remained disabled and local authentication disabled.

Nevertheless, both query hostnames returned the same HTTP 403 /
`PrivateLinkValidationFailedError`, now naming the **new** workspace. AMA logged
403 for both `LINUX_SYSLOGS_BLOB` and `HEALTH_ASSESSMENT_BLOB` uploads between
`19:55:58Z` and `19:58:11Z`; its configuration targeted the new workspace and
private DCE. The independent observer emitted current healthy service/watchdog
evidence locally. No private telemetry receipt, fault, response plan, incident
thread or approval was produced.

During the comparison, the retained Arc host still returned fresh private
Perf/Event evidence through its original `10.84.1.10` endpoint (`19:49:59Z`),
without configuration or fault changes. The fresh-workspace experiment therefore
did **not** solve the rejection, and duplicate same-service DNS zones linked to
the fixture VNets were not observed. This does not establish the underlying
private-link rejection cause; do not infer a workspace-wide outage or compensate
with public access or broader permissions.

**Cleanup verified:** the workspace purge returned successfully and independent
active/recoverable workspace inventories contained no matching workspace.
The initial group deletion exceeded its bounded wait and reported the remaining
owned resources without claiming success. Resuming the recorded Down completed
at `20:14:35Z`; another Down at `20:15:54Z` verified absence again. Independent
readback found no owned tagged resources, workspace grants or custom action role.
The isolated workspace, DCE, AMPLS, endpoint, DNS, VM and agent are removed.

Focused local regression checks are `tests\Test-GuestMonitorIsolation.ps1`,
`tests\Test-GuestServiceMonitor.ps1` and `tests\Test-GuestService.ps1`. They cover
ownership/privacy boundaries and partial/repeated cleanup, not successful live
ingestion or incident acceptance.

The fixture represents a posting worker, not the actual RetailTx ERP ledger,
Service Bus pipeline or business recovery. Do not infer customer impact from
its localhost health or worker progress.

## Acceptance gates

1. Deploy an isolated, owned VM with no public VM IP or inbound SSH/RDP.
   Explicit outbound connectivity is required by the Azure VM Agent.
2. Verify healthy application service, disabled/inactive recovery timer and
   enabled observer, with current guest evidence and source identity.
3. Inject a manual service stop while the VM remains running. Persist the
   exact fault run and lifetime before stopping anything.
4. Verify persistence across elapsed time and a new boot, then explicit
   exact-run recovery. Historical timed canaries do not satisfy this gate.
5. Collect fresh fault evidence, let SRE explain the narrow diagnosis and
   recommend the fixed repair, then execute that repair through the controlled
   operator harness. Verify the named systemd service and localhost health
   independently through the operator harness.
6. Reset and tear down the fixture; preserve receipts and independently check
   absence of owned resources.

Alert-driven investigation, direct SRE guest execution and approval-free
autonomy are separate gates, not implied by operator Run Command success.
The retained SRE action identity receives Reader only on the isolated fixture
group so it can inspect Azure resource evidence. That grant is removed with
the fixture group. No guest-command grant or shared global-mode change is
required for this initial proof.

## Operator lifecycle

Use the authorized subscription explicitly. The fixture defaults to `demo16`;
it must not reuse the retained foundation's environment ID.

```powershell
$subscription = '<subscription-guid>'
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Status -SubscriptionId $subscription -EnvironmentName demo16
```

After readiness, explicitly create the persistent fault.
Keep the exact returned run ID; never substitute a prior run.

```powershell
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestServiceSre.ps1 Investigate -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestServiceSre.ps1 Read -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Repair -SubscriptionId $subscription -EnvironmentName demo16 -RunId '<current-run-guid>'
.\scripts\Invoke-GuestServiceSre.ps1 Verify -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName demo16
```

SRE request intents are durable and deliberately non-replayable after an
uncertain POST. Read/reconcile the saved thread rather than create a substitute.
Recovery follow-up accepts only fresh healthy evidence from the initial run;
it requires repair attribution to the currently authenticated operator.
Watchdog recovery is not operator-repair acceptance. `Up -WhatIf` describes
the operation without preflight, local files or Azure writes.

If thread creation returns no reliable ID, preserve its saved intent and use
the SRE UI to locate the exact owner marker and fault run. Decline any pending
actions there, tear down the owned fixture and start with a fresh environment
rather than replaying creation or hand-editing an uncertain intent into success.

## Authority boundary

Azure documents Run Command as a guest diagnosis/remediation channel through
the VM Agent. It does not require inbound SSH/RDP, but requires outbound
connectivity. Linux Action Run Command normally executes elevated scripts,
supports only one active command, returns at most the last 4,096 bytes, cannot
be cancelled and has an approximately 20-second minimum execution time.
These are command-channel constraints, not an incident-duration guarantee.
See [Linux Action Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command)
and the [Run Command comparison](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-overview).

A VM-scoped Run Command grant restricts the target VM, **not the script**.
The operator harness can constrain its own fixed operations; it does not turn
the operator's Azure permissions into a service-only RBAC boundary. SRE receives
no guest-command grant in the first gate. A hard fixed-action boundary must be
demonstrated before describing direct autonomous repair as constrained.

Run Command itself is a write operation even when its script only reads guest
state. A read-only SRE investigation therefore uses Azure resource evidence
and explicitly attributed, fresh operator-collected guest receipts. Do not
claim that SRE independently read the guest when it received that evidence.

## Stop condition

If the native guest channel or independent recovery cannot be proven reliably,
record the failure and remove the fixture rather than adding another custom
execution platform. If the channel works but authority confinement remains
unresolved, retain the recommendation/operator proof and report autonomous
guest repair as blocked by that specific boundary.

## Native SRE execution gate

**2026-10-09 decision: no-go for granting guest-write authority to the retained
shared agent.** This is an authority-boundary finding, not evidence that native
SRE execution is unsupported. No new fixture was deployed, fault injected,
write permission granted or shared setting changed during this gate.

[Execute mitigations in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/execute-mitigations)
documents native Azure CLI write actions. Combined with Linux Run Command,
this establishes a documented candidate transport, not verified SRE guest
execution in this environment. Linux `RunShellScript` accepts arbitrary
elevated scripts; limiting the role to one VM does not restrict script content.

[Tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies)
now document argument matching, but deny rules exist only at global scope.
Custom-agent and thread policies only add allows, and an allow skips default
approval even in Review mode. An exact-command allow alone is therefore
neither a deny-by-default boundary nor an approval-gated test.
A read-only live GET of `/api/v2/agent/settings/global` returned empty
allow, ask and deny lists; the retained agent's ARM action mode remained Review.
Those settings were left unchanged.

[Agent hooks](https://learn.microsoft.com/en-us/azure/sre-agent/agent-hooks)
document Stop and **PostToolUse**, not a pre-execution argument veto.
PostToolUse runs after successful execution and cannot prevent an arbitrary
guest script from already having run. A hook returning allow can also override
global policy denies. Do not use prompt instructions or a post-execution hook
as the privileged repair boundary.

An isolated SRE agent alone does **not** resolve this boundary. Further review
of the documented precedence found that a blanket global deny also rejects
the intended repair, even when an exact allow exists. An exact allow without
that deny leaves unmatched commands subject to default behavior, not hard
rejection. No exception/default-deny mechanism is documented that meets the
proposed exact-repair-only acceptance gate. This is a documentation-based
no-go, not a live negative-policy test or proof about undocumented controls.

The user explicitly resolved
[the owner decision](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/10):
demonstrate **human approval before any SRE guest command**, with Review mode
and privileged Run Command authority limited to one disposable native VM.
This accepts supervised execution, not a hard service-only permission boundary.
The retained shared agent must not gain guest-write permissions. Arc remains
recommendation/operator repair; alert plumbing and autonomous mode remain deferred.

## Human-approved native repair

**2026-10-09: the `demo23` fixture passed this gate.** SRE proposed the exact
repair command; a human approver independently verified it byte-for-byte
against the portal's pending card before clicking Approve, and execution ran
only after that click. See
[the `demo23` evidence](#human-approved-repair-evidence-demo23) below for the
full reconciliation. The optional execution fixture uses its own SRE agent,
action managed identity and delegated network. Its custom VM-scoped role grants
Action Run Command, not general Contributor, managed Run Command resource writes,
SSH or OBO elevation. Do not add tool Allow rules that bypass Review.

After current healthy readiness, inject a non-canary manual fault and create the
proposal. Inspect the exact command and pending approval in SRE; **a human**
clicks Approve. The adapter has no programmatic approval operation.

```powershell
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName demo20 -WithSreExecution
.\scripts\Invoke-GuestServiceApproval.ps1 Configure -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestService.ps1 Status -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestServiceApproval.ps1 Propose -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestServiceApproval.ps1 Read -SubscriptionId $subscription -EnvironmentName demo20
# Human reviews/approves the exact native RunAzCliWriteCommands card in SRE.
.\scripts\Invoke-GuestServiceApproval.ps1 Verify -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName demo20
```

Read saves the native execution records without running a guest command. Propose
uses the operator-collected fault receipt and refuses stale, canary or near-expiry
evidence. The encoded repair binds owner, source hashes, exact run, action principal
and deadline; the locked guest controller rejects late, recovered or rebooted
faults before touching the service. This protects the supplied repair from stale
approval; it does not constrain arbitrary privileged scripts.

Configure requires Ask for native writes and guest invocations routed through
the CLI read tool, denies terminal, shell and Python alternatives, and installs
no Allow rules. These are documented
[tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies),
not a service-only OS boundary. User-defined hooks and thread/custom-agent
Allow overrides must remain absent; verify those in the SRE UI as part of the
supervised gate.

Verify requires an exact completed native execution with no OBO scopes, an
independent successful Azure Activity Log action by the isolated action principal,
and fresh operator-collected health with that principal's exact-run repair
attribution. Watchdog recovery is never accepted as SRE repair. The final supplied
receipt is explicitly operator-collected, not independent SRE guest verification.
Guest diagnostic/status commands by SRE would also require human approval and
are deliberately excluded from this first demo.

These are the legacy/VmIdentity synchronous semantics. New explicit Operator-mode
proposals use [async submission and separate completion verification](#approved-async-submission-and-independent-verification);
native Completed means submitted, not repaired. Their Verify records acceptance
locally and does not supply a corrective message to the agent.

Keep the supervised window short. Decline outstanding cards and remove the
fixture/grant if approval cannot happen before recovery expiry. Do not leave an
authorized pending command unattended or silently replace human approval with
an automated test decision. Teardown must report agent retention/residuals rather
than claim a fully removed environment without checking them.

## Current evidence

The isolated `demo19` fixture verified a stopped application service inside a
running native Azure VM on 2026-10-09. SRE independently read Azure resource and
Activity Log evidence, distinguished the running VM from the stopped worker,
recommended the exact current-run operator repair and recorded recovery.
Guest service evidence was explicitly operator-collected throughout.

| Measurement | Observed outcome |
| --- | --- |
| Independent safety canary | Service stopped at 16:36:20 UTC and watchdog recovered it at 16:37:22 UTC: 62.15 seconds, without operator repair |
| Application fault | Real worker stop at 16:41:09 UTC; VM remained running; localhost health failed |
| Operator repair | Same-run repair recovered the service at 16:46:35 UTC: 5m26s after the actual service stop, before the ten-minute watchdog deadline |
| Repair command channel | Durable repair intent at 16:46:28 UTC; verified command result at 16:47:03 UTC: approximately 35 seconds, not a five-minute restart |
| SRE recovery conclusion | Fresh healthy receipt supplied at 16:50:13 UTC; SRE concluded recovered/no repair needed at 16:51:07 UTC: approximately ten minutes after the actual stop |
| Reset | Exact-run reset returned active/healthy service with a separate reset attribution |
| Teardown | Hardened inventory validation passed; Down and repeated Down returned absent; independent reads confirmed group, owner-tagged resources and fixture Reader grant absent |

The recovery conclusion included a verification-code correction: persisted JSON
timestamps can become PowerShell `DateTime` values, so deadline matching now
compares instants rather than string representations. This was not an
uninterrupted demo rehearsal. The timings exclude deployment and start at the
actual guest stop, not the fault request. Native Run Command added observable
command latency; the service failure itself was immediate. Fault-command intent
to SRE's final recovery note was approximately 10m05s. Operator orchestration and
the verification correction account for part of this interval; it is not a
measured autonomous or presentation time.

This initial demo19 proof is a promising replacement for VM-start-only
demonstrations, **not an autonomous scenario**. Later demo23 and demo25 proofs
below establish human-approved repair and repeatability/reboot safety.
Alert-triggered investigation and retail transaction recovery remain unverified.
The health gate checks the named systemd process and expected localhost JSON;
it does not verify worker progress, ERP ledger writes or Service Bus recovery.

**Planned reuse — GitHub-issue intake scenario.** This fixture's stopped
posting-worker fault is the designated fixture for the separate
"GitHub-reported incident to SRE recommendation" scenario (see
`docs/implementation-plan.md`): a user-filed GitHub issue describing the
stopped service, relayed to SRE through an HTTP trigger. That reuse is design-only
and not yet built. By the latest user direction, the monitored native variant
above must be verified before the full demo; the issue supplies a human report
alongside the Monitor alert and must correlate rather than duplicate its
investigation. The original unmonitored proof remains a narrower transport/
approval fixture, not the final incident demo.

Teardown rejects unexpected child resources before deleting the owned group.
The sole untagged exception is the exact VM-child `AzurePolicyforLinux`
extension with its ARM publisher/type verified. Pending repair/reset readback
requires the matching recovery actor and reason; watchdog recovery cannot
confirm an operator command with an unknown outcome.

The retained shared foundation remains intentionally present and billable.
Its SRE action mode stayed Review; no guest-write permission was granted.

Initial deployment exposed an invalid Allow rule using the deny-only
`AzurePlatformDNS` platform opt-out tag. The rule now targets the Azure resolver
address `168.63.129.16` on port 53 while preserving deny-all gates and explicit
NAT. The failed partial `demo16` fixture was removed and absence verified.
A fresh `demo17` VM provisioned and its exact fixture-scoped SRE Reader grant
was independently observed; post-deployment verification then exposed an
unsupported combination of scoped role-assignment listing with `--all`.
No guest fault was attempted during either provisioning failure. These are
deployment findings, not guest transport or autonomous-repair acceptance.
A fresh `demo18` installation verified the real guest command channel and
healthy service, but operator lookup failed before fault injection because
`az ad signed-in-user show` rejects the shared helper's subscription argument.
The harness now uses the authenticated Graph `/me` endpoint. The unused fixture
was removed rather than rebinding its source attestation; `demo19` supplied the
live fault/recovery evidence above.

## Repeatability and reboot test wrapper

`scripts\Invoke-GuestServiceCycleTest.ps1` is an orchestration wrapper for
repeatability and reboot testing. It does not add a new operation: it drives the
existing `Invoke-GuestService.ps1 Fault`/`Repair`/`Status` operations in a loop,
and triggers a VM restart (`az vm restart`, the same pattern used by
`Invoke-DiskScenario.ps1`). On new Manual fixtures it verifies a new boot with
the same stopped fault, then explicitly repairs it. Legacy fixtures retain the
old watchdog-reboot branch.

```powershell
.\scripts\Invoke-GuestServiceCycleTest.ps1 -SubscriptionId $subscription `
    -EnvironmentName demo16 -Cycles 3 -IncludeRebootCycle
```

Each cycle injects a manual fault, waits for a fresh fault run, collects the
SRE-equivalent repair attribution via `Repair -RunId`, and verifies healthy
Status evidence before starting the next cycle; it aborts on the first failed
cycle rather than masking a partial result. The optional final reboot cycle
restarts the VM, verifies same-run stopped state and a new `bootId`, then invokes
explicit exact-run Repair and verifies healthy recovery. The wrapper emits a
single structured summary object (`EnvironmentName`, `TotalCycles`, `Success`,
and a `Cycles` array with per-cycle timings and evidence) rather than narrating
progress, consistent with the repo's `Write-Verbose`-only console convention.

**Historical timed version, 2026-10-10:** executed live against a fresh `demo25` fixture. The wrapper
ran bootstrap + three fault/repair cycles + one reboot cycle end to end and
returned `TotalCycles=5, Success=True`. Every one of the 33 entries in the
fixture's persisted journal (`guest-service-state.json`) recorded
`outcome: "verified"` (or `"deployment-succeeded"` for the initial deploy) —
zero failures anywhere in the run.

| Cycle | Run ID | Fault injected (UTC) | Recovery (UTC) | Recovered by |
| --- | --- | --- | --- | --- |
| Bootstrap canary | `659a2dab-6f54-4b2d-a426-561feb6786f5` | 13:06:50 (60 s, canary) | 13:07:58 | `watchdog` (self-heal, proves the watchdog is live before real cycles start) |
| Cycle 1 | `4e65332d-f760-41cf-9b0d-e9b2d2704daf` | 13:10:56 (300 s) | 13:14:32 (repair started 13:13:58) | operator-equivalent `Repair` call |
| Cycle 2 | `15aca3dc-ea45-45e7-badd-5b7212914fd0` | 13:18:10 (300 s) | 13:21:47 (repair started 13:21:13) | operator-equivalent `Repair` call |
| Cycle 3 | `b705f5c6-5d2e-49bb-a269-0c8dae7e2234` | 13:25:22 (300 s) | 13:28:59 (repair started 13:28:25) | operator-equivalent `Repair` call |
| Reboot cycle | `36882af3-5694-41be-a05b-37bc53bdd2d1` | 13:32:34 (300 s, non-canary) | 13:33:45 | `watchdog`, `recoveryReason: "reboot"` |

The reboot cycle is the key new proof: the VM actually restarted (a distinct
`bootId`, `e90e6c24-...`, confirms a real reboot rather than a service
restart) and the watchdog detected and recovered the stopped service on its
own, with **no operator or SRE repair call**, well inside the ten-minute
recovery deadline (`13:37:43`). A final `Status` check at `13:35:25` confirmed
`active=true, healthy=true`. All five cycles share one consistent actor/owner
identity throughout, with no unexpected identity changes between cycles.

Total live test execution ran from the fixture's `deploy` entry (`12:56:49`)
to its final `status` entry (`13:35:25`) — about 38.5 minutes, in line with
the original estimate. This closes both previously open gaps: three-cycle
repeatability and cross-reboot watchdog acceptance are now verified, not just
tooled. The `demo25` fixture was torn down after evidence was captured.

## Human-approved repair evidence (`demo23`)

The isolated `demo23` fixture repeated the `demo19` proof with the
human-approved gate from "Human-approved native repair" live. SRE proposed the
exact native repair command; the human approver fetched the same pending
command from the SRE portal, verified it byte-for-byte against the harness's
expected output, and only then clicked Approve.

| Measurement | Observed outcome |
| --- | --- |
| Fault injected | 2026-10-09 19:49:11.957860 UTC |
| Recovery deadline | 2026-10-09 19:59:11.957860 UTC (ten-minute watchdog window) |
| Command verification | Portal pending command matched the harness's encoded repair byte-for-byte (965/965 characters), confirmed before approval |
| Human approval | Approver clicked Approve in the SRE portal only after verification; the adapter exposes no programmatic approval operation |
| Repair completed | 2026-10-09 19:52:53.185469 UTC, approximately six minutes before the watchdog deadline |
| Guest-side evidence | `recoveredBy` matched the isolated action principal (`d0c24ad7-...2b59`); `recoveryReason: "repair"`, distinct from `"watchdog"` |
| Independent Activity Log evidence | A single `correlationId` recorded `Started` -> `Accepted` -> `Succeeded` for the Run Command action, with caller equal to the same action principal; no duplicate or earlier invocation existed in the window |

Three independent lines of evidence (guest-reported attribution, the Azure
control-plane Activity Log, and the approver's own byte-for-byte verification
immediately before clicking Approve) agree on exactly one gated invocation.
This confirms the human-approval gate worked as intended: SRE proposed and
waited; only the human's own portal click released the command.

### Known tooling limitation, not a gate failure

The adapter's `Read` operation (`Invoke-GuestServiceApproval.ps1 Read`) never
populated the `approval`, `nativePending` or `nativeCompleted` fields during
this rehearsal, even while a command was genuinely pending and later executed.
This reflects a gap in the adapter's structured visibility into the SRE
portal's native-action approval state, not a bypass of the gate itself; the
Activity Log and guest evidence independently confirm the single approved
execution. Operators should treat the SRE portal/chat UI itself, not scripted
polling against this field, as authoritative for observing and acting on
pending native-action approvals until that visibility gap is closed.
