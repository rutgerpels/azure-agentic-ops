# Checkout delivery and lifecycle plan

## Scope

RetailTx now focuses on two independent incidents in one hybrid checkout estate:
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
| Sanitized SRE RCA to Copilot PR and gated demo deployment/reset | Retained optional [code loop](checkout-code-loop.md), tracked in [#44](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/44) |
| Foundry business-facing incident assistant | Parked, unfinished [#45](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/45) / [draft PR #54](https://github.com/rutgerpels/retailtx-agentic-ops-demo/pull/54) |
| Foundation/native VM/guest proofs, Windows disk/IIS, posting/backlog, GitHub-to-SRE intake | Retired from the active source tree |

Foundry remains on its separate draft branch; cleanup does not merge or resume
it. Its recorded teardown is not live checkout integration acceptance, and its
unresolved agent-evaluation failures remain unresolved.

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
Get-ChildItem .\tests\Test-Checkout*.ps1 | ForEach-Object { & $_.FullName }
bicep build .\infra\checkout\main.bicep --stdout > $null
bicep build .\infra\checkout\arc.bicep --stdout > $null
bicep build .\infra\checkout\latency-alert.bicep --stdout > $null
```

Use an isolated virtual environment. The development lock covers checkout
contracts using the frontend's FastAPI and telemetry pins, without the retired
PostgreSQL/Service Bus application or its build package. Azure deployment
installs `app/checkout/frontend/requirements.txt` independently, including its
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
- Before a future Foundry merge, reconcile its documentation and source with
  checkout-only scope so obsolete scenarios are not reintroduced.

Any permission, manual prerequisite or residual outside the authorized owned
deployment must be surfaced explicitly. Cleanup is delivered as a PR to `main`
for human review, not as a request for the owner to perform implementation.
