# Native guest fixture: differential diagnosis and proposal

Knowledge version: `github-investigation-v1`.
Retrieval probe: `native-fixture-differential-v1`.

Use the architecture/evidence reference and independently obtain current
instance view and newest bound Syslog observation. Do not start from a canned
fault answer. Restrict tools to operational reads and knowledge search; no
guest Run Command, shell, Python execution, write skill, OBO, permission change,
alert acknowledgement, issue closure or remediation.

| Evidence | Supported conclusion | Next proposed step |
| --- | --- | --- |
| Fresh VM running; fresh bound service active/healthy | Cannot reproduce the reported outage at the observed time | State that timing or another dependency may explain the report; request a precise exposure window |
| Fresh VM running; fresh supported Manual marker; service inactive/unhealthy | Current fixture service is stopped; VM itself is not down | Propose the existing separately human-approved, current-run recovery procedure |
| Fresh instance view says VM stopped/deallocated/unavailable | VM availability is a candidate cause; service state is not independently current | Recommend operator inspection of VM lifecycle/change evidence; do not automatically start it |
| VM running; missing/stale/invalid/foreign/future Syslog | Insufficient service evidence; a telemetry/observer hypothesis remains | Recommend read-only observation/ingestion investigation; never invoke guest diagnostics |
| Service active but unhealthy, conflicting fields or unsupported marker | A service/dependency/configuration hypothesis, not the supported stopped-service fault | Cite the contradiction and request targeted read-only dependency/configuration evidence |
| Dependency/configuration error without a correlated fresh source | Unproven hypothesis | Keep it a hypothesis, not root cause; do not recommend arbitrary configuration changes |

A Manual marker establishes a logged fixture change, not all underlying causes
or retail impact. Keep observation, supported inference and hypothesis distinct.
Existing Monitor investigations should be linked when exact correlation is
available; absence of a proven merge capability must remain explicit.

## Recommendation, not execution

For the supported stopped-service case, propose that a human use the existing
approved native fixture recovery path after revalidating exact owner, VM,
current run and original actor. Do not generate executable repair instructions
or attach `guest-service-recovery` or `RunAzCliWriteCommands` to this investigator.
Review mode alone is not a write boundary.

Expected validation: independently obtain newer same-owner/run service evidence,
active/healthy state and separately correlated Azure execution evidence after
the human action. Monitor clearance is another outcome, not a substitute for
service verification. If recovery fails or is uncertain, stop and inspect the
existing operation rather than replay it. A rollback/reset is an explicit
operator decision using the owned lifecycle; intake does not execute it.

For healthy, stale, unbound or unsupported conditions, recommend obtaining the
missing evidence rather than proposing the stopped-service recovery.

The final answer must be the structured JSON requested by the trusted
investigator configuration, with actual retrieved source/version, evidence
timestamps, observations, hypotheses, proposed action, expected validation,
rollback/stop condition, uncertainty and any matched Monitor investigation.
Never copy issue prose as a result or mistake an Idle thread for a completed
diagnosis. Do not claim live acceptance, business recovery or a repair performed
by this proposal-only investigator.
