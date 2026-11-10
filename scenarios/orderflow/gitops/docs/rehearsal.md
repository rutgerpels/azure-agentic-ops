# OrderFlow GitOps rehearsal

The comprehensive, maintained **A-Z guide now lives in the
[OrderFlow README](../../README.md)**. Start there for deployment, setup,
healthy customer experience, security change, SRE diagnosis, manual agent
assignment, tested PR, production recovery and cleanup.

The demo is a fictional concert merchandise shop. Automatic issue publication
is still selectable, but **a human reviews the issue and assigns Copilot**.
The automatic assignment workflow is retired. Keep GitHub workflow approvals.

## 12. Reset source for next time and tear down the owned Azure generation

For existing bookmarks: see [README step 12](../../README.md#12-reset-and-clean-up)
and the complete [owned-cleanup commands](cleanup.md). Reset never rearms an
old generation; keep ownership receipts after verified teardown.

## Historical rehearsal evidence

The November 4 run established production recovery, but its pre-merge test
deployment remained `action_required`. The presenter reported completing the
November 10 demo and confirmed the automatic issue-to-PR path worked. The new
manual assignment and merch storefront need their own live rehearsal; do not
inherit acceptance merely from those older runs. See the
[verification history](operations.md#verification-status).
