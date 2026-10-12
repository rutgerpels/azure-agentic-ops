# GitHub report to knowledge-led SRE recommendation

Repository implementation: proposal-only, locally exercised with mocked APIs.
**Not live outage acceptance.** The workflow is disabled unless the repository
variable `SRE_INTAKE_ENABLED` is exactly `true`. Do not enable it just because
configuration upload succeeds.

The owner explicitly selected **public sanitized-demo mode** on 2026-10-12:
keep the repository public and require a maintainer to add `sre-investigate`.
The implementation changes no visibility. A reviewed default-branch merge is
needed before GitHub can deliver `issues: labeled` to this workflow.

## Boundaries and flow

Anyone can report a demo symptom in the public repository. That alone does not
start SRE. Only `issues: labeled` with added label exactly `sre-investigate`
is eligible. The bridge checks the **label actor's current** repository
`maintain` or `admin` role through the GitHub collaborator-permission API, matching
the returned actor login/numeric ID. Issue authors, `author_association`, a
label merely being present and default issue-form labels on `opened` do not
authorize intake. The bridge refetches the current issue/label and exact public
repository numeric/name binding, excludes PRs and checks authorization again
immediately before its sole trigger POST. Failure/ambiguity denies admission.

GitHub Actions uses Entra workload federation, not a PAT, client secret or SAS.
The documented native HTTP trigger admits the investigation. Azure Monitor
remains enabled and unchanged. SRE checks the two reusable knowledge references
and reads the exact native VM/systemd fixture evidence. The bridge reads the
result and updates its **one originating-issue journal comment** with a strict
allowlisted generic finding/recommendation. The issue stays open. No GitHub connector or GitHub
write tool is attached to SRE: only the bridge holds `GITHUB_TOKEN`.

The investigator's tool list is exactly `RunAzCliReadCommands`, `SearchMemory`;
skills/system skills and handoffs are disabled. It never attaches the recovery
skill or write tool. Review is additional policy, **not** the enforcement
boundary. The native read tool enforces operational read-only behavior; the
reviewed binding identifies the resources. Configuration readiness checks reject
tool, instruction or routing drift before admission. No guest Run Command,
diagnostic execution, OBO, permission change or repair is introduced.

Knowledge is diagnostic guidance, not current-state evidence:

- [Architecture and evidence](agent-context/github-investigation/architecture.md).
- [Differential diagnosis and proposed recovery](agent-context/github-investigation/diagnosis.md).

Both use version `github-investigation-v1`, independent retrieval probes and
no historical run IDs. This is **not** verified queue/ERP/business recovery.
Healthy observations produce **cannot reproduce**. Missing, stale, future,
foreign or conflicting observations produce **insufficient evidence**.
VM unavailable and running-VM/stopped-service are distinct outcomes.
The unit filename ends in `.service`, but the native receipt and binding service
identity are exactly `retailtx-demo-posting-worker` without that suffix.
Only a fresh supported Manual stopped-service observation passes the
stopped-service recommendation gate; the bridge never executes that action.

## Configuration and ownership

Copy `profiles/github/intake.example.json` into an ignored, operator-owned
artifact directory. Replace every placeholder from independently verified
current configuration. Do not copy runtime incident IDs into it. Keep
`runtimeVerified` and `knowledgeRetrievalVerified` false until their distinct
integration checks succeed. These flags are reviewed attestations, not tests.

Preview the canonical native payloads without authenticating:

```powershell
python -m scripts.github.intake spec --config artifacts\github-intake\config.json
```

Names are `retailtx-github-<environment>-architecture`, `-diagnosis`,
`-investigator`, and HTTP trigger `retailtx-github-<environment>`.
The knowledge PUT shape reuses the native `KnowledgeFile` connector used by
`Invoke-Stage0.ps1`. Both KB paths have scoped LF checkout attributes. The factory
validates UTF-8, normalizes legacy CRLF checkout bytes to LF, and rejects BOM,
standalone CR, NUL and missing final newline. Upload base64, file size and SHA256
all use these same **canonical UTF-8 LF bytes**, not platform-dependent raw
working-tree bytes. Diagnostic text is unchanged.

