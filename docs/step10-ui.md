# Étape 10 — Interface Utilisateur Minimale (UI Web)

> **Document de pilotage technique — AI-Enhanced SIEM MVP**  
> VM cible : `vm-ai-01` (192.168.56.40 / 10.110.188.66)  
> Modèle LLM : Qwen3 14B (Q4_K_M) via Ollama  
> Date de validation : 2026-05-26

---

## 1. Objectif de l'étape

Livrer une **interface utilisateur fonctionnelle** qui consomme l'API FastAPI et rend le MVP **démontrable visuellement** : liste d'incidents, détail d'incident, boutons d'enrichissement, affichage formaté du résultat, persistance au refresh.

**Choix technique MVP :** HTML statique + Vanilla JS + Tailwind CSS via CDN. Pas de framework React/Vue, pas de bundler. Servi par FastAPI via `StaticFiles`.

**Argument de soutenance :** Un PFA n'a pas besoin d'une SPA complexe. Le temps économisé sur le frontend est investi dans la qualité de l'enrichissement et l'évaluation. L'UI est "suffisante" pour démontrer le concept.

**Pages livrées :**

| Page | Route | Contenu |
|------|-------|---------|
| Liste incidents | `/` | Tableau trié par `risk_score`, badge couleur par catégorie |
| Détail incident | `/incident.html?alert_id=xxx` | Alerte source + contexte + 3 boutons enrichir + zone résultat |
| Health | `/ui/health` | État ES + Ollama + version + modèle |

---

## 2. Architecture et principes

### 2.1 Séparation routes API vs routes UI

| Espace | Préfixe | Usage |
|--------|---------|-------|
| **API** | `/` | Endpoints REST (`/enrich`, `/incidents`, `/health`) |
| **UI** | `/`, `/incident.html`, `/ui/health` | Pages HTML statiques servies par `FileResponse` |
| **Assets** | `/static/` | CSS, JS, images |

**Convention de routing :** `/incident.html?alert_id=xxx` (UI) vs `/incidents` (API). Cela évite tout conflit entre routes FastAPI et fichiers statiques.

### 2.2 Persistance du résultat au refresh

**Problème identifié :** L'enrichissement s'affiche mais disparaît au refresh de page (F5). Le résultat n'était stocké que dans le DOM.

**Solution implémentée :**
1. Quand l'enrichissement réussit, `enrichment_id` et `usage` sont ajoutés à l'URL (`window.history.replaceState`)
2. Au chargement de la page, si `enrichment_id` est présent dans l'URL, le frontend appelle `GET /enrichments/{id}` pour récupérer le document depuis Elasticsearch
3. Le résultat est réaffiché instantanément sans nouvel appel LLM (latence < 1s)

**Flux :**
```
Clic "Expliquer" → POST /enrich/{id}/explain (60-90s)
  → Réponse : enrichment_id = "abc123"
  → URL mise à jour : /incident.html?alert_id=xxx&enrichment_id=abc123&usage=explain
  → Affichage du résultat

Refresh (F5) → Détection enrichment_id dans URL
  → GET /enrichments/abc123 (< 1s depuis ES)
  → Réaffichage instantané
```

### 2.3 Gestion des états asynchrones

| État | Indicateur visuel |
|------|-------------------|
| Chargement alerte | "Chargement de l'alerte…" |
| Enrichissement en cours | Spinner CSS + compteur de secondes |
| Succès | Résultat formaté selon le usage |
| Erreur API | Message rouge avec détail |
| Cache hit | Résultat instantané (pas de spinner) |

### 2.4 Sécurité frontend

- **Pas d'appel direct Elasticsearch** : tout passe par l'API FastAPI
- **Pas de credentials dans le JS** : l'API ES est côté serveur uniquement
- **Échappement HTML** : fonction `esc()` systématique sur toutes les données dynamiques
- **Pas de eval() / innerHTML injecté** : le HTML est construit par concaténation contrôlée

---

## 3. Fichiers créés / modifiés

### 3.1 Création — `app/fastapi/app/static/index.html`

- En-tête "SOC AI Enrichment" + navigation
- Tableau dynamique des incidents (chargé via `API.listIncidents()`)
- Colonnes : Risk (badge), Score, Règle, Source, Entité, Occurrences, Vu, Enrichi, Action
- Bouton "Rafraîchir"
- Ligne cliquable → redirection vers `/incident.html?alert_id=...`

