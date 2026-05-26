# Étape 8 — Validation des sorties LLM et persistance

> **Document de pilotage technique — AI-Enhanced SIEM MVP**  
> VM cible : `vm-ai-01` (192.168.56.40)  
> Modèle LLM : Qwen3 14B (Q4_K_M) via Ollama  
> Date de validation : 2026-05-25

---

## 1. Objectif de l'étape

Implémenter la couche de **validation** des réponses générées par le LLM et la **persistance** des enrichissements dans l'index Elasticsearch `soc-ai-enrichments-*`.

**Flux complet orchestré par `EnrichmentService` :**

```
Alerte (ES) → Déduplication → Contexte corrélé → Score de risque
    → Construction du prompt → Appel LLM (Ollama) → Validation JSON
    → Retry si invalide → Persistance ES → Mise en cache dédup
```

**Livrables attendus :**
- `validation_service.py` — validation des sorties LLM contre JSON Schema Draft 2020-12
- `enrichment_service.py` — orchestrateur métier complet
- `elastic_repository.py` — méthodes `write_enrichment()` et `get_enrichment()`
- `exceptions.py` — `AlertNotFound` ajouté
- `routes_debug.py` — endpoints `/debug/enrich` et `/debug/enrichment`
- Template ES `soc-ai-enrichments-template`

---

## 2. Architecture et principes

### 2.1 Double barrière de validation

| Couche | Responsabilité | Outil |
|--------|---------------|-------|
| **Génération contrainte** | Forcer la structure JSON (champs requis, types, enums) | Ollama Structured Output (grammaire GBNF) |
| **Validation sémantique** | Vérifier les contraintes fines (longueurs, patterns MITRE, cardinalité) | `jsonschema.Draft202012Validator` |

### 2.2 Document persisté

Chaque enrichissement est stocké dans `soc-ai-enrichments-{yyyy.MM.dd}` avec la structure suivante :

```json
{
  "@timestamp": "2026-05-24T17:28:37.329490+00:00",
  "enrichment_id": "ca8JW54BidyXsbuGYdmH",
  "incident_key": "sha256_hex",
  "source_alert_id": "ta8dKZ4BidyXsbuGs9iV",
  "source_engine": "wazuh",
  "usage": "explain|investigate|remediate",
  "prompt_version": "v1",
  "model": "qwen3:14b",
  "validated": true,
  "risk_score": 78.4,
  "risk_category": "high",
  "occurrences": 12,
  "context_count": 5,
  "latency_ms": 67432,
  "validation_attempts": [
    {"attempt": 1, "valid": true, "errors": [], "llm_latency_ms": 83454}
  ],
  "response": { ... contenu validé selon schéma ... },
  "errors": [],
  "factors": { "severity_norm": 0.8, "occurrence_w": 0.7, "recency_w": 0.9, "mitre_bonus": 0.1 }
}
```

### 2.3 Stratégie de retry

- **1 retry maximum** sur échec de validation (même prompt, même schéma)
- **Pas de retry sur timeout** (déjà géré par `LlmGateway` avec backoff 5s)
- **Fallback structuré** : si 2 échecs consécutifs, on persiste `validated=false` avec `response.raw` et les erreurs

### 2.4 Déduplication composite

La clé de déduplication combine l'incident **et** l'usage :

```
dedup_key = sha256(entity_primary | rule_id | time_bucket_15min) + ":" + usage
```

Cela permet d'enrichir le même incident avec 3 usages différents (`explain`, `investigate`, `remediate`) tout en évitant les appels redondants pour un couple (alerte, usage) donné.

---

## 3. Problème rencontré et correction

### 3.1 Symptôme

Après implémentation initiale, les enrichissements retournaient systématiquement :

```json
{
  "validated": false,
  "errors": [
    "(root): 'summary' is a required property",
    "(root): 'severity_assessment' is a required property",
    "(root): 'key_iocs' is a required property",
    "(root): 'attack_phase' is a required property"
  ],
  "response": {
    "raw": {},
    "errors": [ ... ]
  }
}
```

**Latence anormale :**  
- Tentative 1 : ~83s (inférence réelle)  
- Tentative 2 : ~969ms (modèle génère `{}` instantanément)

### 3.2 Diagnostic

`format: "json"` dans l'API Ollama ne contraint que la **syntaxe** JSON (objet valide, guillemets, virgules). Il ne contraint pas la **structure** (champs requis, types).

Qwen3 14B, face à un prompt complexe et sans contrainte structurelle forte, choisit le chemin de moindre résistance : un objet vide `{}`, syntaxiquement valide mais structurellement vide.

### 3.3 Solution — Structured Outputs Ollama

