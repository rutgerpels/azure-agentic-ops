// Minimal DOM for deterministic evidence tests. Native dialog/layout is checked in a browser.
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = process.argv[2];

class Element {
  constructor() {
    this.children = [];
    this.attributes = {};
    this.events = {};
    this.classes = new Set();
    this.classList = {
      toggle: (name, force = !this.classes.has(name)) => {
        force ? this.classes.add(name) : this.classes.delete(name);
        return force;
      },
      contains: (name) => this.classes.has(name)
    };
    this.value = "BE-101";
    this.selectedOptions = [{textContent: "BE-101"}];
  }
  append(...nodes) { this.children.push(...nodes); }
  prepend(...nodes) { this.children.unshift(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === "class") this.classes = new Set(value.split(" "));
  }
  querySelector(selector) {
    return this.children.find((child) => child.classes.has(selector.slice(1)));
  }
  addEventListener(name, callback) { this.events[name] = callback; }
  focus() { this.focused = true; }
  showModal() { this.open = true; }
  close() { this.open = false; this.events.close?.(); }
}

function environment() {
  const elements = new Map();
  const get = (id) => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  let now = 100000;
  const timers = new Map();
  const context = vm.createContext({
    console, Map, Set, AbortSignal, performance: {now: () => now},
    Date: class extends Date { static now() { return now; } },
    document: {
      getElementById: get, createElement: () => new Element(),
      createElementNS: () => new Element(),
      querySelectorAll: () => [get("architecture-open")],
      addEventListener() {}, dispatchEvent() {},
    },
    Event: class {}, setInterval: (callback) => { timers.set(callback, callback); return callback; },
    clearInterval: (id) => timers.delete(id), setTimeout() {}, clearTimeout() {},
  });
  context.window = context;
  return {context, get, timers, advance: (ms) => { now += ms; }};
}
function run(file, env) { vm.runInContext(readFileSync(path.join(root, file), "utf8"), env.context); }
const scripts = [
  ["scenarios/orderflow/app/static", "dependency", "api"],
  ["scenarios/retailx/app/checkout/frontend/static", "BE", "prices"]
];
async function architectureTests() {
  for (const [directory, key, backend] of scripts) {
    for (const variant of directory.includes("orderflow") ? ["direct", "gitops"] : ["hybrid"]) {
      const env = environment();
      let configCalls = 0;
      env.context.fetch = async (url) => {
        assert.equal(url, "/api/architecture");
        configCalls++;
        return {ok: true, json: async () => ({variant})};
      };
      run(`${directory}/architecture-data.js`, env);
      run(`${directory}/architecture.js`, env);
      await env.get("architecture-open").events.click();
      const svg = env.get("architecture-svg");
      const node = svg.children.find((item) => item.attributes["data-item"] === backend);
      const evidence = () => env.get("architecture-evidence").children.map((item) => item.textContent).join(" ");
      assert.match(evidence(), /unknown/);
      if (variant !== "hybrid") {
        assert.match(env.get("architecture-variant").textContent, variant === "gitops" ? /Container Apps/ : /App Service/);
      }
      env.context.DemoArchitecture.observe(key, "failed", "Observed HTTP 503; root cause unconfirmed.");
      assert.equal(node.classes.has("failed"), true);
      assert.match(evidence(), /root cause unconfirmed/);
      node.events.keydown({key: "Enter", preventDefault() {}});
      assert.match(env.get("architecture-detail").textContent, /not|cannot/);
      env.context.DemoArchitecture.observe(key, "healthy", "Read succeeded.");
      assert.equal(node.classes.has("failed"), false);
      assert.match(evidence(), /Recovery observed/);
      env.context.DemoArchitecture.observe(key, "slow", "Lookup took 2100 ms.");
      assert.equal(node.classes.has("slow"), true);
      env.advance(30001);
      for (const callback of env.timers.values()) callback();
      assert.equal(node.classes.has("slow"), false);
      assert.match(evidence(), /Stale evidence/);
      env.get("architecture-motion").events.click();
      assert.equal(env.get("architecture-dialog").classes.has("animating"), true);
      env.get("architecture-close").events.click();
      assert.equal(env.timers.size, 0);
      assert.equal(env.get("architecture-open").focused, true);
      assert.equal(configCalls, variant === "hybrid" ? 0 : 1);
    }
  }
}
async function checkoutTests() {
  const env = environment();
  const observed = [];
  env.context.DemoArchitecture = {observe: (...args) => observed.push(args)};
  run("scenarios/retailx/app/checkout/frontend/static/till.js", env);
  vm.runInContext('basket.set("MILK-1L", 1)', env.context);
  let mode = "failed";
  env.context.fetch = async () => ({
    ok: mode !== "failed", status: mode === "failed" ? 503 : 200,
    json: async () => ({total: 2.49, priceRoute: "primary", priceLookupMs: mode === "slow" ? 2000 : 25})
  });
  await vm.runInContext("pay()", env.context);
  assert.deepEqual(observed.at(-1).slice(0, 2), ["BE", "failed"]);
  mode = "slow";
  await vm.runInContext("pay()", env.context);
  assert.deepEqual(observed.at(-1).slice(0, 2), ["BE", "slow"]);
  mode = "healthy";
  await vm.runInContext("pay()", env.context);
  assert.deepEqual(observed.at(-1).slice(0, 2), ["BE", "healthy"]);
  env.context.fetch = async () => ({
    ok: true, json: async () => ({status: "ok", routes: {BE: "legacy", NL: "primary"}})
  });
  await vm.runInContext("architectureProcessHealth()", env.context);
  assert.deepEqual(observed.at(-2).slice(0, 2), ["BE", "unknown"]);
  assert.match(observed.at(-2)[2], /route changed/);

  let finishCheckout;
  env.context.fetch = () => new Promise((resolve) => { finishCheckout = resolve; });
  const pendingCheckout = vm.runInContext("pay()", env.context);
  env.context.fetch = async () => ({
    ok: true, json: async () => ({status: "ok", routes: {BE: "primary", NL: "primary"}})
  });
  await vm.runInContext("architectureProcessHealth()", env.context);
  finishCheckout({ok: true, json: async () => ({total: 2.49, priceRoute: "legacy", priceLookupMs: 25})});
  await pendingCheckout;
  assert.deepEqual(observed.at(-1).slice(0, 2), ["BE", "unknown"]);
  assert.match(observed.at(-1)[2], /changed during checkout/);
  env.context.fetch = async () => ({
    ok: true, json: async () => ({total: 2.49, priceRoute: "legacy", priceLookupMs: 25})
  });
  await vm.runInContext("pay()", env.context);
  assert.deepEqual(observed.at(-1).slice(0, 2), ["BE", "unknown"]);
  assert.match(observed.at(-1)[2], /differs from current configuration/);
  env.context.fetch = async () => { throw new Error("offline"); };
  await vm.runInContext("pay()", env.context);
  assert.deepEqual(observed.at(-1).slice(0, 2), ["BE", "unknown"]);
  assert.equal(observed.some(([country]) => country === "NL"), false);
}
(async () => {
  await architectureTests();
  await checkoutTests();
  console.log("Architecture evidence, variant, keyboard, stale and checkout contracts passed.");
})().catch((error) => { console.error(error); process.exitCode = 1; });
