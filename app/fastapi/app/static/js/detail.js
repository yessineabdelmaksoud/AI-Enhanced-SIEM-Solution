function getParam(name) {
  return new URLSearchParams(window.location.search).get(name);
}

function esc(s) {
  if (s === null || s === undefined) return "";
  return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function timeAgo(iso) {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  if (isNaN(then)) return "—";
  const min = Math.floor((Date.now() - then) / 60000);
  if (min < 1) return "à l'instant";
  if (min < 60) return `il y a ${min} min`;
  const h = Math.floor(min / 60);
  if (h < 24) return `il y a ${h} h`;
  return `il y a ${Math.floor(h / 24)} j`;
}

const SEVERITY_BADGE = {
  critical: "bg-red-100 text-red-800 border border-red-300",
  high: "bg-orange-100 text-orange-800 border border-orange-300",
  medium: "bg-yellow-100 text-yellow-800 border border-yellow-300",
  low: "bg-slate-100 text-slate-600 border border-slate-300",
};

const ALERT_ID = getParam("alert_id");
const USAGES = ["explain", "investigate", "remediate"];
const TAB_LABEL = { explain: "Explication", investigate: "Investigation", remediate: "Remédiation" };

const state = { explain: null, investigate: null, remediate: null };
let activeTab = "explain";
let currentQueries = [];

// ---------- Load context ----------
async function loadDetail() {
  const statusEl = document.getElementById("status");
  if (!ALERT_ID) {
    statusEl.textContent = "alert_id manquant dans l'URL";
    return;
  }
  statusEl.textContent = "Chargement de l'incident…";

  const res = await API.context(ALERT_ID);
  if (!res.ok) {
    statusEl.textContent = "Erreur: " + res.error;
    return;
  }
  const data = res.data;
  const src = data.source_alert;

  document.getElementById("alert-section").classList.remove("hidden");
  statusEl.textContent = "";

  renderHeader(src, data);

  const mitre = (src.mitre_id || [])
    .map((m) => `<span class="font-mono">${esc(m)}</span>`).join(", ") || "—";

  document.getElementById("alert-body").innerHTML = `
    <div class="grid grid-cols-2 gap-2">
      <div><span class="text-slate-500">ID:</span> <span class="font-mono">${esc(src.id)}</span></div>
      <div><span class="text-slate-500">Moteur:</span> ${esc(src.source_engine)}</div>
      <div><span class="text-slate-500">Règle:</span> <span class="font-mono">${esc(src.rule_id)}</span></div>
      <div><span class="text-slate-500">Sévérité:</span> ${esc(src.severity)}</div>
      <div class="col-span-2"><span class="text-slate-500">Description:</span> ${esc(src.description)}</div>
      <div><span class="text-slate-500">Source IP:</span> <span class="font-mono">${esc((src.entity && src.entity.source_ip) || "—")}</span></div>
      <div><span class="text-slate-500">Hôte:</span> <span class="font-mono">${esc((src.entity && src.entity.host_name) || "—")}</span></div>
      <div class="col-span-2"><span class="text-slate-500">MITRE:</span> ${mitre}</div>
    </div>`;

  const events = data.related_events || [];
  document.getElementById("ctx-count").textContent = events.length;
  const ctxBody = document.getElementById("context-body");
  if (events.length === 0) {
    ctxBody.innerHTML = `<p class="text-slate-400">Aucun événement corrélé.</p>`;
  } else {
    ctxBody.innerHTML = `
      <table class="w-full text-xs mt-1">
        <thead class="text-slate-500 text-left">
          <tr><th class="py-1 pr-3">Δt(s)</th><th class="pr-3">Moteur</th><th class="pr-3">Règle</th><th class="pr-3">Sév.</th><th>Description</th></tr>
        </thead>
        <tbody>
          ${events.map((e) => `
            <tr class="border-t border-slate-100">
              <td class="py-1 pr-3 font-mono">${esc(e.delta_seconds)}</td>
              <td class="pr-3">${esc(e.source_engine)}</td>
              <td class="pr-3 font-mono">${esc(e.rule_id)}</td>
              <td class="pr-3">${esc(e.severity)}</td>
              <td>${esc(e.description)}</td>
            </tr>`).join("")}
        </tbody>
      </table>`;
  }

  // Charger les enrichissements déjà persistés
  await loadExistingEnrichments();
  renderTab(activeTab);
}

function renderHeader(src, ctx) {
  const cat = ctx.risk_category || "low";
  const badge = SEVERITY_BADGE[cat] || SEVERITY_BADGE.low;
  const entity = (src.entity && (src.entity.source_ip || src.entity.host_name)) || "—";
  document.getElementById("incident-header").innerHTML = `
    <div class="bg-white rounded-lg shadow p-4 flex items-center gap-4">
      <span class="px-3 py-1 rounded text-sm font-semibold ${badge}">${esc(cat)}</span>
      <div class="text-sm">
        <span class="text-slate-500">Règle</span> <span class="font-mono">${esc(src.rule_id)}</span>
        <span class="mx-2 text-slate-300">|</span>
        <span class="text-slate-500">Entité</span> <span class="font-mono">${esc(entity)}</span>
        <span class="mx-2 text-slate-300">|</span>
        <span class="text-slate-500">Occurrences</span> ${esc(ctx.occurrences)}
      </div>
    </div>`;
}

// ---------- Existing enrichments ----------
async function loadExistingEnrichments() {
  const res = await API.enrichmentsByAlert(ALERT_ID);
  if (res.ok && res.data && res.data.enrichments) {
    for (const u of USAGES) {
      state[u] = res.data.enrichments[u] || null;
    }
  }
  updateTabBadges();
}

function updateTabBadges() {
  document.querySelectorAll(".tab-btn").forEach((btn) => {
    const u = btn.dataset.tab;
    const has = state[u] !== null;
    const isActive = u === activeTab;
    btn.className =
      "tab-btn px-4 py-2 text-sm font-medium border-b-2 " +
      (isActive ? "border-blue-600 text-blue-600 " : "border-transparent text-slate-600 ") +
      "hover:text-blue-600";
    btn.innerHTML = TAB_LABEL[u] + (has ? ' <span class="text-green-600">●</span>' : "");
  });
}

// ---------- Tab rendering ----------
function renderTab(usage) {
  activeTab = usage;
  updateTabBadges();
  const content = document.getElementById("tab-content");
  const doc = state[usage];

  if (!doc) {
    content.innerHTML = `
      <div class="text-center py-6">
        <p class="text-slate-400 mb-3">Pas encore d'enrichissement ${esc(TAB_LABEL[usage])}.</p>
        <button class="gen-btn bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded" data-usage="${usage}">Générer</button>
      </div>`;
    attachGenButtons();
    return;
  }

  let inner;
  if (!doc.validated) {
    inner = renderError(doc, usage);
  } else if (usage === "explain") {
    inner = explainFmt(doc);
  } else if (usage === "investigate") {
    inner = investigateFmt(doc);
  } else {
    inner = remediateFmt(doc);
  }

  content.innerHTML = `
    ${inner}
    <div class="flex items-center gap-3 mt-4 pt-3 border-t border-slate-100">
      <button class="gen-btn text-sm bg-slate-200 hover:bg-slate-300 px-3 py-1.5 rounded" data-usage="${usage}">Régénérer</button>
      <span class="text-xs text-slate-400">Généré ${esc(timeAgo(doc["@timestamp"]))} · ${esc(doc.latency_ms)}ms</span>
    </div>`;
  attachGenButtons();
  attachCopyButtons();
}

function attachGenButtons() {
  document.querySelectorAll(".gen-btn").forEach((btn) => {
    btn.addEventListener("click", () => generateEnrichment(btn.dataset.usage));
  });
}

function attachCopyButtons() {
  document.querySelectorAll(".copy-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const idx = parseInt(btn.getAttribute("data-idx"), 10);
      const kql = (currentQueries[idx] && currentQueries[idx].kql) || "";
      navigator.clipboard.writeText(kql).then(() => {
        btn.textContent = "Copié ✓";
        setTimeout(() => { btn.textContent = "Copier"; }, 1500);
      });
    });
  });
}

