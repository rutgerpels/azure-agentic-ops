# GitHub report to knowledge-led SRE recommendation

Repository implementation: proposal-only, locally exercised with mocked APIs.
**Not live outage acceptance.** The workflow is disabled unless the repository
variable `SRE_INTAKE_ENABLED` is exactly `true`. Do not enable it just because
configuration upload succeeds.

The current repository was observed **public** on 2026-10-12. The conservative
default private-repository policy therefore blocks admission here. Repository
policy remains an owner decision, not an inherent SRE product requirement.
An owner could explicitly select a private repository/visibility, or authorize
a separately reviewed public-demo admission and disclosure policy; public mode
is not implemented here. The implementation changes neither visibility nor
policy. A reviewed default-branch merge is also needed
before GitHub can deliver `issues: opened` to this new workflow.

## Boundaries and flow

An operator-authored issue, labeled `sre-investigate`, starts the workflow on
`opened` or when that label is added. The author must have `OWNER`, `MEMBER` or
`COLLABORATOR` association. These are eligibility filters, not authorization to
change Azure resources. The bridge refetches the issue and repository, verifies
private visibility and exact numeric/name binding, and excludes pull requests.

GitHub Actions uses Entra workload federation, not a PAT, client secret or SAS.
The documented native HTTP trigger admits the investigation. Azure Monitor
remains enabled and unchanged. SRE checks the two reusable knowledge references
and reads the exact native VM/systemd fixture evidence. The bridge reads the
result and updates its **one originating-issue journal comment** with a bounded,
escaped recommendation. The issue stays open. No GitHub connector or GitHub
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
`Invoke-Stage0.ps1`. Investigator PUT uses the existing `extendedAgent` API.
Trigger creation uses the documented flat `name`, `description`, `prompt`,
`handlingAgent` and `agentMode: review` shape. No alternate transport is attempted.

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

## Federation and least privilege: explicit owner prerequisites

Create or reuse an explicitly owned Entra workload identity and record its
tenant/client/object IDs, federated credential ID and exact role-assignment
IDs/scopes in the owner's operational journal. Do not adopt an unknown identity
or grant broad Contributor merely to make a call succeed.

| Federation field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:rutgerpels/retailtx-agentic-ops-demo:environment:sre-github-intake` |
| Exchange audience | `api://AzureADTokenExchange` |
| GitHub environment | `sre-github-intake` |

Use environment/default-branch restrictions and protected workflow ownership.
The GitHub environment contains nonsecret `SRE_INTAKE_CONFIG`,
`SRE_INTAKE_CLIENT_ID` and `SRE_INTAKE_TENANT_ID` variables. Only repository-level
`SRE_INTAKE_ENABLED` controls the job gate. For a different explicitly selected
private repository, update the reviewed hardcoded workflow allowlist, numeric
binding and FIC subject together; never infer a new destination from an issue.

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

Native HTTP trigger GET must establish the exact named investigator, Review,
prompt, ID and enabled state. The implementation fails explicitly on an
unrecognized enabled-field contract. Actual invocation must return HTTP **202**
with `success`, `executionTime` and `threadId`. Acceptance is not completion.

Thread GET is `/api/v1/threads/{threadId}/messages`, with `state` and `value`.
Only a complete **`author.role == 'SREAgent'`** text after the admitted execution
can be a conclusion; Idle alone and user/issue text cannot be one. The trusted
investigator specification requests one provenance-bound JSON final result.
The bridge requires actual `memorySearchResult` traces containing both document
probes, not just model citations. Missing/changed trace or result shapes fail
explicitly. This strict output contract still needs native rehearsal.

Record a separate ignored retrieval evidence file:

```json
{
  "agentId": "<exact configured agent resource>",
  "ownerToken": "<configured owner UUID>",
  "method": "native-memory-search",
  "sourceHashes": {
    "<owned architecture connector>": "<raw UTF8 SHA256>",
    "<owned diagnosis connector>": "<raw UTF8 SHA256>"
  },
  "results": ["<actual native search results with both probes>"]
}
```

