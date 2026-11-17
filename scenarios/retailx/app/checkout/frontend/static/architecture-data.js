"use strict";
window.architectureModel = {
  assets: "/",
  evidence: {web: "Web till process / route configuration", BE: "Belgium price lookup", NL: "Netherlands price lookup"},
  async load() {
    return {
      caption: "Hybrid checkout: an Azure VM simulates on-premises services. Peering is not a VPN. Arc, agents and the read-only Foundry assistant are optional.",
      nodes: [
        {id: "browser", x: 20, y: 45, label: "Demo browser", sub: "BE / NL web till", detail: "Synthetic purchases only. This architecture observes this browser's real checkout results; it does not place orders or poll price services."},
        {id: "web", x: 245, y: 45, label: "Azure App Service", sub: "Checkout API + till", icon: "app-service", keys: ["web"], detail: "The public web till selects PRICE_ROUTE_BE or PRICE_ROUTE_NL. /health reads process/configuration only, not backend availability. A working till does not prove prices are reachable."},
        {id: "prices", x: 695, y: 45, label: "Azure Virtual Machine", sub: "Simulated datacenter", icon: "vm", keys: ["BE", "NL"], detail: "One private VM hosts erp-price-service (primary), legacy-price-gateway (slow), and BE/NL POS simulators. VNet peering joins cloud and simulated datacenter. HTTP 503 indicates the selected price path failed, not a confirmed stopped service."},
        {id: "monitor", x: 245, y: 280, label: "Azure Monitor", sub: "App Insights / logs", icon: "monitor", detail: "Application Insights checkout/dependency spans, Log Analytics, latency alerts and workbooks. Arc deployments also collect guest service evidence. This panel does not query these systems."},
        {id: "sre", x: 470, y: 280, label: "Azure SRE Agent", sub: "Optional / human gated", detail: "Not deployed in AlertsOnly mode. Latency repair restores the Belgian primary route; the service scenario uses a guarded Arc command. Native human approval remains required. The optional GitHub/Copilot code loop retains branch and reviewer gates."},
        {id: "arc", x: 695, y: 280, label: "Azure Arc", sub: "Optional guest control", icon: "arc", detail: "Only WithArc deployments support the guarded service-repair path. Azure Monitor Agent supplies guest evidence. No Arc status, approval or command is available to website visitors. The optional Foundry assistant is separately deployed and read-only, not a checkout dependency."}
      ],
      flows: [
        {id: "visit", from: "browser", to: "web", label: "HTTPS checkout", keys: ["web"], detail: "The web browser calls /checkout. Synthetic POS simulators on the VM also call the public checkout API; they do not supply this browser's evidence."},
        {id: "belgium", from: "web", to: "prices", label: "BE price route", keys: ["BE"], bend: -30, detail: "Belgian requests select primary or legacy from app configuration. A successful checkout reports the actual priceRoute and priceLookupMs. A slow lookup is observed latency, not proof of an NSG or service fault."},
        {id: "netherlands", from: "web", to: "prices", label: "NL price route", keys: ["NL"], bend: 75, detail: "Dutch requests select their own route. Only a checkout for NL establishes NL evidence; a Belgian failure never marks Dutch checkouts failed."},
        {id: "telemetry", from: "web", to: "monitor", label: "Spans / telemetry", kind: "ops", detail: "Checkout API dependency spans and optional browser telemetry feed Application Insights. Animated dashes are illustrative, not live data or confirmed ingestion."},
        {id: "alert", from: "monitor", to: "sre", label: "Alerts / optional SRE", kind: "ops", detail: "Latency alerts support investigation; AlertsOnly omits agents. This diagram does not discover installed optional components or report SRE progress."},
        {id: "approve", from: "sre", to: "arc", label: "Approved guest action", kind: "ops", detail: "WithArc only: a native approval card precedes the guarded service command. Latency routing repair instead changes App Service configuration. This website cannot repair or approve anything."},
        {id: "guest", from: "arc", to: "prices", label: "Guest service action", kind: "ops", detail: "WithArc only: Azure Arc delivers the bounded, approved service action to the VM's guarded controller. Fresh service and BE/NL customer evidence is required before declaring recovery. This diagram does not read command or approval status."}
      ]
    };
  }
};
