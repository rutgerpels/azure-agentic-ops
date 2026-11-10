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
  element("product").disabled = busy || !catalogFresh || Boolean(pendingId && !confirmed);
  element("quantity").disabled = busy || Boolean(pendingId && !confirmed);
  const product = products.find((item) => item.id === element("product").value);
  const quantity = Number(element("quantity").value);
  element("total").textContent = product && Number.isInteger(quantity) && quantity >= 1 && quantity <= 5
    ? money(product.price_cents * quantity) : "—";
  document.querySelectorAll(".product-card").forEach((card) => {
    const selected = card.dataset.product === element("product").value;
    card.classList.toggle("selected", selected);
    const button = card.querySelector("button");
    button.disabled = busy || !catalogFresh || Boolean(pendingId && !confirmed);
    button.setAttribute("aria-pressed", String(selected));
    button.textContent = selected ? "Selected" : "Choose";
  });
}

function stale() {
  healthy = false;
  catalogFresh = false;
  element("catalog").classList.add("stale");
  element("catalog-status").textContent = products.length
    ? `Collection offline · showing the last read from ${lastCatalogAt}. These items cannot be ordered yet.`
    : "We can't load the collection right now. No substitute products are being served.";
  element("dependency-status").textContent = "Unavailable / not verified";
  element("dependency-status").className = "bad-text";
  element("incident-banner").className = "notice bad";
  element("incident-banner").textContent = "Merch ordering is paused. The shop is still here, but we can't reach the order service. No new collection passes can be confirmed. Already submitted? Check your existing pass instead of ordering again.";
  if (confirmed) element("order-status").textContent = "Earlier pass · not rechecked";
  updateForm();
}

function renderCatalog() {
  const selected = element("product").value;
  element("catalog").replaceChildren();
  element("product").replaceChildren();
  const artwork = {
    "tour-shirt": "/static/tour-shirt.svg",
    "tour-poster": "/static/tour-poster.svg",
    "tour-tote": "/static/tour-tote.svg"
  };
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
    if (artwork[product.id]) {
      const image = document.createElement("img");
      image.src = artwork[product.id];
      image.alt = "";
      image.width = 300;
      image.height = 300;
      icon.append(image);
    }
    const info = document.createElement("div");
    info.className = "product-info";
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
    select.textContent = "Choose";
    select.setAttribute("aria-label", `Choose ${product.name}`);
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
    element("catalog-status").textContent = `Live collection checked at ${lastCatalogAt} · choose your piece of the show.`;
    renderCatalog();
  } catch {
    stale();
  } finally {
    element("refresh").disabled = false;
  }
}

function showReceipt(receipt) {
  if (receipt.id !== pendingId || receipt.request_id !== pendingId ||
      receipt.status !== "confirmed" || receipt.synthetic !== true) {
    throw new Error("Collection pass did not match this order.");
  }
  confirmed = true;
  element("collection-pass").classList.add("confirmed");
  element("order-status").textContent = "You're on the list.";
  const name = products.find((product) => product.id === receipt.product_id)?.name || receipt.product_id;
  element("receipt-detail").textContent = `${receipt.quantity} × ${name} · ${money(receipt.total_cents)}. Demo collection at the merch desk. Saved ${new Date(receipt.created_at).toLocaleString()}. No payment or real pickup; this stored pass expires after 24 hours.`;
  element("request-id").textContent = `Collection reference: ${receipt.id}`;
  element("reconcile").hidden = false;
  element("reconcile").textContent = "Verify stored collection pass";
}

element("order-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (element("submit-order").disabled) return;
  pendingId = crypto.randomUUID();
  confirmed = false;
  element("collection-pass").classList.remove("confirmed");
  // Preserve the reconciliation identifier across refreshes, never an order payload.
  sessionStorage.setItem("orderflow.pending", pendingId);
  busy = true;
  element("order-status").textContent = "Saving your spot…";
  element("receipt-detail").textContent = "Waiting for your collection confirmation. This order is sent once, never automatically retried.";
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
    element("order-status").textContent = "Don't order twice.";
    element("receipt-detail").textContent = "Your order outcome is unknown: it may already be saved. Check this collection reference after connectivity returns. No confirmation is not proof of failure.";
    element("reconcile").hidden = false;
    element("reconcile").textContent = "Check collection pass";
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
    element("order-status").textContent = confirmed ? "Earlier pass · not rechecked" : "Order outcome still unknown";
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
    element("incident-banner").textContent = pendingId && !confirmed
      ? "The order service is reachable. Check your pending collection pass before placing another order; nothing has been resubmitted."
      : catalogFresh
        ? "The merch desk is connected. Choose your merch and confirm a demo order. No real payment or collection."
        : "The order service is reachable again. Refresh the collection to reopen ordering. Earlier passes do not prove a new order will succeed.";
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
  element("order-status").textContent = "Got a pass already?";
  element("request-id").textContent = `Request ID: ${pendingId}`;
  element("receipt-detail").textContent = "A request ID was retained across refresh. Read the stored receipt before creating a new order.";
  element("reconcile").hidden = false;
}
loadCatalog();
pollHealth();
