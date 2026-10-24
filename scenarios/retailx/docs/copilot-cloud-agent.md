# Copilot cloud agent Azure access

Prerequisite for [#44](https://github.com/rutgerpels/azure-agentic-ops/issues/44):
the Copilot cloud agent turns an SRE RCA issue into a config-as-code pull request and
may read the live checkout estate through the Azure MCP server. The end-to-end loop,
gated deploy and reset are described in [checkout-code-loop.md](checkout-code-loop.md).
For `checkout-demo` issues, always open the pull request against `demo/checkout`,
never `main`.

## Identity model

- `scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Configure` creates an owned resource group
  `rg-retailtx-copilot-<environment>-<location>` with an `expiresAt` tag, the
  user-assigned identity `id-retailtx-copilot-<environment>` and one federated
  credential.
- The credential subject is the repository's immutable OIDC subject with
  `:environment:copilot`. This binds trust to that repository and environment,
  not a particular branch or workflow; environment policies enforce those limits.
- Client and tenant IDs are stored as repository **Agents** secrets (read by Copilot
  sessions) and as `copilot` environment secrets (read by workflow validation runs).
  They are identifiers, not credentials.
- Configure grants **no** Azure role. `Grant` assigns Reader on one existing checkout
  resource group only, after checkout `Up`. Never grant at subscription scope.
- `.github/workflows/copilot-setup-steps.yml` logs in with
  `allow-no-subscriptions: true` before each Copilot session.

## Lifecycle

```powershell
./scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Configure -SubscriptionId <guid>
./scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Grant -SubscriptionId <guid> -CheckoutEnvironmentName checkout01
./scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Check -SubscriptionId <guid>
./scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Remove -SubscriptionId <guid>
```

Configure refuses to adopt a resource group it does not own or overwrite a credential
with a different subject. Remove deletes role assignments, the owned group, the Agents
secrets, the `copilot` environment and local state under `.azure/` (gitignored).
Checkout `Down` deletes its resource group, which removes a Reader assignment scoped to
it.

## Repository rename and OIDC failures

`AADSTS700213` means the presented assertion has no matching federated trust.
After a rename, compare the workflow's subject with the existing credential:
even GitHub's immutable format contains the repository name as well as its ID.
See [GitHub's OIDC reference](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims)
and [Microsoft's exact-match requirements](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity#important-considerations-and-restrictions).

Do not disable login, ignore the failing check or broaden the subject. With
explicit authorization, update only the existing credential's subject after
confirming the same repository/owner IDs and retained identity. Preserve issuer,
audience, role assignments and ownership manifests. `Configure` intentionally
refuses mismatches; do not remove that safeguard or recreate the identity.
Verify ARM readback, then rerun the failed workflow to prove token exchange.

## Manual repository setting

Repository MCP configuration is only available in **Settings → Copilot → Cloud agent →
MCP configuration** and is shared with Copilot code review. Copilot calls configured
MCP tools without per-call approval, so allow only read tools:

```json
{
  "mcpServers": {
    "Azure": {
      "type": "local",
      "command": "npx",
      "args": ["-y", "@azure/mcp@latest", "server", "start", "--read-only"],
      "tools": ["*"]
    }
  }
}
```

Read-only behavior is enforced by the identity's Reader scope, not by the
`--read-only` flag alone.

## Verification status

| Item | Status |
|---|---|
| Identity, federated subject, `copilot` environment and secrets | Verified by `Check` readback |
| OIDC token exchange from GitHub Actions | Verified by a successful `copilot-setup-steps` pull request run |
| Copilot session using Azure MCP | Verified in the 2026-10-18 checkout code-loop run; see the code-loop guide for evidence and limits |
| Reader on checkout resource group | Verified for that disposable fixture; a new environment needs its own scoped `Grant` |
| Repository rename repair (2026-10-24) | User explicitly approved updating only the retained Copilot credential's subject. Readback confirmed the same identity, credential, issuer, audience and role assignments. The previously failing [PR check](https://github.com/rutgerpels/azure-agentic-ops/actions/runs/40106177233) passed on rerun. No workflow gates or login behavior changed; this is not a new checkout rehearsal or deploy-identity verification. |
