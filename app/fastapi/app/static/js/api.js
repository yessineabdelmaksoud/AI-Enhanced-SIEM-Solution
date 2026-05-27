const API = {
  base: window.location.origin,

  async _fetch(path, options = {}) {
    try {
      const res = await fetch(this.base + path, options);
      if (!res.ok) {
        let detail = `HTTP ${res.status}`;
        try {
          const body = await res.json();
          detail = body.detail || detail;
        } catch (e) { /* ignore */ }
        return { ok: false, error: detail };
      }
      const data = await res.json();
      return { ok: true, data };
    } catch (err) {
      return { ok: false, error: err.message || "Erreur réseau" };
    }
  },

  listIncidents(hours = 24, limit = 50) {
    return this._fetch(`/incidents?hours=${hours}&limit=${limit}`);
  },

  context(alertId) {
    return this._fetch(`/debug/context/${encodeURIComponent(alertId)}`);
  },

  enrich(alertId, usage) {
    return this._fetch(`/enrich/${encodeURIComponent(alertId)}/${usage}`, {
      method: "POST",
    });
  },

  getEnrichment(id) {
    return this._fetch(`/enrichments/${encodeURIComponent(id)}`);
  },

  enrichmentsByAlert(alertId) {
    return this._fetch(`/enrichments/by-alert/${encodeURIComponent(alertId)}`);
  },

  health() {
    return this._fetch(`/health`);
  },
};