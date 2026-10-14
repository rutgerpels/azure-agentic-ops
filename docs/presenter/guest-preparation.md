# Native VM demo: preparation sheet

**Use this before the audience joins.** This sheet prepares the retained native
Linux VM service-stopped scenario. It does not deploy, rebuild, start a VM,
change permissions or trigger a fault. Subagent consolidation, GitHub issue
intake and the Arc scenario are not part of this rehearsal.

Then use the [live presenter sheet](guest-live.md). Technical evidence and
limitations remain in the [scenario guide](../guest-service-scenario.md).

## Step 1 - Open the prepared workstation and choose a shell

Use the repository checkout on the prepared Windows workstation. Open either
**PowerShell 7.5+** or **Git Bash** in its repository root. Both choices use the
same PowerShell guard engine; Bash is a launcher, not a separate Azure
implementation. Windows PowerShell 5.1 and an unprepared WSL shell are not
supported. `pwsh` and `az` must be on PATH in the chosen shell.

Sign into Azure CLI with the authorized operator account if necessary:

```powershell
az login
```

Keep the verified installation snapshot and original ownership manifest on this
workstation. They contain operational bindings, not credentials, and are ignored
by Git. Do not copy someone else's profile or edit its hashes/resource IDs.

## Step 2 - Create the local presenter profile once

For the currently retained fixture, the verified snapshot is
`artifacts/presenter/demo-cleanup-guidance-update.json`. This is a preparation
artifact, not a new deployment. Configure resolves the original manifest from
that snapshot, validates the frozen guest sources and pins the snapshot's hash.
It never substitutes the current deployment sources or rehashes the fixture.

Choose **one** one-liner. Answer **Yes** to creating the local profile.

**PowerShell**

```powershell
pwsh -NoProfile -File .\scripts\Invoke-GuestPresenter.ps1 Configure -GuidanceSnapshot .\artifacts\presenter\demo-cleanup-guidance-update.json
```

**Bash**

```bash
bash scripts/guest-presenter.sh Configure -GuidanceSnapshot artifacts/presenter/demo-cleanup-guidance-update.json
```

**Expected:** `ProfileConfiguredNotReady`. The profile defaults to
`artifacts/presenter/guest-profile.json`. If it already exists, skip this step
and run Ready; do not overwrite it to bypass a failed check. A different
prepared fixture needs its own explicitly verified snapshot/profile, not
copied historical IDs.

## Step 3 - Make the intended SRE Agent the only active agent

In the Azure portal, identify the native VM demo's SRE Agent and the separate
Arc agent. The native agent must be **Running** and the other agent **Stopped**.
Before any manual stop, settle that agent's existing investigation, pending
approvals and executing actions. Do not stop an executing repair.

For this retained environment the Arc agent was already stopped during the
last verified rehearsal. **Check; do not assume it is still stopped.**
The presenter script refuses to proceed if any other SRE Agent in the
subscription is not Stopped. It never stops, deletes or modifies an agent.
This is a conservative demo operating constraint, not proven multi-agent
intake isolation.

## Step 4 - Run the readiness check

**PowerShell**

```powershell
pwsh -NoProfile -File .\scripts\Invoke-GuestPresenter.ps1 Ready
```

**Bash**

```bash
bash scripts/guest-presenter.sh Ready
```

**Expected:** `phase: Ready`, the intended VM/agent names and a fresh observation
time. Azure operations here are reads only; local observation/journal files may
be updated.

Ready requires the owned VM to be running, the worker healthy, Manual lifetime
with no watchdog, exact installed guidance/tools/Review policy/plan/grants,
fresh same-run telemetry, previous alert naturally Resolved and previous SRE
approval/execution settled, including any earlier native diagnostic command.
It does not claim fresh deployment acceptance.

**If it fails:** stop preparation. A stale observation can be retried with Ready
later; do not relax freshness or run Fault. An ownership, source, permission,
agent-state or approval mismatch needs reconciliation, not an automatic repair,
VM start, reconfiguration or rebuild.

## Step 5 - Arrange the presentation screen

Open the intended SRE Agent's incident view and Azure Monitor alerts. Keep the
live sheet and one terminal tab ready. Select that terminal's **Fault** command,
but do not run it yet.

Prepare a screen recording if desired; recording is manual, not implemented by
these scripts. Keep a previously captured fallback recording separately. Do
not claim one exists unless you have it.

The presenter will trigger the actual fault in live Step 2. A readiness check,
an assistant saying "ready", or approving the later repair is not that trigger.

## Step 6 - Confirm the talk track and stop at healthy

Say: "This is a real stopped application service on an Azure VM. SRE investigates
an Azure Monitor alert and proposes a repair that I approve. It is a small
operational proof, not the full retail transaction chain or an Arc-managed host."

Use the [live sheet](guest-live.md) when ready. No new fault is needed to finish
preparation. Do not use `Invoke-GuestService.ps1` from the current checkout
against the frozen retained fixture; that deployment lifecycle has different
artifact hashes. The presenter adapter reuses the unchanged controller and
verified configuration without adopting or replacing its original manifest.