À partir d'Ollama ≥ 0.5.0, le champ `format` accepte un **schéma JSON complet** au lieu de la simple chaîne `"json"`. Ollama compile ce schéma en une grammaire GBNF (Grammar-Based Neural Network Format) qui force le modèle à générer **uniquement** des tokens respectant la structure demandée.

**Changements appliqués :**

1. **`validation_service.py`** — expose `get_schema(usage)` qui retourne le schéma brut chargé depuis `config/ai/schemas/v1/{usage}_response.schema.json`
2. **`llm_gateway.py`** — méthode `generate()` accepte `response_schema: dict | None`. Si fourni, passe le schéma nettoyé (sans contraintes de longueur/pattern non supportées par la grammaire) dans `payload["format"]`
3. **`enrichment_service.py`** — récupère le schéma avant la boucle LLM et l'injecte dans l'appel

**Nettoyage du schéma pour la grammaire :**

Certaines contraintes JSON Schema (`minLength`, `maxLength`, `pattern`, `minimum`, `maximum`) ne sont pas supportées par le moteur de grammaire llama.cpp sous-jacent. Un helper `_clean_schema_for_ollama()` les supprime récursivement avant l'envoi. Ces contraintes restent vérifiées par `jsonschema` en post-traitement.

### 3.4 Résultat après correction

| Métrique | Avant | Après |
|----------|-------|-------|
| `validated` | `false` (100%) | `true` (structure garantie) |
| `response.summary` | `null` | Texte français structuré |
| `response.severity_assessment` | `null` | Enum valide (`low`/`medium`/`high`/`critical`) |
| Tentative 2 | 969ms (`{}`) | Inutile (tentative 1 passe) |
| Couverture schema | Syntaxe uniquement | Structure + types + enums |

---

## 4. Fichiers modifiés / créés

### 4.1 Création — `app/fastapi/app/services/validation_service.py`

- Charge les 3 schémas JSON (`explain`, `investigate`, `remediate`) au démarrage (`warmup()`)
- Cache les validateurs `Draft202012Validator` et les schémas bruts
- `validate(usage, response)` → `(bool, list[str])`
- `get_schema(usage)` → `dict` (pour Ollama structured output)

### 4.2 Création — `app/fastapi/app/services/enrichment_service.py`

Orchestrateur principal. Méthode `enrich(alert_id, usage)` :

1. Récupération alerte (`AlertService`)
2. Check dédup (`DedupService`) — cache hit → retour immédiat
3. Construction contexte (`ContextService`)
4. Calcul score déterministe (`ScoringService`)
5. Construction prompt (`PromptService`)
6. Appel LLM avec schéma structurant (`LlmGateway.generate(prompt, response_schema=...)`)
7. Validation (`ValidationService`)
8. Retry ×1 si invalide
9. Persistance ES (`ElasticRepository.write_enrichment()`)
10. Registration dédup (`DedupService.register()`)

### 4.3 Modification — `app/fastapi/app/repositories/elastic_repository.py`

Ajout de deux méthodes :
- `write_enrichment(doc)` → indexe dans `soc-ai-enrichments-{date}`, retourne `_id`
- `get_enrichment(enrichment_id)` → recherche par `_id` sur `soc-ai-enrichments-*`

### 4.4 Modification — `app/fastapi/app/services/exceptions.py`

Ajout de `AlertNotFound` pour distinguer les erreurs métier (404) des erreurs techniques (500/502/504).

### 4.5 Modification — `app/fastapi/app/services/llm_gateway.py`

- Helper `_clean_schema_for_ollama()` pour compatibilité grammaire
- Signature `generate(prompt, response_schema=None, json_format=True)`
- Si `response_schema` fourni : `payload["format"] = schema_cleaned`
- Sinon : `payload["format"] = "json"` (fallback)

### 4.6 Modification — `app/fastapi/app/api/routes_debug.py`

Ajout des endpoints :
- `POST /debug/enrich/{usage}/{alert_id}` — flux complet
- `GET /debug/enrichment/{enrichment_id}` — récupération d'un doc persisté
- `GET /debug/prompt/{usage}/{alert_id}` — inspection du prompt généré
- `GET /debug/remediation-actions` — liste des actions fixes

### 4.7 Modification — `app/fastapi/app/main.py`

Initialisation de tous les services dans le `lifespan` :
- `EnrichmentService` instancié avec injection de dépendances
- `PromptService.warmup()` et `ValidationService.warmup()` au boot

---

## 5. Procédure de mise en place

### 5.1 Prérequis

- Étape 7 validée (LLM Gateway complet, sémaphore, retry)
- Ollama ≥ 0.5.0 (support structured outputs)
- Schémas JSON présents dans `config/ai/schemas/v1/`
- Prompts versionnés dans `config/ai/prompts/v1/`

### 5.2 Setup Elasticsearch (une fois)

