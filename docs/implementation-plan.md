# RetailTx: staged architecture and implementation plan

**Status:** private Stage 0 foundation deployed and verified; a constrained
[native SRE VM-start proof](native-action-proof.md) now verifies native approval,
denial, managed-identity execution and private Arc evidence, with three
consecutive automated recoveries and incident notes. Human rehearsal and the
complete approved-incident gate remain open. A separate disposable
[guest-service repair fixture](guest-service-scenario.md) (`demo23`,
2026-10-09, PR #9) verified a narrower human-approved native-repair gate: SRE
proposed the exact repair command, a human approver verified it byte-for-byte
against the portal's pending card before clicking Approve, and guest evidence
plus an independent Activity Log query agreed on exactly one gated
invocation. This used its own isolated VM/action identity and does not by
itself satisfy the complete approved-incident/customer gate above. Stage 1 local transaction slice implemented and locally verified; see the
[local guide](local-development.md) for commands, evidence, and limitations.
Stage 2 private Azure application profile implemented, but live acceptance is
blocked by Arc command delivery. Evidence and the reliability assessment are
recorded in the [Azure application guide](azure-deployment.md).
The user-directed [operator-first Windows Arc disk scenario](disk-scenario.md)
has completed real faults on three fresh fixtures, alert-triggered SRE investigation/proposal,
supplied operator-script recovery, private recovery verification, automatic
monitor-condition clearance and final SRE note. Same-fixture reset produced
distinct alerts and threads after prior clearance; the second incident needed
one read-only SRE verification retry after an internal error. Acknowledgment
remained permission-blocked, and post-recovery verification used follow-up messages.
Earlier Arc command stalls remain unexplained; repeatability, presentation
timing and human rehearsal are open. Automatic SRE-to-Arc execution is a later
gate, not a prerequisite for this milestone.
The [operator demo runsheet](disk-demo-runsheet.md) now prepares the proposed
shorter presentation sequence: deployment/warm-up before the session, exact-run
operator recovery promptly after SRE's proposal, independent verification and
RCA, then automatic monitor clearance during the walkthrough. It changes no
alert or safety settings and is not evidence of a shorter measured run.
A first fresh timing experiment stopped before fault injection because
Arc-identity private queries returned an authorization denial despite recorded
grants. The subsequent experiment passed readiness only after a bounded retry.
Prompt execution restored the guest 9 minutes 17 seconds after fault request,
but conflicting private Perf/Event evidence delayed verified SRE recovery/RCA
to about 18 minutes; the full flow still took 28 minutes. Earlier workspace grant placement and no-write
reconciliation now avoid needless assignment updates; future investigator
instructions bind the configured identity and exact nested alert-read path.
These are reliability corrections, not a verified fix for authorization
propagation or counter delay. The twelve-minute gate is now decided as a split
target, not an unmet single number: it applies only to the live, presented
segment (fault through visible guest recovery, measured 9–11 minutes across
runs), while automatic monitor clearance (28–30 minutes) is platform-bound and
narrated during the walkthrough; see "Remaining acceptance gates" in
[disk-scenario.md](disk-scenario.md). The 18-minute verified-RCA delay in this
run is not resolved by that split and remains open below.
Stages 3 onward remain proposed.
**Assessment date:** 2026-10-09.
**Scope:** reusable demo product, private infrastructure integration proof, and
local transaction correctness, the private Azure application lifecycle, a
small native-action integration proof and an operator-first disk incident.
Operator-driven recovery does not establish approved SRE healing.

The [Stage 0 deployment guide](deployment-stage0.md) describes the implemented
private networking, Entra identities, infrastructure automation, fixed operator
verification, and owned teardown. Its baseline SRE configuration is read-only;
the separate native-action fixture adds only an exact VM-start grant, without
changing that agent's Review configuration. No budgets or scheduled expiry are
configured.

### Presenter-triggered live incidents

**Required for every live demo scenario, including future profiles:** the person
presenting the demo explicitly triggers each showcased fault using its prepared
button or scenario command. An assistant, scheduled task or acceptance-test
runner must not start that fault on the presenter's behalf. Confirming that the
presenter is ready is not the same as the presenter triggering it.

Automate deployment, readiness and teardown, then stop at the healthy, prepared
boundary. The presenter triggers the real fault; Azure Monitor detects
it and creates the incident through the scenario's verified routing path. Do
not manually create a substitute alert or investigation. Scenarios whose
alert-routing path is not verified must retain that limitation rather than
claim this flow.

This initiation rule does not change each scenario's recovery or approval
model. SRE may investigate, propose and perform only its permitted, verified
actions with the configured approval; an operator-script scenario remains
operator-driven. The user-directed fault-lifetime change below replaces
automatic safety recovery for new demo faults; historical watchdog recoveries
remain safety evidence, not SRE fixes.

**Development and testing authorization:** the assistant may trigger
incidents, safety canaries, fault-injecting `Verify` operations and
repeatability/cycle harnesses during building, preparation and acceptance
testing, outside the live demo. The user does not need to execute or reconfirm
each test fault. Existing scope, ownership, readiness and independent cleanup
guards still apply.

When SRE remediation requires a human in the loop, stop for the user's
availability and approval of the exact validated action; development/testing
fault authorization does not authorize approving the repair on their behalf.
Tests must finish with explicit recovery/reset or verified teardown and leave
a verified healthy fixture before presentation. Their faults are test
evidence, not presenter-triggered live incidents. Historical assistant-triggered
rehearsals do not establish this presenter-initiation acceptance gate.

Record the presenter-trigger action, time and exact scenario/run in the demo
evidence. If the prepared scenario cannot expose a supported explicit trigger,
it is not ready for this live-demo requirement. The current CLI operations
provide explicit triggers, but they do not universally enforce the presenter's
physical action or identity in code; this is a mandatory run-sheet and
acceptance requirement, not a claimed technical security boundary.

### User-directed fault lifetime change (2026-10-11)

**Implemented for new faults; local checks pass, live acceptance remains open.** The user selected
all implemented demo scenarios, not only the native guest-service fixture.
New faults must persist until an explicit repair, reset or teardown: no timed
watchdog recovery and no automatic recovery on reboot. Destroy/rebuild is an
accepted escape path for these disposable environments. Versioned native,
Windows and Service Bus contracts distinguish new Manual markers from legacy
timed evidence. The posting worker persists its manual pause in a new additive
database column; existing timed rows still retain their old expiry semantics.

Implementation scope is the actual local/Azure posting-backlog controls,
native VM-stop proof, native guest-service controller, Windows disk and
price-service controllers, and Service Bus SendDisabled fixture. Do not build
the proposed chaos catalogue. Recurring telemetry/observer work may remain,
but must not silently remediate a persistent fault.

Retain fixed disk/allocation caps, disposable-volume identity, source/resource
ownership, exact current-run binding, fresh independent evidence, least
privilege and real human approval of SRE remediation. Transport, admission,
polling and audit-observation limits remain bounded; they are not fault
expiry. Stale or replaced runs must not become executable merely because
their original deadline is removed. Legacy manifests and historical proofs
retain their original meaning, rather than becoming retroactively accepted.

**User-directed demo acceptance (2026-10-11):** judge the outcome and evidence,
not an identical conversation sequence on every run. SRE must execute the exact
human-approved repair using the explicitly declared supported baseline and
VM-scoped action permission, with no untracked permission drift. It must then
query fresh same-run service evidence and accurately report recovery, either
automatically or after a neutral human question such as "Is the issue resolved?
Check the current service health without repeating the repair." That question
is normal human-in-the-loop interaction, not an operator correction. Supplying
the recovery result for SRE to repeat is not independent verification.
Automatic post-action confirmation remains an improvement target, not a
demo-success prerequisite. Missing permission or recovery evidence remains a
blocker; unhealthy, stale or incomplete observations must not become a "yes."

The old `demo34` fixture is disposed. Unit/contract checks cover no timed or
reboot repair, exact-run explicit recovery and legacy interpretation; a real
isolated PostgreSQL restart preserved the posting pause until explicit undo.
Native live persistence passed in one frozen-source `demo35` fixture: the same
stopped service remained fault-active across a real reboot and 11.42 minutes
past injection, with recovery timer disabled. Monitor created the real
incident and SRE independently diagnosed it. The exact single-action
AsyncAudit card was human-approved: native submission Completed in 3.86s,
same-run SRE-principal guest recovery followed 14.32s after approval and the
unique Azure correlation reached Succeeded. The original guard rejected a
subscription Monitoring Contributor grant (exact user-authorized deletion
verified). On 2026-10-12 the owner accepted Microsoft's documented baseline:
Reader, Log Analytics Reader and Monitoring Reader at the managed resource
group, plus Monitoring Contributor at subscription scope. New guest execution
deployments explicitly own those assignments and reject untracked drift.
The earlier absence gate was stricter than the supported baseline; role presence
alone is not managed-identity self-elevation. Subscription monitoring is not
group-only isolation. VM Run Command remains a separate VM-scoped custom grant
requiring real human Review approval. See
[the permission/lifecycle boundary](guest-service-scenario.md#documented-sre-permission-baseline-2026-10-12).
This correction does not retroactively accept the old incident.
On 2026-10-12 the user explicitly advanced reusable native SRE skills from
deferred backlog to implementation. The opt-in
[guest recovery skill route](guest-service-scenario.md#opt-in-native-recovery-skill-repository-implementation-2026-10-12)
binds fixture configuration separately from fresh fault evidence, removes the
operator Propose prerequisite, retains one real human Review approval and
independent same-run recovery checks. It changes no protected guest source or
live fixture by itself; skills remain guidance, not service-only RBAC.
Issue #26 is In Progress; #25 remains the independent live acceptance gate.
SRE remained Idle with a stale pending-approval conclusion; automatic
continuation was not demonstrated and a neutral follow-up was not attempted
before teardown. Local Verify used read-only evidence, without correcting that
thread or replaying repair. The earlier unprompted-conclusion gate was stricter
than the outcome-based demo acceptance above.
Windows/broker live acceptance remains open; no customer rehearsal claim.
After evidence preservation, explicit Reset, Down and repeated Down completed.
Independent read-only checks confirmed the fixture group, owned resources,
custom role, action grants and active/soft-deleted workspace absent.
Next verify explicit baseline deployment, VM-scoped approved repair and independent
recovery confirmation in
[the focused validation](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/25),
not another full rebuild/test loop. The manual-lifetime/async changes were reviewed
and merged in PR #24; the new baseline changes require separate human review.

**Time-efficient validation:** batch implementation and focused local checks
before freezing source. Provision one owned fixture for the remaining
end-to-end acceptance; use read-only polling/reconciliation for delayed
command results instead of replaying writes or rebuilding. Explicit reset
can reuse healthy exact-owned state, but must archive the old run and approval.
Rebuild only for source changes, uncertain ownership/integrity or unrecoverable
fixture state. Preserve command/admission/audit limits and do not replace
missing evidence with success.

### Current Monitor transport decision (2026-10-10)

The user has selected **public HTTPS ingestion/query as the next baseline**
for the native service incident, with managed identities, Entra RBAC and
disabled local authentication preserved. The read-only policy review included
subscription and inherited management-group assignments and found no assigned
restriction requiring LAW/DCE public access to be disabled. Storage and Key
Vault Modify policies remain applicable to those services.

The public baseline is **implemented and live-verified for ingestion/query**;
the complete Monitor -> SRE -> human approval -> recovery gate remains open.
Fresh `demo28` proved AMA ingestion, VM-system-identity queries, built-in SRE
queries after tool-discovery guidance, and an actual Monitor-created incident.
Its independent fault diagnosis used incorrect KQL, and the exact-command guard
rejected an altered repair card. No human-approved repair executed; watchdog
recovery is not SRE healing. The existing private variants and their failed
native comparisons remain documented below. Every fresh fixture must still
verify public readiness before a real fault.
Fresh monitored native fixtures default to an owned public LAW, without a
DCE, AMPLS, Monitor private DNS or peerings. Transport is immutable and recorded
in lifecycle/readiness evidence. Reset/teardown preserve the selected mode and
permanently purge only owned disposable workspaces. Do not weaken authentication or fabricate
private transport success.

AMPLS troubleshooting/full-private Monitor transport is now a deferred
[optional-profile Spike](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/20),
not a baseline release blocker where public access is policy-compatible.
After the native baseline is verified, apply the same default to **future fresh
Arc profiles**. Preserve the retained working Arc/private foundation until a
separately implemented replacement or migration is authorized and verified.
This decision concerns Monitor data transport only, not Arc onboarding,
Arc control-plane private networking or other services' policy requirements.

## 1. Assessment and recommendation

At the initial assessment, the checkout contained only the project brief,
contributor tooling, and `.gitignore`, with no application, infrastructure,
tests, issues, or pull requests. The subsequent Stage 0 implementation is tracked
in [issue #2](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/2);
it adds infrastructure, lifecycle scripts, documentation, and offline tests.

The strongest part of the design is the connection between a technical incident
and **accepted sales not yet posted to the ERP, expressed in EUR per country**.
Keep that. The weakest part is attempting networking realism, host management,
two overlapping AI experiences, six failure scenarios, and automation together.

Build a reusable, versioned demo with one incident first:

> A posting worker stops. Sales continue to be accepted. Unposted sales increase.
> Azure Monitor alerts. SRE Agent investigates the evidence and proposes a restart.
> An engineer approves. The worker drains the backlog without duplicate postings.
> The agent records the outcome.

The first release does not need two agents to tell this story. It does need
correct transaction state, trustworthy telemetry, constrained actions, and a
repeatable deploy-reset-destroy lifecycle.

### Assumptions

- The first deployments use a dedicated demonstrator-controlled Azure subscription,
  not a customer's production subscription. Customer-tenant deployment is a later,
  separately approved onboarding path.
- Only synthetic stores, brands, transactions, and monetary values are used.
  Committed profiles have generic identifiers, never customer or people names.
- Reliable demonstrations and reproducibility matter more than production HA.
- Recommendations for later stages are proposals, not completed capabilities.
  Stage 0 subscription/region/provider and quota preflight has been performed;
  live integration evidence belongs in the deployment guide, not assumptions
  that every proposed product capability is already working.

## 2. What is the Observability Agent actually for?

The original "analyst versus operator" distinction is useful as a responsibility
model, but inaccurate as a hard product boundary: SRE Agent also investigates,
correlates telemetry, tests hypotheses, and explains impact.

| Capability | Azure Copilot Observability Agent | Azure SRE Agent | RetailTx decision |
| --- | --- | --- | --- |
| Explore logs, metrics, and application evidence | Azure Monitor-native chat and deep investigations | Queries connected telemetry during investigations | Either can explain an incident; do not duplicate the main demo |
| Preserve investigation context | Save investigations as Azure Monitor issues | Incident conversations, knowledge, and follow-up context | Keep one incident owner in the baseline |
| Background triage | Preview autonomous alert correlation and issue creation | Alert-triggered investigation and response plans | Optional comparison when alert noise is the customer problem |
| Change the environment | Autonomous operations do not restart resources or change configuration | Can execute permitted actions with configured approval controls | SRE Agent owns approved remediation |
| Custom operational process | Monitor-scoped instructions for autonomous operations | Runbooks, connectors, custom agents, tasks, and response plans | Start with one SRE Agent and a small knowledge pack |

Microsoft documents on-demand Observability Agent chat and investigation as
requiring no separate agent-resource provisioning. Autonomous operations require
an Observability Agent resource and are preview functionality. Access still
depends on Azure Copilot permissions and supported availability. It is not simply
a switch to enable on a Log Analytics workspace. [S1]

**Recommended narrative:** telemetry foundation -> SRE-led operational loop ->
optional specialists. Observability Agent sits alongside that loop as an
alternative Azure Monitor-native investigation and triage experience.

Include it when demonstrating how a monitoring team explores telemetry or reduces
multiple alerts into issues. Leave it out when the customer wants one incident
handled end to end. Do not promise automatic Observability-to-SRE handoff: that
integration has not been verified here and is not a release dependency.

SRE Agent already documents alert investigation, telemetry queries, hypothesis
testing, and proposing or executing fixes. [S2] Its run modes are not a universal
approval boundary: Review applies to Azure infrastructure writes; other tools
need appropriate policies or hooks. Response plans and scheduled tasks have
their own settings, with documented Autonomous defaults. Explicitly configure
Review for every demo remediation trigger instead of relying on an agent-wide
default. [S3]

## 3. Architecture and technology choices

### Alternatives

| Approach | Strength | Trade-off | Decision |
| --- | --- | --- | --- |
| Thin VM-based hybrid simulation | Matches the host/ERP operations story and existing Python stack | Requires disciplined host bootstrap and packaging | Recommended baseline |
| Container Apps for the cloud half | Useful revisions and managed application hosting | Adds platform and image-delivery concepts; does not remove the ERP VM problem | Reconsider only if cloud application operations become the main story |
| Full two-region VPN estate immediately | Highest network realism | Adds slow provisioning, routing, quota, and cleanup failure modes before the transaction works | Optional later profile |

### Smallest useful Azure topology

Use two peered VNets in one region, with explicit private routes, DNS, restricted
service access, and necessary outbound connectivity. Peering is **not a VPN** and
must be described as a simulation of a boundary, not an encrypted hybrid tunnel.
Private networking also does not replace application authentication or TLS.

| Placement | Components |
| --- | --- |
| One cloud VM | `cap-api`, outbox publisher, and scheduled `recon-job` |
| One simulated-datacenter VM | `erp-core`, its PostgreSQL ledger, `erp-poster`, and `pos-sim`, as separate services |
| Azure managed data services | PostgreSQL Flexible Server for accepted cloud transactions; Service Bus queue `IDOC_POSTING` |
| Operations resource group | Log Analytics, workspace-based Application Insights, workbook, alerts, and later SRE Agent |

The poster remains logically on-premises. Co-location is an explicit first-release
compromise: it is suitable for a stopped-worker scenario, not independent host
failure or capacity claims. Split ERP, poster, and simulator hosts before adding
those scenarios. A second cloud VM and load balancer are needed only for the
redundancy scenario.

Configure the simulated-datacenter host through the documented Arc evaluation
pattern after bootstrap. Azure still owns the backing VM's power/network/disk
lifecycle; Arc owns guest operations. Do not describe the hardware lifecycle as
"managed only through Arc." Never install both Azure-VM and Arc variants of the
monitoring extension on that host. [S4]

### Recommended stack

| Concern | Choice | Reason and boundary |
| --- | --- | --- |
| Azure infrastructure | Bicep; pinned Azure Verified Modules where suitable | Fits the Azure-only baseline without adding a second IaC state system |
| Environment orchestration | Azure Developer CLI (`azd`) with explicit hooks; PowerShell 7 lifecycle scripts | Same entry points on the developer machine and in CI; VM application installation needs custom automation |
| Guest bootstrap and processes | Supported Ubuntu LTS, cloud-init bootstrap, systemd services | Simple host/service failure model; later configuration through Arc |
| Application | Python, FastAPI, locked dependencies, versioned Python packages | Keep the existing proposal; reuse the same business code locally and on VMs |
| Local development | Docker Compose for services, PostgreSQL, and the official Service Bus emulator | Fast contract tests without building the Azure estate; not proof of Azure identity, networking, durability, or scale [S8] |
| Data correctness | PostgreSQL, migrations, transactional outbox, idempotent ledger writes | Survive retries, restarts, and temporary broker failures without losing accepted sales |
| Telemetry | OpenTelemetry, Azure Monitor/Application Insights, AMA and DCRs, KQL workbook | Application evidence plus host evidence, without a second observability stack |
| Agent operations | Azure SRE Agent; official IaC/configuration tooling pinned to a reviewed version | Do not build a custom agent framework to duplicate an existing service [S5] |
| Delivery and identity | GitHub Actions with OIDC, scoped Azure roles, managed identities, Key Vault only for unavoidable secrets | No long-lived deployment password in GitHub or committed environment files |
| Application artifacts | Build once, identify by version/digest, distribute through private artifact storage | Do not clone a moving branch or install unpinned packages during demonstrations |

Use the emulator's published prerequisites and license terms, including its SQL
dependency. Its data does not persist across container restarts and AMQP WebSockets
are unsupported; local tests must not be presented as cloud-equivalent tests. [S8]
Do not switch to RabbitMQ as an allegedly transparent substitution: broker SDKs,
authentication, delivery behavior, and operations would need an adapter and tests.

Defer AKS, a custom web control plane, Terraform alongside Bicep, Grafana/Zabbix,
ITSM integrations, Foundry/Copilot Studio agents, and multi-agent orchestration.
Each can be added for a distinct customer question, not as a baseline dependency.

## 4. Corrections to the application and incident design

### Transaction and reconciliation contract

Assign stable transaction IDs and store money as decimal values or integer cents.
Persist the accepted transaction and outbox entry in the same database transaction;
publish asynchronously with retries. Enforce a unique ledger transaction ID and
acknowledge the broker message only after the ERP commit. A redelivered message
must not create a second ledger entry.

Compute unposted EUR from authoritative accepted-versus-posted transaction state,
not queue depth multiplied by average basket size. Reconciliation reads must be
paginated/incremental and idempotent. Record their watermark, last successful
observation, and expected lag: unavailable ERP evidence means **unknown/stale**,
not zero unposted sales.

Define `unposted_eur` as sales not yet posted, not lost revenue. Show age of the
oldest unposted transaction, transaction count, and affected countries alongside
the value. Test that the outbox, broker, and ledger can recover from every
acknowledgment/commit boundary.

### Telemetry contract

Propagate trace context through HTTP and message properties. Correlate logs with
transaction and trace IDs, but do not use those high-cardinality IDs as metric
dimensions. Keep country and brand dimensions bounded.

Native Service Bus queue depth is queue-wide; it does not know message countries
or brands. Derive per-country business backlog from transaction state instead.
Calculate checkout p95 from request durations or a suitable histogram/query, not
from an average of precomputed percentiles. Keep error numerator/denominator
counts as well as the displayed ratio.

Use static metric or log-query alerts for the first disposable environment.
Dynamic thresholds require at least three days and 30 samples before firing;
weekly seasonality needs at least three weeks. Native Service Bus message-count
metrics, including `ActiveMessages`, are listed as unsupported for dynamic
thresholds. Therefore do not promise same-day learned promo curves or dynamic
queue-depth alerts. [S6]

Emit an explicit, timestamped demo change event for every fault and recovery.
This guarantees evidence for the first incident; Change Tracking can enrich it
later but is not a substitute for an application audit event.

### Deterministic faults and safe actions

Start with `backlog`: stop only `erp-poster`, leaving checkout healthy. A logged,
reversible configuration marker provides the change breadcrumb; do not introduce
a genuinely invalid configuration and pretend that restarting alone fixes it.
Use a repeatable load profile to make two countries dominate the first signal.
A shared stopped worker eventually affects all countries; say so.

Every scenario needs preconditions, expected evidence, capped resource pressure,
idempotent `--undo`, explicit reset/teardown independent of the SRE path, and a
verified healthy baseline. New demo faults have no recovery deadline; command,
admission and observation waits remain bounded.
Publish proposed thresholds and rehearsal measurements before claiming the
12-minute target. Agent response and telemetry latency are not guaranteed.

Do not fill a root disk or apply unbounded CPU/network pressure. Later headroom
scenarios use capped disposable storage and resource limits. Forecasting requires
enough real samples; otherwise display "insufficient history." Any seeded
historical trend must be visibly labeled synthetic, not a learned live forecast.

## 5. Delivery stages and acceptance gates

These are delivery gates, not calendar promises. Stage 0
and Stage 1 can proceed independently. Stage 2 depends on both; Stage 3 depends on
Stage 2; Stage 4 depends on Stage 3. Stage 5 contains optional, separately scoped
extensions, not a requirement for the first customer demonstration.

**Reliability reassessment, 2026-10-07:** pause expansion of the Azure application
profile. First return to the Stage 0 action gate and prove a small SRE-led flow
with hybrid evidence and a narrowly authorized Azure-side remediation. Arc guest
command delivery failed repeatedly, including after one backing VM restart;
adding more command transports or retries is not the default response. The
backlog scenario remains useful correctness evidence, not the required first
live SRE scenario. This smaller integration proof does not waive the lifecycle,
approval, or customer-release gates below. The subsequent native-action fixture
completed three consecutive automated recovery/incident-note runs on 2026-10-08
in 200-291 seconds, without operator recovery. Independent audit confirmed the
SRE identity for all three starts; private Arc evidence was refreshed. It has
no retail application or hybrid service dependency and therefore
does not satisfy Stage 3 business recovery or a human/no-terminal rehearsal.

**Subsequent user-directed sequencing:** adapt the workshop's disk-capacity
incident first, with explicit operator recovery. Use a separate disposable data
volume, not an OS disk, and prove independent cleanup before applying pressure.
This supersedes extending VM-start as the immediate next implementation step;
the native-action proof remains a verified fallback. The disk milestone does
not waive Stage 3's approved action/business-recovery criteria or Stage 4's
customer repeatability criteria. Do not diagnose an unreliable operator
transport as an SRE automation limitation without evidence.

| Stage | Scope | Exit gate |
| --- | --- | --- |
| **0. Prove the risky integrations** | Small disposable proof of agent availability, IaC/data-plane configuration, Arc onboarding, identity, and one approved action | Given the intended subscription and region, agent configuration can be reapplied; an approved fixed-action path works, or the manual fallback is explicitly accepted. All spike resources are removed |
| **1. Local transaction slice** | API, ERP, two databases, outbox, queue, poster, reconciliation, synthetic load, traces, and backlog fault | Given a known dataset, when the poster stops and resumes, expected unposted EUR rises and returns to baseline with no lost or duplicate ledger entries |
| **2. Repeatable Azure foundation** | Two-VM topology, Arc evaluation host, real managed data services, telemetry, workbook, static alert; deploy and destroy automation together | Given a fresh environment, when deployed twice, no duplicate infrastructure/configuration appears; backlog produces the expected signal; after destruction no unexplained owned resources remain |
| **3. One SRE-led incident** | One knowledge pack, alert response plan, evidence-based diagnosis, enforced action boundary, visible approval, recovery verification, RCA | Given the selected hybrid incident, no write occurs before approval; denial causes no write; approved recovery restores the business baseline; audit and RCA identify the action, target, and outcome |
| **4. Customer-repeatable release** | Generic profiles, CI lifecycle, readiness checks, no-terminal scenario trigger, reset, TTL cleanup, fallback recording | Given a new environment ID, deploy -> check -> demonstrate -> reset -> destroy succeeds three times from the same release; the presentation path targets <=12 minutes and lifecycle durations are recorded |
| **5. Targeted realism** | Add latency, then separated-host batch pressure/redundancy; optional VPN, second region, prevention, Observability Agent comparison, and real hybrid | Each extension has a distinct customer outcome, isolated feature/profile selection, fault/recovery evidence, and its own lifecycle gate |

Stage 0 must specifically establish:

- Subscription/region eligibility, providers, quotas, allowed SKUs, outbound access,
  and required operator approvals. Do not discover these during a customer setup.
- Arc bootstrap sequencing after removing VM extensions, disabling the Azure
  guest agent, and persistently blocking Azure IMDS as documented. Fetch required
  artifacts first; subsequent automation must not depend on the disabled VM agent.
- Azure cloud managed identity versus Arc identity behavior for Service Bus and
  application dependencies. Prove SDK token acquisition after Azure IMDS is blocked;
  do not silently substitute a shared broker connection string.
- The precise SRE -> approved action -> selected execution target path. First
  complete the selected operator-led incident; then test automatic execution
  separately, retaining the verified native Azure action as a fallback. Arc Run Command
  exists, but that alone does not prove reliable delivery, SRE integration,
  approval semantics, or a safe command allow-list. [S9] If broad script execution
  cannot be constrained, retain read-only diagnosis plus a human-run fixed action.
  A custom adapter is a separate decision, not an automatic workaround.
- SRE ARM deployment **and** data-plane configuration. Official tooling documents
  a second phase for knowledge uploads, hooks, and other extras; skipped mandatory
  extras must fail readiness, not count as successful deployment. [S5]

Before filing implementation work, classify it using the repository taxonomy:
Spikes for Stage 0, Enablers for lifecycle/telemetry, Tasks for technical wiring,
User Stories for operator outcomes, and Bugs for incorrect behavior. No
prioritization model currently exists in the checkout; use WSJF for independent
ready items after dependencies are honored. Every ticket must include priority,
rationale, Given/When/Then criteria, dependencies, estimate, labels, and Definition
of Ready. Missing estimates or scoring inputs remain explicit assumptions with
`needs-po-review`; this plan does not invent a scored Ready backlog.

### Open work after the private foundation proof

As of 2026-10-08, the private foundation in
[PR #1](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/1) is merged and
[issue #2](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/2) is closed.
The local transaction slice was reviewed and merged in
[PR #4](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/4). The private
Azure application profile extends it with real managed services and operator
lifecycle automation; its live acceptance record is maintained separately.
The separate native-action fixture proves a narrower action path, not the
complete approved-incident/customer gate. Remaining work:

| Work remaining | Dependency or boundary |
| --- | --- |
| Establish repeatability and presentation timing for the operator-first disk incident | Three fresh fixtures and one same-fixture reset completed actual pressure, automatic SRE investigation/proposal, exact-run operator recovery, private verification, automatic clearance and a final note. The latest prompt-recovery experiment restored the guest in 9m17s but counter/event disagreement delayed verified SRE recovery/RCA to about 18 minutes; the full flow remained 28 minutes. It required a readiness retry and correction of SRE's alert-read scope/API and identity fallback. The earlier reset needed one verification retry after an internal error. Early workspace-grant placement, no-write grant reconciliation, exact read-only incident snapshots and the prior-alert-resolution reset gate are implemented; their presence does not prove a faster uninterrupted cycle. Earlier Arc stalls and telemetry delay remain unexplained; acknowledgment remained AuthorizationBlocked. Four incidents across three fresh fixtures are not three uninterrupted customer acceptance cycles. The twelve-minute gate is now decided as a split target (live segment vs. platform-bound automatic clearance; see "Remaining acceptance gates" in [disk-scenario.md](disk-scenario.md)), but the 18-minute verified-RCA delay and human rehearsal remain open; retain the native-action fallback |
| Evaluate automatic guest recovery only after the operator-led incident is reliable | Separate Arc delivery, SRE tool support, approval boundaries and host/platform configuration. Native VM start remains the narrower verified fallback, not proof of guest remediation |
| Preserve the private Azure application profile as incomplete work until its live acceptance gates pass | Application identity, private connectivity and backlog recovery worked; final trace acceptance and repeatable guest control did not pass. Evidence belongs in the Azure application guide |
| Automate validation/deploy/reset/destroy in CI with OIDC, generic profiles, and externally scheduled expiry | Extend the existing operator lifecycle; no budget requirement |
| Rehearse the verified disk investigation/recovery/RCA flow with a human operator | The first proof used post-recovery follow-up messages and left alertState New despite monitorCondition Resolved. The acknowledgment boundary is now settled: keep it unacknowledged by design rather than widen the SRE role to Monitoring Contributor (the only built-in role with `alerts/changestate/action`); see "Remaining acceptance gates" in [disk-scenario.md](disk-scenario.md). Prove a clear human-operated presentation without claiming autonomous guest healing or requiring the deferred full application topology |
| Resolve the native VM Guest Configuration policy conflict for an accepted evaluation-host operating model | Coordinate with the policy owner or use real hybrid hosts; do not silently add exemptions |
| Add optional Observability Agent comparison, VPN/second region, prevention scenarios, and real hybrid | Only after the baseline incident is repeatable; not blockers for this foundation PR |

### Scenario direction agreed on 2026-10-09

Prioritize a service interruption **inside an Arc-managed Windows guest**:
automatic SRE investigation and recommendation, followed by an operator-run
fixed repair through Arc. The implemented
[pricing dependency fixture](price-service-scenario.md) uses an owned IIS pool
and real loopback HTTP failure/recovery evidence, not the full ERP, checkout
traffic, or business recovery. The first live incident verified real HTTP 503,
automatic alert/SRE investigation, an exact-run recommendation, operator-script
HTTP 200 recovery about 5m21s after injection, fresh private recovery evidence,
and an independent SRE recovery note. Ordinary and reboot watchdog safety also
passed. Monitor cleared automatically about 16m21s after injection; the SRE
incident record remained `new` with blocked acknowledgement. A distinct repeat
recovered after an operator corrected stale-run SRE evidence; it is not
uninterrupted repeatability acceptance. Owned teardown and independent grant
absence passed. New activation-time/freshness instructions require fresh live
acceptance; repeatability and human rehearsal remain separate gates.
Autonomous Arc repair is deferred.

The second target is a dedicated Azure Service Bus queue send-disablement with
**fully autonomous SRE recovery**, not automated test approval presented as
native autonomy. The [private broker slice](servicebus-scenario.md) implements
private infrastructure, a durable sender/receiver probe, a separate fixed-action
executor/deadline watchdog and a private Linux publishing/probe runner.
Queue-scoped RBAC alone permits other property writes; the executor code and
its exact authenticated caller/run/deadline checks are the proposed
pre-execution boundary. Live provisioning began, including the private queue
and executor-specific Entra grant; Linux provisioning authentication and Flex
Consumption configuration failures currently block runtime acceptance.
An independent live Queue GET also confirmed that the selected ARM API supplies
neither a queue ETag nor `userMetadata` in the response. Earlier mock-backed
coordination assumptions therefore cannot support a safe live fault. A private
Entra-authenticated blob using actual Blob ETags and leases is a potential
replacement, not an accepted implementation. It could serialize participating
fault, executor and watchdog writers, but not unrelated ARM administrators.
No broker fault was attempted under the unsupported contract.
Arming, fault injection and autonomous recovery remain unverified. The SRE
identity has no queue-management role; this is an explicit architecture
addition, not an assumed native capability.
By user direction on 2026-10-09, this is now a parked feasibility investigation,
not an open-ended implementation workstream. Partial fixture teardown and
independent resource/Entra/peering absence checks passed. The blob redesign
remains unfinished and is not deployment-ready. Prefer a bounded native
Azure VM-action feasibility check next; the existing native proof used
automated test approval and does not establish approval-free, alert-triggered
autonomy.

| Alternative | Verified evidence / remaining gate | Feasibility conclusion |
|---|---|---|
| Native Azure VM start | [Existing proof](native-action-proof.md) verifies SRE action identity and recovery with automated test authorization. Alert-triggered, approval-free execution remains unverified. | Preferred bounded next investigation; not yet an autonomous demo. |
| Azure-hosted application recovery | No supported native action or end-to-end recovery path verified for this workload. | Check action support first; do not provision a new executor speculatively. |
| Operator-driven Service Bus restoration | Private queue provisioning worked, but no broker incident/recovery flow was exercised. | Possible fallback, but duplicates the Arc recommendation/operator experience. |
| Custom autonomous Service Bus restoration | Executor, watchdog, private publishing runner and leased state require further runtime and lifecycle acceptance. | Technically plausible; park because complexity is disproportionate to this iteration's demo value. |

The partial `demo15` fixture was removed without injecting a fault. Repeated
Down returned `Absent`, and independent reads confirmed the resource group,
external foundation peering and exact executor application/service principal
absent. The ownership manifest is archived locally; the shared foundation
remains intentionally retained. Unfinished broker source experiments are not
part of the verified delivery and must not be deployed or armed. Any renewed
broker work needs a separate bounded acceptance decision and freshly attested
fixture.

By user direction, the next bounded gate is
[native Azure VM guest-service recovery](guest-service-scenario.md), not VM
start. Keep the VM running while a disposable application service is stopped.
Prove current guest evidence, an independent deadline watchdog, exact-run
operator repair and owned teardown first. SRE can reason over explicitly
attributed operator-collected guest receipts without receiving privileged
Run Command authority. Direct SRE guest execution and alert-triggered autonomy
remain separate gates: VM-scoped Run Command RBAC is not a service-only action
boundary. Do not recreate the parked broker's custom execution platform.
The first native guest fixture (`demo19`) verified a real stopped worker with
the VM still running, independent canary recovery in 62 seconds, SRE read-only
diagnosis and exact-run operator repair 5m26s after the actual service stop.
SRE recorded recovery about ten minutes after the stop, using attributed guest
receipts. A persisted timestamp comparison required correction before that
follow-up; this is not an uninterrupted rehearsal or autonomous acceptance.
Alert-driven intake and a defensible guest-write boundary remain separate
gates. See the scenario guide for timing definitions and limitations.

The subsequent native SRE execution gate found a documented Azure CLI candidate,
but **no safe guest-write grant for the retained shared agent**. Its live global
tool-policy lists were empty and remained unchanged. Argument-aware deny rules
are global only; thread/custom-agent allows cannot supply a deny-by-default
boundary and can bypass Review approval. Documented hooks run after tool use,
not before a privileged script executes. Follow-up review found that an isolated
agent alone cannot establish the proposed boundary: blanket deny overrides the
exact repair allow, and exact allow alone is not deny-by-default. An explicit
[owner decision](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/10)
was resolved explicitly by the user: the next demo is supervised Review-mode
execution on one disposable native VM, with a human approving the proposed
command before any SRE guest execution. VM-scoped privileged scripting is
accepted for that proof, not claimed to be service-only enforced. Use an isolated
agent/action identity and remove the grant afterward; do not broaden the shared
agent or add another executor. **2026-10-09: the `demo23` fixture passed this
gate.** SRE proposed the exact repair command; a human approver verified it
byte-for-byte against the portal's pending card and clicked Approve before any
execution. Guest evidence (`recoveredBy`/`recoveryReason`), an independent
Azure Activity Log query (single `correlationId` across `Started` ->
`Accepted` -> `Succeeded`) and the approver's own verification all confirm
exactly one gated invocation. See
[guest-service-scenario.md](guest-service-scenario.md#human-approved-repair-evidence-demo23)
for the full reconciliation, including a known tooling gap: the adapter's Read
operation does not yet expose a structured pending-approval state, so
operators must watch the SRE portal/chat UI itself during the approval step.
Arc remains recommendation/operator repair, with alert intake and autonomy deferred.

A reusable, code-only repeatability tool
(`scripts\Invoke-GuestServiceCycleTest.ps1`) now exists to close the remaining
"only once each" gaps on this scenario: three repeated fault/repair cycles and
one VM-reboot cycle that must recover via the independent watchdog alone, with
no operator repair call. It orchestrates the existing `Fault`/`Repair`/`Status`
operations and the same `az vm restart` pattern used for the disk scenario; it
adds no new privileged path. **2026-10-10: run live against a fresh `demo25` fixture** — bootstrap canary
plus three fault/repair cycles plus one reboot cycle, `TotalCycles=5,
Success=True`, zero failures across all 33 persisted journal entries. The
reboot cycle confirmed a real VM restart (distinct `bootId`) followed by
unattended watchdog recovery (`recoveredBy: "watchdog"`,
`recoveryReason: "reboot"`), with no operator repair call, inside the
recovery deadline. Three-cycle repeatability and cross-reboot watchdog
acceptance are now verified, not just tooled; see
[guest-service-scenario.md](guest-service-scenario.md#repeatability-and-reboot-test-wrapper)
for the full per-cycle evidence table. The `demo25` fixture was torn down
afterward.

**Next authorized gate: native Azure Monitor intake.** The user has approved
making service-down incidents Monitor-triggered before the full demo, rather
than treating monitoring as optional because the original fixture was minimal.
`Up -WithSreExecution -WithMonitoring` now prepares a fresh monitored native
variant with public Monitor HTTPS by default; Monitor/Telemetry/Connect/Arm/Incident lifecycle operations add authenticated
Syslog observations, an exact-VM stateful alert and isolated Review routing.
The existing exact-command adapter can continue the alert-created thread with
`-IncidentThreadId`, preserving human portal approval and action-identity audit.
Readiness and subsequent faults reject missing/stale/wrong-run evidence;
reset waits for previous Monitor clearance and archives approval receipts;
Down removes recorded external query grants and owned infrastructure without
changing the retained foundation/shared agent. **2026-10-11, `demo28`:** public
AMA delivery, VM-identity query, built-in SRE query with alternate execution
channels denied, and real alert-to-thread routing were verified. SRE query
discovery needed intervention; same-run fault queries then used case-sensitive
ARM-ID equality and wrong nested field paths. The supplied repair's encoded
controller path was altered by SRE, and exact-command validation refused the
pending card without approval/execution. The watchdog restored the real run
at `09:58:25 UTC`; a separate operator query confirmed ingested recovery.
Independent diagnosis, an exact human-approved repair, action-identity audit,
accepted RCA and the complete monitored lifecycle remain acceptance gates.
The alert resolved naturally at `10:09:11 UTC`, about 10 minutes 46 seconds
after watchdog recovery, without acknowledgement or forced resolution.
Two Down calls verified complete owned-fixture absence at `10:20:25` and
`10:20:56 UTC`, including active/recoverable LAW absence, recorded grants and
the custom role. The pending altered card was never approved; its agent/VM
were removed rather than claiming a human rejection. Monitored Reset and
another incident cycle were not attempted. Subsequent local guidance and
empty-query diagnostic corrections preserve all approval/identity/freshness
gates and require a fresh live rehearsal.
See [the live public proof](guest-service-scenario.md#first-public-monitor-proof-connectivity-passes-repair-blocked).

**Fresh corrected rehearsal (`demo29`, 2026-10-11): blocked before real fault.**
Public deployment/monitoring and the sixty-second watchdog canary passed;
operator LAW queries returned fresh exact-owner/canary healthy Syslog.
The VM-system-identity telemetry diagnostic timed out after 180 seconds,
and a subsequent read attempt failed. Its inspected Activity Log contained
Started / Accepted, not a verified result. No readiness bypass, SRE Connect,
real fault or approval was attempted. Reconcile the native read-command
boundary before another live incident; this is not a public Monitor outage
diagnosis or a failed human approval. The investigator corrections are still
live-unverified. See [the fresh rehearsal boundary](guest-service-scenario.md#fresh-public-rehearsal-blocked-before-the-real-incident).
Two Down calls verified complete owned-fixture/workspace/grant/custom-role
absence at `11:17:42 UTC` and `11:18:24 UTC`; the retained Arc foundation was
unchanged.

**Authorized reliability gate before another incident:** use a smaller
`Up -WithMonitoring` public fixture without SRE deployment or retained-identity
grants. Probe/Telemetry preserve native Action Run Command submission intent,
tracking headers and safe request/error evidence; Command resumes only the
saved GET operation. Lost submissions and missing output remain unknown and
block another command. Stage diagnostics separate DNS, VM identity and LAW
query execution without exposing credentials. Require a tiny delivery/result
probe plus three sequential fresh identity-query successes and an independent
operator LAW read, then remove the owned fixture/workspace and verify absence
twice. This tooling does not prove SRE investigation or human-approved repair.
See [native command diagnostics](guest-service-scenario.md#native-command-diagnostics-without-sre).

**2026-10-11, `demo31`: diagnostic tooling verified, reliability still blocked.**
The tiny native probe returned exact output in about 27 seconds. The first
staged VM query returned DNS/identity success and LAW HTTP 403
`InsufficientAccessError`. A later query remained Azure `InProgress` through
bounded GET-only resumption, with no returned guest-stage evidence. One native
VM restart was accepted but its completion was not verified; no diagnostic
POST or restart was replayed. Independent fresh healthy Syslog ingestion
continued. Zero of three successful VM telemetry cycles passed, so SRE/fault/
approval remained unattempted. Complete owned-fixture/workspace/grant absence
was verified twice at `12:53:35 UTC` and `12:54:02 UTC`; retained Arc/private
resources were unchanged. Native command reliability remains an open gate,
not a public Monitor outage diagnosis or completed incident.

**User-directed next experiment:** try the real bounded fault/Monitor/SRE/
human-approved-repair flow with direct operator LAW readiness, instead of
requiring a successful VM-side LAW diagnostic. Fresh public SRE fixtures may
explicitly select immutable `-MonitorReadMode Operator`; defaults/legacy stay
`VmIdentity`. This source change preserves exact-owner/VM/run, freshness,
watchdog, Review, exact-command and action-audit gates. SRE must still read LAW
independently. Verify approved recovery from ingested observations without a
new guest diagnostic, but do not accept watchdog recovery or unresolved native
execution. For a live demo, stop before injection and have the presenter
explicitly trigger the real fault; readiness confirmation is not injection.
See [the direct rehearsal path](guest-service-scenario.md#direct-incident-rehearsal-with-operator-law-reads).

**Direct rehearsal result, 2026-10-11 (`demo32`):** the bounded real fault ran
despite a missing native CLI result. Independent ingestion established it, the
real Monitor alert created the incident, and SRE correctly read/diagnosed the
same-run stopped service without corrective messages. An adapter UTC/local
timestamp representation mismatch blocked the exact proposal before any repair
card or approval. Watchdog recovery was independently verified; it is not SRE
repair. The fixture and its grants were removed twice, following explicit
human authorization to remove one newly added out-of-manifest subscription
Monitoring Contributor grant. Timestamp semantics were fixed and regression
tested only after disposal. At that point the next gate was fresh human-approved
SRE repair and same-run audited recovery, not another mandatory VM-side LAW
diagnostic.

**Fresh follow-up, 2026-10-11 (`demo33`): actual SRE repair, incomplete result
acceptance.** The timestamp fix admitted the exact proposal. A real Monitor
incident led to independent correct diagnosis, a validated policy card and
actual human portal approval at `16:05:07 UTC`. Fresh ingested same-run
observations show the SRE action principal restored the service at `16:05:20`,
about 13.6s after approval and before the watchdog deadline. Azure eventually
recorded the matching action correlation as Succeeded at `16:15:24`; natural
Monitor resolution followed at `16:18:05`. This was an assistant-triggered
development test, not live presenter-initiation evidence.

SRE's native CLI execution remained Failed despite the real guest recovery and
eventual successful Azure audit. Strict Verify correctly rejected it. SRE's
incorrect "no card/no repair" conclusion required an operator corrective message
and an independent LAW requery; that is not autonomous conclusion acceptance.
An unrecorded subscription-wide Monitoring Contributor grant was present during
execution, rejected by the lifecycle guards and removed only after explicit
human permission. The intended scoped-only execution boundary is not proven
by this run. Exact-run Reset and repeated Down passed, including independent
absence/zero owned residuals at `16:33:17 UTC`; the retained estate was unchanged.

**Next gate:** a fresh fixture with its explicitly recorded documented baseline,
VM-scoped repair grant, no untracked drift, and an
independent SRE recovery check and conclusion, automatically or after a neutral
human follow-up under the user-directed demo acceptance above. Improve automatic
continuation separately; a supplied outcome/corrective RCA is not that check.
On 2026-10-11 the user authorized
testing documented `--no-wait` submission on the same native action path:
new Operator-mode proposals now distinguish successful native submission from
correlated Azure operation completion and exact-run pre-watchdog guest recovery.
Read durably binds one matching correlation and rejects a sliding window,
ambiguous/truncated audit or changed identity. Async Verify saves acceptance
without posting a corrective message to SRE. Legacy synchronous runs retain
their original gate; `demo33` remains unaccepted. Do not suppress warnings as a
claimed root-cause fix or replay a repair whose effect is unknown. See
[the new submission/completion contract](guest-service-scenario.md#approved-async-submission-and-independent-verification) and
[the measured return-path boundary](guest-service-scenario.md#human-approved-monitored-repair-result-return-boundary).
Full incident repeatability and retail/business recovery remain open.

The user-authorized diagnostic variant, `Up -WithSreExecution -WithMonitoring
-MonitorTransport Private -WithIsolatedMonitoring`, provisions a disposable private LAW/DCE/AMPLS instead
of using the retained foundation. DNS checks reject duplicate/foreign Monitor
namespaces linked to either fixture VNet. Down unlinks and permanently deletes
only that owned workspace. This comparison is not a requirement for one workspace
per VM, a shared-foundation fix or incident acceptance; see
[the diagnostic boundary](guest-service-scenario.md#isolated-private-monitoring-diagnostic).

**2026-10-10 isolated comparison (`demo27`): same readiness failure.** A new
owned private LAW/DCE/AMPLS did not avoid query `PrivateLinkValidationFailedError`
or AMA Syslog-upload HTTP 403. Post-deployment checks attested ten unique owned
DNS links across the two fixture VNets, correct endpoint NIC addresses and the
new workspace/AMPLS backlink. The retained Arc private path still returned
current telemetry. Duplicate same-service DNS zones linked to these VNets were
not found; the underlying rejection remains unresolved. No fault or incident
acceptance was attempted. The disposable workspace was purged and checked
against active/recoverable inventories; resumed Down and repeated absence
verification removed the fixture and its owned grants/custom role completely.

**2026-10-10 live attempt (`demo26`): blocked at private telemetry readiness.**
The fresh VM/SRE and monitoring deployments succeeded; local Syslog
observations and AMA collection configuration were present. Private query
returned `PrivateLinkValidationFailedError` / HTTP 403 and AMA Syslog uploads
also returned 403 despite approved endpoint and matching private DNS/AMPLS
bindings. The cause is unresolved. No fault, automatic investigation, approval
or repair was attempted, and private-only settings were not relaxed.
The attempt also exposed teardown inventory omissions for owned DNS links and
the platform Defender extension; guarded cleanup now attests these exact
resources rather than accepting arbitrary children. Two live Down calls
verified fixture absence, external grant/custom-role cleanup and removal of
its AMPLS endpoint connection; no owned tagged residuals remained. See
[live findings](guest-service-scenario.md#first-monitored-live-attempt-readiness-blocked).

Preserve bounded faults, independent cleanup, authenticated telemetry with an
explicit verified transport mode and fixed-action
permissions. Changing a fault alone does not remove log-alert clearance or
evidence-ingestion delays; measure verified fixture recovery/RCA and automatic
Monitor clearance separately without silently replacing the full-flow
acceptance gate.

### Third scenario: GitHub-reported incident to SRE recommendation

**Status: design clarified and mechanism identified by documentation research
(2026-10-11); not yet built or live-verified. Still independent of the faster
Arc/native-VM fault experiments above and must not delay them.**

**Latest direction supersedes the fallback-only framing below:** verify the
native Monitor-triggered variant first. The GitHub issue will then be a human
report alongside that alert, correlated to its existing investigation rather
than replacing Monitor or creating a duplicate. HTTP-trigger/OIDC intake and
comment-back remain unbuilt; the historical design below is not authorization
to omit monitoring from the final demo.

Two decisions narrow this scenario from the earlier "parked, unverified
connector" framing:

1. **Intake mechanism.** Azure SRE Agent has no native inbound GitHub trigger.
   [S2]'s GitHub connector and incident platforms ([S11]) are outbound/ServiceNow/
   PagerDuty/Azure-Monitor-only. The documented, generic mechanism for any
   external source is an **HTTP trigger** ([S10]): a named webhook endpoint on
   the agent (`POST /api/v1/httptriggers/trigger/{id}`) whose JSON body is
   merged into the agent's prompt, authenticated with an ARM bearer token
   (`Microsoft.App/agents/threads/write`). For a GitHub issue, the realistic
   bridge is a **GitHub Actions workflow on `issues: opened`** in the private
   allowlisted repository, using OIDC federated credentials (no stored secret)
   to mint that ARM token and POST the issue title/body/URL to the trigger.
   This is still unverified end-to-end in this environment; it is a documented
   capability, not a tested one.
2. **Fixture reuse.** Rather than build a new synthetic fault for this
   scenario, reuse the existing stopped-posting-worker fixture from
   [`guest-service-scenario.md`](guest-service-scenario.md) (the non-Arc native
   Azure VM, deliberately unmonitored by design). The GitHub issue becomes an
   alternate, human-reported intake path into the same already-proven
   diagnosis/evidence flow, instead of its own fault.

This scenario stays a deliberate contrast case for the standing principle
"eventually every incident should be Monitor-alert-triggered": because this
fixture has no monitoring by design, it demonstrates the fallback path for when
Monitor has not (and structurally cannot yet) fire — not a replacement for
alert-driven intake. See the open item below for closing that gap generally.

| Backlog field | Proposed value |
| --- | --- |
| Title | Investigate a GitHub-reported retail incident and recommend a fix |
| Agile type | Feature; a prerequisite Spike verifies the HTTP-trigger bridge end to end |
| Description | An operator reports the stopped-posting-worker symptom (reusing the `guest-service-scenario.md` fixture) in a private GitHub issue. A GitHub Actions workflow on `issues: opened` mints an ARM token via OIDC and posts to the SRE Agent HTTP trigger. SRE correlates bounded private evidence and returns an actionable recommendation without executing a fix |
| Priority | Deferred behind the agreed faster incident scenarios; numerical WSJF rank pending |
| Rationale | Demonstrate human-reported incident intake even when Monitor has not alerted, using the same evidence and guardrails rather than another autonomous-action demonstration |
| Dependencies | Verified HTTP-trigger creation and OIDC-to-ARM-token bridge, private allowlisted repository, least-privilege GitHub Actions/telemetry access, incident correlation against the reused fixture, approved runbook |
| Estimate | Not estimated until the integration Spike verifies the bridge live |
| Labels | Proposed: `feature`, `scenario`, `deferred`, `needs-po-review`; not applied to a GitHub item |
| Definition of Ready | Not Ready: mechanism identified but unverified live; estimate and WSJF inputs missing |

**Storyboard:** an operator raises an issue such as "checkout postings look
stuck on the native ERP VM." A GitHub Actions workflow on `issues: opened`
mints an ARM token (OIDC, no stored secret) and POSTs the issue title, body and
URL to the agent's HTTP trigger. SRE picks up the merged prompt as a new
investigation, preserving the exact issue URL and source provenance, checks the
relevant private evidence and approved runbook for the reused fixture, then
posts the observed condition, evidence timestamps, likely cause, confidence,
recommended fixed recovery action and verification steps back to the issue.
Missing or conflicting evidence produces an explicit uncertainty or
clarification request, not an invented cause. Posting the recommendation is the
only intended write; the issue remains open for human disposition.

Acceptance criteria for the future implementation:

- Given an eligible issue in the allowlisted private repository, when it is
  raised, then the Actions workflow mints a token and calls the HTTP trigger
  automatically, and the investigation preserves the issue-to-trigger-call link.
- Given private evidence for the reused fixture's symptom, when SRE
  investigates, then its recommendation cites fresh scoped evidence and an
  approved recovery procedure without executing remediation.
- Given missing, stale or conflicting evidence, when SRE responds, then it
  states the limitation and requests the specific information needed.
- Given an existing alert-driven investigation or duplicate issue delivery,
  when intake runs, then it correlates/links the report without duplicate
  investigations or repeated recommendations.
- Given malicious instructions in an issue or comment, when SRE reads them,
  then they remain untrusted incident data: no arbitrary commands, identity
  switching, permission expansion or disclosure of secrets/customer context.
- Given the scenario is reset or removed, when its lifecycle runs, then the
  owned HTTP trigger, Actions workflow and OIDC federated-credential grant are
  disabled/removed, and existing repository or shared-agent configuration is
  preserved.

**Assumptions and integration gate:** the HTTP-trigger mechanism and its ARM
auth requirement are documented ([S10]), but the specific OIDC-to-ARM-token
bridge, trigger-to-issue correlation, and comment-back behavior have not been
exercised live in this environment. A manual issue-URL handoff can illustrate
recommendation quality but does not pass automatic-intake acceptance. Do not
build a custom Functions/Logic Apps/APIM bridge instead of a direct OIDC Actions
call without an explicit decision — it adds infrastructure the documented
mechanism does not require. WSJF inputs are unknown; keep `needs-po-review`
rather than fabricate a score.

The existing autonomous proof is narrowly scoped native Azure VM start with
automated test authorization, not autonomous Arc/application repair. This
future scenario intentionally demonstrates recommendations instead; it requires
no new guest-write permissions, code-fixing agent or automatically generated PR.

**Open item — Azure Monitor as the eventual trigger for every incident:** the
user's standing direction is that all incidents should ultimately be
Azure-Monitor-alert-triggered, including process-down conditions like the one
in `guest-service-scenario.md` (Azure Monitor Agent can watch a Linux process
via a custom-log/syslog pattern — a service-down watchdog line collected by AMA
and fired by a scheduled-query alert — the same pattern already proven in
[`infra/disk-monitor.bicep`](../infra/disk-monitor.bicep) for disk capacity).
This is now the authorized next gate, not deferred: the original fixture stays
available for its narrower proof, while a fresh opt-in monitored variant must
pass live acceptance before the full demo. The GitHub report should correlate
with Monitor intake; it is not justification to keep final incidents unmonitored.

## 6. Deployment, reset, and teardown are product features

### Configuration, not customer forks

Use a pinned release and a small profile: generic `environmentId`, target
subscription/tenant, workload and agent regions, deployment profile, synthetic
dataset seed, scenario selection, expiry, and resource-size choices. Keep actual
customer association outside the repository.

Start with `local` and `azure-lite`. Add `azure-vpn` and `real-hybrid` only when
their stages are implemented. Keep options bounded instead of supporting arbitrary
combinations. Generate agent knowledge and resource references from the same
profile; validate and review the generated context before enabling actions.

Use environment-scoped cloud, simulated-datacenter, and operations resource groups.
Include an environment ID in names, not just a region, to avoid collisions.
For future deployments, use stable workload/component names and a neutral generic
ID such as `demo01`: for example, `rg-retailtx-ops-demo01-swedencentral`.
Do not encode delivery stages, phases, or milestones in resource names, environment
IDs, or reusable deployment artifacts. Delivery stages remain useful for planning,
not runtime identity. Existing proof names and ownership manifests are retained;
changing this convention does not authorize renaming or recreating live resources.
Tag resources with `demo=retailtx`, `environmentId`, `profile`, `expiresAt`,
`managedBy`, and generic `site`/`system` values where applicable.

### Proposed operator contract

The following is the **full target application contract**. The narrower foundation
commands remain in `scripts/Invoke-Stage0.ps1`. The independent
`scripts/Invoke-Azure.ps1` now implements `Preflight`, `Up`, `Status`, `Doctor`,
`Verify`, `Scenario`, `Reset`, and `Down` for the private application profile.
Agent configuration, CI/expiry automation, and a no-terminal presentation surface
remain outside that implementation.

| Operation | Required behavior |
| --- | --- |
| `preflight` | Validate identity, target subscription, profile, quota, region support, permissions, and protected/shared-resource boundaries |
| `up` | Build or select pinned artifacts, provision with Bicep, bootstrap hosts, configure Arc/monitoring, seed data, apply agent configuration, and wait for readiness |
| `status` / `doctor` | Check applications, dependency reachability, poster heartbeat, actual telemetry ingestion, alert wiring, context version, and pending/skipped steps |
| `scenario` / `reset` | Apply a selected fault or undo all faults; verify business and technical recovery without destroying the environment |
| `down` | Preview the exact owned deletion set, stop triggers/load, perform pre-delete cleanup, delete owned resources, and report residuals |

Back these with `azd` where it fits, not an assumption that `azd up` automatically
deploys arbitrary VM applications. Use its documented provisioning/deployment and
`predown`/`postdown` hooks for the missing lifecycle steps. [S7]

Idempotency includes data-plane uploads, role assignments, synthetic seed data,
Arc registrations, and alert connections, not just Bicep. Retry transient failures
with bounds; persist phase results so failed setup can be resumed or destroyed.
Serialize operations per environment to prevent deployment racing with TTL cleanup.

### Ownership and deletion safety

Create an external-to-the-target-groups environment manifest containing exact
owned resource IDs, deployed release, registration IDs, and configuration versions.
Protect the manifest and keep it available after partial provisioning failures.
Classify everything as **owned and disposable**, **shared**, or **retained by
policy**. Subscription IDs, group names, and tags must agree before deletion;
tags alone are not sufficient authority.

Disable incident triggers and scheduled tasks, stop the simulator, undo faults,
and export only explicitly retained synthetic rehearsal evidence before removing
resources. Disconnect Arc while machines are reachable; delete orphan Arc records
when a machine is already gone. Remove owned role assignments, connectors,
temporary onboarding credentials, and scope-external artifacts recorded in the
manifest. Never delete shared networks, shared identities, or real customer hosts.

Check soft-deleted resources, purge protection, diagnostic destinations, resource
locks, deployment artifacts, public IPs, disks, and retained workspaces. Do not
promise that deleting resource groups or running `azd down` removes Entra objects,
external integrations, or every retained item. Do not default to force-purging
protected resources. Report retention reason, owner, and remaining cost exposure.

Run `down` again safely after both a successful deletion and a partial failure.
Verify absence of owned live resources and produce an explicit residual inventory;
do not declare zero ongoing cost solely because a delete command returned success.

TTL cleanup must run outside the environment it deletes, using the same scoped
destruction implementation and an independently authenticated identity. Budget
alerts notify; they are not spending caps. Default to full per-demo isolation,
including SRE memory and telemetry. Retaining a shared warmed-up environment is an
explicit alternative with ongoing charges and a data/memory reset obligation,
not the disposable baseline.

### CI and the no-terminal presentation

Use protected GitHub Actions environments, scoped OIDC trust, pinned actions,
explicit environment IDs, and per-environment concurrency. Separate validation,
deploy, scenario/reset, and destroy workflows. Privileged workflows must not execute
untrusted pull-request code. Authentication/bootstrap of the CI trust relationship
is a documented one-time prerequisite, not hidden manual per-demo setup.

Start the presentation from Azure portal and approved agent actions. Before the
customer-repeatable stage exits, provide a protected workflow-dispatch scenario
button and reset button; a custom dashboard is unnecessary. Separate the ability
to inject a fault from the agent's narrow remediation permissions.

## 7. Guardrails and evidence

The deployment identity, agent identity, action executor, and presenter are
different roles. Grant only scoped access each requires. A Markdown allow-list
is guidance, not enforcement; resource-level RBAC on Run Command also does not
constrain arbitrary script contents by itself.

Enforce approved targets and fixed actions at the tool/execution boundary, with
action policies or a constrained executor as established by Stage 0. Do not expose
a general root shell as a "restart worker" tool. Test wrong-target requests,
unapproved actions, denial, missing permissions, and attempts to pass arbitrary
commands. Log correlation, approver, action, outcome, and recovery evidence.
Turning off triggers or revoking the action executor must stop future writes.

Operational data is evidence, not instructions: logs and runbook retrieval must
not be allowed to widen tool permissions. Keep secrets and personal data out of
logs, traces, profiles, prompts, and generated documentation.

Local tests prove financial invariants and fault undo. Azure integration tests
prove real broker behavior, identity, private connectivity, Arc host operations,
telemetry arrival, and approval enforcement. End-to-end rehearsal measures the
complete incident and lifecycle, not just API health. Distinguish **infrastructure
provisioned**, **application healthy**, and **demo ready** in every status report.

For real-hybrid Stage 5 work, reuse application packages, telemetry contracts,
and runbooks, but implement separate Proxmox/host and site-to-site VPN lifecycle
adapters. Azure resource teardown must not destroy pre-existing homelab/customer
machines. Keep Service Bus initially; changing the broker is a separate project.

Non-Arc systems can still contribute exported logs or API evidence. Lack of Arc
primarily limits supported host management, not all visibility. Do not claim
complete estate coverage from either agent.

## 8. Sources and unresolved evidence

Product documentation was consulted on the assessment date. Preview surfaces and
APIs may change; pin implementation dependencies and repeat capability checks
before choosing deployment regions or making customer-facing commitments.

- **[S1]** [Azure Copilot Observability Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/aiops/observability-agent-overview):
  chat, investigations, issues, optional agent resource, and non-remediating
  autonomous operations.
- **[S2]** [Automate incident response in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/incident-response):
  telemetry investigation, hypotheses, and response ownership.
- **[S3]** [Run modes in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes):
  infrastructure-write approvals, response-plan/task modes, and other tool controls.
- **[S4]** [Evaluate Azure Arc-enabled servers on an Azure virtual machine](https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine):
  evaluation-only support, Azure guest-agent/IMDS restrictions, and management split.
- **[S5]** [Deploy with infrastructure as code in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/deploy-iac):
  official Bicep/azd tooling, ARM phase, data-plane extras, and verification.
- **[S6]** [Alert rules with dynamic thresholds overview](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds):
  minimum history and unsupported Service Bus metrics.
- **[S7]** [Customize Azure Developer CLI workflows using hooks](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/azd-extensibility)
  and [Azure Developer CLI reference](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/reference):
  lifecycle extension points and resource deletion controls.
- **[S8]** [Overview of the Azure Service Bus emulator](https://learn.microsoft.com/en-us/azure/service-bus-messaging/overview-emulator):
  local-development scope and limitations.
- **[S9]** [Cloud-native scripting and task automation with Arc-enabled servers](https://learn.microsoft.com/en-us/azure/azure-arc/servers/cloud-native/scripting-task-automation):
  Arc remote execution, not proof of an integrated SRE remediation path.
- **[S10]** [HTTP triggers in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/http-triggers):
  named webhook endpoint per agent, JSON body merged into the agent prompt,
  ARM-token authentication (`Microsoft.App/agents/threads/write`), and
  alert-driven investigation as a documented use case.
- **[S11]** [Incident platforms in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/incident-platforms):
  native inbound incident intake is documented for ServiceNow, PagerDuty and
  Azure Monitor Alerts only; GitHub is not a native incident-platform source
  (confirms [S2]'s [GitHub connector](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
  is outbound-only: comments, issues and PRs, not inbound triggers).

**Verified for the current target:** service availability and deployment
permissions in Sweden Central, Arc onboarding with blocked Azure IMDS,
Entra-authenticated private Monitor access from both Arc and the SRE workspace,
operator-driven SRE knowledge configuration, and owned teardown/recreation.
See the [deployment evidence](deployment-stage0.md#deployment-evidence-and-tenant-caveats).

**Still to prove:** repeatable SRE data-plane authentication in CI; Arc application
SDK identity for Service Bus and databases after IMDS blocking; and an enforceable,
approval-gated SRE-to-Arc fixed action. Repeat availability and permission checks
for each new tenant/subscription/region.
Until those pass, label the experience "investigate and propose" rather than
claiming fully automated healing.