| Source | Canonical bytes | Canonical SHA256 |
| --- | --- | --- |
| architecture | 3934 | `ba090360f86018be67f1d58a2389e0eb65fd5c056abb7ede4742a14f61630ade` |
| diagnosis | 3736 | `b6058ccd50c4cda4b74a4e661ce9920ae6c8b77a596dc2db891acc20fbc21052` |

Earlier parent-owned uploads used Windows CRLF bytes: architecture 4007 bytes,
SHA256 `8250a31621454c11810feeab0c03d19716bda18459f57c2a90c0fc8490986ff0`;
diagnosis 3786 bytes, SHA256
`3b74699c38b4cc4900ce656ccee04c424883a8844d4697e63a3a5e8ebc834d3a`.
Those are **not LF hashes**. Preserve the old ownership/upload journal and
record an explicit owner-authorized normalization of only these two assets,
including old/new hashes and sizes; do not relabel old receipts as LF evidence.
The generic lifecycle rejects changed stored payloads rather than silently
rewriting/adopting them. Repeat metadata and actual retrieval verification after
the owner reconciles the canonical uploads.

The parent subsequently performed that explicit two-file normalization,
verified canonical displayName hashes and 3934/3736-byte metadata, and retained
the original journal plus separate old/new update history. This is owner-reported
live evidence, not a write performed by the repository implementation session.

Investigator PUT uses the existing `extendedAgent` API.
Trigger creation uses the native flat `name`, `description`, **`agentPrompt`**,
**`agent`** and `agentMode: review` shape. Public template YAML uses aliases
`prompt`/`handlingAgent`; the official Bash adapter maps them to native API
fields, whereas the Windows sample did not. Parent's first flat alias create
silently left prompt/agent null; it was disabled without invocation. Readback
must check actual fields; no default-agent fallback is accepted.
Newly owned triggers are immediately disabled and verified before configuration
readiness. Activation is an explicit later owner decision after all gates.
No alternate transport is attempted.

Only the authorized lifecycle owner runs native configuration:

```powershell
python -m scripts.github.lifecycle configure --config artifacts\github-intake\config.json --state artifacts\github-intake\ownership.json
```

The manifest records exact owner, binding, content and once-only request intent
**before** each write. Unknown submissions reconcile by GET, never by blind
create replay. Unowned collisions and changed content/tools prevent overwrite,
adoption and deletion. Monitor plans, guest/controller sources, recovery skill,
permissions and shared agent settings are not touched.

Knowledge GET returns filename/type/size metadata, not file bytes. It cannot
detect an external same-size content substitution. Retain the upload manifest
and source hashes, prevent other writers from changing these owner-specific
names, and require separate native retrieval evidence. Metadata alone is never
claimed as source-content verification.

## Federation and least privilege: operator lifecycle

The operator-only ARM lifecycle declares a dedicated UAMI
`retailtx-github-intake-<environment>` in the existing agent resource group.
It creates an exact environment FIC, an owner-specific custom role and one
assignment scoped **only** to the configured SRE agent. No Directory application,
client secret, PAT or broad Contributor grant is required.

```powershell
python -m scripts.github.federation spec --config artifacts\github-intake\config.json --location swedencentral --expires-at "<explicit UTC retention expiry>"
python -m scripts.github.federation configure --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json --location swedencentral --expires-at "<explicit UTC retention expiry>"
python -m scripts.github.federation check --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

The private manifest records the exact assets and tenant/client/principal IDs.
Setup rejects existing unowned assets, persists request intent before each PUT,
and reconciles uncertainty by GET without resubmission. Changes to identity,
FIC, permissions or assignment scope block reuse/deletion. ARM readback is not
proof of actual workflow OIDC access. Only the separately authorized owner runs
these operations; the issue workflow does not call this module.
All local token helpers resolve Azure CLI to its absolute executable on PATH,
including Windows `az.cmd`, and use fixed argv with `shell=False` and a finite
timeout. Missing CLI fails explicitly before writes. Operator ARM token
acquisition is bound to the configured subscription; SRE token acquisition keeps
the verified SRE audience and supports the workflow's no-subscriptions login.

| Federation field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:rutgerpels/retailtx-agentic-ops-demo:environment:sre-github-intake` |
| Exchange audience | `api://AzureADTokenExchange` |
| GitHub environment | `sre-github-intake` |

