# Étape 5 — Déduplication + Scoring déterministe

## 1. Objectif

Implémenter deux services internes :

- **Déduplication par hash d’incident** pour éviter les enrichissements redondants.
- **Score de risque déterministe** pour prioriser les incidents sans LLM.

Cette étape ne branche pas encore ces services aux routes FastAPI. Ils seront intégrés plus tard (étape 8).

---

## 2. Stratégie de déduplication

### 2.1 Clé unifiée (indépendante du `source_engine`)

```text
incident_key = sha256(
  entity_primary +  # source_ip si présent, sinon host_name
  rule_id        +
  time_bucket_15min(timestamp)
)
```

- `entity_primary` = `alert.entity.source_ip` ou `alert.entity.host_name` ou `"unknown"`
- `rule_id` = `alert.rule_id` ou `"unknown"`
- `time_bucket_15min` = `epoch // 900`
- **Résultat** : `sha256(...).hexdigest()[:16]`

### 2.2 Cache en mémoire (TTL)

- Stockage en mémoire : `{incident_key: (enrichment_id, expires_at)}`
- TTL = `DEDUP_TTL_MIN` (30 minutes par défaut)
- Implémentation simple, **pas de Redis** pour le MVP
- Thread-safe via `asyncio.Lock`
- Logs `DEBUG` sur hit/miss

---

## 3. Formule de score

```text
severity_norm   = min(severity, 15) / 15
occurrence_w    = min(log10(occurrences + 1), 1.0)
recency_w       = max(0, 1 - (now - timestamp) / 24h)
mitre_bonus     = 0.1 if mitre_id present else 0

risk_score = round(
  100 * (
    0.4 * severity_norm +
    0.3 * occurrence_w  +
    0.2 * recency_w     +
    0.1 * mitre_bonus
  ), 1
)
```

- Score borné **[0, 100]**
- Catégories :
  - **low** < 40
  - **medium** < 70
  - **high** < 90
  - **critical** ≥ 90

---

## 4. Livrables

Fichiers créés :

```text
app/fastapi/app/services/dedup_service.py
app/fastapi/app/services/scoring_service.py
app/fastapi/tests/conftest.py
app/fastapi/tests/test_scoring.py
app/fastapi/pytest.ini
```

---

## 5. Tests et validation

### 5.1 Tests pytest (scoring)

Commande :

```bash
cd ~/soc-ai-lab/app/fastapi
.venv/bin/pytest -v
```

Attendu :

```text
collected 5 items

tests/test_scoring.py::test_critical_score PASSED
tests/test_scoring.py::test_low_score PASSED
tests/test_scoring.py::test_medium_or_high_score PASSED
tests/test_scoring.py::test_zero_occurrences_no_crash PASSED
tests/test_scoring.py::test_future_timestamp_recency_bounded PASSED
```

### 5.2 Test manuel déduplication

Exemple minimal :

```bash
cd ~/soc-ai-lab/app/fastapi
.venv/bin/python -c "
import asyncio
from datetime import datetime, timezone
from app.services.dedup_service import DedupService
from app.models.alert import AlertCore, Entity

async def main():
    svc = DedupService(ttl_minutes=30)
    alert = AlertCore(
        id='test-001',
        timestamp=datetime.now(timezone.utc),
        source_engine='wazuh',
        rule_id='5763',
        severity=10,
        entity=Entity(source_ip='10.110.188.30'),
    )
    key = svc.compute_key(alert)
    print(f'Key: {key}')
    print(f'Before register: {await svc.check(key)}')
    await svc.register(key, 'enrich-uuid-abc123')
    print(f'After register: {await svc.check(key)}')
    print(f'Cache size: {await svc.size()}')

asyncio.run(main())
"
```

Attendu :

```text
Key: <16-char hex>
Before register: None
After register: enrich-uuid-abc123
Cache size: 1
```

### 5.3 Test TTL (optionnel)

- Forcer un TTL très court (2s) et vérifier que `check(key)` retourne `None` après expiration.

---

## 6. Critères de réussite

- `pytest -v` : 5 tests verts.
- `compute_key()` retourne 16 caractères hex et reste déterministe.
- `check()` retourne `None` avant `register()`.
- `register()` puis `check()` retourne `enrichment_id`.
- Après TTL expiré : `check()` retourne `None`.
- Score sur alerte Wazuh `severity=12`, `occurrences=5`, `age=1h`, MITRE présent → score dans **70–85**.
- FastAPI reste opérationnel (`/health` toujours OK).

---

## 7. Prompts agent IA (trace de génération)

### Prompt 5.A — DedupService

Contexte : éviter d'appeler le LLM deux fois pour le même incident. Cache mémoire simple, TTL configurable.

Tâche : générer `app/fastapi/app/services/dedup_service.py` :

```python
class DedupService:
    def __init__(self, ttl_minutes: int)

    def compute_key(self, alert: AlertCore) -> str:
        # entity_primary = alert.entity.source_ip OR alert.entity.host_name OR "unknown"
        # time_bucket = (timestamp epoch) // 900 (15 min)
        # rule_id = alert.rule_id ou "unknown"
        # return sha256(f"{entity_primary}|{rule_id}|{time_bucket}").hexdigest()[:16]

    def check(self, key: str) -> str | None:
        # retourne enrichment_id existant si présent et non expiré, sinon None
        # purge automatique des entrées expirées

    def register(self, key: str, enrichment_id: str) -> None:
        # ajoute key → (enrichment_id, expires_at)
```

Contraintes :

- thread-safe avec `asyncio.Lock`
- mémoire seulement (pas de Redis)
- log DEBUG sur hit/miss

### Prompt 5.B — ScoringService et tests

Contexte : score déterministe à partir de `IncidentContext`.

Tâches :

1. Générer `app/fastapi/app/services/scoring_service.py` :

```python
class ScoringService:
    @staticmethod
    def compute(ctx: IncidentContext, now: datetime) -> dict:
        # implémente la formule (severity_norm, occurrence_w, recency_w, mitre_bonus)
        # retourne {"score": float, "category": str, "factors": dict}
```

2. Générer `app/fastapi/tests/test_scoring.py` avec 5 tests :

- Severity 15 + 100 occurrences + now + MITRE → score >= 90 (critical)
- Severity 3 + 1 occurrence + 23h ago + no MITRE → score < 40 (low)
- Severity 8 + 5 occurrences + 1h ago + MITRE → 50 <= score <= 80
- occurrences=0 ne crash pas (log10 protection)
- timestamp futur ne crash pas, `recency_w` borné [0, 1]

3. Générer `app/fastapi/tests/conftest.py` avec fixtures synthétiques.

---

## 8. Résultat attendu

Cette étape fournit un **socle de priorisation et de déduplication** prêt à être branché :

- Pas de double enrichissement LLM sur un même incident.
- Score de risque stable et explicable.
- Tests déterministes pour valider la formule.