### 3.2 Création — `app/fastapi/app/static/incident.html`

- Navigation retour vers liste
- Section "Alerte source" (cachée initialement, affichée après chargement)
- Section "Contexte corrélé" avec compteur
- 3 boutons : Expliquer, Investiguer, Remédiation
- Zone de résultat unique avec spinner/erreur/résultat

### 3.3 Création — `app/fastapi/app/static/health.html`

- État global : OK/KO avec pastille couleur
- État Elasticsearch : OK/KO
- État Ollama : OK/KO
- Modèle chargé : `qwen3:14b`
- Version API : `0.1.0`

### 3.4 Création — `app/fastapi/app/static/css/style.css`

- Overrides minimaux (font-family, animation spin)
- Tailwind CDN gère 99% du styling

### 3.5 Création — `app/fastapi/app/static/js/api.js`

Client API vanilla :
- `listIncidents(hours, limit)` → GET `/incidents`
- `context(alertId)` → GET `/debug/context/{id}`
- `enrich(alertId, usage)` → POST `/enrich/{id}/{usage}`
- `getEnrichment(id)` → GET `/enrichments/{id}`
- `health()` → GET `/health`

Gestion d'erreur uniforme : `{ok: bool, data?, error?}`

### 3.6 Création — `app/fastapi/app/static/js/incidents.js`

- Chargement automatique au `DOMContentLoaded`
- Mapping `risk_category` → classe CSS Tailwind (critical=rouge, high=orange, medium=jaune, low=gris)
- Formatage dates avec `toLocaleString()`
- Échappement HTML systématique (`esc()`)
- Clic sur ligne → `window.location.href = /incident.html?alert_id=...`

### 3.7 Création — `app/fastapi/app/static/js/detail.js`

**Fonctionnalités :**
- `loadDetail()` : charge l'alerte + contexte, détecte `enrichment_id` dans l'URL
- `renderAlert()` : affiche les métadonnées de l'alerte source + contexte corrélé
- `doEnrich(usage)` : appelle l'API, met à jour l'URL, affiche le résultat
- `renderResult()` : formate le résultat selon le usage (explain/investigate/remediate)
- `copyKql()` : copie la requête KQL dans le presse-papiers

**Persistance au refresh :**
```javascript
// Après enrichissement réussi
const url = new URL(window.location.href);
url.searchParams.set("enrichment_id", data.enrichment_id);
url.searchParams.set("usage", usage);
window.history.replaceState({}, "", url);

// Au chargement
const savedEnrichmentId = urlParams.get("enrichment_id");
if (savedEnrichmentId) {
  const res = await API.getEnrichment(savedEnrichmentId);
  renderResult(res.data, savedUsage);
}
```

### 3.8 Modification — `app/fastapi/app/main.py`

Ajouts :
```python
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

app.mount("/static", StaticFiles(directory="app/static"), name="static")

@app.get("/", include_in_schema=False)
async def ui_index() -> FileResponse:
    return FileResponse("app/static/index.html")

@app.get("/incident.html", include_in_schema=False)
async def ui_incident() -> FileResponse:
    return FileResponse("app/static/incident.html")

@app.get("/ui/health", include_in_schema=False)
async def ui_health() -> FileResponse:
    return FileResponse("app/static/health.html")
```

---

## 4. Problème rencontré et correction

### 4.1 Symptôme — Page incident bloquée sur "Chargement…"

La page `incident.html` affichait "Chargement…" et les 3 boutons, mais :
- La section alerte ne s'affichait jamais
- Les boutons ne réagissaient pas
- Aucune erreur dans la console F12

### 4.2 Diagnostic

Tests console F12 :
```javascript
console.log("ALERT_ID =", ALERT_ID);  // OK : "kK-MYZ4BidyXsbuG49mO"
console.log(typeof loadDetail);        // OK : "function"
API.context(ALERT_ID).then(res => {    // OK : {ok: true, data: {...}}
  console.log(res.data.source_alert);  // OK : objet alerte complet
});
```

L'API fonctionnait, le DOM existait, mais `renderAlert()` ne remplissait rien. Le fichier `detail.js` original (fourni dans le plan d'implémentation) était **tronqué** — il s'arrêtait après `let timerId = null;` sans le corps des fonctions.

