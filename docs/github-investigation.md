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
python -m scripts.github.federation configure --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json --repository-evidence artifacts\github-intake\repository.json --location swedencentral --expires-at "<explicit UTC retention expiry>"
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
| Verified immutable subject | `repo:rutgerpels@121695274/retailtx-agentic-ops-demo@1399486000:environment:sre-github-intake` |
| Exchange audience | `api://AzureADTokenExchange` |
| GitHub environment | `sre-github-intake` |

On 2026-10-12, the authorized parent ran the published Windows operator
`configure` and an independent `check` successfully. All four owned ARM assets
(caller UAMI, FIC, minimal custom role and exact-agent assignment) were
`Verified`; overall state remained **`ConfiguredOidcUnverified`**. Retention
expiry was applied only to the new caller identity. Existing retained resource
groups, guest fixtures, proof resources and their expiry tags were unchanged.
This is actual operator setup/readback evidence, not workflow identity proof.
That initial FIC used the classic name-only subject, not the immutable subject
in the table above. Preserve its original ownership manifest.

### Explicit verified subject and scoped transition

The profile now explicitly records the subject and **repository owner's** numeric
ID, independently verified through authenticated `GET /repos/<owner>/<repo>`:

```json
{
  "oidc": {
    "repositoryOwnerId": 121695274,
    "subject": "repo:rutgerpels@121695274/retailtx-agentic-ops-demo@1399486000:environment:sre-github-intake"
  }
}
```

Only the exact classic or immutable repository/environment form is supported.
The owner/name, owner ID, repository/name and repository ID must agree with the
trusted configuration. Wildcards, arbitrary templates, other environments and
issue-actor IDs are rejected. The owner-reviewed `repository.json` is the
authenticated repository GET response (or its exact `full_name`, numeric `id`,
`owner.login`, numeric `owner.id` projection), not issue or actor data.
New setup requires this evidence and an explicit `oidc` configuration. Pure
`spec` validates the configured shape but is not evidence of provider settings
or an authenticated token. Retain independent repository OIDC-settings GET and
actual Azure-login subject evidence before approving the configuration.

Existing manifests without `oidc` retain their original classic subject and
binding hash for exact check/reuse/teardown. Changing the private configuration
does **not** migrate a manifest or adopt a changed live FIC. Preserve the old
configuration and manifest, then add `oidc` to a separate target configuration.
Only the authorized operator may run the explicit classic-to-immutable transition:

```powershell
python -m scripts.github.federation transition-spec --config artifacts\github-intake\target-config.json --state artifacts\github-intake\federation.json --repository-evidence artifacts\github-intake\repository.json
python -m scripts.github.federation transition-subject --config artifacts\github-intake\target-config.json --state artifacts\github-intake\federation.json --repository-evidence artifacts\github-intake\repository.json
python -m scripts.github.federation check --config artifacts\github-intake\target-config.json --state artifacts\github-intake\federation.json
```

The pure interface is `subject_transition_spec(config, state, repository_evidence)`;
it returns `before`, `after` and the verified repository binding without
authentication or writes. The exact PUT path is
`resource_path(plan["after"]["assets"][1])`, with body
`plan["after"]["assets"][1]["body"]`. Review the full plan; do not manually edit
the manifest or submit that PUT outside the durable transition.
The plan requires all four assets already `Verified`, the original owner token
and unchanged non-OIDC binding. It changes only FIC `properties.subject` and the
manifest's configuration hash. UAMI IDs, client/principal/tenant, issuer,
audience, location/tags/expiry, role and assignment remain unchanged.

`transition-subject` GET-validates all four frozen assets, persists the original
manifest, full before-readbacks, owner binding and exact target intent under
`subjectTransition` **before** its one FIC-only PUT. Full four-asset readback
must then match, allowing only the subject and FIC server-maintained `systemData`
to differ. The updated manifest retains before/intent/readback history and stays
`ConfiguredOidcUnverified`, not workflow-authenticated. Unknown writes, lost
responses or failed readback keep `SubjectTransitionRequested`; every retry is
GET-only, never another PUT, even if the classic subject remains. Ordinary
configure/check/down are blocked until transition reconciliation succeeds.
Afterward use the target config for inverse teardown: the new exact subject is
mandatory; the old config or a reverted live subject prevents any deletion.
This is one scoped transition, not a general manifest-migration mechanism.

