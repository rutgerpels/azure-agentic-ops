"use strict";
const element = (id) => document.getElementById(id);
const money = (cents) => new Intl.NumberFormat("en", {style: "currency", currency: "EUR"}).format(cents / 100);
let products = [];
let catalogFresh = false;
let healthy = false;
let busy = false;
let pendingId = null;
let confirmed = false;
let lastCatalogAt = null;

function activity(operation, outcome, duration, ok) {
  element("empty-activity")?.remove();
  const row = document.createElement("tr");
  [new Date().toLocaleTimeString(), operation, outcome, `${Math.round(duration)} ms`].forEach((value, index) => {
    const cell = document.createElement("td");
    cell.textContent = value;
    if (index === 2) cell.className = ok ? "good-text" : "bad-text";
    row.append(cell);
  });
  element("activity").prepend(row);
  while (element("activity").children.length > 12) element("activity").lastChild.remove();
}

async function request(path, operation, body) {
  const start = performance.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5500);
  try {
    const response = await fetch(path, {
      method: body ? "POST" : "GET",
      cache: "no-store",
      credentials: "same-origin",
      signal: controller.signal,
      headers: body ? {"Content-Type": "application/json", "X-OrderFlow-Request": "1"} : {},
      ...(body ? {body: JSON.stringify(body)} : {})
    });
    const data = await response.json();
    activity(operation, response.ok ? `HTTP ${response.status} · verified` : `HTTP ${response.status} · failed`, performance.now() - start, response.ok);
    if (!response.ok) {
      const error = new Error(typeof data.detail === "string" ? data.detail : "Request failed.");
      error.status = response.status;
      error.recorded = true;
      throw error;
    }
    return data;
  } catch (error) {
    if (!error.recorded) activity(operation, "No usable response", performance.now() - start, false);
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

function updateForm() {
  element("submit-order").disabled = busy || !healthy || !catalogFresh || Boolean(pendingId && !confirmed);
  element("product").disabled = busy || !catalogFresh;
  element("quantity").disabled = busy || Boolean(pendingId && !confirmed);
  const product = products.find((item) => item.id === element("product").value);
  const quantity = Number(element("quantity").value);
  element("total").textContent = product && Number.isInteger(quantity) && quantity >= 1 && quantity <= 5
    ? money(product.price_cents * quantity) : "—";
  document.querySelectorAll(".product-card").forEach((card) => {
    card.classList.toggle("selected", card.dataset.product === element("product").value);
  });
}

function stale() {
  healthy = false;
  catalogFresh = false;
  element("catalog").classList.add("stale");
  element("catalog-status").textContent = products.length
    ? `Stale catalog · last read ${lastCatalogAt}. Refresh after connectivity returns.`
    : "Catalog unavailable. No cached or substitute products are being served.";
  element("dependency-status").textContent = "Unavailable / not verified";
  element("dependency-status").className = "bad-text";
  element("incident-banner").className = "notice bad";
  element("incident-banner").textContent = "The portal can remain online while its order dependency is unavailable. Displayed data is stale; new orders are paused.";
  if (confirmed) element("order-status").textContent = "Previously confirmed · not rechecked";
  updateForm();
}

function renderCatalog() {
  const selected = element("product").value;
  element("catalog").replaceChildren();
  element("product").replaceChildren();
  const symbols = {"field-kit": "▣", "sensor-pack": "◉", "gateway": "▤"};
  products.forEach((product) => {
    const option = document.createElement("option");
    option.value = product.id;
    option.textContent = product.name;
    element("product").append(option);
    const card = document.createElement("article");
    card.className = "product-card";
    card.dataset.product = product.id;
    const icon = document.createElement("div");
    icon.className = "product-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = symbols[product.id] || "□";
    const info = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = product.name;
    const description = document.createElement("p");
    description.textContent = product.description;
    info.append(title, description);
    const price = document.createElement("div");
    price.className = "product-price";
    const amount = document.createElement("span");
    amount.textContent = money(product.price_cents);
    const unit = document.createElement("small");
    unit.textContent = "PER UNIT";
    const select = document.createElement("button");
    select.type = "button";
    select.className = "button secondary";
    select.textContent = "Select";
    select.setAttribute("aria-label", `Select ${product.name}`);
    select.addEventListener("click", () => {
      if (!catalogFresh || busy || (pendingId && !confirmed)) return;
      element("product").value = product.id;
      updateForm();
    });
    price.append(amount, unit, select);
    card.append(icon, info, price);
    element("catalog").append(card);
  });
  if (products.some((product) => product.id === selected)) element("product").value = selected;
  updateForm();
}

async function loadCatalog() {
  element("refresh").disabled = true;
  try {
    const result = await request("/api/products", "Read catalog");
    products = result.products;
    catalogFresh = true;
    lastCatalogAt = new Date().toLocaleTimeString();
    element("catalog").classList.remove("stale");
    element("catalog-status").textContent = `Read from Cosmos DB at ${lastCatalogAt} · health checked separately`;
    renderCatalog();
  } catch {
    stale();
  } finally {
    element("refresh").disabled = false;
  }
}

function showReceipt(receipt) {
  confirmed = true;
  element("order-status").textContent = "Order confirmed";
  element("receipt-detail").textContent = `${receipt.quantity} × ${receipt.product_id} · ${money(receipt.total_cents)} · stored ${new Date(receipt.created_at).toLocaleString()}. Synthetic only. Receipt expires after 24 hours.`;
  element("request-id").textContent = `Request ID: ${receipt.id}`;
  element("reconcile").hidden = false;
  element("reconcile").textContent = "Recheck stored receipt";
}

element("order-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (element("submit-order").disabled) return;
  pendingId = crypto.randomUUID();
  confirmed = false;
  // Preserve the reconciliation identifier across refreshes, never an order payload.
  sessionStorage.setItem("orderflow.pending", pendingId);
  busy = true;
  element("order-status").textContent = "Submitting once…";
  element("receipt-detail").textContent = "Waiting for a stored receipt. This request will not be automatically retried.";
  element("request-id").textContent = `Request ID: ${pendingId}`;
  element("reconcile").hidden = true;
  updateForm();
  try {
    const receipt = await request("/api/orders", "Create order", {
      product_id: element("product").value,
      quantity: Number(element("quantity").value),
      request_id: pendingId
    });
    showReceipt(receipt);
  } catch {
    stale();
    element("order-status").textContent = "Order outcome unknown";
    element("receipt-detail").textContent = "No confirmation received. The order may have been stored. Read its status; do not submit it again. A missing receipt is not proof of failure.";
    element("reconcile").hidden = false;
    element("reconcile").textContent = "Read receipt status";
  } finally {
    busy = false;
    updateForm();
  }
});

