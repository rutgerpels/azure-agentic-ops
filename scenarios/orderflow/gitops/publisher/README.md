# OrderFlow GitHub App issue publisher

Small, stateless Streamable HTTP MCP server. It exposes **only**
`find_incident_issue` and `publish_incident_issue`. GitHub App installation
authentication is mandatory; there is no PAT, arbitrary HTTP proxy, repository
parameter, context reader, assignee, label parameter, workflow dispatch or
Copilot assignment.

## Deployment contract

Build with this directory as the Docker context; serve port **8080** behind
HTTPS. Configure the remote MCP connector URL as **`https://<host>/mcp`** and
its custom **`x-orderflow-key`** header from the same secret used below.
`GET /healthz` is an unauthenticated liveness check only, not a dependency check.
No cloud resources or settings are created by this application.

| Required environment variable | Value |
| --- | --- |
| `GITHUB_APP_ID` | GitHub App client ID (recommended) or numeric App ID |
| `GITHUB_INSTALLATION_ID` | Numeric App installation ID |
| `GITHUB_REPOSITORY_ID` | Numeric ID of the single permitted repository |
| `GITHUB_REPOSITORY` | Fixed `owner/name` |
| `GITHUB_APP_PRIVATE_KEY` | Actual RSA PEM, supplied through a platform Key Vault secret reference; no path or secret URI |
| `ORDERFLOW_PUBLISHER_KEY` | Cryptographically random base64url secret, 32–256 characters (at least 32 random bytes recommended) |
| `AZURE_CLIENT_ID` | Publisher's user-assigned managed identity client GUID |
| `ORDERFLOW_RECEIPT_ACCOUNT_URL` | Fixed `https://<account>.blob.core.windows.net`, without path or SAS |
| `ORDERFLOW_RECEIPT_CONTAINER` | Pre-provisioned private Blob container, normally `incidents` |
| `ORDERFLOW_GENERATION` | Fixed lowercase owner GUID for this deployment generation |

Optional `ORDERFLOW_PUBLISHER_PUBLIC_ORIGIN=https://<host>` permits that exact
browser Origin and restricts Host to its hostname. Without it, **all requests
containing Origin are rejected**; server-to-server requests without Origin work.
Do not enable permissive CORS. Enforce the expected host and HTTPS at ingress.
The custom header is connector authentication, not an OAuth implementation.

The App needs repository **Issues: write** (GitHub's implicit Metadata: read
remains). Install it only on the chosen repository. Each minted installation
token explicitly requests only `repository_ids: [GITHUB_REPOSITORY_ID]` and
`permissions: {"issues":"write"}`. Before using a new token, the publisher reads
`GET /repos/<configured owner/name>` and checks both ID and full name. JWTs use
RS256, a backdated `iat`, and expiry nine minutes ahead. Installation tokens
refresh before expiry; failed GitHub operations are never automatically replayed.
JWTs, installation tokens, keys and issue bodies are not logged.

The managed identity needs data-plane read/create/update permission on the
receipt container (for example **Storage Blob Data Contributor scoped to that
container**). It does not need Azure management-plane writes. Secret-reference
resolution is the hosting platform's responsibility; there is no Key Vault SDK
or developer credential fallback. Keep receipts across restarts, revisions and
unknown outcomes. Never delete or expire receipts to force another attempt.
All replicas/revisions for one generation must use the same container and
repository ID. Disable old revisions before changing owner generations.

## Approval, inputs and no replay

The SRE integration must put **publish** behind a native, enforced human approval
card. Do not treat prose assent or a model-supplied boolean as approval. This
server authenticates the connector, not the human: anyone holding its key can
publish within the fixed scope. Configure approval enforcement before exposing
the tool, keep the connector key private and rotate it if compromised.

Both tools take `incident_key`, which **must exactly equal `ORDERFLOW_GENERATION`**.
There is one fault/issue attempt per owner generation; callers cannot invent
new keys to bypass unknown outcomes. Publish additionally requires `title`
(1–200 characters, single line) and `body` (1–24,000 characters, synthetic
evidence only). Unknown fields, alternate repositories, labels, assignees,
control characters and injected key markers are rejected. The server appends:

```text
<!-- orderflow-incident-key:<ORDERFLOW_GENERATION> -->
```

GitHub reads use issue GET endpoints, never the eventually indexed search API.
The bounded listing includes open and closed `orderflow-incident` issues and
excludes pull requests. At most five pages of 100 items are scanned; a full
fifth page or multiple matches returns **unknown**, never permission to create.

Before any issue POST, a Blob `upload_blob(overwrite=False)` durably reserves
`github-<repository ID>/<generation>.json`. A collision triggers observation,
not another POST. A reservation timeout, issue timeout, rejected/redirected
write, process death or failed receipt confirmation can leave a pending receipt.
Subsequent calls reconcile it against GitHub by marker (or issue-number GET for
a completed receipt). If not observed, they return **unknown** and never issue
a second POST. Even a known rejection after reservation consumes the attempt:
availability is deliberately sacrificed for no replay.

Receipts contain only `{"key": "<GUID>", "issue": null}` or the key and an issue
`{"number": ..., "url": ...}` reference, never issue text or credentials.
`find_incident_issue` does not mutate receipts or GitHub. Results are
`not_found`, `found`, `published`, or `unknown`; unknown is an MCP tool result
with `isError: true`. `not_found` from a plain find is not approval to publish.
Operators must investigate unresolved pending receipts out of band, not clear
them, change the key, resubmit or assume failure. A new presenter-approved
rehearsal needs a fresh owned deployment generation.

## Protocol and bounds

Supported MCP versions: `2025-03-26`, `2025-06-18`, `2025-11-25`. Initialize
negotiates a supported version, `notifications/initialized` returns empty 202,
and requests return JSON-RPC 2.0 JSON responses. Clients send
`Accept: application/json, text/event-stream`, `Content-Type: application/json`
and the negotiated `MCP-Protocol-Version` header on subsequent POSTs. Without
the version header, the compatibility default is `2025-03-26`. No sessions,
server-initiated requests, SSE stream, batch requests, resources or prompts.
Authenticated GET/DELETE `/mcp` returns 405.

Inbound bodies are capped at 64 KiB with a ten-second read deadline. GitHub
responses are capped at 8 MiB, use five-second connection and fifteen-second
I/O timeouts, and a thirty-second streaming deadline checked between reads.
Blob operations have five-second connection, ten-second socket/service
timeouts, no retries, and receipt reads are capped at 4 KiB. GitHub redirects,
environment proxy inheritance and transport retries are disabled. The scan is
bounded by pages, not an unbounded total history traversal. Put a suitable
overall ingress request deadline and rate/concurrency limit in front of this
private connector; the application is not a public multi-tenant gateway.

Runtime pins: FastAPI `0.143.0`, httpx `0.28.1` (repository pins), uvicorn
`0.54.0`, PyJWT `[crypto]` `2.15.1`, azure-identity `1.27.0`,
azure-storage-blob `12.31.1`. PyJWT and Azure package releases were checked
against PyPI on 2026-11-02. Dependency installation still resolves transitive
versions; release images should be built, scanned and pinned by digest.

## Offline validation

From the repository root, using an environment containing this directory's
requirements and the repository's pytest/ruff development pins:

```powershell
python -m pytest scenarios\orderflow\gitops\publisher\tests -q
python -m ruff check scenarios\orderflow\gitops\publisher
```

Tests generate an in-memory RSA key and mock GitHub's HTTP transport and the
receipt interface/Blob clients. They never use live credentials or create live
resources. These tests are not proof of App installation permissions, managed
identity/RBAC propagation, secret-reference resolution, native SRE approval,
connector interoperability, Container Apps ingress or live recovery. Those
require separately authorized integration validation.

Authoritative contracts:
[MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[GitHub App JWT](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app),
[installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app),
[BlobClient](https://learn.microsoft.com/python/api/azure-storage-blob/azure.storage.blob.blobclient),
[ManagedIdentityCredential](https://learn.microsoft.com/python/api/azure-identity/azure.identity.managedidentitycredential).