```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
     -u elastic:'SocSiem2024!' \
     -X PUT "https://10.110.188.110:9200/_index_template/soc-ai-enrichments-template" \
     -H 'Content-Type: application/json' \
     -d '{
  "index_patterns": ["soc-ai-enrichments-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "refresh_interval": "5s"
    },
    "mappings": {
      "dynamic": true,
      "properties": {
        "@timestamp":       {"type": "date"},
        "incident_key":     {"type": "keyword"},
        "source_alert_id":  {"type": "keyword"},
        "source_engine":    {"type": "keyword"},
        "usage":            {"type": "keyword"},
        "prompt_version":   {"type": "keyword"},
        "model":            {"type": "keyword"},
        "validated":        {"type": "boolean"},
        "risk_score":       {"type": "float"},
        "risk_category":    {"type": "keyword"},
        "occurrences":      {"type": "integer"},
        "context_count":    {"type": "integer"},
        "latency_ms":       {"type": "integer"},
        "errors":           {"type": "keyword"},
        "factors":          {"type": "object", "dynamic": true},
        "response":         {"type": "object", "dynamic": true},
        "validation_attempts": {"type": "object", "dynamic": true}
      }
    }
  }
}' | jq
```

**Attendu :** `{"acknowledged": true}`

### 5.3 Déploiement code

```bash
# Copie des fichiers
sudo systemctl restart soc-ai-fastapi
sleep 3
sudo systemctl status soc-ai-fastapi --no-pager | head -10
```

**Attendu au démarrage (logs) :**
```
Validator loaded {usage: explain, ...}
Validator loaded {usage: investigate, ...}
Validator loaded {usage: remediate, ...}
ValidationService warmed up
Application initialized
```

---

## 6. Protocole de validation

### 6.1 Test 1 — Enrichissement explain complet

```bash
WAZUH_ID=$(curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
     -u elastic:'SocSiem2024!' \
     "https://10.110.188.110:9200/wazuh-alerts-*/_search" \
     -H 'Content-Type: application/json' \
     -d '{"size":1,"sort":[{"@timestamp":{"order":"desc"}}]}' \
  | jq -r '.hits.hits[0]._id')

time curl -s -X POST "http://localhost:8000/debug/enrich/explain/$WAZUH_ID" \
  | jq '{
    enrichment_id,
    validated,
    risk_score,
    risk_category,
    usage,
    model,
    latency_ms,
    occurrences,
    context_count,
    response: .response | {summary, severity_assessment, attack_phase, mitre_techniques}
  }'
```

**Critères de succès :**
- `validated: true`
- `enrichment_id` non vide
- `risk_score` entre 0 et 100
- `response.summary` : texte français, ≥ 50 caractères
- `response.severity_assessment` : une des 4 valeurs enum
- `response.attack_phase` : une des 13 phases MITRE
- Latence : 60–120s sur CPU (acceptable pour démo)

### 6.2 Test 2 — Récupération par ID

```bash
ENRICH_ID=<id_du_test_1>

curl -s "http://localhost:8000/debug/enrichment/$ENRICH_ID" \
  | jq '{enrichment_id: ._id, validated, usage, source_alert_id, "@timestamp"}'
```

**Critère :** retourne le même document, `source_alert_id == $WAZUH_ID`.

### 6.3 Test 3 — Cache hit dédup

```bash
echo ">>> Premier appel (lent)..."
time curl -s -X POST "http://localhost:8000/debug/enrich/explain/$WAZUH_ID" \
  | jq '{enrichment_id, _cache_hit, validated}'

echo ">>> Deuxième appel (cache hit, instantané)..."
time curl -s -X POST "http://localhost:8000/debug/enrich/explain/$WAZUH_ID" \
  | jq '{enrichment_id, _cache_hit, validated}'
```

**Attendu :**
- 1er : 60–120s, `_cache_hit: null/false`
- 2e : < 1s, `_cache_hit: true`, même `enrichment_id`

### 6.4 Test 4 — Alert inexistant → 404

```bash
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  "http://localhost:8000/debug/enrich/explain/does-not-exist-xyz"
```

**Attendu :** HTTP 404, detail `"Alert 'does-not-exist-xyz' not found"`.

### 6.5 Test 5 — Usage différent sur même alerte (pas de cache hit)

```bash
time curl -s -X POST "http://localhost:8000/debug/enrich/remediate/$WAZUH_ID" \
  | jq '{enrichment_id, validated, _cache_hit, response: {primary_action, confidence}}'
```

**Attendu :** nouvel `enrichment_id`, `_cache_hit: null`, `primary_action` dans la liste fixe des 10 actions.

### 6.6 Test 6 — Investigate

```bash
curl -s -X POST "http://localhost:8000/debug/enrich/investigate/$WAZUH_ID" \
  | jq '{enrichment_id, validated, queries_count: (.response.queries | length), rationale: .response.rationale}'
```