On 2026-10-12, the authorized parent ran the published Windows operator
`configure` and an independent `check` successfully. All four owned ARM assets
(caller UAMI, FIC, minimal custom role and exact-agent assignment) were
`Verified`; overall state remained **`ConfiguredOidcUnverified`**. Retention
expiry was applied only to the new caller identity. Existing retained resource
groups, guest fixtures, proof resources and their expiry tags were unchanged.
This is actual operator setup/readback evidence, not workflow identity proof.

Use environment/default-branch restrictions and protected workflow ownership.
The GitHub environment stores noncredential but operationally private
`SRE_INTAKE_CONFIG`, `SRE_INTAKE_CLIENT_ID` and `SRE_INTAKE_TENANT_ID` in **masked
secret slots**, not runner-printed variables. This adds no authentication or
encryption key. Before Azure login, preflight also masks individual configuration
field values; masking the full JSON alone would not mask its separate fields.
`AZURE_CORE_OUTPUT=none` suppresses Azure CLI account output. Raw workflow-log
inspection remains an enablement gate. Only repository-level
`SRE_INTAKE_ENABLED` controls the job gate. For a different explicitly selected
public demo repository, update the reviewed hardcoded workflow allowlist, numeric
binding and FIC subject together; never infer a new destination from an issue.

The parent also created the owned `sre-github-intake` GitHub environment with a
main-only deployment branch policy, uploaded the three masked configuration
slots, and verified their name metadata. GitHub does not expose the stored
values for readback. Repository `SRE_INTAKE_ENABLED` remains `false`, and the
native HTTP trigger remains disabled. Identity/environment creation is no
longer an outstanding manual prerequisite for this retained setup; executing
OIDC, label admission, token-permission checks and public-log/comment privacy
are still unverified.

The narrow invocation role has ordinary `Actions` containing
`Microsoft.App/agents/read` and **`DataActions`** containing
`Microsoft.App/agents/threads/read`, `Microsoft.App/agents/threads/write`, assigned
only to the exact agent resource. Do **not** grant threads/delete,
threads/approve/action, guest-write, role-assignment or OBO permissions.
Trigger/investigator readback access under this exact caller must also be
verified; do not silently widen the role when it fails. The operator identity,
not the issue caller, owns native asset creation/deletion.

The official HTTP-trigger page contradicts itself about ARM versus SRE token
audience. The parent verified `https://azuresre.dev` resolves to audience
`59f0a04a-b322-4310-adc9-39ac41e9631e`; configuration allows that resource or exact
app ID, checks the token's audience and never falls back to ARM authentication.
This token check is not signature verification; the service validates tokens.
Actual workload-federation invocation/permissions remain an integration gate.

## Readiness and result contract

Native HTTP trigger GET must establish the exact named investigator through
`agent`, its `agentPrompt`, Review, ID and **`triggerEnabled`** state. The
implementation fails explicitly on unknown/missing fields and extra investigator
MCP/common/agent-tool or permission attachments. Actual invocation must return HTTP **202**
with `success`, `executionTime` and `threadId`. Acceptance is not completion.

Thread GET is `/api/v1/threads/{threadId}/messages`, with `state` and `value`.
Only a complete **`author.role == 'SREAgent'`** text after the admitted execution
can be a conclusion; Idle alone and user/issue text cannot be one. The trusted
investigator specification requests one provenance-bound JSON final result.
The bridge requires actual `memorySearchResult` traces containing both document
probes, not just model citations or echoed search queries. The trace must have
actual `documents` objects with each exact indexed title and content containing
its version/probe. The concrete prompt requires exact canonical source strings,
not annotated filenames. Missing/changed trace or result shapes fail explicitly.
This strict output contract still needs native rehearsal.

The initial `[HTTP_TRIGGER_EXECUTION]` marker is also complete SREAgent text;
it is not a diagnosis. The bridge skips only its exact wrapper and bound
trigger/handler/acceptance identity. Pre-tool narration without a report remains
pending. A later unrelated narration or equal-time final ambiguity is rejected,
not treated as successful completion.

Record a separate ignored retrieval evidence file:

