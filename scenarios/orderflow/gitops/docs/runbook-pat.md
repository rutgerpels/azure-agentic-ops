## GitHub issue (PAT quick-demo mode)

This section replaces the App publication procedure in the generated investigator.
The PAT connector has no durable publication reservation. Native approval is
the human-enforced write boundary, not a server-enforced create-only guarantee.

1. Use only the configured `list_issues` operation for owner `{{owner}}`, repo
   `{{repo}}`, `perPage=100`, requesting number, body, title and state. Omit
   `state` so both open and closed issues are included. Follow `pageInfo.endCursor`
   with `after` while `hasNextPage` is true, at most ten pages. If the result
   is incomplete, lacks bodies or exceeds that bound, stop for human inspection.
   Do not infer absence from semantic search results or an empty first page.
2. Look for the exact standalone body line
   `<!-- orderflow-incident-key:{{generation}} -->` across all returned issues.
   If found, use `issue_read` with `method=get` and the issue number, report its
   URL and stop, even if it is closed. Never update it or create a replacement.
3. Before any write, ask the presenter to confirm no previous create approval,
   failed/timed-out publication or parallel investigation exists for this
   generation. If any outcome is unknown, stop and observe GitHub with reads;
   never retry `issue_write`, even if no issue is visible yet. Across restarted
   threads, require the presenter to reconcile prior approval cards first.
4. Only for a proven first publication, request native approval for exactly one
   `issue_write` with `method=create`, owner `{{owner}}`, repo `{{repo}}`,
   labels `["orderflow-incident"]`, a concise dependency-failure title and body
   containing the exact marker above. Omit assignees, issue_number, state,
   milestone, parent linkage, type and issue fields. Never use `method=update`.
   The presenter must inspect these arguments on the native approval card;
   do not request blanket or thread-level approval.
5. Include Summary, Impact, Evidence (UTC timeline), Root cause, Proposed change,
   Validation plan and Rollback sections. Propose only the rules-file change
   described above; distinguish verified evidence from unknown CD/PR links.
   Validate offline rules, test deployment/smoke, then human merge and fresh
   production smoke/alert recovery. Rollback is a human-reviewed reset PR.
6. After one create call, stop writing regardless of its response. If necessary
   observe through list/read only. Return the observed issue URL and state that
   Actions handles Copilot assignment; do not claim assignment succeeded without
   independent evidence. Never assign Copilot yourself.