### 4.3 Solution — Réécriture complète de detail.js

Création d'un `detail.js` complet avec :
- `renderAlert()` : affichage des métadonnées + contexte
- `renderResult()` : formatage conditionnel selon le usage
- `doEnrich()` : appel API + persistance URL + affichage
- `loadDetail()` : détection `enrichment_id` dans URL pour restauration
- Guards (`if (element)`) sur tous les accès DOM
- `console.log` pour le debug

### 4.4 Second problème — Résultat perdu au refresh

Après correction du chargement initial, l'enrichnement s'affichait mais disparaissait au F5.

**Fix :** Ajout de la persistance via URL parameters (`enrichment_id`, `usage`) et restauration via `API.getEnrichment()` au chargement.

---

## 5. Procédure de mise en place

### 5.1 Prérequis

- Étape 9 validée (`/enrich`, `/incidents`, `/enrichments` fonctionnels)
- Au moins un incident indexé dans ES
- `WorkingDirectory` du service systemd = `/home/vm-ai/soc-ai-lab/app/fastapi`

### 5.2 Déploiement

```bash
# Créer la structure
mkdir -p ~/soc-ai-lab/app/fastapi/app/static/{css,js}

# Créer les 7 fichiers (index.html, incident.html, health.html, style.css, api.js, incidents.js, detail.js)
# [voir contenu dans les sections 3.1–3.7]

# Mettre à jour main.py

sudo systemctl restart soc-ai-fastapi
sleep 3
```

### 5.3 Vérification des assets servis

```bash
curl -s -o /dev/null -w "index: %{http_code}
" http://localhost:8000/
curl -s -o /dev/null -w "incident: %{http_code}
" http://localhost:8000/incident.html
curl -s -o /dev/null -w "health: %{http_code}
" http://localhost:8000/ui/health
curl -s -o /dev/null -w "api.js: %{http_code}
" http://localhost:8000/static/js/api.js
curl -s -o /dev/null -w "detail.js: %{http_code}
" http://localhost:8000/static/js/detail.js
```

**Attendu :** `200` pour tous.

---

## 6. Protocole de validation

### 6.1 Test 1 — Page d'accueil

```bash
# Navigateur : http://10.110.188.66:8000/
```

**Attendu :**
- Tableau chargé avec incidents
- Badges de couleur selon `risk_category`
- Colonnes : Risk, Score, Règle, Source, Entité, Occurrences, Vu, Enrichi
- Clic sur ligne → redirection vers page détail

**Résultat observé :**
```json
{
  "count": 1,
  "top5": [{
    "rule_id": "2013504",
    "source_engine": "suricata",
    "entity": "10.110.188.115",
    "occurrences": 16,
    "risk_score": 43.1,
    "risk_category": "medium",
    "has_enrichment": false
  }]
}
```

### 6.2 Test 2 — Page détail (chargement alerte)

```bash
# Navigateur : http://10.110.188.66:8000/incident.html?alert_id=kK-MYZ4BidyXsbuG49mO
```

**Attendu :**
- Section "Alerte source" s'affiche après 1-2s
- Métadonnées : ID, Engine, Rule, Severity, Time, MITRE, Entity, Description
- Section "Contexte corrélé" avec nombre d'événements
- 3 boutons actifs

**Résultat observé :**
- Alert source affichée : Suricata rule 2013504, severity 3
- Contexte : 20 événements corrélés
- Boutons cliquables

### 6.3 Test 3 — Enrichissement explain

**Action :** Clic sur "Expliquer"

**Attendu :**
- Spinner avec compteur de secondes
- Après 60-90s : résumé en français, severity badge, IoCs, MITRE techniques
- URL mise à jour avec `enrichment_id` et `usage`

**Résultat observé :**
```json
{
  "enrichment_id": "da-ZXJ4BidyXsbuGr9kf",
  "validated": true,
  "risk_score": 28.6,
  "summary": "Deux tentatives de connexion SSH ont été enregistrées...",
  "attack_phase": "credential_access",
  "mitre": ["T1110.001", "T1021.004"]
}
```

### 6.4 Test 4 — Persistance au refresh

**Action :** F5 après enrichissement explain

