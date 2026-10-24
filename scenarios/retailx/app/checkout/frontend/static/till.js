"use strict";

const PRODUCTS = [
  { sku: "MILK-1L", name: "Fresh milk 1 L", icon: "🥛" },
  { sku: "BREAD-800", name: "Sourdough 800 g", icon: "🍞" },
  { sku: "COFFEE-500", name: "Coffee beans 500 g", icon: "☕" },
  { sku: "APPLE-1KG", name: "Apples 1 kg", icon: "🍎" },
  { sku: "CHEESE-400", name: "Aged cheese 400 g", icon: "🧀" },
];
const SHELF_PRICE = 2.49;
const AI_SDK = {
  src: "https://js.monitor.azure.com/scripts/b/ai.3.4.4.gbl.min.js",
  integrity: "sha384-StHgVQoR6nIJMQwVfWcIZjDF0yvNpPgoTVaSD2+oVWXwuXnHkuUvOkpd8dSTLJmB",
};
const GOOD_MS = 500;
const SLOW_MS = 1000;

const basket = new Map();
const $ = (id) => document.getElementById(id);
const euro = (value) => `€${value.toFixed(2)}`;
const grade = (ms) => (ms < GOOD_MS ? "good" : ms < SLOW_MS ? "slow" : "bad");
let appInsights = null;
let paying = false;
let checkoutFailed = false;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderShelf() {
  const shelf = $("products");
  for (const product of PRODUCTS) {
    const button = element("button", "product");
    button.type = "button";
    button.append(element("span", "icon", product.icon), element("span", "name", product.name),
      element("span", "sku", product.sku), element("span", "price", euro(SHELF_PRICE)));
    button.addEventListener("click", () => {
      basket.set(product.sku, Math.min((basket.get(product.sku) || 0) + 1, 20));
      renderBasket();
    });
    shelf.append(button);
  }
}

function renderBasket() {
  const lines = $("lines");
  lines.replaceChildren();
  let total = 0;
  for (const [sku, quantity] of basket) {
    const product = PRODUCTS.find((item) => item.sku === sku);
    const row = element("li");
    const remove = element("button", "remove", "✕");
    remove.type = "button";
    remove.setAttribute("aria-label", `Remove ${product.name}`);
    remove.addEventListener("click", () => { basket.delete(sku); renderBasket(); });
    row.append(element("span", "qty", `${quantity}×`), element("span", "", `${product.icon} ${product.name}`),
      element("strong", "", euro(quantity * SHELF_PRICE)), remove);
    lines.append(row);
    total += quantity * SHELF_PRICE;
  }
  $("total").textContent = euro(total);
  $("empty").hidden = basket.size > 0;
  $("pay").disabled = basket.size === 0;
}

async function checkoutLine(store, sku, quantity) {
  const response = await fetch("/checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ country: store.slice(0, 2), store, sku, quantity, channel: "web" }),
  });
  if (!response.ok) {
    const error = new Error(`Checkout failed (${response.status})`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

async function pay() {
  if (paying) return;
  paying = true;
  $("pay").disabled = true;
  const store = $("store").value;
  const screen = $("screen");
  screen.className = "screen";
  screen.hidden = false;
  $("receipt").hidden = true;
  $("terminal").hidden = false;
  $("terminal-title").textContent = "Processing payment";
  $("terminal-hint").textContent = "Checking prices…";
  const started = performance.now();
  const ticker = setInterval(() => {
    const elapsed = performance.now() - started;
    $("elapsed").textContent = (elapsed / 1000).toFixed(1);
    screen.className = `screen ${grade(elapsed)}`;
    if (elapsed > SLOW_MS) $("terminal-hint").textContent = "Still waiting for the price service…";
  }, 100);

  let results = [];
  let error = null;
  try {
    results = await Promise.all([...basket].map(([sku, quantity]) => checkoutLine(store, sku, quantity)));
  } catch (caught) {
    error = caught;
  }
  clearInterval(ticker);
  paying = false;
  $("pay").disabled = basket.size === 0;
  checkoutFailed = Boolean(error);
  const elapsedMs = Math.round(performance.now() - started);
  $("elapsed").textContent = (elapsedMs / 1000).toFixed(1);
  showReceipt(store, results, elapsedMs, error);
  appInsights?.trackEvent({ name: "till-checkout" }, {
    country: store.slice(0, 2), store, durationMs: elapsedMs, ok: !error, lines: basket.size,
  });
}

function showReceipt(store, results, elapsedMs, error) {
  $("screen").hidden = true;
  $("receipt").hidden = false;
  $("receipt-store").textContent = $("store").selectedOptions[0].textContent;
  const lines = $("receipt-lines");
  lines.replaceChildren();
  let total = 0;
  [...basket].forEach(([sku, quantity], index) => {
    const amount = results[index]?.total ?? quantity * SHELF_PRICE;
    total += amount;
    const row = element("li");
    row.append(element("span", "", `${quantity} × ${sku}`), element("span", "", euro(amount)));
    lines.append(row);
  });
  $("receipt-total").textContent = error ? "Not paid" : euro(total);
  $("receipt-label").textContent = error ? "Status" : "Paid";
  $("done").textContent = error ? "Try again" : "New customer";
  const verdict = $("receipt-verdict");
  const seconds = (elapsedMs / 1000).toFixed(1);
  if (error) {
    verdict.className = "verdict bad";
    verdict.textContent = error.status === 503
      ? "Checkout unavailable. We cannot verify prices. Please try again."
      : `Checkout could not complete after ${seconds} s. Please try again.`;
  } else {
    const level = grade(elapsedMs);
    verdict.className = `verdict ${level}`;
    verdict.textContent = {
      good: `Paid in ${seconds} s. Smooth checkout.`,
      slow: `Paid in ${seconds} s. Noticeable wait at the till.`,
      bad: `Paid in ${seconds} s. The customer had to wait.`,
    }[level];
  }
  $("receipt-meta").textContent = `${new Date().toLocaleString()} · ${store}`;
  $("done").focus();
}

async function startTelemetry() {
  try {
    const config = await (await fetch("/api/config", { cache: "no-store" })).json();
    if (!config.connectionString) return;
    await new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = AI_SDK.src;
      script.integrity = AI_SDK.integrity;
      script.crossOrigin = "anonymous";
      script.onload = resolve;
      script.onerror = reject;
      document.head.append(script);
    });
    const sdk = new window.Microsoft.ApplicationInsights.ApplicationInsights({
      config: { connectionString: config.connectionString, enableAutoRouteTracking: false, disableCookiesUsage: true },
    });
    sdk.loadAppInsights();
    sdk.addTelemetryInitializer((item) => {
      item.tags = item.tags || {};
      item.tags["ai.cloud.role"] = "checkout-web-till";
    });
    sdk.trackPageView({ name: "Web till" });
    appInsights = sdk;
  } catch {
    // Browser telemetry is optional for the demo.
  }
}

document.addEventListener("DOMContentLoaded", () => {
  renderShelf();
  renderBasket();
  $("pay").addEventListener("click", pay);
  $("done").addEventListener("click", () => {
    if (checkoutFailed) {
      pay();
      return;
    }
    $("terminal").hidden = true;
    basket.clear();
    renderBasket();
  });
  startTelemetry();
});
