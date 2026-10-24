# Scenario organization and contribution

## Boundaries

A scenario is a named, independently managed demo, not a customer fork.
Use a stable lowercase kebab-case directory slug and a human-readable display
name in its README. **Retailx** uses `scenarios/retailx/` and is aimed primarily
at hybrid-cloud conversations where Azure Arc manages the simulated datacenter.
Its `latency` and `service` incidents are choices within Retailx, not separate
top-level demos. Its optional Foundry assistant and code loop belong to Retailx.

```text
scenarios/
  retailx/
    README.md
    AGENTS.md
    app/
    infra/
    scripts/
    chaos/
    tests/
    docs/
```

Use only the directories a demo actually needs. `chaos/` is optional. Extensions
may have their own application and lifecycle within the scenario; keep optional
extensions optional. There is no mandatory demo registry, plugin API, generic
launcher or customer-specific copy of the source tree.

## Shared surfaces

| Surface | Ownership |
|---|---|
| `scripts/Azure.Common.psm1` | Existing Azure CLI, identity, state and payload helpers |
| `infra/azure-bootstrap-identity.bicep` | Shared bootstrap identity module |
| `tests/` | Shared helper and repository-organization contracts |
| `pyproject.toml`, `requirements-dev.lock` | Root Python validation configuration and pinned development environment |
| `.github/workflows/` | Required GitHub Actions location; use explicit scenario paths and isolated gates |
| `.github/agents/`, `.github/skills/`, `.github/instructions/` | Cross-scenario contributor tooling and policy |

Extract additional shared code only when real consumers need the same contract.
Do not make one scenario import another scenario's implementation or require
another demo to be deployed. Shared changes must cover all existing consumers.
Runtime dependencies remain beside the application that is published.

## Adding a demo

1. Choose a unique display name and directory slug; add a row to the root
   README's scenario table.
2. Add a scenario README describing audience, architecture, prerequisites,
   repository-root commands, costs and verification limits. Put detailed guides,
   presenter material and the delivery plan in its `docs/`.
3. Keep app, infra, scripts and tests inside the scenario. Add a scoped
   `AGENTS.md` with its operational boundaries. Do not copy Retailx merely as a
   template: its Arc controller, store data and incident assumptions are specific.
4. Own setup, readiness, explicit fault selection, reset/undo and verified
   teardown. Choose non-overlapping state paths and cloud ownership boundaries;
   never adopt another scenario's resources. Preserve state on partial failure.
5. Add offline contracts and wire their discovery into root tooling where
   appropriate. Keep executable scripts separate from dot-sourced helper
   libraries. Use the pinned development environment; introduce dependencies
   only for actual requirements.
6. If Actions are needed, add uniquely named workflows at `.github/workflows/`
   and isolate environments, branch gates, concurrency and identity scopes.
   Retailx's `demo/checkout`, labels and baseline tags are not global defaults.

New Azure resources or live incident rehearsals require their own authorized
scope. A repository relocation is not authorization to deploy or inject faults.

## Retailx migration and compatibility

Retailx's former root `app/`, `chaos/`, scenario `infra/`, lifecycle `scripts/`,
scenario `tests/` and `docs/` now live under `scenarios/retailx/`. Use the
[Retailx README](../scenarios/retailx/README.md) for the new entry points; old
root scenario commands are not retained as duplicate wrappers.

The display name is Retailx. Existing `retailtx-*` resource names, service units,
environment variables, ownership markers and state formats are intentionally
unchanged. In the **same working checkout**, existing `.azure/<environment>/`
ownership state remains at the repository root and is read by the relocated
lifecycle scripts. Do not move state into the scenario, adopt live resources
from another checkout, or discard manifests to get past a failed operation.
Use unique environment IDs across demos; new demos must document their own state
namespace instead of reusing Retailx's legacy files.

The checkout deploy/reset workflow filenames, reviewer environments,
`checkout-demo` label and `demo/checkout` branch are unchanged. Existing immutable
baseline tags still contain their historical layout. After human review and
merge, use Retailx's documented baseline lifecycle to create a **new** tag and
coordinate a reviewer-gated reset when no demo work is in flight. Never move an
old tag or automatically reset the demo branch as part of this migration.

The repository defaults and links now use `rutgerpels/azure-agentic-ops`.
Existing GitHub-to-Azure federation is external configuration, not renamed by
moving source files. Before reusing a retained code-loop identity, run its
documented `Check` action against the renamed repository. A name-bound OIDC
subject may no longer match; the existing mismatch refusal is intentional.
Do not overwrite credentials or recreate identities as part of this relocation.
Resolve any reported mismatch through a separately reviewed identity change.

Offline commands are in the
[Retailx delivery plan](../scenarios/retailx/docs/implementation-plan.md).
Run shared PowerShell contracts with
`Get-ChildItem .\tests\Test-*.ps1 | ForEach-Object { & $_.FullName }`.
Recorded live evidence remains historical; relocating files does not establish
a new deployment or recovery proof.