**Attendu :**
- Résultat réapparaît instantanément (< 2s)
- Pas de nouvel appel LLM (pas de spinner long)
- `enrichment_id` conservé dans l'URL

**Résultat observé :** ✅ Résultat restauré depuis ES en < 1s

### 6.5 Test 5 — Enrichissement remediate

**Action :** Clic sur "Remédiation"

**Attendu :** Action principale, justification, alternatives, confiance

**Résultat observé :**
```json
{
  "validated": true,
  "primary_action": "block_source_ip",
  "confidence": 0.85,
  "justification": "L'adresse IP 10.110.188.90 tente de se connecter...",
  "alternatives": ["isolate_host", "increase_logging"]
}
```

### 6.6 Test 6 — Enrichissement investigate

**Action :** Clic sur "Investiguer"

**Attendu :** 1-3 cartes KQL avec titre, requête, expected_findings, bouton Copier

**Résultat observé :**
```json
{
  "validated": true,
  "queries_count": 3,
  "titles": [
    "Tentatives de connexion SSH depuis IP suspecte",
    "Alertes sur hôte cible",
    "Historique des tentatives de brute force"
  ]
}
```

### 6.7 Test 7 — Health page

**Action :** Visiter `/ui/health`

**Attendu :** ES OK (vert), Ollama OK (vert), modèle `qwen3:14b`, version `0.1.0`

### 6.8 Test 8 — Console F12

**Attendu :** Aucune erreur JavaScript (rouge)

### 6.9 Test 9 — Network tab

**Attendu :** Aucun appel direct vers Elasticsearch (tout passe par `/enrich`, `/incidents`, `/debug/context`)

---

## 7. Checklist de validation Étape 10

| # | Critère | Statut |
|---|---------|--------|
| 1 | `/`, `/incident.html`, `/ui/health`, `/static/*` → 200 | ✅ |
| 2 | Liste incidents chargée avec badges de couleur | ✅ |
| 3 | Clic ligne → redirection page détail avec `alert_id` | ✅ |
| 4 | Détail incident : alerte source + contexte affichés | ✅ |
| 5 | Bouton "Expliquer" → spinner → résultat formaté | ✅ |
| 6 | Bouton "Remédiation" → action + justification + confiance | ✅ |
| 7 | Bouton "Investiguer" → 1-3 cartes KQL + bouton Copier | ✅ |
| 8 | Persistance au refresh (enrichment_id dans URL) | ✅ |
| 9 | Aucune erreur JavaScript dans console F12 | ✅ |
| 10 | Aucun accès direct Elasticsearch depuis le navigateur | ✅ |
| 11 | Health page : ES + Ollama + modèle OK | ✅ |
| 12 | Responsive basique (tableau scrollable sur mobile) | ✅ |

**Étape 10 validée : 12/12 critères verts.**

---

## 8. Améliorations UI/UX proposées (post-MVP / V2)

### 8.1 Court terme (facile, 1-2 jours)

| Amélioration | Impact | Complexité |
|--------------|--------|------------|
| **Auto-refresh incidents** | Recharge toutes les 30s sans F5 | Faible (`setInterval`) |
| **Toast notifications** | "Enrichissement terminé" au lieu de spinner muet | Faible |
| **Skeleton loaders** | Placeholders gris pendant le chargement | Faible (CSS) |
| **Filtres rapides** | Boutons "Critical only", "Non enrichis" | Moyenne |
| **Recherche incident** | Barre de recherche par IP ou règle | Moyenne |
| **Dark mode** | Toggle clair/sombre | Faible (Tailwind `dark:`) |

### 8.2 Moyen terme (1-2 semaines)

| Amélioration | Impact | Complexité |
|--------------|--------|------------|
| **Timeline interactive** | Visualisation chronologique des événements corrélés | Élevée |
| **Graph de relations** | Noeuds IP/Host/User liés (D3.js) | Élevée |
| **Export PDF rapport** | Génération de rapport de shift | Moyenne |
| **Chat SOC libre** | Input texte libre au lieu des 3 boutons fixes | Élevée (prompt engineering) |
| **Multi-langue** | Switch FR/EN | Moyenne |

### 8.3 Production-ready (infrastructure)