```json
{
  "agentId": "<exact configured agent resource>",
  "ownerToken": "<configured owner UUID>",
  "method": "native-memory-search",
  "sourceHashes": {
    "<owned architecture connector>": "<canonical UTF8 LF SHA256>",
    "<owned diagnosis connector>": "<canonical UTF8 LF SHA256>"
  },
  "results": ["<actual native search results with both probes>"]
}
```

Preserve actual raw native search results, not the placeholder strings. Native
search retrieval is independent of upload metadata. The operational owner
verifies the live tool contract, routing, auth, source/version retrieval, Monitor
connectivity and exact workload-identity grants before setting attestations.

```powershell
python -m scripts.github.lifecycle check --config artifacts\github-intake\config.json --state artifacts\github-intake\ownership.json --retrieval-evidence artifacts\github-intake\retrieval.json
```

A valid **private native result** cites knowledge source/version, binding,
observations versus hypotheses, proposed action,
validation/rollback, uncertainty and Monitor correlation. Freshness is at most
**180 seconds**, future tolerance at most **30 seconds** at publication. The
bridge validates actual native CLI command/argument, completion/error/timeout
status and plain JSON outputs, and requires the model's receipt/power state to
match them. Instance-view and query read times come from provider
`azCliExecution.completedTimestamp`, after admission—not model-reported clocks
or the VM's old provisioning time. Model read times may be null. The receipt's
own observation clock is checked independently; the bridge performs no second
Azure query itself.

The public comment is **not that result with free-text redaction**. It is a
strict projection into fixed generic templates: stopped demo service, host
unavailable, cannot reproduce, or insufficient evidence; a fixed nonexecuting
recommendation/validation/limitation; and an allowlisted GitHub workflow-run link.
Raw SRE text, tool outputs, logs, Azure resource paths/names/endpoints, owner,
fixture-run/principal fields, actual configuration and knowledge-owner fields
are never copied. Public failure logging uses a fixed explicit error rather
than backend exception text/tracebacks. No SRE thread endpoint link is published.
Keep detailed evidence in the authenticated SRE conversation. Monitor
correlation is private evidence, not a promise of automatic native merging.

## Admission, reset/reuse and teardown

One bot-owned issue comment records public repository/issue identity, admission
and configuration digests, GitHub run provenance, phase, UTC acceptance time and
the canonical opaque thread GUID. The GUID is a nonsecret resume handle, not an
ARM resource path, credential or permission. It is validated before a GET built
only from trusted configuration; backend thread reads still require Entra and
the scoped `threads/read` DataAction. No endpoint, actual configuration, binding
fields, token or raw response is saved in the public journal. No encryption
secret, custom cryptography or additional infrastructure is introduced.
It is created as `SubmissionUnknown` before the sole trigger POST. A crash,
timeout, rejected request or lost response never permits another POST. Manual
reconciliation is required when no accepted handle was durably saved.

`Accepted` reruns only GET the same thread. Polling is capped at 180 seconds,
each full HTTP exchange (including DNS/request/headers) has a bounded caller
wait, and the job is capped at 12 minutes. A timed-out exchange is uncertain,
not proof that the server did nothing. A completed result
updates the existing comment; duplicate delivery is a no-op. No comment events,
automatic retry schedules, outbound GitHub SRE tools or own-comment loops exist.
Removing/readding the label cannot erase the admission. A maintainer's relabel
may resume only GET of an already accepted thread; it cannot create another.

**Journal retention is a safety prerequisite.** GitHub comments are mutable and
deletable, and other workflows can share the Actions bot identity. Preserve
these comments and serialize this sole admission workflow. Concurrency plus a
comment journal is not server-enforced exactly-once delivery. Before new
admission, a bounded complete workflow-run inventory must bind the current
first attempt and contain no prior qualifying run for that issue. Thus a deleted
or marker-stripped comment with retained run history blocks a new POST. Missing,
changing, truncated or oversized history fails closed; prior failed/skipped
admission runs may also require manual reconciliation. This is an identity-only
additional guard, **not permanent deduplication**: privileged deletion of both
comment and run history, or another privileged bot writer forging state,
defeats the retention/trust assumption.
No server-side idempotency API is assumed. Do not delete journals for reset or
allow a changed config/new workflow run to silently create another investigation.

For reuse, reconcile the existing thread GET-only and rerun configuration
readiness; report a genuinely new incident with a new eligible issue. A fixture
reset or human-approved recovery is a separate authorized lifecycle, never
invoked here. Never unlock a crashed operator lifecycle blindly: independently
check the owner process and reconcile saved intent first.

