# Native VM demo: live presenter sheet

**Start only after the [preparation sheet](guest-preparation.md) reports Ready.**
Choose PowerShell or Bash; all terminal commands below are single lines.
Keep the same workstation, checkout and local profile throughout the run.

## Step 1 - Explain the healthy starting point

Show the intended SRE Agent and the previously resolved alert.

Say: "The VM is running and the application service is healthy. I will stop the
fixture's posting-worker service. Azure Monitor, not a manually created ticket,
will initiate the investigation. The fault will remain until explicitly repaired."

If the readiness observation is old, run the preparation sheet's Ready command
again. Do not substitute a manually created alert or investigation.

## Step 2 - Personally trigger the service fault

Run **one** command yourself and answer **Yes** to the confirmation.
This is consent to inject the fault, **not** approval of SRE's repair.

**PowerShell**

```powershell
pwsh -NoProfile -File .\scripts\Invoke-GuestPresenter.ps1 Fault -PresenterTriggered
```

**Bash**

```bash
bash scripts/guest-presenter.sh Fault -PresenterTriggered
```

**Expected:** `SubmittedNotVerified` and a new `runId`. Copy that run ID into
your rehearsal notes together with the trigger time. The flag records presenter
intent; it is not a technical proof that a human, rather than automation, typed
the command.

**Do not run Fault again**, even if submission times out, the alert is slow or
the command prints a warning. Intent is saved before the Azure write; a second
invocation is refused. If needed, observe with the read-only command below.

**PowerShell**

```powershell
pwsh -NoProfile -File .\scripts\Invoke-GuestPresenter.ps1 Status
```

**Bash**

```bash
bash scripts/guest-presenter.sh Status
```

Status is an operator observation, not an SRE conclusion. Telemetry can lag:
a stale or different-run receipt causes an explicit stop, not a success claim.
Record alert/incident time separately from submission time.

## Step 3 - Follow the automatic incident

In SRE, open the **new** native VM alert incident. Confirm that its target is
the VM shown by Ready. Follow the diagnosis: the VM is running, but the fixture
service was stopped by a Manual fault.

If no new incident arrives within **five minutes**, stop the live segment and
use your fallback material. Do not create an investigation manually or restart
Fault to make the demo proceed. Reconcile the exact run outside the presentation
before attempting cleanup or another incident.

## Step 4 - Review and approve exactly one repair

Inspect the native approval card. It should target the intended VM, invoke the
readable protected-controller wrapper for this exact run and original fault
actor, and use `--no-wait`.

Approve **only the single action**. Never approve the entire thread, change
Review mode, add permissions or paste a replacement repair command. If the
target/run differs, reject the card and stop the demonstration.

Say: "I approve this proposed action. The controller validates the current
fault. Azure Run Command itself is a broader guest-execution permission; the
runbook is not a service-only RBAC boundary."

Record approval time separately. Submission acceptance is not proof of recovery.

## Step 5 - Read the first answer and verify recovery

Wait for SRE's first completed answer. Do not supply the expected outcome.

| What SRE reports | What to say |
| --- | --- |
| Recovery verification pending | "The repair was submitted; current health is not verified yet." |
| Service observed healthy; repair verification pending | "Fresh evidence shows the service recovered; execution audit confirmation is still arriving." |
| Service recovery verified | "SRE correlated the repair's Azure execution with fresh same-run health." |
| Unhealthy, unknown, contradictory or failed evidence | Explain that evidence honestly; do not rerun repair to get a nicer answer. |

If confirmation is pending, ask SRE this neutral follow-up:

> Is the issue resolved? Check the current service health and report the evidence.
> Do not repeat the repair.

A follow-up is a permitted read-only verification step, not another approval or
repair. If SRE says the ignored-subscription warning proves rejection, point out
that this explanation needs reconciliation; the warning alone proves neither
non-execution nor success.

Use Status if you need an independent operator check, but do not present it as
SRE's own verification. Record time to verified service health separately from
Azure audit completion and natural Monitor clearance.

## Step 6 - Close the story without overstating the result

Summarize the evidence: real service fault, automatic Monitor incident, SRE
diagnosis, visible human approval, observed recovery and what remains pending.
The incident thread is the available outcome record; a separately delivered
incident-update/RCA channel is not established.

Do not claim store impact, queue recovery, ERP recovery or lost-sales prevention.
Do not force the alert to Resolved or call acknowledgement repair approval.
Its natural clearance can happen later, during the walkthrough.

## Step 7 - Reset or archive this exact run after the presentation

First use Status. If a card is still pending, reject it in SRE. Wait for the
thread to be Idle and any admitted command to have terminal Azure audit.
Do not stop an agent or run an operator reset while a repair is unsettled.

Replace `PASTE-THIS-RUN-ID` with the run ID from Step 2. Choose one one-liner:

**PowerShell**

```powershell
pwsh -NoProfile -File .\scripts\Invoke-GuestPresenter.ps1 Reset -RunId 'PASTE-THIS-RUN-ID'
```

**Bash**

```bash
bash scripts/guest-presenter.sh Reset -RunId 'PASTE-THIS-RUN-ID'
```

Answer **Yes** only after reviewing the displayed action:

- If SRE already recovered the service and Monitor is naturally Resolved, Reset
  archives the local presenter run with **zero guest writes**.
- If the service remains stopped and the SRE thread/approvals/actions are
  settled, Reset submits one exact-run **operator fallback**. This is not
  SRE-approved healing. Use Status afterward; never repeat an uncertain Reset.
  Once recovery and natural clearance are verified, the same Reset command
  archives the run rather than executing another guest action.
- If the incident is missing, approval/execution is unsettled, audit is missing
  (including a prior native diagnostic), another workflow owns a pending command
  or evidence conflicts, Reset refuses. Leave the exact run for operator
  reconciliation; there is no timer or reboot auto-recovery.

An interrupted local archive can be completed with the same exact-run Reset;
a conflicting archive is never overwritten. Once archived, repeating that
command performs readiness reads only, with no guest write.

Run Ready again after `ArchivedHealthy` before another presentation.
Retention/expiry and teardown remain separate owner decisions; these commands
do not destroy the fixture or stop/start either agent.
