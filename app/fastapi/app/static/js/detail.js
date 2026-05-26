console.log("=== detail.js START ===");

function getParam(name) {
  return new URLSearchParams(window.location.search).get(name);
}

const ALERT_ID = getParam("alert_id");
console.log("ALERT_ID =", ALERT_ID);

async function loadDetail() {
  console.log("loadDetail() called");
  
  if (!ALERT_ID) {
    console.log("No ALERT_ID");
    document.getElementById("status").textContent = "Aucun alert_id dans l'URL";
    return;
  }

  console.log("Fetching context for", ALERT_ID);
  const res = await API.context(ALERT_ID);
  console.log("API result:", res);

  if (!res.ok) {
    console.log("API error:", res.error);
    document.getElementById("status").textContent = "Erreur: " + res.error;
    return;
  }

  const data = res.data;
  console.log("Data received:", data);
  console.log("source_alert:", data.source_alert);

  // Remplir la page
  const section = document.getElementById("alert-section");
  console.log("section element:", section);
  
  if (section) {
    section.classList.remove("hidden");
    console.log("Section shown");
  }

  const alert = data.source_alert;
  const alertBody = document.getElementById("alert-body");
  console.log("alertBody element:", alertBody);
  
  if (alertBody) {
    alertBody.innerHTML = `
      <div class="grid grid-cols-2 gap-y-1 text-sm">
        <div class="text-slate-500">ID</div><div class="font-mono">${alert.id}</div>
        <div class="text-slate-500">Engine</div><div>${alert.source_engine}</div>
        <div class="text-slate-500">Rule</div><div class="font-mono">${alert.rule_id}</div>
        <div class="text-slate-500">Severity</div><div>${alert.severity}</div>
        <div class="text-slate-500">Description</div><div>${alert.description || "—"}</div>
      </div>
    `;
    console.log("Alert body filled");
  }

  const ctxCount = document.getElementById("ctx-count");
  if (ctxCount) ctxCount.textContent = (data.related_events || []).length;

  const contextBody = document.getElementById("context-body");
  if (contextBody) {
    const ctx = data.related_events || [];
    if (ctx.length === 0) {
      contextBody.innerHTML = '<p class="text-slate-400 italic">Aucun événement corrélé.</p>';
    } else {
      contextBody.innerHTML = `<p>${ctx.length} événements corrélés.</p>`;
    }
    console.log("Context body filled");
  }

  document.getElementById("status").textContent = "";

  // Attacher handlers boutons
  document.querySelectorAll(".enrich-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const usage = btn.dataset.usage;
      console.log("Button clicked:", usage);
      doEnrich(usage);
    });
  });
  console.log("Buttons attached");
}

async function doEnrich(usage) {
  console.log("doEnrich called:", usage);
  const btns = document.querySelectorAll(".enrich-btn");
  btns.forEach(b => b.disabled = true);

  const result = document.getElementById("result");
  if (result) {
    result.innerHTML = `<div class="flex items-center gap-3 text-slate-500">
      <div class="w-5 h-5 border-2 border-blue-600 border-t-transparent rounded-full animate-spin"></div>
      <span>Enrichissement ${usage} en cours…</span>
    </div>`;
  }

  const res = await API.enrich(ALERT_ID, usage);
  console.log("Enrich result:", res);

  if (!res.ok) {
    if (result) result.innerHTML = `<div class="text-red-700">Erreur: ${res.error}</div>`;
    btns.forEach(b => b.disabled = false);
    return;
  }

  const data = res.data;
  const r = data.response || {};

  if (usage === "explain") {
    if (result) {
      result.innerHTML = `
        <div class="space-y-3">
          <div><span class="px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800">${r.severity_assessment || "—"}</span></div>
          <div><h3 class="font-semibold text-sm">Résumé</h3><p class="text-sm text-slate-700">${r.summary || "—"}</p></div>
          <div class="text-xs text-slate-400">Latence: ${data.latency_ms}ms</div>
        </div>
      `;
    }
  } else if (usage === "remediate") {
    if (result) {
      result.innerHTML = `
        <div class="space-y-3">
          <div class="text-xl font-bold text-emerald-700">${r.primary_action || "—"}</div>
          <div><p class="text-sm text-slate-700">${r.justification || "—"}</p></div>
          <div class="text-xs text-slate-400">Latence: ${data.latency_ms}ms</div>
        </div>
      `;
    }
  } else if (usage === "investigate") {
    const queries = r.queries || [];
    let html = `<div class="space-y-3"><p class="text-sm text-slate-600">${r.rationale || ""}</p>`;
    for (const q of queries) {
      html += `
        <div class="border border-slate-200 rounded p-3 bg-slate-50">
          <div class="font-semibold text-sm">${q.title || "Requête"}</div>
          <pre class="text-xs font-mono bg-slate-900 text-green-400 p-2 rounded mt-1">${q.kql || ""}</pre>
        </div>
      `;
    }
    html += `<div class="text-xs text-slate-400">Latence: ${data.latency_ms}ms</div></div>`;
    if (result) result.innerHTML = html;
  }

  btns.forEach(b => b.disabled = false);
}

console.log("=== detail.js END ===");

document.addEventListener("DOMContentLoaded", () => {
  console.log("DOMContentLoaded fired");
  loadDetail();
});