**Runtime-confirmed facts, separate from product documentation:** parent run
`38266510273` on merged commit `52f95f5d240f68dc15b8d072a651c06f8656a09d`
passed maintainer-label preflight but Azure login failed `AADSTS700213`, before
any SRE POST or issue journal. The official login log reported the exact immutable
subject in the table, matching issuer/audience. Repository GET independently
confirmed `owner.id=121695274` and `id=1399486000`; OIDC-settings GET returned
`use_default: true`, `use_immutable_subject: true` and matching immutable
`sub_claim_prefix`. After that failed run, both intake gates were disabled again.
That run did not verify workflow authentication. Preserve the failed
case and the unchanged first-admission/no-replay guard; a later authorized test
uses a separate operational verification request, not a retry of that admission.

The parent subsequently ran `transition-subject` from a pinned snapshot of
published commit `c2a8745ea70e7014dcc416a6af2af621af998318`, followed by an
independent `check`, and reported both succeeded. All four owned assets were
GET-validated; only the FIC subject changed. UAMI client/principal/tenant and the
identity, role and assignment remained exactly unchanged. The original private
configuration/manifest backups were preserved, and the SDK transition journal
and new configuration hash were verified. The parent updated only the existing
masked `SRE_INTAKE_CONFIG` slot with `oidc`; no other secret, role or GitHub OIDC
setting changed. This is owner-reported live transition evidence, not a live
write performed by the implementation session.

