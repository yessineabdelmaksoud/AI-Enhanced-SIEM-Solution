# Étape 9 — Endpoint `/enrich` public et liste `/incidents`

> **Document de pilotage technique — AI-Enhanced SIEM MVP**  
> VM cible : `vm-ai-01` (192.168.56.40)  
> Modèle LLM : Qwen3 14B (Q4_K_M) via Ollama  
> Date de validation : 2026-05-25

---

## 1. Objectif de l'étape

Formaliser l'**API publique** d'enrichissement et exposer l'**agrégation d'incidents** pour alimenter l'interface utilisateur du MVP.

**Routes exposées :**

| Méthode | Route | Description |
|---------|-------|-------------|
| `POST` | `/enrich/{alert_id}/{usage}` | Enrichir une alerte (explain, investigate, remediate) |
| `GET`  | `/enrichments/{enrichment_id}` | Récupérer un enrichissement persisté |
| `GET`  | `/incidents?hours=&limit=` | Lister les incidents agrégés des dernières N heures |

**Livrables attendus :**
- `routes_enrich.py` — routes publiques `/enrich` et `/enrichments`
- `routes_incidents.py` — agrégation ES par entité avec scoring
- `elastic_repository.py` — méthode `search_raw()` pour requêtes ES génériques
- `main.py` — inclusion des nouveaux routers

---

## 2. Architecture et principes

### 2.1 Séparation des routes

| Espace | Préfixe | Usage |
|--------|---------|-------|
| **Public** | `/` | API consommée par l'UI et les tests E2E |
| **Debug** | `/debug/` | Inspection interne (prompt, contexte, LLM brut) |

Les routes publiques retournent des documents complets prêts à l'affichage. Les routes debug servent au développement et au débogage.

### 2.2 Agrégation des incidents

L'endpoint `/incidents` effectue une agrégation Elasticsearch en deux passes :

1. **Agrégation par `source.ip`** sur `wazuh-alerts-*` et `suricata-eve-*` (top hits représentatif + max timestamp)
2. **Scan des enrichissements existants** sur `soc-ai-enrichments-*` pour marquer `has_enrichment: true`

Chaque bucket est ensuite scoré via `ScoringService.compute()` (déterministe, sans LLM) et trié par `risk_score` décroissant.

**Limitation assumée du MVP :** l'agrégation est faite sur `source.ip` uniquement. Les alertes sans IP source tombent dans un bucket `0.0.0.0`. Une agrégation composite multi-entité (`source.ip` OR `host.name` OR `user.name`) est repoussée en V2.

### 2.3 Gestion d'erreurs typées

| Exception | HTTP | Message client |
|-----------|------|----------------|
| `AlertNotFound` | 404 | `Alert 'xxx' not found` |
| `LlmTimeoutError` | 504 | `LLM timeout: ...` |
| `LlmHttpError` | 502 | `LLM unavailable: ...` |

Les erreurs 502/504 concernent Ollama. Les erreurs 404 concernent les alertes source introuvables dans ES.

---

## 3. Fichiers modifiés / créés

### 3.1 Création — `app/fastapi/app/api/routes_enrich.py`

- `POST /enrich/{alert_id}/{usage}` : appelle `EnrichmentService.enrich()`, propage les erreurs typées en HTTP
- `GET /enrichments/{enrichment_id}` : recherche par `_id` dans `soc-ai-enrichments-*`

### 3.2 Création — `app/fastapi/app/api/routes_incidents.py`

- `GET /incidents?hours=24&limit=50` :
  - Requête ES `terms` sur `source.ip` avec `top_hits` représentatif
  - Parsing via `from_es_doc()` → `AlertCore`
  - Scoring via `ScoringService.compute()`
  - Marquage `has_enrichment` via scan secondaire sur `soc-ai-enrichments-*`
  - Tri final par `risk_score` desc

### 3.3 Modification — `app/fastapi/app/repositories/elastic_repository.py`

Ajout de `search_raw()` :
- Wrapper générique autour de `AsyncElasticsearch.search()`
- Accepte `index_pattern`, `query`, `aggs`, `sort`, `size`, `timeout`
- Retourne `{}` en cas d'erreur (jamais d'exception remontée à l'API)
- Utilisé par `routes_incidents` pour les agrégations complexes

### 3.4 Modification — `app/fastapi/app/main.py`

- Import des nouveaux routers : `routes_enrich`, `routes_incidents`
- `app.include_router(routes_enrich.router, tags=["enrichment"])`
- `app.include_router(routes_incidents.router, tags=["incidents"])`