| Amélioration | Justification |
|--------------|---------------|
| **Docker + docker-compose** | Portabilité, reproductibilité, déploiement CI/CD |
| **Nginx reverse proxy** | HTTPS, rate limiting, compression, servir le frontend |
| **Redis pour cache dédup** | Persistance cross-reboot, multi-instance |
| **PostgreSQL pour métadonnées** | Historique des utilisateurs, préférences, audit |
| **Prometheus + Grafana** | Métriques temps réel (latence LLM, taux validation, queue) |
| **Celery + RabbitMQ** | File d'attente async pour les enrichissements longs |
| **Tests E2E (Playwright)** | Automatisation des scénarios de démo |
| **RBAC + OAuth2** | Authentification analyste, isolation des tenants |

---

## 9. Préparation production — Roadmap technique

### Phase 1 — Containerisation (1 semaine)

```yaml
# docker-compose.yml
version: '3.8'
services:
  fastapi:
    build: ./app/fastapi
    ports: ["8000:8000"]
    env_file: .env
    depends_on: [elasticsearch, ollama]

  nginx:
    image: nginx:alpine
    ports: ["80:80", "443:443"]
    volumes: ["./nginx.conf:/etc/nginx/nginx.conf"]
    depends_on: [fastapi]

  ollama:
    image: ollama/ollama:latest
    volumes: ["ollama-models:/root/.ollama"]
    deploy:
      resources:
        limits:
          memory: 12G

  elasticsearch:
    image: elasticsearch:8.13.0
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=true
    volumes: ["es-data:/usr/share/elasticsearch/data"]
```

### Phase 2 — Haute disponibilité (2 semaines)

- Load balancer (HAProxy / Nginx upstream)
- FastAPI en mode cluster (3+ instances)
- Redis Sentinel pour cache HA
- Elasticsearch cluster (3 nœuds minimum)
- Backup automatique ES (snapshot S3/minio)

### Phase 3 — Sécurité (1 semaine)

- mTLS interne (service mesh Istio/Linkerd)
- Vault pour secrets (pas de .env en clair)
- WAF (ModSecurity / CloudFlare)
- Audit logging (qui a enrichi quoi quand)

---

## 10. Règles de rollback

Si l'étape échoue :

```bash
sudo systemctl stop soc-ai-fastapi
# Supprimer les fichiers statiques
cd ~/soc-ai-lab/app/fastapi/app/static
rm -rf *.html css/ js/
# Revenir au code étape 9
git checkout step9-validated -- app/fastapi/app/main.py
sudo systemctl start soc-ai-fastapi
```

---

## 11. Décisions architecturales justifiables en soutenance

### 11.1 Pourquoi pas React/Vue/Angular ?

- **Complexité** : Un framework SPA ajoute Webpack, Babel, state management, routing client
- **Valeur** : Pour un MVP, le temps investi dans le frontend framework ne démontre pas la valeur AI
- **Alternative** : Vanilla JS + Tailwind = 7 fichiers, 0 dépendance build, déploiement instantané
- **Évolutivité** : Si V2 nécessite une SPA, le backend API REST est déjà prêt

### 11.2 Pourquoi la persistance via URL et pas localStorage ?

- **Partageable** : L'URL avec `enrichment_id` peut être copiée/collée dans un ticket SOC
- **Bookmarkable** : Un analyste peut bookmarker un incident enrichi
- **Pas de pollution** : localStorage est opaque, difficile à debugger, sensible aux attaques XSS
- **Stateless** : Le serveur ES est la source de vérité, pas le navigateur

### 11.3 Pourquoi Tailwind via CDN et pas build ?

- **Zero build step** : Pas de Node.js, npm, postcss sur la VM
- **Tailwind JIT** : Le CDN charge uniquement les classes utilisées (tree-shaking automatique)
- **Cache navigateur** : Le CDN CloudFlare est probablement déjà en cache chez le jury
- **Limitation** : Pas de custom config (colors, fonts) sans build — acceptable pour MVP

---

## 12. Références

- Plan d'implémentation MVP : `detailled AI-SIEM-Implementation-Plan.md`, section 12 (Étape 10)
- API REST : `/openapi.json` sur `http://10.110.188.66:8000/openapi.json`
- Tailwind CDN : https://cdn.tailwindcss.com
- FastAPI StaticFiles : https://fastapi.tiangolo.com/tutorial/static-files/

---

*Document généré le 2026-05-26 — Étape 10 validée avec persistance URL et restauration depuis ES.*
