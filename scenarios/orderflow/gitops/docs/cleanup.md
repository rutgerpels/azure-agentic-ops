# OrderFlow GitOps: owned cleanup

Cleanup does not require repeating deployment, configuration or the demo. Closing
VS Code loses terminal variables, not the retained ownership or deletion progress.
Use PowerShell 7.2+ and the **original owning checkout**, with Azure CLI and GitHub
CLI signed in. Do not copy `.azure` state to another checkout.

## Remove the Azure environment

First settle SRE approval cards/threads, Copilot tasks, deployment approvals and
unknown operations. Then run one command from the repository root, replacing
`demo1` with the original environment name:

```powershell
.\scenarios\orderflow\gitops\scripts\Remove-OrderFlowGitOps.ps1 -EnvironmentName demo1 -ActionsSettled
```

`-ActionsSettled` is your confirmation that those actions have been reconciled,
not an approval of any SRE repair. The script displays the saved subscription,
repository and owned groups in its confirmation prompt. To preview that scope
without contacting Azure/GitHub or writing files:

```powershell
.\scenarios\orderflow\gitops\scripts\Remove-OrderFlowGitOps.ps1 -EnvironmentName demo1 -WhatIf
```

**After a timeout, terminal close or laptop restart, run the same removal command
again.** There is no `$common`, `$statePath`, `$cleanupPath`, dot-sourcing, `Reset`
or `Up` prerequisite. To find the retained environment names locally:

```powershell
Get-ChildItem .\.azure\orderflow-gitops -Directory | Select-Object -ExpandProperty Name
```

## What the command does

1. Loads and validates the saved subscription, environment and ownership token;
   takes the existing lifecycle lock so two cleanup processes cannot overlap.
2. Pauses future OrderFlow production **and test** deployment workflows and disables legacy automatic handoff.
   Reads each workflow's [GitHub state](https://docs.github.com/en/rest/actions/workflows#get-a-workflow),
   skips already-disabled workflows, and verifies newly requested pauses before continuing.
   An unreadable or unexpected state stops cleanup rather than assuming deployment is paused.
   Checks a complete paginated run listing, without status-transition gaps.
   Refuses to delete while admitted OrderFlow deployment/handoff runs are active
   or awaiting approval. It does not cancel runs or approve actions for you.
3. Captures private `cleanup-inventory.json` **before** deleting identities:
   three owned groups, two provider-managed infrastructure groups, the SRE
   principal and its exact subscription-level Monitoring Contributor assignment.
   An existing inventory is validated and reused, never overwritten.
4. Uses the existing `Down` sequence: SRE Agent first while its identity and
   knowledge graph still exist, then prod/test, then shared. Ownership and
   foreign-resource checks remain enforced.
5. Verifies all five recorded groups are absent. Provider-managed groups are
   observed, never directly deleted. Only then removes any recorded monitoring
   assignment whose live identity, scope and role still match.
6. Records final absence in private `cleanup-progress.json`. Keeps ownership,
   inventory and journals for audit; never treats an error or timeout as success.
   A completion timestamp records that observation, not perpetual proof of absence;
   each later verification clears it until absence is established again.

Each deletion stage waits up to 90 seconds by default, rather than holding the
terminal for 45 minutes per stage. Azure deletion may still take longer. Adjust
the observation window with `-WaitSeconds 300` if desired; this does not change
the deletion itself. On resume, already-submitted deletions are **observed, not
replayed**. The script can finish verification even if `Down` already recorded
the generation as `removed`.

An interruption **between saving delete intent and submitting the request**, or
between targets in a deletion wave, can require manual reconciliation of the
original operation. Rerunning observes rather than guessing which request ran;
it cannot guarantee automatic completion in that narrow interruption window.

## If cleanup stops

| Message or situation | Safe next action |
| --- | --- |
| Not signed in / access denied | Restore your existing Azure/GitHub sign-in or authorized access, then rerun the same command. Do not rerun configuration or widen roles. |
| Active or waiting deployment run | Inspect and settle the indicated OrderFlow runs in GitHub, then rerun. Pausing CD does not cancel admitted runs. |
| Run discovery changed / incomplete | Rerun after admitted work settles. Discovery refuses changing totals, duplicate entries or more than 100 pages of history. If the limit persists, reconcile deployment admission and original receipts with an authorized maintainer; do not bypass the gate or discard evidence. |
| Still deleting / managed group still present | Wait, then rerun the removal command to observe the original deletion. |
| SRE deletion failed / group no longer deleting | Inspect the original provider failure. Preserve receipts; repeated cleanup does not resubmit deletion. |
| Monitoring-role delete attempted but still present | Inspect the original assignment/delete outcome. The saved attempt prevents replay, including after a timeout. |
| Existing `cleanup-inventory.json` from the old walkthrough | It is reused after validating its groups, SRE principal and exact monitoring role against ownership. No old terminal variables are needed. |
| Deletion started without an inventory, or inventory missing/corrupt | Stop and reconcile retained original private receipts. Do not recreate identities, fabricate a replacement inventory or discard ownership. |

The underlying `Invoke-OrderFlowGitOps.ps1 -Action Down` remains available, but
only removes the owned groups. Use the removal command above for inventory,
resumption and final managed-group/monitoring-grant verification together.
Partially provisioned environments without the required outputs need individual
ownership-checked reconciliation; the helper will stop rather than guess targets.

## What remains

GitHub environments, variables, labels and valid issue credentials remain;
production and test deployment workflows stay **paused** and legacy automatic handoff stays off. For another
rehearsal, use the normal fresh-environment setup to refresh Azure-bound settings
and re-enable both workflows at README step 6. This command does not rearm a consumed
generation or reset repository source.

`Reset` is optional source housekeeping, not a deletion prerequisite. It opens a
baseline PR for human review; it does not remove Azure resources or GitHub settings.
For permanent retirement, separately review credentials, connector and environments
before removing them. The old assignment token is unused by manual handoff; retire
it only after reconciling historical tasks and checking it is dedicated to this demo.

The cleanup helper is offline-tested; local checks are not a live Azure teardown
acceptance claim.