// ---------- Generate ----------
async function generateEnrichment(usage) {
  activeTab = usage;
  updateTabBadges();
  const content = document.getElementById("tab-content");

  let seconds = 0;
  content.innerHTML = `
    <div class="flex items-center gap-3 text-slate-600">
      <div class="w-5 h-5 border-2 border-blue-600 border-t-transparent rounded-full animate-spin"></div>
      <span>Génération <strong>${esc(TAB_LABEL[usage])}</strong>… <span id="sec">0</span>s</span>
    </div>
    <p class="text-xs text-slate-400 mt-2">LLM sur CPU, compte 60 à 120 secondes.</p>`;
  const timer = setInterval(() => {
    seconds += 1;
    const el = document.getElementById("sec");
    if (el) el.textContent = seconds;
  }, 1000);

  const res = await API.enrich(ALERT_ID, usage);
  clearInterval(timer);

  if (!res.ok) {
    content.innerHTML = `<div class="border border-red-200 bg-red-50 rounded p-4 text-red-700">Erreur: ${esc(res.error)}</div>`;
    return;
  }
  state[usage] = res.data;
  renderTab(usage);
}

async function generateAll() {
  for (const u of USAGES) {
    await generateEnrichment(u);
  }
}

// ---------- Formatters ----------
function metaBadge(doc) {
  return `<span class="text-xs text-slate-400 ml-auto">score ${esc(doc.risk_score)} (${esc(doc.risk_category)})</span>`;
}

