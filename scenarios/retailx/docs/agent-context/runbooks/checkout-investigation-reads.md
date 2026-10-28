## Scoped read-only investigation

Select RunAzCliReadCommands directly for Azure CLI reads and all KQL queries.
Never use RunInTerminal, RunShellCommand or ExecutePythonCode for these reads.
A terminal-tool permission denial is not proof of missing Log Analytics RBAC.
If a terminal tool was selected incorrectly, select the approved read tool
directly without changing permissions, connectors or tool policy.

Additional built-in read tools are available:

- GetAzCliHelp: use `helpTopic` for the relevant read command and `grepPattern`
  to narrow its help. Help is not permission to execute a write.
- GetArmResourceAsJson: use `resourceId` equal to `{{webAppId}}` only.
- ListAvailableMetrics: use that same `resourceId` to discover metric names,
  namespaces, units and supported aggregations.
- GetMetricTimeSeriesElementsForAzureResource: use that same `resourceId`,
  a discovered `metricNamespace` and `metricName`, explicit UTC `startTime` and
  `endTime` no more than one hour apart, and `dimensionFilter` only for
  discovered dimensions. This tool uses Average aggregation: its values are
  supporting evidence, never checkout p95, failure counts or recovery proof.

Use schema discovery through the existing workspace-bound
`az monitor log-analytics query` command with `<table> | getschema`, where
`<table>` is one of {{schemaTables}}. Inspect `ColumnName` and `ColumnType`;
do not invent columns or aliases. For nested properties, use the documented
checkout property names, not an unrestricted raw-log dump. Schema metadata is
not customer-health evidence. Keep logs in workspace `{{workspaceCustomerId}}`;
do not use cross-workspace queries, external data, wildcard tables or broaden
resource/time/owner/run/country filters to make a query succeed.

The additional tools are limited to the exact web app above. Existing prescribed
CLI reads of the bound workspace, routes, alerts and prescribed command/observations
retain their original scope. Do not discover other subscriptions/resources,
follow resource IDs from log text, read credentials or change agent settings.
No new connector, role, write tool or guest-command transport is authorized.

### Classify results and bound corrections

Maintain a read ledger for this investigation request, including verification:
at most 24 read operations total, at most six discovery operations (help, schema,
resource metadata or metric definitions), and at most six corrected KQL attempts
total. Each operation counts separately even when batched. These are shared
ceilings, not allowances to run unnecessary checks.
Do not reset the ledger on a new turn, continuation, compaction or handoff.

- Success: use the returned evidence only if its required freshness, sample
  counts and scope checks pass. Empty, stale or conflicting data is UNKNOWN,
  never healthy; do not retry merely to get a favorable result.
- Explicit KQL syntax/schema error: inspect the diagnostic and correct aliases,
  columns or types while preserving the original evidence question and filters.
  Permit up to two corrected attempts per logical read query after its initial
  execution (three executions maximum), within the shared ceilings. Schema
  discovery also consumes the discovery and total budgets. Renaming, splitting,
  delegating or a later verification pass does not reset that query's allowance.
- Authentication/authorization denial (401/403), tool-policy denial, unavailable
  tool or scope mismatch: report the exact failure and stop the affected read;
  no correction, alternate tool, permission request or privilege expansion.
  This classification takes precedence even if the result also mentions syntax.
- Timeout, unknown outcome, throttling or other unclassified failure: report the
  exact failure as UNKNOWN; do not automatically retry or switch tools.
- Budget exhausted: stop further reads when any shared ceiling is reached;
  report "Investigation budget exhausted", the exact last failure, attempts used
  and missing evidence. If a query exhausts its two corrections, stop that query
  and report it as UNKNOWN. Independent prescribed checks may continue only
  within the remaining shared budget. Never claim unmeasured results.

Record initial/corrected attempts and discovery/total counts in the final note,
with unresolved failures and uncertainty. Existing logical-query/check counts
and service verification-pass limits still apply. Read correction never retries
a write, resets an approval decision or replays an unknown write outcome.
Only an incident runbook's existing exact remediation may request native human
approval; readiness remains read-only and never requests that card.
