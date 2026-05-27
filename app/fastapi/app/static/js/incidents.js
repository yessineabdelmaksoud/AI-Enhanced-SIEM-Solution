const CATEGORY_BADGE = {
  critical: "bg-red-100 text-red-800 border border-red-300",
  high: "bg-orange-100 text-orange-800 border border-orange-300",
  medium: "bg-yellow-100 text-yellow-800 border border-yellow-300",
  low: "bg-slate-100 text-slate-600 border border-slate-300",
};

let allIncidents = [];

function esc(s) {
  if (s === null || s === undefined) return "";
  return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function fmtDate(iso) {
  if (!iso) return "—";
  try { return new Date(iso).toLocaleString(); } catch (e) { return iso; }
}

async function loadIncidents() {
  const statusEl = document.getElementById("status");
  const hours = document.getElementById("time-range").value;
  statusEl.textContent = "Chargement…";

  const res = await API.listIncidents(hours, 50);
  if (!res.ok) {
    statusEl.textContent = "Erreur: " + res.error;
    allIncidents = [];
    return;
  }
  allIncidents = res.data.incidents || [];
  applyFilters();
}

function applyFilters() {
  const cat = document.getElementById("category-filter").value;
  const q = document.getElementById("search").value.trim().toLowerCase();
  const statusEl = document.getElementById("status");
  const body = document.getElementById("incidents-body");

  let filtered = allIncidents.slice();
  if (cat !== "all") {
    filtered = filtered.filter((i) => (i.risk_category || "low") === cat);
  }
  if (q) {
    filtered = filtered.filter((i) => {
      const entity = (i.entity && (i.entity.source_ip || i.entity.host_name)) || "";
      return (
        String(i.rule_id || "").toLowerCase().includes(q) ||
        entity.toLowerCase().includes(q)
      );
    });
  }

  renderStats(allIncidents);
  statusEl.textContent = `${filtered.length} / ${allIncidents.length} incident(s)`;
  body.innerHTML = "";

  if (filtered.length === 0) {
    body.innerHTML = `<tr><td colspan="9" class="px-4 py-6 text-center text-slate-400">Aucun incident</td></tr>`;
    return;
  }

  for (const inc of filtered) {
    const c = inc.risk_category || "low";
    const badge = CATEGORY_BADGE[c] || CATEGORY_BADGE.low;
    const entity = (inc.entity && (inc.entity.source_ip || inc.entity.host_name)) || "—";
    const alertId = inc.alert_id;

    const tr = document.createElement("tr");
    tr.className = "border-t border-slate-100 hover:bg-slate-50 cursor-pointer";
    tr.innerHTML = `
      <td class="px-4 py-3"><span class="px-2 py-0.5 rounded text-xs font-medium ${badge}">${esc(c)}</span></td>
      <td class="px-4 py-3 font-mono">${esc(inc.risk_score)}</td>
      <td class="px-4 py-3 font-mono">${esc(inc.rule_id)}</td>
      <td class="px-4 py-3">${esc(inc.source_engine)}</td>
      <td class="px-4 py-3 font-mono">${esc(entity)}</td>
      <td class="px-4 py-3">${esc(inc.occurrences)}</td>
      <td class="px-4 py-3 text-slate-500">${esc(fmtDate(inc.last_seen))}</td>
      <td class="px-4 py-3">${inc.has_enrichment ? '<span class="text-green-600">✓</span>' : "—"}</td>
      <td class="px-4 py-3 text-blue-600">Ouvrir →</td>
    `;
    tr.addEventListener("click", () => {
      window.location.href = `/incident.html?alert_id=${encodeURIComponent(alertId)}`;
    });
    body.appendChild(tr);
  }
}

function renderStats(incidents) {
  const counts = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const i of incidents) counts[i.risk_category || "low"]++;
  const statsEl = document.getElementById("stats");
  statsEl.innerHTML = `
    <span class="px-2 py-1 rounded ${CATEGORY_BADGE.critical}">Critical: ${counts.critical}</span>
    <span class="px-2 py-1 rounded ${CATEGORY_BADGE.high}">High: ${counts.high}</span>
    <span class="px-2 py-1 rounded ${CATEGORY_BADGE.medium}">Medium: ${counts.medium}</span>
    <span class="px-2 py-1 rounded ${CATEGORY_BADGE.low}">Low: ${counts.low}</span>
    <span class="px-2 py-1 rounded bg-slate-800 text-white">Total: ${incidents.length}</span>
  `;
}

document.getElementById("refresh").addEventListener("click", loadIncidents);
document.getElementById("time-range").addEventListener("change", loadIncidents);
document.getElementById("category-filter").addEventListener("change", applyFilters);
document.getElementById("search").addEventListener("input", applyFilters);
document.addEventListener("DOMContentLoaded", loadIncidents);