element("reconcile").addEventListener("click", async () => {
  if (!pendingId || busy) return;
  busy = true;
  element("reconcile").disabled = true;
  updateForm();
  try {
    showReceipt(await request(`/api/orders/${encodeURIComponent(pendingId)}`, "Read receipt"));
  } catch (error) {
    if (error.status !== 404) stale();
    element("order-status").textContent = confirmed ? "Previously confirmed · not rechecked" : "Outcome still unknown";
    element("receipt-detail").textContent = error.status === 404
      ? "No receipt found at this read. It may still be in flight or have expired. No order has been replayed."
      : "Receipt lookup unavailable. Keep this request ID and read again when connectivity returns. No order has been replayed.";
  } finally {
    busy = false;
    element("reconcile").disabled = false;
    updateForm();
  }
});

async function pollHealth() {
  try {
    const process = await request("/healthz", "Portal process");
    element("portal-status").textContent = process.status === "online" ? "Online · process only" : "Not verified";
    element("portal-status").className = "good-text";
  } catch {
    element("portal-status").textContent = "Unreachable from browser";
    element("portal-status").className = "bad-text";
    stale();
  }
  try {
    const result = await request("/api/health", "Dependency health");
    healthy = result.status === "healthy";
    if (!healthy) throw new Error("Unhealthy");
    element("dependency-status").textContent = "Healthy · database read verified";
    element("dependency-status").className = "good-text";
    element("incident-banner").className = "notice good";
    element("incident-banner").textContent = catalogFresh
      ? "The latest dependency check succeeded. Orders require a fresh catalog; previous receipts remain historical evidence."
      : "Dependency connectivity verified. Refresh the stale catalog before creating another order. Unknown orders still need a receipt lookup.";
    updateForm();
  } catch {
    stale();
  } finally {
    element("last-check").textContent = new Date().toLocaleTimeString();
    setTimeout(pollHealth, 5000);
  }
}

element("refresh").addEventListener("click", loadCatalog);
element("product").addEventListener("change", updateForm);
element("quantity").addEventListener("input", updateForm);
const savedId = sessionStorage.getItem("orderflow.pending");
if (savedId && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(savedId)) {
  pendingId = savedId;
  element("order-status").textContent = "Previous order · verification needed";
  element("request-id").textContent = `Request ID: ${pendingId}`;
  element("receipt-detail").textContent = "A request ID was retained across refresh. Read the stored receipt before creating a new order.";
  element("reconcile").hidden = false;
}
loadCatalog();
pollHealth();
