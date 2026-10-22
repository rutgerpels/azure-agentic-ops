# Copilot cloud agent Azure access

Prerequisite for [#44](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/44):
the Copilot cloud agent turns an SRE RCA issue into a config-as-code pull request and
may read the live checkout estate through the Azure MCP server. The end-to-end loop,
gated deploy and reset are described in [checkout-code-loop.md](checkout-code-loop.md).
For `checkout-demo` issues, always open the pull request against `demo/checkout`,
never `main`.

## Identity model

- `scripts/Invoke-CopilotCloudAgent.ps1 Configure` creates an owned resource group
  `rg-retailtx-copilot-<environment>-<location>` with an `expiresAt` tag, the
  user-assigned identity `id-retailtx-copilot-<environment>` and one federated
  credential.
- The credential subject is the repository's immutable OIDC subject with
  `:environment:copilot`. No other branch, workflow or environment can exchange it.
- Client and tenant IDs are stored as repository **Agents** secrets (read by Copilot
  sessions) and as `copilot` environment secrets (read by workflow validation runs).
  They are identifiers, not credentials.
- Configure grants **no** Azure role. `Grant` assigns Reader on one existing checkout
  resource group only, after checkout `Up`. Never grant at subscription scope.
- `.github/workflows/copilot-setup-steps.yml` logs in with
  `allow-no-subscriptions: true` before each Copilot session.

## Lifecycle

```powershell
./scripts/Invoke-CopilotCloudAgent.ps1 Configure -SubscriptionId <guid>
./scripts/Invoke-CopilotCloudAgent.ps1 Grant -SubscriptionId <guid> -CheckoutEnvironmentName checkout01
./scripts/Invoke-CopilotCloudAgent.ps1 Check -SubscriptionId <guid>
./scripts/Invoke-CopilotCloudAgent.ps1 Remove -SubscriptionId <guid>
```

Configure refuses to adopt a resource group it does not own or overwrite a credential
with a different subject. Remove deletes role assignments, the owned group, the Agents
secrets, the `copilot` environment and local state under `.azure/` (gitignored).
Checkout `Down` deletes its resource group, which removes a Reader assignment scoped to
it.

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
