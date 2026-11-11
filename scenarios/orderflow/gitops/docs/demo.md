# OrderFlow: presenter run sheet

Complete the [A-Z README](../../README.md) before audience time. Start only with
fresh Ready, a verified merchandise order and no outstanding actions. Keep six
tabs: storefront, PRs, Actions, SRE, Issues and NSG. Timing varies; do not promise
a fixed recovery duration.

| Beat | Show | Say / do |
| --- | --- | --- |
| Healthy customer | The Static merch store | Choose a shirt, poster or tote. Confirm a demo order and show the saved collection pass. No real payment or pickup. |
| Urgent change | Security-hardening PR | “We need to restrict lateral access to customer-order data before the next sales window.” Review/merge the staged change; no real emergency is claimed. |
| Disruption | Store and CD | Deployment succeeds but smoke fails. Show ordering paused, stale merchandise and no new confirmations. The page itself is still available. |
| Investigation | SRE incident | Show current evidence: dependency failures, NSG deny and Activity Log. Approve bounded reads; do not grant broad roles for query errors. |
| **Human decision** | **Unassigned incident issue** | **Pause. Read root cause and proposed fix with the audience. Then manually assign Copilot once.** Issue publication alone does not start it. |
| Engineering | Copilot draft PR | Explain the narrow allow that retains segmentation. Only runtime rules may change. |
| Proof in test | Separate test deployment | Approve workflows when asked. Require this head SHA's test deployment, smoke and report. Green offline CI is insufficient. |
| Production release | Human merge and CD | Merge only after test proof. Watch production smoke, then refresh collection and place a distinct new order. |
| Recovery | New collection pass and resolved alert | Independently read the saved order and original alert. Earlier passes or an agent claim are not proof. |

The “urgent” change is a fictional security-hardening request with an
intentionally missing application exception. Keep its explicit presenter note
and demo label. Do not disguise the staged risk from the reviewer.

The smoke job **detects** disruption; the NSG change causes it. Real dependency
probes generate telemetry and the Monitor alert even without an audience order.
During an uncertain POST, use **Check collection pass**, never submit again.

If assignment is uncertain, inspect the issue and session before doing anything
else. If an issue is automatically assigned, stop and inspect old handoff runs
or another repository automation. Keep **Require approval for workflow runs**
enabled. No production repair is delegated to SRE in option 2.