**Attendu :** 1 à 3 requêtes KQL, `rationale` non vide.

### 6.7 Test 7 — Agrégation ES

```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
     -u elastic:'SocSiem2024!' \
     "https://10.110.188.110:9200/soc-ai-enrichments-*/_search?size=0" \
     -H 'Content-Type: application/json' \
     -d '{"aggs":{"by_usage":{"terms":{"field":"usage"}}}}' \
  | jq '.aggregations.by_usage.buckets'
```

**Attendu :** 3 buckets minimum (`explain`, `investigate`, `remediate`).

### 6.8 Test 8 — Logs structurés

```bash
sudo journalctl -u soc-ai-fastapi -n 100 --no-pager \
  | grep -oE '"message":"[^"]+"' \
  | grep -E "(Enrichment started|Context built|Score computed|Prompt built|Validation result|Enrichment completed)" \
  | tail -20
```

**Attendu :** séquence complète des étapes dans l'ordre pour chaque enrichment.

---

## 7. Checklist de validation Étape 8

| # | Critère | Statut |
|---|---------|--------|
| 1 | Template `soc-ai-enrichments-template` créé (`acknowledged: true`) | ☐ |
| 2 | `pytest -v` toujours vert (tests étapes 1–7) | ☐ |
| 3 | Premier enrichment explain : `validated: true` | ☐ |
| 4 | `risk_score` et `incident_key` calculés **avant** appel LLM | ☐ |
| 5 | GET `/debug/enrichment/{id}` retourne le doc persisté | ☐ |
| 6 | 2e appel même (alert, usage) : `_cache_hit: true`, latence < 1s | ☐ |
| 7 | Alert inexistant : HTTP 404 (pas 500) | ☐ |
| 8 | 3 usages distincts persistés dans ES (agg `by_usage`) | ☐ |
| 9 | Logs montrent 6 étapes par enrichment | ☐ |
| 10 | Aucun OOM dans `dmesg` après plusieurs enrichments | ☐ |
| 11 | `/health` répond toujours 200 | ☐ |
| 12 | Structured output active (`format: <schema>`) dans les logs Ollama | ☐ |

**Étape 8 validée si et seulement si les 12 critères sont verts.**

---

## 8. Règles de rollback

Si l'étape échoue ou devient instable :

```bash
sudo systemctl stop soc-ai-fastapi
# Revenir au code de l'étape 7 (git checkout ou stash)
git stash push -m "step8-attempt"
git checkout step7-validated
sudo systemctl start soc-ai-fastapi
```

Puis corriger et réappliquer les fichiers de l'étape 8.

---

## 9. Décisions architecturales justifiables en soutenance

### 9.1 Pourquoi un score déterministe en amont du LLM ?

Le LLM est non déterministe et coûteux (latence 60–120s). Le score de risque est calculé par formule mathématique **avant** l'appel LLM, ce qui permet :
- De prioriser les incidents sans attendre l'enrichissement
- D'avoir une métrique reproductible et auditable
- De ne pas dépendre de l'humeur du modèle pour la sévérité

### 9.2 Pourquoi deux couches de validation ?

- **Ollama structured output** garantit la structure (champs requis présents, types corrects, enums respectées). C'est une contrainte au niveau du tokenizer/grammar.
- **jsonschema** garantit les contraintes fines (longueur minimale du summary, pattern MITRE T####, cardinalité max). C'est une contrainte applicative.

Cette redondance défensive est nécessaire car les grammaires GBNF d'Ollama ne supportent pas toutes les constructions JSON Schema (regex, min/max length, etc.).

### 9.3 Pourquoi `think: false` ?

Qwen3 supporte un mode "thinking" (raisonnement interne) qui produit du texte hors JSON avant la réponse structurée. Avec `think: false`, on force le modèle à passer directement en mode réponse, éliminant les fuites de chain-of-thought qui cassaient le parsing JSON dans les versions précédentes.

### 9.4 Pourquoi la déduplication est-elle en mémoire et non Redis ?

Vertical slicing MVP. Le cache mémoire (`asyncio.Lock` + dict) prouve le concept à coût zéro. Redis est planifié en V2 pour la résilience multi-instance et la persistance cross-reboot.

---

## 10. Références

- Plan d'implémentation MVP : `detailled AI-SIEM-Implementation-Plan.md`, sections 10 (Étape 8) et 14 (règles de progression)
- Schémas JSON : `config/ai/schemas/v1/`
- Prompts versionnés : `config/ai/prompts/v1/`
- Documentation Ollama Structured Outputs : https://github.com/ollama/ollama/blob/main/docs/api.md#structured-outputs
- JSON Schema Draft 2020-12 : https://json-schema.org/draft/2020-12

---

*Document généré le 2026-05-25 — Étape 8 validée avec structured outputs.*
