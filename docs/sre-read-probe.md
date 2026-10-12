# Isolated SRE configuration-read permission probe

**Preparation only, for human review.** No setup, grant, authentication trial,
dispatch, native invocation, fault or repair is authorized by this change.
The manual workflow is inert unless the separately authorized operator sets
`SRE_READ_PROBE_ENABLED=true` in repository variables **and** provisions an
enabled, unexpired private configuration. No gate is enabled by repository code.

The [actual healthy intake run](https://github.com/rutgerpels/retailtx-agentic-ops-demo/actions/runs/38295364433)
passed maintainer admission, Entra OIDC and the exact investigator configuration
GET, then stopped at `trigger_get;http_status=403`. No native invocation or bot
journal followed. The existing native trigger and `SRE_INTAKE_ENABLED` remain
off. Requests 30, 32, 33 and 35 must not be rerun or relabeled.

The registered `Microsoft.App/agents/scheduledtasks/read` DataAction means
"Read scheduled tasks in an SRE agent". Its relationship to **HTTP trigger
configuration GET is unconfirmed**. Neither the registered description nor the
current primary documentation establishes that mapping. This probe tests one
candidate, not a broad role or an accepted permission fix.

## Fixed comparison

| Caller | Actions | DataActions |
| --- | --- | --- |
| BASELINE | `Microsoft.App/agents/read` | `Microsoft.App/agents/extendedagents/read` |
| CANDIDATE | Same | Same, plus only `Microsoft.App/agents/scheduledtasks/read` |

Each caller has a new separately owned UAMI, environment FIC, immutable custom
role and unconditional assignment at the **exact configured agent resource**.
Role definition availability is confined to the agent resource group because
Azure custom roles require a subscription, management group or resource-group
assignable scope; availability is not an assignment/grant. No thread,
configuration-write, VM, Monitor, Directory, wildcard, OBO, PAT, client-secret
or SAS permission is added. Old intake assets, subjects, profiles and transition
journals are not adopted or mutated.

The runtime exposes only two named native reads:

- `GET /api/v2/extendedAgent/agents/<canonical-investigator-name>`
- `GET /api/v1/httptriggers/<configured-trigger-id>`

It repeats both reads per caller to detect unstable status/content. There is no
arbitrary method, host, URL, route, query, issue input or code-ref input, and no
thread/chat, telemetry command, invocation, execute, enable or approval call.
Both investigator responses must match current `investigator_spec` and
`assert_no_extra_tools`. A successful trigger response must match every current
`trigger_spec` field, the exact ID and **`triggerEnabled=false`**. A 403 remains
observed denial: the inaccessible trigger body is not claimed as validated.
The candidate's successful body check is mandatory, not skipped as intake was
previously blocked.

| Observations after identities, role snapshot and contracts pass | Result |
| --- | --- |
| BASELINE 403; CANDIDATE 200, stable across rechecks | `permission_effect_observed`, exit 0 |
| Both 200 or both 403 | `equal_results_inconclusive`, exit 2 |
| Other/reversing HTTP status, including 401, 404 or 429 | Inconclusive, exit 2 |
| Acquisition/transport/expiry uncertainty or identity/content drift | Fixed failure marker, exit 2 |

Exit 0 is **only a point-in-time permission-effect observation**. It is not
readiness, a general provider-operation mapping, an accepted fix, or successful
end-to-end intake. It never upgrades the existing caller or activates intake.
Propagation delays can make a negative/equal comparison inconclusive.

## Interfaces and future operator sequence

`scripts.github.read_probe.specifications(config)` and the local `spec` command
are pure. `read_probe_lifecycle.configure`, `check` and `remove` are operator-only
ARM/GitHub interfaces; the workflow never imports/calls their lifecycle.
The example is a non-secret shape, not deployable evidence.

```powershell
python -m scripts.github.read_probe spec --config profiles\github\read-probe.example.json
```

**Stop here under the present authorization.** After reviewed merge and separate
explicit authorization for setup and a manual probe, an operator with already
established Azure CLI and GitHub CLI sessions may perform the following:

1. Make a private ignored copy in `artifacts\read-probe\config.json`. Use a new
   owner UUID distinct from fixture/intake owners, independently confirmed tenant,
   endpoint, route ID and native binding; do not edit the old configuration.
   Select an explicit short retention expiry and `enabled=true` before first
   setup. Verify the repository's effective OIDC subject (classic or immutable)
   for **`sre-read-probe`**, not the intake environment. Pure shape validation
   is not provider-subject verification.
2. Ensure exclusive operator admission: no other process/administrator may
   create or alter these neutral names, callers, role grants or the environment
   during setup/check/probe/down. Keep the repository gate unset/off. Execute
   `configure`, then independent `check` below. All calls are finite and use
   existing authentication; no fallback or interactive login is implemented.
3. Only after successful checks, set repository variable
   `SRE_READ_PROBE_ENABLED=true` manually and dispatch **once from main** within
   the 15-minute role-attestation window. The dispatch has no inputs. Immediately
   turn that repository gate off/unset again. There is no automatic dispatch,
   rerun, grant change or retry. A stale snapshot requires disposal and a
   separately authorized new probe owner, not secret refresh/adoption.
4. Preserve only sanitized fixed result markers, not private responses/tokens.
   With the repository gate off, execute `down`; retain its ownership journal.
   Confirm the gate is unset/off independently. The operator-managed gate is
   deliberately not created or modified by this lifecycle.

```powershell
python -m scripts.github.read_probe_lifecycle configure --config artifacts\read-probe\config.json --state artifacts\read-probe\ownership.json
python -m scripts.github.read_probe_lifecycle check --config artifacts\read-probe\config.json --state artifacts\read-probe\ownership.json
# Separately authorized manual main dispatch, then gate OFF; no dispatch in this task.
python -m scripts.github.read_probe_lifecycle down --config artifacts\read-probe\config.json --state artifacts\read-probe\ownership.json
```

The new environment has only a custom **main branch** policy (not a tag), no
extra protection architecture and four fixed secret slots:
`SRE_READ_PROBE_BASELINE_CLIENT_ID`, `SRE_READ_PROBE_CANDIDATE_CLIENT_ID`,
`SRE_READ_PROBE_TENANT_ID`, `SRE_READ_PROBE_CONFIG`.
The final secret carries one private trusted native/identity/spec snapshot plus
the independent ARM-check timestamp. Repository and environment access remain
normal administrator responsibilities. The workflow needs only `contents:read`
and `id-token:write`; there is no issue/comment/actions write permission.

## Ownership, uncertainty and inverse guards

Setup rejects collisions **before first write**, journals durable intent before
every ARM/environment/policy/slot write, and checks exact readback and immutable
client/principal/tenant/environment/policy identity. The local exclusive lock
does not coordinate other machines. GitHub create-or-update APIs lack an
ownership-conditioned create: a check/write race is possible without the
explicit exclusive-writer requirement above. UUIDs and names are not, by
themselves, proof of ownership.

`check` refetches exact roles/assignments/FICs and the subscription's complete
direct-assignment inventory for each new principal. Extra grants/FICs, extra
policies/secrets/variables, changed metadata, conditional/delegated assignments
and incomplete/paged results fail closed. No Directory lookup/grant is added.
The operator must ensure these new principals have no external group,
management-group or other-subscription grants; subscription inventory cannot
prove absence outside its visibility. A snapshot is bounded point-in-time
evidence, not cryptographic proof that no administrator later changed RBAC.
No candidate success is evidence of a controlled difference if this external
ownership/admission condition was violated.

Unknown create/delete outcomes reconcile by exact GET/inventory only, never
blind replay. Secret values are unreadable: an acknowledged `gh secret set`
plus bound metadata is recorded, **not remote value readback**. Loss between
write and durable acknowledgment remains blocking even if metadata appears.
`down` checks all inverse guards before deleting the owned environment (and its
policy/slots), then reverses exact ARM assets; unknown creates, changed identity,
foreign additions and remaining objects prevent an absence claim. It records
residual kinds privately; failures emit only a fixed public uncertainty marker.
There is no recursive resource-group/root-directory deletion. Retention is
tag-only; explicit teardown is required.

## Authentication and public-log boundary

One Python process validates/masks one trusted configuration snapshot before
requesting a GitHub OIDC assertion. The assertion must name the exact repository,
numeric owner/repository IDs, main branch, manual workflow, run attempt and
commit; Entra verifies its signature. Each caller gets a different freshly
created `AZURE_CONFIG_DIR` under a narrowly owned temporary directory. The
runtime never uses a shared/cache fallback identity. Temporary caches are
removed on success and failure; only this process's exact directory is removed.

Fixed `az login --service-principal --federated-token` and token acquisition
argv use `shell=False`, a 30-second wait and capped stdout/stderr capture. No
login action forwards provider errors. Secret input uses an anonymous private
file, not a potentially blocked pipe feeder; output pipes are unbuffered so
cleanup cannot wait on a feeder/reader-held buffered-stream lock.
Tenant, audience, application and caller
principal claims are checked internally; JWT decoding is **not signature
verification**. The SRE service validates the access token. Token exchange is
authentication, not a native application write.

All individual private fields and tokens are registered as masks. Public
reports contain only whitelisted caller/stage/result codes and bounded numeric
HTTP statuses: no traceback, exception type/reason, URLs, IDs, configuration
hashes, bodies, model output or diagnostic artifacts. There is no artifact
upload. Workflow reruns, non-main dispatch and missing/disabled configuration
deny admission before Azure login.

## Remaining live gates

GitHub automation is only a messenger for a custom issue source, not built-in
ServiceNow/PagerDuty/AzureMonitor incident scanning. The actual incident
platform stays AzMonitor. The real goal remains issue, investigation, proposed
fix, real human approval, SRE execution and independently verified recovery.
This diagnostic is only a prerequisite. The current service is a tiny native
health-check fixture, not transaction-worker or retail/business recovery.
Candidate mapping, fresh setup/OIDC isolation/teardown, accepted intake and the
full repair loop all remain unverified and require later authorization.

## Primary references

- [HTTP triggers in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/http-triggers):
  documents trigger-detail GET; does not map its read authorization. The page's
  invocation/troubleshooting audience guidance differs; this diagnostic keeps
  the verified SRE audience and never invokes or falls back to an ARM token.
- [SRE API reference](https://sre.azure.com/docs/reference/api-reference) and
  [SRE user roles](https://learn.microsoft.com/en-us/azure/sre-agent/user-roles):
  not evidence mapping `scheduledtasks/read` to this GET.
- [Azure CLI concurrent configuration](https://learn.microsoft.com/en-us/cli/azure/use-azure-cli-successfully-tips),
  [login reference](https://learn.microsoft.com/en-us/cli/azure/reference-index#az-login)
  and [account tokens](https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token):
  isolated `AZURE_CONFIG_DIR`, federation and explicit resource/tenant selection.
- [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc):
  token claims and classic/immutable environment subjects.
- [GitHub environment API](https://docs.github.com/en/rest/deployments/environments),
  [branch-policy API](https://docs.github.com/en/rest/deployments/branch-policies)
  and [secret API](https://docs.github.com/en/rest/actions/secrets):
  environment lifecycle, branch-vs-tag policy and metadata-only secret reads.
