# Checkout delivery and lifecycle plan

## Scope

Retailx focuses on two independent incidents in one hybrid checkout estate:
Belgium-only successful-but-slow checkout, and an Arc-managed shared price-service
outage that interrupts checkout in both Belgium and the Netherlands.

The [README](../README.md) is the deployment entry point.
The [scenario guide](checkout-latency-scenario.md) records architecture, exact
operator steps and verified evidence. The
[presenter runsheet](presenter/checkout-latency-runsheet.md) separates preparation,
fault injection, approval, customer recovery and natural alert clearance.

| Capability | Disposition |
|---|---|
| App Service till, private price backend/POS simulator, Arc and SRE | Core checkout deployment |
| Latency and service faults, guarded repair and explicit undo | Core, one incident at a time |
| Monitor workbook, alerts-only latency mode and readiness brief | Retained checkout experiences; their live evidence is documented separately |
| Sanitized SRE RCA to Copilot PR and gated demo deployment/reset | Retained optional [code loop](checkout-code-loop.md), tracked in [#44](https://github.com/rutgerpels/azure-agentic-ops/issues/44) |
| Foundry business-facing incident assistant | Basic question answering retained; further enrichment paused in [#45](https://github.com/rutgerpels/azure-agentic-ops/issues/45). Corrective closeout does not establish live SRE-progress acceptance. Optional, read-only, separately owned; see [incident-management agent](incident-management-agent.md) |
| Private Foundry backend connectivity | Deferred user-directed follow-up: owned VNet integration, private endpoint/DNS, both-channel acceptance, rollback and teardown. Keep Teams ingress reachable; not deployed or verified. See [network plan](incident-management-agent.md#deferred-private-foundry-connectivity) |
| Personal Teams pilot | Optional channel for the same Foundry runner; basic conversations retained and earlier walkthroughs user-reported. Existing live/SRE binding is unchanged; live SRE-progress reporting and expanded conversation acceptance remain unverified and deferred. See [architecture and lifecycle](teams-pilot.md) |
| Foundation/native VM/guest proofs, Windows disk/IIS, posting/backlog, GitHub-to-SRE intake | Retired from the active source tree |

The Foundry assistant has its own lifecycle (`Invoke-IncidentAgent.ps1`). It
attaches to a checkout deployment for read-only Log Analytics evidence and,
on explicit opt-in, scoped GET-only SRE observations. The latter remain
unverified and deferred, not a supported live presenter capability. It never
injects, repairs or approves. Checkout does not depend on it. Detach it
before checkout `Down`. Its fixture evaluations are not live integration
acceptance.

The 29 October 2026 closeout retains the already deployed corrections without
further diagnostics, deployment, permission changes, rollback or teardown.
No support ticket or user diagnostic action is required. Broader #45 acceptance
and diagnostic #79 remain deferred; merging the corrective PR does not mark them
Done. Any resumption requires a new explicit decision.

## Lifecycle contract

Deploy with `Invoke-CheckoutDemo.ps1 Up -WithArc`, then `ProbeArc`, `PrepareArc`
and `Ready`. Deployment and preparation must leave both price routes on primary
and the service healthy. Only an explicit presenter `Inject` starts an incident.
Omit Arc for latency-only deployment; use `-AlertsOnly` only on a fresh
latency-only environment without autonomous agents.

Ownership, bounded submission/observation, exact identities, source checks and
unknown-operation/no-replay behavior are required, including on deployment failure.
Fault lifetime is manual across reboot. Repair requires a native human approval
card and independent fresh evidence. Monitor clearance is a separate observation.
`Undo` is an operator reset, not approval-gated SRE healing.

`Down` reconciles owned resources, scheduled automation, external assignments,
settings and deployment records. Keep ignored `.azure/<environment>/` state until
cleanup succeeds. Do not delete unrelated resources or relax guardrails to make
acceptance pass. Expiry tags are not an automatic cleanup mechanism.

## Repository cleanup acceptance

The owner approved retiring non-checkout scenarios while retaining the code loop
and parked Foundry work. Merged/closed PRs, issues and immutable baseline tags
remain historical evidence; incomplete retired work is not marked accepted.
Retired lifecycle source remains recoverable from pre-cleanup commit
`39b3d497b03275151e1930e2a40528f4238b8fa6`.
Do not use historical receipts to adopt or delete live resources.

The authorized live check is a fresh Arc-enabled deployment/preparation/teardown
using the README commands, **without injecting a fault or exercising a full
incident**. Require successful deployment, healthy application/preparation,
and verified owned teardown. This checks the deployment dependency closure;
it does not establish a new human-approved recovery rehearsal.

Offline checks run from the repository root:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --require-hashes -r requirements-dev.lock
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m mypy
Get-ChildItem .\scenarios\retailx\tests\Test-Checkout*.ps1 | ForEach-Object { & $_.FullName }
Get-ChildItem .\tests\Test-*.ps1 | ForEach-Object { & $_.FullName }
bicep build .\scenarios\retailx\infra\checkout\main.bicep --stdout > $null
bicep build .\scenarios\retailx\infra\checkout\arc.bicep --stdout > $null
bicep build .\scenarios\retailx\infra\checkout\latency-alert.bicep --stdout > $null
```

The root Python configuration discovers shared layout contracts and Retailx
checkout tests. The optional incident assistant retains its independent
Azure-hosted evaluation lifecycle; a source move does not establish new live
integration evidence. The
[repository organization guide](../../../docs/scenarios.md) describes shared
boundaries, ownership-state compatibility and adding another named demo.

Use an isolated virtual environment. The development lock covers checkout
contracts using the frontend's FastAPI and telemetry pins, without the retired
PostgreSQL/Service Bus application or its build package. Azure deployment
installs `scenarios/retailx/app/checkout/frontend/requirements.txt` independently, including its
Linux process server. Python tests require neither Azure nor a local Compose
stack.

To regenerate the hash-pinned lock, compile the project's runtime requirements
and `dev` dependency group together. Do not emit a developer-machine package
index into the reusable lock. For example, with `pip-tools` installed:

```powershell
$requirements = python -c "import pathlib,tomllib; p=tomllib.loads(pathlib.Path('pyproject.toml').read_text()); print('\n'.join(p['project']['dependencies']+p['dependency-groups']['dev']))"
$requirements | pip-compile --generate-hashes --strip-extras --no-emit-index-url --output-file requirements-dev.lock -
```

## Cleanup verification - 2026-10-21

A fresh Arc-enabled environment completed the README lifecycle without injecting
either fault. No checkout runtime, infrastructure or lifecycle behavior was
changed to obtain these results.

| Check | Observed result |
|---|---|
| `Up -WithArc` | Infrastructure, frontend publication, monitoring, Review-mode response plans and scheduled readiness brief deployed successfully. |
| `ProbeArc`, `PrepareArc` | Guest-command delivery and guarded service-controller preparation succeeded. |
| `Ready` | Returned `True` with no blockers, both routes on `primary`, and fresh active/healthy service evidence. Belgium p95 was 101 ms and Netherlands p95 was 99 ms, with 99 observations each. |
| HTTP smoke check | Till and `/health` returned HTTP 200; no fault was active. |
| `Down` | Completed successfully in about nine minutes and removed the ownership state after verification. |
| Independent residual check | Resource group absent; zero active resources with the saved owner token. Both tracked custom roles, the Arc assignment, both subscription reader/monitoring assignments, the owned Monitor default setting and all four subscription deployment records returned HTTP 404. |

Initial readiness was blocked while service telemetry arrived and a startup
latency alert remained fired. Bounded read-only retries reached `Ready=True`
after natural alert clearance; thresholds and admission checks were not relaxed,
and no manual alert acknowledgement or remediation was used.

The two pre-existing reusable RetailTx identity groups remained in place;
unrelated subscription resources were not modified. These checks establish
active-resource teardown, not purging of provider soft-delete or retention data.
Private receipts remain outside Git. This was not an incident/recovery rehearsal.

Offline validation passed: 22 Python tests, 617 checks across six PowerShell
suites, all three checkout Bicep entry points, Ruff, mypy and retained Markdown
file links. The regenerated dependency lock installed with hash verification.

## Remaining delivery gates

### SRE telemetry tool routing - 2026-10-27

An isolated live read-tool probe explicitly selected `RunAzCliReadCommands` for
the existing `az monitor log-analytics query` command. Its execution receipt
identified that tool and completed without approval, returning valid per-country
successful-checkout latency and failure measurements. This establishes that the
approved read path works with the existing identity; no connector or additional
Log Analytics RBAC was needed. A `RunInTerminal` permission-rule denial instead
reflects incorrect tool selection, not evidence of missing Log Analytics access.

The initial repository fix named `RunAzCliReadCommands` explicitly. Its blanket
stop-on-read-error instruction was superseded by the bounded correction design
below; it must not be applied unchanged. The exact workspace-bound log command,
terminal restrictions, native write approvals and repair boundaries are retained.

The isolated probe is **not end-to-end incident repair evidence**. Applying this
guidance to deployed agents and verifying a fresh presenter-triggered incident,
native approval, repair and same-run recovery remain separate live work. No Azure
configuration, SRE messages, fault injection or repair was performed for this
repository-only fix. Live IDs and raw receipts remain outside tracked files.

### Scoped investigation revision - 2026-10-28

The user authorized broader read-only investigation and bounded correction of
KQL syntax/schema errors, not unrestricted terminal execution. After reading
[Tools in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/tools),
[Skills and tool attachment](https://learn.microsoft.com/azure/sre-agent/skills)
and [Azure observability](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability),
read-only discovery of the deployed tool picker
(`GET /api/v1/extendedAgent/systemtools?stableOnly=true`) confirmed the following
selectable system tools and parameter names. No tools were executed or enabled.

| Additional built-in tool | Observed parameters | Intended use |
|---|---|---|
| `GetAzCliHelp` | `helpTopic`, `grepPattern` | Relevant read-command syntax, no execution authority |
| `GetArmResourceAsJson` | `resourceId` | Exact checkout web app metadata |
| `ListAvailableMetrics` | `resourceId` | Exact web app metric definitions |
| `GetMetricTimeSeriesElementsForAzureResource` | `resourceId`, `metricNamespace`, `metricName`, `startTime`, `endTime`, `dimensionFilter` | Discovered web app metrics, explicit window at most one hour; Average is not checkout p95 or recovery proof |

These are actual additions to the generated custom-agent tool lists and their
existing drift checks, not just new prose. Investigator/service retain their
one existing native-approval write tool; readiness has only the five read tools.
No global permission allow/deny/ask settings, Azure roles or connectors change.
The primary agent's tool settings may differ from the custom-agent picker;
selectability is not evidence that these tools have executed successfully.
Context7 lookup was attempted but its monthly quota was exhausted; the official
Microsoft references and observed platform definitions above are the sources.
The Azure MCP discovery identity returned 403; the existing authorized Azure CLI
identity completed catalog GETs without any access changes.

All logs still use `RunAzCliReadCommands` and the existing GUID-bound CLI command.
Schema discovery uses the documented
[`getschema` operator](https://learn.microsoft.com/kusto/query/getschema-operator?view=azure-monitor)
for the named checkout tables only. No alternate log transport or new service is
introduced. Additional resource/metric tools are instructed to target only the
exact bound checkout web app; no arbitrary subscription discovery is permitted.
Existing IAM remains the hard access boundary: tool attachment does **not** add
resource-ID restrictions to IAM or make these prompt-level scopes enforceable
server-side. Do not describe this as new resource-scoped RBAC.

The shared rendered procedure allows an initial execution plus at most two
corrected attempts per logical query **only** for explicit KQL syntax/schema
diagnostics. Authentication/authorization/policy denials take precedence;
timeouts, unknown outcomes and other errors are reported without automatic retry.
One investigation request, including verification, has shared ceilings of 24 read operations,
six discovery operations and six corrected KQL attempts. Renaming, splitting or
verification does not replenish correction allowances; turns, continuations,
compaction and handoffs do not reset the ledger. Existing three logical
latency queries, three service verification passes and one initial execution
per readiness check remain. Empty/stale/conflicting evidence stays UNKNOWN.

These budgets and tool-target constraints are **agent instructions, not a
deterministic retry controller**. Offline contracts assert rendered success,
correction, denial, exhaustion and approval instructions and mock the actual
configuration payloads; they do not prove model compliance or live execution.
Human review must accept these procedural bounds before application. A hard
pre-execution per-target/counter enforcement layer would be a separate design,
not silently introduced here.

After review, apply the full custom-agent configuration using the existing
`Up` lifecycle only under a separately authorized deployment scope; the
`ConfigureReadiness` action updates readiness alone. Verify the selected tool
lists/instructions and unchanged native approval policy, then perform explicitly
authorized read-only acceptance for schema, resource metadata, metric discovery
and metric reads using the existing identity. Record real success, classified
syntax correction, denial and budget outcomes before claiming acceptance.
The new tools may surface an access/platform failure: report it without adding
IAM, connectors or a fallback. Presenter-triggered repair, native approval and
fresh same-run recovery are separate acceptance gates. This revision makes no
live agent/policy/role/connector writes, deployment, SRE messages or fault changes.

### Outstanding acceptance

- Preserve the incident evidence boundaries in the scenario guide. A healthy
  deployment alone does not prove approval, recovery or presentation timing.
- Reverse-order rehearsal and other documented combined-profile acceptance
  remain separate from this cleanup.
- Keep the code-loop feature's remaining gates explicit: post-merge fault drift,
  open-PR reset, repeatability and timed presentation are not proved by cleanup.
- After the cleanup is human-reviewed and merged, create a new immutable
  `demo-baseline/checkout-v<N>` on that reviewed history. Coordinate a reviewer-
  gated reset of `demo/checkout` when no demo work is in flight. Never move old
  tags or silently force-reset the branch: existing baselines contain retired
  files and can restore them until deliberately replaced.
- The resumed Foundry source and docs contain no retired scenarios; keep it
  that way when changing them.

Any permission, manual prerequisite or residual outside the authorized owned
deployment must be surfaced explicitly. Cleanup is delivered as a PR to `main`
for human review, not as a request for the owner to perform implementation.