A fresh, separate operational verification request was labeled once. The parent
reported that default-main
[run 38268832278](https://github.com/rutgerpels/retailtx-agentic-ops-demo/actions/runs/38268832278)
passed admission preflight and **Entra workload-federation login**. The next
bridge step failed with generic `SRE_INTAKE_FAILED`, before any bot journal or
new native invocation. Both gates were disabled afterward; the failed admission
was not replayed and no fault or repair was performed. The successful transition
and OIDC login are verified separately from still-unverified narrow-caller
SRE/readiness access, native acceptance and public callback. The parent is tracing
that remaining failure; this earlier generic failure did not establish a
permission cause. The subject-transition change was subsequently reviewed and
merged; its live provenance remains distinct from the role correction below.

### Safe intake failure diagnostics

The CLI entrypoint now adds only fixed allowlisted `stage`, `code` and
`http_status` fields to its existing generic failure/no-replay warning, on stderr
with exit code **1**. For example, **hypothetical, not observed runtime evidence**:

```text
::error::SRE_INTAKE_FAILED: admission or result contract rejected; stage=investigator_get; code=http_rejected; http_status=403; do not replay an uncertain submission.
```

| Operation | Fixed stage values |
| --- | --- |
| Input/configuration | `configuration`, fallback `unknown` |
| GitHub admission and journal | `admission`, `journal` |
| SRE token | `token_acquisition`, `token_audience` |
| Investigator readiness | `investigator_get`, `investigator_contract` |
| Trigger readiness | `trigger_get`, `trigger_contract` |
| Once-only submission and observation | `submission`, `result` |

Codes are only `http_rejected` for the module's exact typed `HttpStatusError`, or
`operation_failed` otherwise. Numeric status is only an exact integer in
**100-599** carried from an API status rejection; absent status is `unknown`,
malformed/unsupported status is fixed `other`. Bool, float and string statuses
are not treated as trusted integers. Transport failures, token/dependency
errors and contract failures remain `unknown`; exception text, attributes or
class names are never parsed for status. Stages are scoped to the failed
operation, reset on successful/later operations and each entrypoint invocation;
a successful configuration read cannot label a later journal/result failure.

Diagnostics contain no raw exception/reason, URL/path, resource/config/actor/
thread ID, token, model text, response body or dependency output. Existing
GitHub mask commands are unchanged. No debug mode, unrestricted artifact or new
credential exists. Requests, accepted-status handling, retry/deadline policy,
journal ordering, once-only POST semantics, native payloads and first-admission
guards are unchanged. Ordinary errors still fail closed.

The diagnostic change was reviewed and merged in
[PR #31](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/31).
The parent then observed fresh default-main
[run 38287250683](https://github.com/rutgerpels/retailtx-agentic-ops-demo/actions/runs/38287250683)
pass maintainer preflight and actual OIDC login, then fail with
`stage=investigator_get; code=http_rejected; http_status=403`.
It stopped before the bot journal and native trigger POST: native invocation
delta **0**, bot journal **0**, known private-field log leaks **0**. This is an
actual denied configuration GET, not a retroactive diagnosis of the earlier
generic failure or proof about later native boundaries.

The parent independently read current Microsoft.App provider operations and
built-in Standard User/Author role definitions. They identify the registered
lowercase `Microsoft.App/agents/extendedagents/read` as a **DataAction** for
configuration read; the frozen caller role omits it. This is an evidenced
permission gap alongside the actual denied GET. Published documentation and
cached examples may differ from the live inventory; the exact spelling here
comes from that parent-owned read evidence, not an inferred wildcard.
The parent also verified canonical KB metadata, restricted native configuration
and fresh healthy service receipts. No role/identity/permission or fault/repair
change was performed in that test.

Preserve failed requests #30, #32 and #33 and their run history; never rerun or
relabel them to bypass the no-replay guard. Both live gates remain off under
parent control. The narrow role fix below is repository implementation for
human review, not evidence of a live upgrade, successful caller readiness,
native invocation/result or public callback.

### Explicit role-only configuration-read upgrade

Fresh `spec`/`configure` emits the fixed manifest-only role profile
`investigator-read-v1`. It adds **only**
`Microsoft.App/agents/extendedagents/read` to the original two DataActions.
The existing `agents/read` Action, exclusions, role name/description/ID,
assignable scope and exact-agent assignment are unchanged. No configuration
write, Administrator, wildcard, approval, delete, scheduled-task, VM, Monitor
or speculative HTTP-trigger permission is added.

An absent `roleProfile` means the exact original legacy role. Existing frozen
manifests, including verified immutable-subject transition history, remain
check/configure/down compatible with that legacy role. Ordinary configure does
not upgrade it; external permission drift is not adopted. Unknown, null or
arbitrary profiles are rejected. Neither the private runtime configuration nor
its hash, OIDC subject, identity IDs, tags/expiry, secret slots or native payloads
changes for a role upgrade.

Only after human review and separate live operator authorization, use the
**same current private configuration and manifest** (the immutable-subject
target configuration if that transition already succeeded):

```powershell
python -m scripts.github.federation role-upgrade-spec --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
python -m scripts.github.federation upgrade-role --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
python -m scripts.github.federation check --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

The pure API is `role_upgrade_spec(config, state)`, returning full `before` and
`after` manifests without authentication, reads or writes. The sole target is
`resource_path(plan["after"]["assets"][2])`, with body
`plan["after"]["assets"][2]["body"]`. Review the exact one-permission diff;
never submit a raw external PUT or manually edit a manifest.
The operator API is `upgrade_role(config, state_path, api)`. It requires all
four original assets `Verified`, canonical recorded identity IDs and intact
prior subject-transition provenance. It GET-validates the UAMI, FIC, role and
assignment plus client/principal/tenant **before** any write, then durably records
the full original manifest, full before-readbacks and exact corrected role
intent under `roleTransition` with top-level `RoleTransitionRequested`.
Only then does it issue **one role-only PUT** using the existing role ID.

Full post-write GET readbacks must verify the corrected role and unchanged
other three assets/identity IDs before the finalized manifest advances to
`ConfiguredOidcUnverified` and `roleProfile: investigator-read-v1`.
Only the new permission and role server-maintained `systemData`,
`properties.updatedBy` and `properties.updatedOn` may differ. Both full
readback sets and original subject-transition history are retained. This is not
a workflow-authentication or native-access attestation.

Every retry once Requested intent is durable is GET-only, including lost
responses, failed/missing readbacks and observations of the **old** role.
Unknown remains fail-closed: ordinary configure/check/down cannot proceed until
`upgrade-role` reconciliation succeeds. Malformed/partial journals, identity
replacement, foreign profiles/assets or other drift prevent advancement and
deletion. A repeated successful upgrade only GET-validates and returns; it
does not rewrite the manifest or role. A completed role-upgrade journal cannot
be rewritten by replaying the earlier subject transition.

For a later separately authorized teardown, the same `down` interface removes
only the corrected exact assignment, role, FIC and UAMI in inverse order:

```powershell
python -m scripts.github.federation down --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

The upgraded manifest reconstructs the corrected role for check/down; a live
reversion to legacy permissions blocks deletion. It preserves the transition
and removal history and verifies final absence. Local mocked coverage establishes
legacy/fresh lifecycle, one-permission planning, before-write durability,
uncertain GET-only reconciliation, unchanged identity/hash/subject history,
drift rejection and exact inverse teardown. **Live transition, actual caller
readiness, native result and public callback remain unverified.** A fresh,
separately authorized proposal-only test may expose another boundary; do not
pre-grant speculative permissions or replay any failed admission.

[User roles and permissions in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/user-roles)
distinguishes configuration access, user roles and backend 403 enforcement.
[Role Definitions - Create Or Update (2022-04-01)](https://learn.microsoft.com/en-us/rest/api/authorization/role-definitions/create-or-update?view=rest-authorization-2022-04-01)
documents the role-only PUT, DataActions and server-maintained update fields.

[GitHub OpenID Connect reference: immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims)
documents ID-bearing subjects for repositories created after July 15, 2026 and
subsequent renames/transfers. The
[Managed Identity FIC create-or-update REST reference (2023-01-31)](https://learn.microsoft.com/en-us/rest/api/managedidentity/federated-identity-credentials/create-or-update?view=rest-managedidentity-2023-01-31)
documents updating the existing exact credential via PUT with
`issuer`, `subject` and `audiences`. No GitHub OIDC settings, permissions,
native bodies, secrets or workflow admission semantics change in this fix.

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
values for readback. At that initial setup, repository `SRE_INTAKE_ENABLED` was
`false` and the native HTTP trigger was disabled. Subsequent temporary gate
activation and fresh-test observation are parent-owned. Identity/environment
creation is no longer an outstanding manual prerequisite for this retained
setup. Workflow OIDC login and maintainer-label preflight were subsequently
verified in the fresh run above; narrow-caller native readiness/permissions and
public callback acceptance remain open.

The narrow invocation role has ordinary `Actions` containing
`Microsoft.App/agents/read` and **`DataActions`** containing
`Microsoft.App/agents/threads/read`, `Microsoft.App/agents/threads/write` and,
for the corrected fixed profile only, `Microsoft.App/agents/extendedagents/read`,
assigned only to the exact agent resource. Frozen legacy manifests retain only
the two thread DataActions until the explicit reviewed upgrade. Do **not** grant threads/delete,
threads/approve/action, guest-write, role-assignment or OBO permissions.
Trigger/investigator readback access under this exact caller must also be
verified; do not silently widen the role when it fails. The operator identity,
not the issue caller, owns native asset creation/deletion.

The official HTTP-trigger page contradicts itself about ARM versus SRE token
audience. The parent verified `https://azuresre.dev` resolves to audience
`59f0a04a-b322-4310-adc9-39ac41e9631e`; configuration allows that resource or exact
app ID, checks the token's audience and never falls back to ARM authentication.
This token check is not signature verification; the service validates tokens.
Workload-federation login is verified in the fresh run above; actual native
invocation/readiness permissions under that exact caller remain an integration gate.

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
Owned ARM setup, immutable-subject transition and independent readback, plus the
configured-disabled GitHub environment, are verified as described above.
[PR #29](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/29) and
[PR #31](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/31) are merged.
Actual default-main labeled-issue delivery, maintainer preflight and OIDC login
passed in the fresh run above; the investigator configuration GET was denied
with HTTP 403 before a journal or native POST. Still unverified: live role-only
upgrade, actual corrected-caller readiness/invocation, model trace under that
caller and sanitized public callback; fresh outage/healthy/stale alternatives.
Human review and merge of the narrow role correction precede any separately
authorized live transition/test. There is no additional manual
identity/environment setup request. Both activation gates remain off;
repository review does not itself authorize live writes or activation.
Dependencies [#25](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/25)
and [#26](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/26) retain
their separate existing lifecycle/acceptance meaning; this does not close them.
