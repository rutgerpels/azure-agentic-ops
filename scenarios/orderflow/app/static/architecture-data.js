"use strict";
window.architectureModel = {
  assets: "/static/",
  evidence: {
    portal: "Browser to storefront",
    dependency: "Order API + Cosmos DB dependency path"
  },
  async load() {
    const response = await fetch("/api/architecture", {cache: "no-store", signal: AbortSignal.timeout(5500)});
    if (!response.ok) throw new Error("Deployment variant unavailable.");
    const {variant} = await response.json();
    if (!["direct", "gitops"].includes(variant)) throw new Error("Unknown deployment variant.");
    const gitops = variant === "gitops";
    return {
      caption: gitops
        ? "Option 2 / GitOps: Azure Container Apps, private Cosmos endpoint; same topology in test and production."
        : "Option 1 / Direct repair: Azure App Service, private VM order API, Cosmos DB service endpoint.",
      nodes: [
        {id: "browser", x: 20, y: 55, label: "Demo browser", sub: "Synthetic merch", detail: "Catalog reads, one-shot orders and receipt lookups. A timed-out order is unknown: read its request ID, never replay it."},
        {id: "portal", x: 245, y: 55, label: gitops ? "Azure Container Apps" : "Azure App Service", sub: "Public storefront", icon: gitops ? "container-apps" : "app-service", keys: ["portal"], detail: "The public portal remains reachable when its dependency fails. Process health alone does not establish that ordering works."},
        {id: "api", x: 470, y: 55, label: gitops ? "Azure Container Apps" : "Azure Virtual Machine", sub: "Private order API", icon: gitops ? "container-apps" : "vm", keys: ["dependency"], detail: "Private FastAPI order API. Health reads the database. A failed end-to-end check identifies this dependency path, not which individual service or network rule caused it."},
        {id: "cosmos", x: 695, y: 55, label: "Azure Cosmos DB", sub: gitops ? "Private endpoint" : "Service endpoint", icon: "cosmos", detail: "Real synthetic catalog and receipt documents, accessed using managed identity. This browser has no direct database or NSG inspection; a failed health check is not proof Cosmos DB itself is down."},
        {id: "monitor", x: 245, y: 280, label: "Azure Monitor", sub: "App Insights / logs", icon: "monitor", detail: "Application Insights dependency events feed Log Analytics and a scheduled-query alert. This panel does not query Azure Monitor, alert state or SRE activity."},
        {id: "sre", x: 470, y: 280, label: "Azure SRE Agent", sub: gitops ? "Investigate / issue" : "Native approval", detail: gitops ? "SRE investigates and publishes an incident issue through the configured publisher. Issue publication is not assignment or repair; a human manually assigns Copilot." : "SRE investigates and requests native human approval before a narrowly scoped NSG rule repair. This website cannot approve or execute it."},
        {id: "human", x: 695, y: 280, label: gitops ? "GitHub + human" : "Human reviewer", sub: gitops ? "Copilot / test / release" : "Approve exact repair", detail: gitops ? "Human assigns Copilot, reviews the fix and test evidence, then merges for release. GitHub Actions uses gated identities; build/registry and issue-publisher infrastructure are supporting services, not customer request hops." : "The exact native SRE approval card gates the owned NSG rule change. Text assent or healthy telemetry is not approval."}
      ],
      flows: [
        {id: "visit", from: "browser", to: "portal", label: "HTTPS", keys: ["portal"], detail: "Browser to public storefront over HTTPS; the browser observes process health separately from backend health."},
        {id: "orders", from: "portal", to: "api", label: gitops ? "Internal HTTP" : "NSG / HTTP", keys: ["dependency"], detail: gitops ? "Portal calls the internal Container Apps order API using a fresh connection. Dependency health covers both this hop and the database read." : "Portal VNet integration reaches the private VM API. The direct-repair fault blocks this NSG-controlled hop. A browser failure alone does not verify the rule changed."},
        {id: "data", from: "api", to: "cosmos", label: gitops ? "NSG / private link" : "HTTPS / identity", keys: ["dependency"], detail: gitops ? "API reaches Cosmos DB through the stage's private endpoint. The GitOps hardening regression denies this outbound data path. The current rule and root cause are not inspected here." : "API uses managed identity and the Cosmos DB service endpoint. A failed dependency check cannot isolate database, API or network health."},
        {id: "telemetry", from: "portal", to: "monitor", label: "Dependency events", kind: "ops", detail: "Portal and API emit real dependency telemetry to Application Insights / Log Analytics. The line is a documented telemetry path, not a live ingestion indicator."},
        {id: "alert", from: "monitor", to: "sre", label: "Alert / investigate", kind: "ops", detail: "Repeated dependency failures feed an Azure Monitor alert and SRE investigation. Neither alert status nor agent activity is fetched by this panel."},
        {id: "repair", from: "sre", to: "human", label: gitops ? "Issue / human handoff" : "Approval request", kind: "ops", detail: gitops ? "SRE issue -> human assigns Copilot -> tested fix PR -> human merge and release. No automated assignment or infrastructure control is exposed here." : "SRE requests the exact native approval card before a scoped NSG repair. No action runs from this diagram."}
      ]
    };
  }
};
