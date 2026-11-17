"use strict";
(() => {
  const model = window.architectureModel;
  const $ = (id) => document.getElementById(id);
  const dialog = $("architecture-dialog");
  const svg = $("architecture-svg");
  const observations = new Map();
  const failedBefore = new Set();
  const FRESH_MS = 30000;
  let topology;
  let selected = null;
  let clock;
  let opener;
  let evidenceText = "";
  const items = new Map();
  const drawings = new Map();
  const buttons = new Map();

  function sample(key) {
    const value = observations.get(key);
    if (!value) return {state: "unknown", text: "Not observed yet."};
    if (Date.now() - value.at > FRESH_MS) return {state: "unknown", text: `Stale evidence (${new Date(value.at).toLocaleTimeString()}). Check again; current state is unknown.`};
    return value;
  }
  function state(item) {
    const states = (item.keys || []).map((key) => sample(key).state);
    return ["failed", "slow", "unknown", "healthy"].find((value) => states.includes(value)) || "unobserved";
  }
  function refresh() {
    for (const [id, item] of items) {
      const active = selected === id || (topology.flows.find((flow) => flow.id === id) &&
        [item.from, item.to].includes(selected));
      const drawing = drawings.get(id);
      drawing.classList.toggle("selected", Boolean(active));
      for (const value of ["failed", "slow", "unknown", "healthy"]) drawing.classList.toggle(value, state(item) === value);
      buttons.get(id).setAttribute("aria-pressed", String(selected === id));
      if (drawing.classList.contains("architecture-node")) drawing.setAttribute("aria-pressed", String(selected === id));
      const badge = drawing.querySelector(".architecture-state");
      if (badge) badge.textContent = item.keys ? `Observed path: ${state(item)}` : "Topology only / not monitored here";
    }
    const keys = selected ? items.get(selected).keys || [] : Object.keys(model.evidence);
    const messages = (keys.length ? keys : Object.keys(model.evidence)).map((key) => {
      const value = sample(key);
      const time = value.at ? ` Checked ${new Date(value.at).toLocaleTimeString()}.` : "";
      return {state: value.state, text: `${model.evidence[key]}: ${value.state}. ${value.text}${time}`};
    });
    const text = JSON.stringify(messages);
    if (text !== evidenceText) {
      $("architecture-evidence").replaceChildren(...messages.map((message) => {
        const p = document.createElement("p");
        p.className = message.state;
        p.textContent = message.text;
        return p;
      }));
      evidenceText = text;
    }
  }
  window.DemoArchitecture = {
    observe(key, status, text) {
      if (!(key in model.evidence)) return;
      if (["failed", "slow"].includes(status)) failedBefore.add(key);
      const recovered = status === "healthy" && failedBefore.has(key);
      observations.set(key, {state: status, text: recovered ? `Recovery observed on this path. ${text} This does not verify an SRE action.` : text, at: Date.now()});
      if (dialog.open) refresh();
    }
  };
  function select(id) {
    selected = id;
    $("architecture-detail-title").textContent = items.get(id).label;
    $("architecture-detail").textContent = items.get(id).detail;
    refresh();
  }
  function shape(tag, attributes, text) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    if (text) node.textContent = text;
    return node;
  }
  function draw() {
    const defs = shape("defs", {});
    const marker = shape("marker", {id: "architecture-arrow", viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 6, markerHeight: 6, orient: "auto-start-reverse"});
    marker.append(shape("path", {d: "M 0 0 L 10 5 L 0 10 z", fill: "#718198"}));
    defs.append(marker);
    svg.append(defs);
    for (const flow of topology.flows) {
      const from = topology.nodes.find((node) => node.id === flow.from);
      const to = topology.nodes.find((node) => node.id === flow.to);
      const vertical = from.x === to.x;
      const down = to.y > from.y;
      const x1 = from.x + (vertical ? 90 : 180), y1 = from.y + (vertical ? (down ? 100 : 0) : 50);
      const x2 = to.x + (vertical ? 90 : 0), y2 = to.y + (vertical ? (down ? 0 : 100) : 50);
      const bend = flow.bend || 0;
      const path = vertical ? `M ${x1} ${y1} L ${x2} ${y2}` :
        `M ${x1} ${y1} Q ${(x1 + x2) / 2} ${y1 + bend * 2} ${x2} ${y2}`;
      const group = shape("g", {class: `architecture-flow ${flow.kind || ""}`, "data-item": flow.id});
      group.append(shape("path", {d: path}), shape("text", {x: (x1 + x2) / 2 + (vertical ? 8 : 0), y: vertical ? (y1 + y2) / 2 : y1 - 65 + (bend > 0 ? 130 : 0), "text-anchor": vertical ? "start" : "middle"}, flow.label));
      svg.append(group);
      drawings.set(flow.id, group);
    }
    for (const node of topology.nodes) {
      const group = shape("g", {class: "architecture-node", transform: `translate(${node.x} ${node.y})`, role: "button", tabindex: 0, "aria-label": `${node.label}: ${node.sub}`, "data-item": node.id});
      group.append(shape("rect", {width: 180, height: 100, rx: 12}));
      if (node.icon) group.append(shape("image", {href: `${model.assets}azure-${node.icon}.svg`, x: 72, y: 10, width: 36, height: 36, "aria-hidden": "true"}));
      else group.append(shape("text", {x: 90, y: 36, "text-anchor": "middle", "aria-hidden": "true"}, node.id === "browser" ? "[ web ]" : "[ human / agent ]"));
      group.append(shape("text", {x: 90, y: 66, "text-anchor": "middle"}, node.label),
        shape("text", {class: "architecture-sub", x: 90, y: 85, "text-anchor": "middle"}, node.sub),
        shape("text", {class: "architecture-sub architecture-state", x: 90, y: 119, "text-anchor": "middle"}));
      group.addEventListener("click", () => select(node.id));
      group.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") { event.preventDefault(); select(node.id); }
      });
      svg.append(group);
      drawings.set(node.id, group);
    }
    for (const item of [...topology.nodes, ...topology.flows]) {
      items.set(item.id, item);
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = item.label;
      button.setAttribute("aria-pressed", "false");
      button.addEventListener("click", () => select(item.id));
      $("architecture-choices").append(button);
      buttons.set(item.id, button);
    }
    refresh();
  }
  let loading;
  async function load() {
    try {
      topology = await model.load();
      $("architecture-variant").textContent = topology.caption;
      draw();
    } catch {
      $("architecture-variant").textContent = "Architecture could not load. Close and reopen to retry. Application behavior is unchanged.";
      topology = null;
    }
  }
  document.querySelectorAll("[data-architecture-open]").forEach((button) => button.addEventListener("click", async () => {
    opener = button;
    dialog.showModal();
    document.dispatchEvent(new Event("architecture-open"));
    if (!topology) {
      loading ||= load().finally(() => { loading = null; });
      await loading;
    }
    if (!dialog.open) return;
    refresh();
    clearInterval(clock);
    clock = setInterval(refresh, 1000);
  }));
  $("architecture-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => {
    clearInterval(clock);
    opener.focus();
    document.dispatchEvent(new Event("architecture-close"));
  });
  $("architecture-motion").addEventListener("click", () => {
    const moving = dialog.classList.toggle("animating");
    $("architecture-motion").setAttribute("aria-pressed", String(moving));
    $("architecture-motion").textContent = moving ? "Pause animation" : "Animate selected flow";
  });
})();