function explainFmt(doc) {
  const r = doc.response || {};
  const sev = r.severity_assessment || "low";
  const badge = SEVERITY_BADGE[sev] || SEVERITY_BADGE.low;
  const iocs = (r.key_iocs || []).map((i) =>
    `<span class="inline-block bg-slate-100 border border-slate-300 rounded px-2 py-0.5 text-xs font-mono mr-1 mb-1">${esc(i)}</span>`).join("");
  const mitre = (r.mitre_techniques || []).map((m) =>
    `<span class="inline-block bg-purple-100 border border-purple-300 text-purple-800 rounded px-2 py-0.5 text-xs font-mono mr-1 mb-1">${esc(m)}</span>`).join("");
  return `
    <div class="flex items-center gap-3 mb-3">
      <h3 class="text-lg font-semibold">Explication</h3>
      <span class="px-2 py-0.5 rounded text-xs font-medium ${badge}">${esc(sev)}</span>
      ${metaBadge(doc)}
    </div>
    <p class="mb-3 leading-relaxed">${esc(r.summary)}</p>
    <div class="mb-2"><span class="text-slate-500 text-sm">Phase d'attaque:</span> <span class="font-medium">${esc(r.attack_phase)}</span></div>
    <div class="mb-2"><span class="text-slate-500 text-sm">IoCs:</span><br>${iocs || "—"}</div>
    <div><span class="text-slate-500 text-sm">MITRE:</span><br>${mitre || "—"}</div>`;
}

function investigateFmt(doc) {
  const r = doc.response || {};
  currentQueries = r.queries || [];
  const cards = currentQueries.map((q, i) => `
    <div class="border border-slate-200 rounded p-3 mb-3">
      <div class="flex items-center justify-between mb-2">
        <h4 class="font-medium">${esc(q.title)}</h4>
        <button class="copy-btn text-xs bg-slate-200 hover:bg-slate-300 px-2 py-1 rounded" data-idx="${i}">Copier</button>
      </div>
      <pre class="bg-slate-900 text-green-300 text-xs p-2 rounded overflow-x-auto whitespace-pre-wrap">${esc(q.kql)}</pre>
      <p class="text-xs text-slate-500 mt-2">${esc(q.expected_findings)}</p>
    </div>`).join("");
  return `
    <div class="flex items-center gap-3 mb-3">
      <h3 class="text-lg font-semibold">Investigation</h3>${metaBadge(doc)}
    </div>
    <p class="text-sm text-slate-600 mb-3">${esc(r.rationale)}</p>${cards}`;
}

function remediateFmt(doc) {
  const r = doc.response || {};
  const conf = typeof r.confidence === "number" ? Math.round(r.confidence * 100) : null;
  const alts = (r.alternatives || []).map((a) =>
    `<span class="inline-block bg-slate-100 border border-slate-300 rounded px-2 py-0.5 text-xs font-mono mr-1 mb-1">${esc(a)}</span>`).join("");
  return `
    <div class="flex items-center gap-3 mb-3">
      <h3 class="text-lg font-semibold">Remédiation</h3>${metaBadge(doc)}
    </div>
    <div class="bg-emerald-50 border border-emerald-200 rounded p-4 mb-3">
      <div class="text-xs text-emerald-700 uppercase tracking-wide">Action recommandée</div>
      <div class="text-2xl font-bold font-mono text-emerald-900">${esc(r.primary_action)}</div>
    </div>
    <p class="mb-3">${esc(r.justification)}</p>
    ${conf !== null ? `
      <div class="mb-3">
        <div class="text-sm text-slate-500 mb-1">Confiance: ${conf}%</div>
        <div class="w-full bg-slate-200 rounded h-2"><div class="bg-emerald-500 h-2 rounded" style="width:${conf}%"></div></div>
      </div>` : ""}
    <div><span class="text-slate-500 text-sm">Alternatives:</span><br>${alts || "—"}</div>`;
}

function renderError(doc, usage) {
  const errs = (doc.errors || []).map((e) => `<li>${esc(e)}</li>`).join("");
  return `
    <div class="border border-red-200 bg-red-50 rounded p-4">
      <h3 class="font-semibold text-red-800 mb-2">Enrichissement ${esc(TAB_LABEL[usage])} non validé</h3>
      <ul class="text-xs text-red-600 list-disc ml-5">${errs || "<li>(aucun détail)</li>"}</ul>
    </div>`;
}

// ---------- Wiring ----------
document.addEventListener("DOMContentLoaded", () => {
  // Attendre que le DOM soit chargé avant d'attacher les écouteurs
  document.querySelectorAll(".tab-btn").forEach((btn) => {
    btn.addEventListener("click", () => renderTab(btn.dataset.tab));
  });
  
  const generateAllBtn = document.getElementById("generate-all");
  if (generateAllBtn) {
    generateAllBtn.addEventListener("click", generateAll);
  } else {
    console.warn("Bouton generate-all non trouvé dans le DOM");
  }
  
  loadDetail();
});