Preserve actual structured search results, not the placeholder strings. Native
search retrieval is independent of upload metadata. The operational owner
verifies the live tool contract, routing, auth, source/version retrieval, Monitor
connectivity and exact workload-identity grants before setting attestations.

```powershell
python -m scripts.github.lifecycle check --config artifacts\github-intake\config.json --state artifacts\github-intake\ownership.json --retrieval-evidence artifacts\github-intake\retrieval.json
```

A valid result cites knowledge source/version, resource binding, current query,
instance-view and observation times, observations versus hypotheses, proposed
action, expected validation/rollback, uncertainty and Monitor correlation.
Freshness is at most **180 seconds**, future tolerance at most **30 seconds** at
publication. The bridge validates these reported fields but does not independently
remeasure Azure telemetry; the comment says so. Link matching Monitor threads
when exact correlation exists; do not promise native automatic thread merging
or suppress Monitor to avoid a duplicate HTTP conversation.

## Admission, reset/reuse and teardown

One bot-owned issue comment durably records repository/issue IDs, configuration
and binding hashes, admission key, workflow run, phase and returned thread ID.
It is created as `SubmissionUnknown` before the sole trigger POST. A crash,
timeout, rejected request or lost response never permits another POST. Manual
reconciliation is required when no accepted handle was durably saved.

`Accepted` reruns only GET the same thread. Polling is capped at 180 seconds,
HTTP requests at a finite timeout, and the job at 12 minutes. A completed result
updates the existing comment; duplicate delivery is a no-op. No comment events,
automatic retry schedules, outbound GitHub SRE tools or own-comment loops exist.

**Journal retention is a safety prerequisite.** GitHub comments are mutable and
deletable, and other workflows can share the Actions bot identity. Preserve
these comments and serialize this sole admission workflow. Concurrency plus a
comment journal is not server-enforced exactly-once delivery. Deleting the
tombstone or a privileged other writer forging it defeats that guarantee.
No server-side idempotency API is assumed. Do not delete journals for reset or
allow a changed config/new workflow run to silently create another investigation.

For reuse, reconcile the existing thread GET-only and rerun configuration
readiness; report a genuinely new incident with a new eligible issue. A fixture
reset or human-approved recovery is a separate authorized lifecycle, never
invoked here. Never unlock a crashed operator lifecycle blindly: independently
check the owner process and reconcile saved intent first.

For teardown, the owner first sets `SRE_INTAKE_ENABLED` false, waits for workflow
and thread settlement, and revokes/removes only exact owned federation and
invocation grants recorded in its operational journal. Then:

```powershell
python -m scripts.github.lifecycle down --config artifacts\github-intake\config.json --state artifacts\github-intake\ownership.json
```

Every live asset is validated before the first DELETE; only manifest-owned
trigger/investigator/knowledge assets are removed. Successful DELETE alone is
not absence: final GET/inventory residual checks are required. Keep tombstones,
ownership/removal receipts and unrelated Monitor/agent resources. Removing the
reviewed workflow itself is a PR change, not a direct push to main.
Federation/grant provisioning and deletion are explicit parent-owned manual
prerequisites, not automated by this SRE data-plane lifecycle.

## Sources and remaining acceptance

[HTTP triggers in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/http-triggers)
documents webhook paths, assigned subagents, Review and asynchronous 202.
[GitHub connector](https://learn.microsoft.com/en-us/azure/sre-agent/github-connector)
does not establish a native inbound issue trigger.
[GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)
and [secure use](https://docs.github.com/en/actions/reference/security/secure-use)
ground federation, untrusted-input separation and action SHA pinning.
The implementation uses existing native knowledge and thread-read prior art.

Still unverified: exact live trigger creation/enabled readback; proposal-only
selection and structured conclusion; current SearchMemory result trace shape;
real KB retrieval; OIDC narrow-role read/invocation; default-branch automatic
issue delivery and recommendation; fresh outage/healthy/stale alternatives.
Repository-policy resolution and reviewed merge are required before enabling.
Dependencies [#25](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/25)
and [#26](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/26) retain
their separate existing lifecycle/acceptance meaning; this does not close them.
