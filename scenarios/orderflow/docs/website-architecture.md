# Storefront architecture panel

Choose **Architecture** on the storefront. Select a service in the SVG or use
the equivalent labelled buttons to explore services and directional flows.
The native modal supports keyboard navigation, Escape, focus containment and
return to its opener. On small screens the diagram scrolls within the panel;
the service/flow buttons and explanation remain readable without diagram zoom.
Animation is opt-in, respects reduced motion and illustrates direction only.

## Topology and incident evidence

`/api/architecture` returns only `direct` or `gitops`, derived from the portal's
already allowlisted API target. It makes no infrastructure call.

| Variant | Customer request path | Human-controlled recovery |
| --- | --- | --- |
| Direct repair | Browser -> App Service -> private VM order API -> Cosmos DB via service endpoint | Native SRE approval before the owned inbound NSG rule repair |
| GitOps | Browser -> public Container App -> internal API Container App -> private Cosmos DB endpoint | SRE issue, human assigns Copilot, tested PR, human merge/release |

Test and production GitOps stages use the same diagram, not a cross-stage
traffic path. Supporting build/registry and issue-publisher services are
explained in the human-handoff details, not drawn as customer request hops.
Monitor and SRE arrows describe configured operations, not live agent activity.

The panel reuses this browser's existing `/healthz`, `/api/health` and HTTP 503
results; it does not add probes or submit orders. A healthy dependency check
verifies an API/database read, not a new order. HTTP 503 highlights the combined
dependency path, **not an independently confirmed failed VM, NSG rule or Cosmos
service**. Other unusable responses are unknown. Samples expire after 30 seconds.
Fresh healthy evidence after failure shows observed recovery, never proof of
an SRE repair. Unknown orders retain their existing receipt-only reconciliation.

## Publish without bypassing lifecycle gates

No Azure deployment is performed by adding these files.

- **GitOps:** after normal human source review, the existing
  `orderflow-gitops-cd.yml` builds the changed content-addressed image and deploys
  production through its existing gates. Publish the matching image to test
  using the documented `orderflow-gitops-test-deploy.yml` flow when required.
  The Dockerfile and image tag already include every flat `app/static` file.
- **Direct repair:** the existing `orderflow-publish.yml` / `Publish-OrderFlow.ps1`
  path packages the full `static` directory. Source hashing now includes all
  flat static assets. Existing ownership/source-generation checks remain in
  force: do not replace a retained source hash or rearm a used generation.
  If a changed source is refused, use a fresh authorized environment generation
  per [the direct-repair guide](direct-repair.md).

Run the app tests and cross-scenario UI evidence contracts from the repository root:

```powershell
.\.venv\Scripts\python.exe -m pytest scenarios\orderflow\tests\test_app.py tests\test_website_architecture.py
pwsh -NoProfile -File scenarios\orderflow\tests\Test-OrderFlow.ps1
```

The UI contracts use Node's built-in modules when Node is available; no npm
package or browser library is required. Native layout and modal behavior need
a real-browser check. Offline checks are not Azure acceptance.

## Azure icon provenance and permitted use

The unmodified SVGs are from Microsoft's
[Azure Architecture Center icon collection](https://learn.microsoft.com/azure/architecture/icons/),
[V25 archive](https://arch-center.azureedge.net/icons/Azure_Public_Service_Icons_V25.zip),
retrieved 16 November 2026. They are displayed only within the service diagram,
with adjacent Azure product names and visible Microsoft attribution.

| Local asset | Archive file under `Azure_Public_Service_Icons/Icons/` |
| --- | --- |
| `azure-app-service.svg` | `app services/10035-icon-service-App-Services.svg` |
| `azure-container-apps.svg` | `other/02884-icon-service-Worker-Container-App.svg` |
| `azure-vm.svg` | `compute/10021-icon-service-Virtual-Machine.svg` |
| `azure-cosmos.svg` | `databases/10121-icon-service-Azure-Cosmos-DB.svg` |
| `azure-monitor.svg` | `monitor/00001-icon-service-Monitor.svg` |

Microsoft permits copying, distributing and displaying these icons in
architectural diagrams, training materials or documentation only, unless
explicit permission is granted; Microsoft reserves all other rights.
Do not crop, flip, rotate, distort, change their shape or use them to represent
the demo's own product. Neutral text symbols represent browsers, humans,
GitHub and SRE Agent rather than inventing product icons. No runtime external
icon request or diagram dependency is added.
