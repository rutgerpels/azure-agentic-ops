"use strict";
const el = (id) => document.getElementById(id);
let session;
let busy = false;

async function api(path, data) {
  const options = {credentials: "same-origin", redirect: "error", headers: {}};
  if (data !== undefined) {
    options.method = "POST";
    options.headers = {"Content-Type": "application/json", "X-CSRF-Token": session.csrfToken};
    options.body = JSON.stringify(data);
  }
  const response = await fetch(path, options);
  const result = await response.json();
  if (!response.ok) throw new Error(`${result.error || "Request failed"} · reference ${result.traceId || "unavailable"}`);
  return result;
}

function setBusy(value) {
  busy = value;
  document.querySelectorAll("button, select").forEach((control) => {control.disabled = value;});
  el("status").textContent = value ? "Agent is selecting tools and checking fresh evidence. This can take a minute…" : "";
}

function showSession() {
  el("scope").value = session.scope.join(",");
  el("fixture").replaceChildren();
  session.fixtureStates.forEach((state) => {
    const option = document.createElement("option");
    option.value = state;
    option.textContent = state;
    el("fixture").append(option);
  });
  el("fixture").value = session.fixtureState;
  el("fixture-panel").hidden = session.evidenceMode !== "fixture";
  el("banner").textContent = session.evidenceMode === "fixture"
    ? `SYNTHETIC FIXTURE · ${session.fixtureState} · Not a live incident. Store data is synthetic.`
    : "LIVE evidence binding · Store map remains synthetic. Unknown or stale evidence is not recovery.";
  if (session.agentConfigured === false) {
    el("banner").textContent += " Agent is not configured yet; chat is unavailable until bootstrap and version pinning.";
  }
}

function addMessage(speaker, text, tools) {
  const box = document.createElement("article");
  box.className = `message ${speaker === "You" ? "user" : "assistant"}`;
  const label = document.createElement("div");
  label.className = "speaker";
  label.textContent = speaker;
  const body = document.createElement("div");
  body.className = "body";
  body.textContent = text;
  box.append(label, body);
  if (tools && tools.length) {
    const details = document.createElement("details");
    const summary = document.createElement("summary");
    summary.textContent = `Inspect actual agent tool calls (${tools.length})`;
    details.append(summary);
    tools.forEach((tool) => {
      const pre = document.createElement("pre");
      pre.textContent = JSON.stringify(tool, null, 2);
      details.append(pre);
    });
    box.append(details);
  }
  el("messages").append(box);
  box.scrollIntoView({behavior: "smooth", block: "nearest"});
}

el("chat").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (busy || !session) return;
  const message = el("message").value.trim();
  if (!message) return;
  addMessage("You", message);
  el("message").value = "";
  setBusy(true);
  try {
    const result = await api("/api/chat", {message});
    addMessage("Incident assistant", result.answer, result.tools);
  } catch (error) {addMessage("Request not completed", error.message);}
  finally {setBusy(false);}
});

el("apply").addEventListener("click", async () => {
  if (busy || !session) return;
  setBusy(true);
  try {
    const oldScope = session.scope.join(",");
    session = await api("/api/settings", {countries: el("scope").value.split(","), fixtureState: el("fixture").value});
    if (oldScope !== session.scope.join(",")) el("messages").replaceChildren();
    showSession();
    addMessage("Context updated", "Scope / fixture changed for this conversation only. Ask again to retrieve new evidence.");
  } catch (error) {addMessage("Request not completed", error.message);}
  finally {setBusy(false);}
});

el("reset").addEventListener("click", async () => {
  if (busy || !session) return;
  setBusy(true);
  try {
    await api("/api/reset", {});
    session = await api("/api/session");
    el("messages").replaceChildren();
    showSession();
  } catch (error) {addMessage("Reset not completed", error.message);}
  finally {setBusy(false);}
});

document.querySelectorAll("[data-question]").forEach((button) => {
  button.addEventListener("click", () => {el("message").value = button.dataset.question; el("message").focus();});
});

setBusy(true);
api("/api/session").then((result) => {session = result; showSession();})
  .catch((error) => {el("banner").textContent = error.message;})
  .finally(() => setBusy(false));