---

## 4. Problème rencontré et correction

### 4.1 Symptôme — Investigate retournait `validated: false`

```json
{
  "validated": false,
  "validation_attempts": [
    {
      "attempt": 1,
      "valid": false,
      "errors": [
        "queries/0: 'title' is a required property",
        "queries/1: 'title' is a required property",
        "queries/2: 'title' is a required property"
      ]
    },
    {
      "attempt": 2,
      "valid": false,
      "errors": [ ...mêmes erreurs... ]
    }
  ]
}
```

Le LLM générait correctement `kql`, `expected_findings` et `rationale`, mais **omettait le champ `title`** dans chaque objet de la liste `queries`.

### 4.2 Diagnostic

Le helper `_clean_schema_for_ollama()` dans `llm_gateway.py` supprimait abusivement la clé `title` lors du nettoyage récursif du schéma JSON. En réalité :
- `title` est une **propriété métier** du schéma investigate (nom de la requête KQL)
- Ce n'est **pas** une métadonnée JSON Schema à supprimer

Le nettoyage initial utilisait un seul ensemble de clés à supprimer (`_GRAMMAR_DROP_KEYS`) sans distinction entre :
- **Métadonnées de schéma** (`$schema`, `$id`, `title` au niveau racine)
- **Contraintes de validation** (`minLength`, `maxLength`, `pattern`, `minimum`, `maximum`, `uniqueItems`)
- **Propriétés métier** (`title` comme champ d'un objet query)

### 4.3 Solution — Nettoyage différencié du schéma

Refonte de `_clean_schema_for_ollama()` avec deux règles distinctes :

```python
_TOP_LEVEL_META_KEYS = {"$schema", "$id", "title"}  # uniquement racine
_CONSTRAINT_KEYS = {
    "minLength", "maxLength", "pattern",
    "minimum", "maximum", "uniqueItems",
}
```

| Règle | Clés supprimées | Niveau |
|-------|-----------------|--------|
| Métadonnées | `$schema`, `$id`, `title` | **Uniquement top-level** (`_depth == 0`) |
| Contraintes | `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`, `uniqueItems` | **Tous les niveaux** |

**Conséquence positive secondaire :** `minItems` et `maxItems` sont **conservés** car ils sont enforceables par la grammaire GBNF d'Ollama. Cela renforce la contrainte structurelle (array de 1 à 3 éléments).

### 4.4 Résultat après correction

| Métrique | Avant | Après |
|----------|-------|-------|
| `validated` (investigate) | `false` | `true` |
| `queries_count` | `null` (échec validation) | `3` |
| `queries[].title` | Absent | Présent et rempli |
| `queries[].kql` | Présent | Présent avec filtre `@timestamp` |
| `queries[].expected_findings` | Présent | Présent en français |

---

## 5. Procédure de mise en place

### 5.1 Prérequis

- Étape 8 validée (`validated: true` sur explain, remediate, investigate)
- Template ES `soc-ai-enrichments-template` en place
- Ollama ≥ 0.5.0 avec structured outputs actifs
- Au moins 50 alertes Wazuh et 20 alertes Suricata indexées

### 5.2 Déploiement

```bash
# 1. Créer les fichiers routes_enrich.py et routes_incidents.py
# 2. Ajouter search_raw() dans elastic_repository.py
# 3. Mettre à jour main.py (imports + include_router)

sudo systemctl restart soc-ai-fastapi
sleep 3
sudo systemctl status soc-ai-fastapi --no-pager | head -8
```

### 5.3 Vérification des routes exposées

```bash
curl -s http://localhost:8000/openapi.json | jq -r '.paths | keys[]'
```

**Attendu :**
```
/enrich/{alert_id}/{usage}
/enrichments/{enrichment_id}
/health
/incidents
/debug/context/{alert_id}
/debug/enrich/{usage}/{alert_id}
/debug/enrichment/{enrichment_id}
/debug/llm
/debug/prompt/{usage}/{alert_id}
/debug/remediation-actions
```

---

## 6. Protocole de validation

### 6.1 Test 1 — Enrichissement explain (endpoint public)

```bash
ALERT_ID=$(curl -sk --cacert ~/soc-ai-lab/certs/ca.crt      -u elastic:'SocSiem2024!'      "https://10.110.188.110:9200/wazuh-alerts-*/_search"      -H 'Content-Type: application/json'      -d '{
       "size": 1,
       "query": {"terms": {"wazuh.rule_id": ["5763","5712","5710","5716"]}},
       "sort": [{"@timestamp": {"order": "desc"}}]
     }' | jq -r '.hits.hits[0]._id')

echo "Alert ID: $ALERT_ID"

time curl -s -X POST "http://localhost:8000/enrich/$ALERT_ID/explain"   | jq '{
    enrichment_id,
    validated,
    risk_score,
    risk_category,
    summary: .response.summary,
    attack_phase: .response.attack_phase,
    mitre: .response.mitre_techniques
  }'
```

**Critères de succès :**
- `validated: true`
- `risk_score` entre 0 et 100
- `summary` : texte français structuré, ≥ 50 caractères
- `attack_phase` : une des 13 phases MITRE
- Latence : 60–120s sur CPU

**Résultat observé (2026-05-25) :**
```json
{
  "enrichment_id": "da-ZXJ4BidyXsbuGr9kf",
  "validated": true,
  "risk_score": 28.6,
  "risk_category": "low",
  "summary": "Deux tentatives de connexion SSH ont été enregistrées depuis l'IP 10.110.188.90...",
  "attack_phase": "credential_access",
  "mitre": ["T1110.001", "T1021.004"]
}
```

### 6.2 Test 2 — GET /enrichments/{id}

```bash
ENRICH_ID=$(curl -s -X POST "http://localhost:8000/enrich/$ALERT_ID/explain" | jq -r '.enrichment_id')

curl -s "http://localhost:8000/enrichments/$ENRICH_ID"   | jq '{id: ._id, validated, usage, source_alert_id, risk_score}'
```

**Attendu :** même document, `source_alert_id == $ALERT_ID`.

**Résultat observé :**
```json
{
  "id": "da-ZXJ4BidyXsbuGr9kf",
  "validated": true,
  "usage": "explain",
  "source_alert_id": "zLCzHJ4B-2SSazc-fF1-",
  "risk_score": 28.6
}
```

### 6.3 Test 3 — Cache hit dédup (2e appel instantané)

```bash
echo ">>> Premier appel (lent)..."
time curl -s -X POST "http://localhost:8000/enrich/$ALERT_ID/explain"   | jq '{enrichment_id, _cache_hit, validated}'

echo ">>> Deuxième appel (cache hit)..."
time curl -s -X POST "http://localhost:8000/enrich/$ALERT_ID/explain"   | jq '{enrichment_id, _cache_hit, validated}'
```

**Attendu :**
- 1er : 60–120s, `_cache_hit: null`
- 2e : < 1s, `_cache_hit: true`, même `enrichment_id`

**Résultat observé :** 76ms pour le 2e appel.

### 6.4 Test 4 — Remediate

```bash
curl -s -X POST "http://localhost:8000/enrich/$ALERT_ID/remediate"   | jq '{
    validated,
    primary_action: .response.primary_action,
    confidence: .response.confidence,
    justification: .response.justification,
    alternatives: .response.alternatives
  }'
```

**Attendu :** `primary_action` dans la liste fixe des 10 actions.

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

### 6.5 Test 5 — Investigate (KQL queries)

```bash
curl -s -X POST "http://localhost:8000/enrich/$ALERT_ID/investigate"   | jq '{
    validated,
    queries_count: (.response.queries | length),
    titles: [.response.queries[].title],
    kql_samples: [.response.queries[].kql]
  }'
```

**Attendu :** 1 à 3 requêtes, chaque `kql` avec filtre `@timestamp`.

**Résultat observé (après correction schéma) :**
```json
{
  "validated": true,
  "queries_count": 3,
  "titles": [
    "Tentatives de connexion SSH depuis IP suspecte",
    "Alertes sur hôte cible",
    "Historique des tentatives de brute force"
  ],
  "kql_samples": [
    "wazuh.rule_id : "5710" and source.ip : "10.110.188.90" and @timestamp >= "now-24h"",
    "host.name : "vmwazuh-CloudStack-KVM-Hypervisor" and @timestamp >= "now-24h"",
    "wazuh.rule_id : "5710" and @timestamp >= "now-24h""
  ]
}
```

### 6.6 Test 6 — GET /incidents

```bash
curl -s "http://localhost:8000/incidents?hours=24&limit=50"   | jq '{
    count,
    top5: [.incidents[:5][] | {
      rule_id,
      source_engine,
      entity: (.entity.source_ip // .entity.host_name),
      occurrences,
      risk_score,
      risk_category,
      has_enrichment
    }]
  }'
```

**Attendu :**
- `count` ≥ 1
- Tri par `risk_score` décroissant
- `has_enrichment: true` pour l'alerte enrichie

**Résultat observé :**
```json
{
  "count": 1,
  "top5": [
    {
      "rule_id": "2013504",
      "source_engine": "suricata",
      "entity": "10.110.188.115",
      "occurrences": 16,
      "risk_score": 43.1,
      "risk_category": "medium",
      "has_enrichment": false
    }
  ]
}
```

### 6.7 Test 7 — 404 sur alerte inexistante

```bash
curl -s -w "
HTTP %{http_code}
" -X POST   "http://localhost:8000/enrich/no-such-alert-999/explain"
```

**Attendu :** HTTP 404.

**Résultat observé :**
```
{"detail":"Alert 'no-such-alert-999' not found"}
HTTP 404
```

---

## 7. Checklist de validation Étape 9

| # | Critère | Statut |
|---|---------|--------|
| 1 | `/openapi.json` liste `/enrich/{alert_id}/{usage}`, `/enrichments/{id}`, `/incidents` | ✅ |
| 2 | Brute force SSH → alerte Wazuh 5763/5712 indexée | ✅ |
| 3 | POST `/enrich/{id}/explain` → 200, `validated: true` en ~60-120s | ✅ |
| 4 | GET `/enrichments/{id}` retourne le même document | ✅ |
| 5 | 2e POST explain → `_cache_hit: true`, < 1s | ✅ |
| 6 | POST remediate → `primary_action` dans la liste fixe | ✅ |
| 7 | POST investigate → 1 à 3 requêtes KQL avec filtre `@timestamp` | ✅ |
| 8 | GET `/incidents` → liste non vide triée par `risk_score` desc | ✅ |
| 9 | POST sur alerte inexistante → HTTP 404 | ✅ |
| 10 | `/health` répond toujours 200 | ✅ |
| 11 | `_clean_schema_for_ollama` ne supprime plus les propriétés métier | ✅ |

**Étape 9 validée : 11/11 critères verts.**

---

## 8. Règles de rollback

Si l'étape échoue :

```bash
sudo systemctl stop soc-ai-fastapi
# Revenir au code de l'étape 8 (git checkout ou stash)
git stash push -m "step9-attempt"
git checkout step8-validated
sudo systemctl start soc-ai-fastapi
```

---

## 9. Décisions architecturales justifiables en soutenance

### 9.1 Pourquoi deux espaces de routes (public / debug) ?

La séparation `/` vs `/debug/` permet de garder une API propre pour l'UI tout en conservant des outils d'inspection interne (prompt, contexte brut, appel LLM direct) pour le développement et le débogage en soutenance. L'UI ne consomme que les routes publiques.

### 9.2 Pourquoi l'agrégation par `source.ip` et non composite ?

Vertical slicing MVP. Une agrégation composite multi-entité (`source.ip` OR `host.name` OR `user.name`) est plus complexe à implémenter et à scorer. L'IP est l'entité la plus fréquemment présente dans les alertes réseau (Wazuh auth + Suricata). Le bucket `0.0.0.0` avec fallback `host.name` couvre les cas restants.

### 9.3 Pourquoi `search_raw()` dans le repository ?

`search_raw()` est un wrapper générique qui encapsule la complexité ES (index patterns, aggs, timeout) tout en garantissant qu'aucune exception ES ne remonte à l'API. Il retourne `{}` en cas d'erreur, ce qui permet à `routes_incidents` de continuer avec une liste vide plutôt que de crasher.

### 9.4 Pourquoi le scoring est-il recalculé à la volée dans `/incidents` ?

Le score est déterministe (formule mathématique). Il n'a pas besoin d'être stocké : il peut être recalculé à chaque appel à partir de l'`IncidentContext` reconstruit. Cela évite la dénormalisation et garantit que le score reflète toujours l'état actuel des données (notamment la recency).

---

## 10. Références

- Plan d'implémentation MVP : `detailled AI-SIEM-Implementation-Plan.md`, sections 11 (Étape 9)
- Schémas JSON : `config/ai/schemas/v1/`
- Prompts versionnés : `config/ai/prompts/v1/`
- Correction étape 8 (structured outputs) : README_Etape8_Validation_Persistance.md
- Documentation Ollama Structured Outputs : https://github.com/ollama/ollama/blob/main/docs/api.md#structured-outputs

---

*Document généré le 2026-05-25 — Étape 9 validée avec correction du nettoyage de schéma Ollama.*