For teardown, the owner first sets `SRE_INTAKE_ENABLED` false, waits for workflow
and thread settlement, and revokes/removes only exact owned federation and
invocation grants recorded in its operational journal. After settlement, the
owned federation lifecycle validates all assets before inverse-order deletion:
assignment, custom role, FIC, then UAMI, with final absence checks. It preserves
its removal manifest and never removes the existing agent/resource group:

```powershell
python -m scripts.github.federation down --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

Then:

```powershell
python -m scripts.github.lifecycle down --config artifacts\github-intake\config.json --state artifacts\github-intake\ownership.json
```

Every live asset is validated before the first DELETE; only manifest-owned
trigger/investigator/knowledge assets are removed. Successful DELETE alone is
not absence: final GET/inventory residual checks are required. Keep tombstones,
ownership/removal receipts and unrelated Monitor/agent resources. Removing the
reviewed workflow itself is a PR change, not a direct push to main.
Federation/grant provisioning and deletion use the separate parent-owned ARM
lifecycle, not SRE data-plane permissions or the GitHub issue workflow.

## Sources and remaining acceptance

[HTTP triggers in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/http-triggers)
documents webhook paths, assigned subagents, Review and asynchronous 202.
[GitHub connector](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
does not establish a native inbound issue trigger.
[GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)
and [secure use](https://docs.github.com/en/actions/reference/security/secure-use)
ground federation, untrusted-input separation and action SHA pinning.
The implementation uses existing native knowledge and thread-read prior art.
[Official template adapter](https://github.com/microsoft/sre-agent/blob/main/sreagent-templates/bicep/apply-extras.sh)
maps HTTP YAML aliases to actual native API fields.
[GitHub workflow-run API](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-workflow)
grounds the bounded identity-only replay check, not permanent retention.
[GitHub secrets](https://docs.github.com/en/actions/reference/security/secrets)
grounds masked operational configuration storage.
[Managed identity federation reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/2023-01-31/userassignedidentities/federatedidentitycredentials)
and [RBAC definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)
ground the owned caller's ARM resources and ordinary/data-action distinction.

Parent-owned live knowledge metadata readback is verified, including exact
dataSource and displayName/version/hash, but returns no file bytes. Native
search returned fragmented nonempty strings containing both sources/version/
probes; the MCP search parser did not successfully consume them. Do not
reconstruct fragments or equate this with model SearchMemory success.
The separate readiness artifact may preserve actual raw strings with the
format limitation. A subsequent parent-owned read-only healthy smoke verified
both actual model SearchMemory document traces and two scoped CLI reads; its
final conclusion correctly could not reproduce an outage, but annotated
knowledge source strings failed the bridge's strict contract. That trial is not
GitHub admission, OIDC acceptance or outage/repair acceptance.

After canonical normalization and the concrete source-string prompt correction,
a separate parent-owned healthy trial passed the published bridge parser against
actual native messages. It verified exact source/document/probe evidence, scoped
successful CLI reads, receipt/power-state equality and sanitized cannot-reproduce
output. The model reported an old provisioning time; the bridge correctly
derived freshness from native provider completion timestamps instead. The
trigger was disabled again. This verifies the native healthy result contract,
not workflow OIDC, automatic GitHub admission or comment-back.

Parent verified actual trigger `agentPrompt`/`agent`/Review readback and boolean
`triggerEnabled`; the one healthy smoke's trigger was disabled again.
Owned ARM setup and independent readback, plus the configured-disabled GitHub
environment, are verified as described above. Still unverified: actual workflow
OIDC narrow-role read/invocation; model trace
under that caller; collaborator-permission and run-inventory checks under workflow GITHUB_TOKEN;
default-branch automatic labeled-issue delivery and sanitized comment; fresh
outage/healthy/stale alternatives. Reviewed merge is required before enabling.
The sole current human action is review/approval and merge of
[PR #29](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/29).
There is no additional manual identity/environment setup request; operational
execution gates remain separate and do not authorize activation by themselves.
Dependencies [#25](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/25)
and [#26](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/26) retain
their separate existing lifecycle/acceptance meaning; this does not close them.
