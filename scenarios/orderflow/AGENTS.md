# OrderFlow configuration drift

OrderFlow adapts upstream VM/Cosmos DB Scenario C into a visible
availability-affecting network drift incident. It is independent of Retailx.

- Keep application, infrastructure, scripts, tests and guides in this scenario.
  Reuse only the root Azure.Common module and root development tooling.
- Setup ends healthy. Only the presenter injects a fault. No automated fault,
  expiry, watchdog repair or public administration endpoints.
- The portal remains reachable while its private VM dependency fails.
  Use real requests and fresh TCP connections; NSG changes do not break existing
  connections. Never synthesize successful orders or recovery.
- Use synthetic data only. No payments, personal data or production endpoints.
  A timed-out order is unknown: observe its request ID without replaying it.
- The native SRE approval card must precede repair. Text assent, a Stop hook,
  an idle agent and a cleared alert are not approval or recovery evidence.
- Restrict SRE writes to the owned NSG rule. No VM command, broad contributor,
  role-management, alternate write tool or thread-level approval bypass.
- One fault per deployment generation. Never admit a new fault while old actions
  could still execute. Rehearse again with a fresh owned environment.
- Persist non-secret ownership and pending operations under repository-root
  `.azure/orderflow/<environment>/`. Refuse adoption and preserve state after
  partial failure or timeout. Observe unknown outcomes instead of replaying.
- Teardown deletes only a verified wholly owned group. A failed SRE deletion is
  not successful cleanup; preserve receipts and stop.
- Local tests are not Azure acceptance. Document unverified provider behavior.
  Do not deploy, change GitHub settings or inject a live fault without scope.
