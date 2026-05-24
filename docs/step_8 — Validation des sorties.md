OK. Étape 8 = 5 fichiers à modifier/créer + 1 setup ES + 1 mise à jour main.py.

---

## Setup — Index template ES (à exécuter une fois)

Crée le template d'index si pas déjà fait :

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

**Attendu** : `{"acknowledged": true}`.

---

## Fichier 1 — Mise à jour `app/fastapi/app/services/exceptions.py`

Ajoute `AlertNotFound` au fichier existant :

```python
"""Custom exceptions raised by the LLM gateway and validation pipeline."""


class LlmTimeoutError(Exception):
    """LLM call timed out (Ollama did not respond within the budget)."""


class LlmInvalidJsonError(Exception):
    """LLM response field is not valid JSON when json_format=True."""


class LlmHttpError(Exception):
    """LLM endpoint returned a non-2xx HTTP status, or unreachable."""


class AlertNotFound(Exception):
    """Source alert not found in any monitored index."""
```

---

## Fichier 2 — Mise à jour `app/fastapi/app/repositories/elastic_repository.py`

Ajoute en **haut du fichier** (avec les imports existants) :

```python
import time
from datetime import datetime, timedelta
```

Si `from datetime import datetime` existait déjà sur une autre ligne, fusionne avec `timedelta`. Ajoute `time` ailleurs si ce n'est pas déjà fait.

Puis ajoute **à la fin de la classe `ElasticRepository`** (après `search_context`) ces deux méthodes :

```python
    async def write_enrichment(self, doc: dict) -> str:
        """Index an enrichment document into soc-ai-enrichments-{date}.

        Returns the generated _id.
        """
        if self._client is None:
            raise RuntimeError("Elasticsearch client not connected")

        index = f"{self._settings.es_index_enrich}-{datetime.utcnow():%Y.%m.%d}"
        t0 = time.monotonic()
        try:
            response = await self._client.index(
                index=index,
                document=doc,
                refresh=False,
            )
            enrichment_id = response.get("_id", "")
            latency_ms = int((time.monotonic() - t0) * 1000)
            logger.info(
                "Enrichment written",
                extra={
                    "enrichment_id": enrichment_id,
                    "index": index,
                    "latency_ms": latency_ms,
                },
            )
            return enrichment_id
        except Exception as exc:
            logger.error(
                "Failed to write enrichment",
                extra={"index": index, "error": str(exc)},
            )
            raise

    async def get_enrichment(self, enrichment_id: str) -> Optional[dict]:
        """Retrieve an enrichment by id from soc-ai-enrichments-*."""
        if self._client is None:
            return None
        try:
            response = await self._client.search(
                index=f"{self._settings.es_index_enrich}-*",
                size=1,
                query={"ids": {"values": [enrichment_id]}},
            )
            hits = response.get("hits", {}).get("hits", [])
            if not hits:
                return None
            doc = hits[0].get("_source", {})
            doc["_id"] = hits[0].get("_id")
            doc["_index"] = hits[0].get("_index")
            return doc
        except Exception as exc:
            logger.error(
                "get_enrichment failed",
                extra={"enrichment_id": enrichment_id, "error": str(exc)},
            )
            return None
```

---

## Fichier 3 — `app/fastapi/app/services/validation_service.py`

```
nano ~/soc-ai-lab/app/fastapi/app/services/validation_service.py
```

```python
"""ValidationService: validate LLM outputs against versioned JSON Schemas."""
import json
import logging
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

logger = logging.getLogger(__name__)


class ValidationService:
    """Cached Draft202012 validators, one per usage."""

    def __init__(self, schemas_dir: Path) -> None:
        self._schemas_dir = Path(schemas_dir)
        self._validator_cache: dict[str, Draft202012Validator] = {}

    def validate(self, usage: str, response: Any) -> tuple[bool, list[str]]:
        """Validate `response` against the schema for `usage`.

        Returns (True, []) when valid, (False, list_of_error_messages) otherwise.
        Never raises.
        """
        if not isinstance(response, dict):
            return False, [
                f"Response must be a JSON object, got {type(response).__name__}"
            ]

        try:
            validator = self._load_validator(usage)
        except (FileNotFoundError, json.JSONDecodeError, KeyError) as exc:
            return False, [f"Schema loading failed: {exc}"]

        errors: list[str] = []
        for err in validator.iter_errors(response):
            path = "/".join(str(p) for p in err.absolute_path) or "(root)"
            errors.append(f"{path}: {err.message}")

        return (len(errors) == 0, errors)

    def warmup(self) -> None:
        """Pre-load all validators."""
        for usage in ("explain", "investigate", "remediate"):
            self._load_validator(usage)
        logger.info("ValidationService warmed up")

    def _load_validator(self, usage: str) -> Draft202012Validator:
        if usage in self._validator_cache:
            return self._validator_cache[usage]

        path = self._schemas_dir / f"{usage}_response.schema.json"
        if not path.exists():
            raise FileNotFoundError(f"Schema not found: {path}")

        schema = json.loads(path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)

        validator = Draft202012Validator(schema)
        self._validator_cache[usage] = validator
        logger.info(
            "Validator loaded",
            extra={"usage": usage, "path": str(path)},
        )
        return validator
```

---

## Fichier 4 — `app/fastapi/app/services/enrichment_service.py`

```
nano ~/soc-ai-lab/app/fastapi/app/services/enrichment_service.py
```

```python
"""EnrichmentService: orchestrate the full enrichment flow."""
import logging
import time
from datetime import datetime, timezone
from typing import Any, Literal

from app.core.config import Settings
from app.models.alert import IncidentContext
from app.repositories.elastic_repository import ElasticRepository
from app.services.alert_service import AlertService
from app.services.context_service import ContextService
from app.services.dedup_service import DedupService
from app.services.exceptions import (
    AlertNotFound,
    LlmHttpError,
    LlmInvalidJsonError,
    LlmTimeoutError,
)
from app.services.llm_gateway import LlmGateway
from app.services.prompt_service import PromptService
from app.services.scoring_service import ScoringService
from app.services.validation_service import ValidationService

logger = logging.getLogger(__name__)


EnrichmentUsage = Literal["explain", "investigate", "remediate"]
PROMPT_VERSION = "v1"


class EnrichmentService:
    """Main business orchestrator.

    Flow: alert -> dedup_check -> context -> score -> prompt -> LLM
          -> validate (1 retry) -> persist -> dedup_register.
    """

    def __init__(
        self,
        alert_svc: AlertService,
        context_svc: ContextService,
        dedup_svc: DedupService,
        scoring_svc: type[ScoringService],
        prompt_svc: PromptService,
        llm_gw: LlmGateway,
        validation_svc: ValidationService,
        es_repo: ElasticRepository,
        settings: Settings,
    ) -> None:
        self._alert_svc = alert_svc
        self._context_svc = context_svc
        self._dedup_svc = dedup_svc
        self._scoring_svc = scoring_svc
        self._prompt_svc = prompt_svc
        self._llm_gw = llm_gw
        self._validation_svc = validation_svc
        self._es_repo = es_repo
        self._settings = settings

    async def enrich(self, alert_id: str, usage: EnrichmentUsage) -> dict:
        """Full enrichment flow.

        Raises:
            AlertNotFound: if the source alert does not exist.
        """
        t_start = time.monotonic()
        log_extra: dict[str, Any] = {"alert_id": alert_id, "usage": usage}
        logger.info("Enrichment started", extra=log_extra)

        # ---- 1. Fetch source alert ----
        alert = await self._alert_svc.get_alert(alert_id)
        if alert is None:
            logger.info("Alert not found", extra=log_extra)
            raise AlertNotFound(f"Alert '{alert_id}' not found")

        # ---- 2-3. Dedup check (composite key: alert + usage) ----
        base_key = self._dedup_svc.compute_key(alert)
        dedup_key = f"{base_key}:{usage}"
        log_extra["incident_key"] = base_key

        existing_id = await self._dedup_svc.check(dedup_key)
        if existing_id is not None:
            existing = await self._es_repo.get_enrichment(existing_id)
            if existing is not None:
                logger.info(
                    "Dedup cache hit",
                    extra={**log_extra, "enrichment_id": existing_id},
                )
                existing["enrichment_id"] = existing_id
                existing["_cache_hit"] = True
                return existing
            else:
                logger.info(
                    "Dedup key matched but enrichment missing from ES, recomputing",
                    extra={**log_extra, "stale_id": existing_id},
                )

        # ---- 4. Build correlated context ----
        ctx: IncidentContext = await self._context_svc.build_context(alert)
        logger.info(
            "Context built",
            extra={
                **log_extra,
                "related_count": len(ctx.related_events),
                "occurrences": ctx.occurrences,
            },
        )

        # ---- 5. Compute deterministic risk score (no LLM) ----
        now = datetime.now(timezone.utc)
        score_info = self._scoring_svc.compute(ctx, now)
        logger.info(
            "Score computed",
            extra={
                **log_extra,
                "risk_score": score_info["score"],
                "risk_category": score_info["category"],
            },
        )

        # ---- 6. Build prompt ----
        prompt = self._prompt_svc.build(usage, ctx)
        logger.info(
            "Prompt built",
            extra={**log_extra, "prompt_chars": len(prompt)},
        )

        # ---- 7-8. LLM call + validation (1 retry on invalid output) ----
        validated = False
        validation_errors: list[str] = []
        llm_response: Any = None
        llm_error: str | None = None
        validation_attempts: list[dict] = []

        for attempt in (1, 2):
            t_llm = time.monotonic()
            try:
                llm_response = await self._llm_gw.generate(prompt, json_format=True)
            except LlmTimeoutError as exc:
                llm_error = "llm_timeout"
                logger.warning(
                    "LLM call failed (timeout)",
                    extra={**log_extra, "attempt": attempt, "error": str(exc)},
                )
                break  # no retry on timeout (already retried inside gateway)
            except (LlmInvalidJsonError, LlmHttpError) as exc:
                llm_error = type(exc).__name__
                logger.warning(
                    "LLM call failed",
                    extra={
                        **log_extra,
                        "attempt": attempt,
                        "error_type": type(exc).__name__,
                        "error": str(exc),
                    },
                )
                if attempt == 1:
                    continue
                break

            llm_latency_ms = int((time.monotonic() - t_llm) * 1000)
            valid, errors = self._validation_svc.validate(usage, llm_response)
            validation_attempts.append({
                "attempt": attempt,
                "valid": valid,
                "errors": errors,
                "llm_latency_ms": llm_latency_ms,
            })
            logger.info(
                "Validation result",
                extra={
                    **log_extra,
                    "attempt": attempt,
                    "valid": valid,
                    "error_count": len(errors),
                    "llm_latency_ms": llm_latency_ms,
                },
            )

            if valid:
                validated = True
                validation_errors = []
                break
            else:
                validation_errors = errors
                if attempt == 1:
                    continue
                break  # validated stays False after 2nd failure

        # ---- 9. Build the persisted document ----
        total_latency_ms = int((time.monotonic() - t_start) * 1000)

        if validated:
            response_field: Any = llm_response
            errors_field: list[str] = []
        elif llm_error == "llm_timeout":
            response_field = {"error": "llm_timeout"}
            errors_field = ["Ollama timeout after 2 attempts"]
        elif llm_error is not None:
            response_field = {"error": llm_error, "raw": llm_response}
            errors_field = [llm_error]
        else:
            response_field = {"raw": llm_response, "errors": validation_errors}
            errors_field = validation_errors

        doc = {
            "@timestamp": now.isoformat(),
            "incident_key": base_key,
            "source_alert_id": alert.id,
            "source_engine": alert.source_engine,
            "usage": usage,
            "prompt_version": PROMPT_VERSION,
            "model": self._settings.ollama_model,
            "validated": validated,
            "risk_score": score_info["score"],
            "risk_category": score_info["category"],
            "factors": score_info["factors"],
            "occurrences": ctx.occurrences,
            "context_count": len(ctx.related_events),
            "latency_ms": total_latency_ms,
            "validation_attempts": validation_attempts,
            "response": response_field,
            "errors": errors_field,
        }

        # ---- 10-11. Persist and register in dedup cache ----
        enrichment_id = await self._es_repo.write_enrichment(doc)
        doc["enrichment_id"] = enrichment_id
        await self._dedup_svc.register(dedup_key, enrichment_id)

        logger.info(
            "Enrichment completed",
            extra={
                **log_extra,
                "enrichment_id": enrichment_id,
                "validated": validated,
                "total_latency_ms": total_latency_ms,
            },
        )

        return doc
```

---

## Fichier 5 — Mise à jour `app/fastapi/app/main.py`

Remplace intégralement :

```python
"""SOC AI Enrichment API entrypoint."""
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI

from app.api import routes_debug, routes_health
from app.core.config import get_settings
from app.core.logging import configure_logging
from app.repositories.elastic_repository import ElasticRepository
from app.services.alert_service import AlertService
from app.services.context_service import ContextService
from app.services.dedup_service import DedupService
from app.services.enrichment_service import EnrichmentService
from app.services.llm_gateway import LlmGateway
from app.services.prompt_service import PromptService
from app.services.scoring_service import ScoringService
from app.services.validation_service import ValidationService

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    configure_logging()
    settings = get_settings()
    logger.info(
        "Starting SOC AI Enrichment API",
        extra={
            "version": "0.1.0",
            "model": settings.ollama_model,
            "es_host": settings.es_host,
        },
    )

    # Repositories
    es_repo = ElasticRepository(settings)
    await es_repo.connect()
    app.state.es_repo = es_repo

    # Gateway
    llm_gw = LlmGateway(settings)
    app.state.llm_gw = llm_gw

    # Domain services
    alert_service = AlertService(es_repo, settings)
    context_service = ContextService(es_repo, settings)
    dedup_service = DedupService(ttl_minutes=settings.dedup_ttl_min)

    prompt_service = PromptService(
        prompts_dir=Path(settings.prompts_dir),
        actions_path=Path(settings.remediation_actions_path),
    )
    prompt_service.warmup()

    validation_service = ValidationService(
        schemas_dir=Path(settings.schemas_dir),
    )
    validation_service.warmup()

    enrichment_service = EnrichmentService(
        alert_svc=alert_service,
        context_svc=context_service,
        dedup_svc=dedup_service,
        scoring_svc=ScoringService,
        prompt_svc=prompt_service,
        llm_gw=llm_gw,
        validation_svc=validation_service,
        es_repo=es_repo,
        settings=settings,
    )

    app.state.alert_service = alert_service
    app.state.context_service = context_service
    app.state.dedup_service = dedup_service
    app.state.prompt_service = prompt_service
    app.state.validation_service = validation_service
    app.state.enrichment_service = enrichment_service

    logger.info("Application initialized")

    try:
        yield
    finally:
        logger.info("Shutting down")
        await es_repo.close()
        await llm_gw.close()


app = FastAPI(
    title="SOC AI Enrichment API",
    version="0.1.0",
    description="Post-detection enrichment layer for SOC analysts",
    lifespan=lifespan,
)

app.include_router(routes_health.router, tags=["health"])
app.include_router(routes_debug.router, prefix="/debug", tags=["debug"])
```

---

## Fichier 6 — Mise à jour `app/fastapi/app/api/routes_debug.py`

Réécriture intégrale (ajoute 2 routes : POST /debug/enrich et GET /debug/enrichment) :

```python
"""Debug endpoints for visual validation of intermediate steps."""
import logging

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.models.alert import IncidentContext
from app.repositories.elastic_repository import ElasticRepository
from app.services.alert_service import AlertService
from app.services.context_service import ContextService
from app.services.enrichment_service import EnrichmentService
from app.services.exceptions import (
    AlertNotFound,
    LlmHttpError,
    LlmInvalidJsonError,
    LlmTimeoutError,
)
from app.services.llm_gateway import LlmGateway
from app.services.prompt_service import PromptService

logger = logging.getLogger(__name__)

router = APIRouter()


class LlmDebugRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=20000)
    json_format: bool = True


# ---------- Context (step 4) ----------

@router.get("/context/{alert_id}", response_model=IncidentContext)
async def get_context(alert_id: str, request: Request) -> IncidentContext:
    alert_service: AlertService = request.app.state.alert_service
    context_service: ContextService = request.app.state.context_service

    alert = await alert_service.get_alert(alert_id)
    if alert is None:
        raise HTTPException(404, f"Alert '{alert_id}' not found")

    return await context_service.build_context(alert)


# ---------- Prompt (step 6) ----------

@router.get("/prompt/{usage}/{alert_id}")
async def get_prompt(usage: str, alert_id: str, request: Request) -> dict:
    if usage not in ("explain", "investigate", "remediate"):
        raise HTTPException(400, f"Invalid usage '{usage}'")

    alert_service: AlertService = request.app.state.alert_service
    context_service: ContextService = request.app.state.context_service
    prompt_service: PromptService = request.app.state.prompt_service

    alert = await alert_service.get_alert(alert_id)
    if alert is None:
        raise HTTPException(404, f"Alert '{alert_id}' not found")

    context = await context_service.build_context(alert)
    prompt = prompt_service.build(usage, context)  # type: ignore[arg-type]

    return {
        "usage": usage,
        "alert_id": alert_id,
        "prompt_chars": len(prompt),
        "estimated_tokens": len(prompt) // 4,
        "prompt": prompt,
    }


@router.get("/remediation-actions")
async def list_actions(request: Request) -> dict:
    prompt_service: PromptService = request.app.state.prompt_service
    return {"actions": prompt_service.list_remediation_actions()}


# ---------- LLM direct (step 7) ----------

@router.post("/llm")
async def debug_llm(body: LlmDebugRequest, request: Request) -> dict:
    llm_gw: LlmGateway = request.app.state.llm_gw

    try:
        result = await llm_gw.generate(body.prompt, json_format=body.json_format)
    except LlmTimeoutError as exc:
        raise HTTPException(504, f"LLM timeout: {exc}")
    except LlmInvalidJsonError as exc:
        raise HTTPException(502, f"LLM returned invalid JSON: {exc}")
    except LlmHttpError as exc:
        raise HTTPException(502, f"LLM HTTP error: {exc}")

    return {"status": "ok", "response": result}


# ---------- Full enrichment (step 8) ----------

@router.post("/enrich/{usage}/{alert_id}")
async def debug_enrich(usage: str, alert_id: str, request: Request) -> dict:
    """Full enrichment flow. Persists to soc-ai-enrichments-*."""
    if usage not in ("explain", "investigate", "remediate"):
        raise HTTPException(400, f"Invalid usage '{usage}'")

    enrichment_service: EnrichmentService = request.app.state.enrichment_service

    try:
        return await enrichment_service.enrich(alert_id, usage)  # type: ignore[arg-type]
    except AlertNotFound as exc:
        raise HTTPException(404, str(exc))


@router.get("/enrichment/{enrichment_id}")
async def debug_get_enrichment(enrichment_id: str, request: Request) -> dict:
    """Retrieve a persisted enrichment by id."""
    es_repo: ElasticRepository = request.app.state.es_repo
    doc = await es_repo.get_enrichment(enrichment_id)
    if doc is None:
        raise HTTPException(404, f"Enrichment '{enrichment_id}' not found")
    return doc
```

---

## Redémarrage

```bash
sudo systemctl restart soc-ai-fastapi
sleep 3
sudo systemctl status soc-ai-fastapi --no-pager | head -10
sudo journalctl -u soc-ai-fastapi -n 20 --no-pager | grep -E "(warmed|Application initialized)"
```

Tu dois voir `Validator loaded` x3, `ValidationService warmed up`, `Application initialized`.

---

## Validation

### Test 1 — Premier enrichissement complet (explain)

```bash
# Récupère un alert ID Wazuh récent
WAZUH_ID=$(curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
     -u elastic:'SocSiem2024!' \
     "https://10.110.188.110:9200/wazuh-alerts-*/_search" \
     -H 'Content-Type: application/json' \
     -d '{"size":1,"sort":[{"@timestamp":{"order":"desc"}}]}' \
  | jq -r '.hits.hits[0]._id')

echo "Wazuh alert ID: $WAZUH_ID"

# Premier enrichment (60-120s sur CPU)
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

**Attendu** : `validated: true`, `enrichment_id` non vide, `risk_score` entre 0 et 100, `response.summary` non vide en français.

### Test 2 — Récupérer l'enrichment par id

```bash
# Réutilise l'enrichment_id du test 1
ENRICH_ID=$(curl -s -X POST "http://localhost:8000/debug/enrich/explain/$WAZUH_ID" | jq -r '.enrichment_id')

curl -s "http://localhost:8000/debug/enrichment/$ENRICH_ID" \
  | jq '{enrichment_id: ._id, validated, usage, source_alert_id, "@timestamp"}'
```

**Attendu** : retourne le même document, `source_alert_id == $WAZUH_ID`.

### Test 3 — Cache hit dédup (2e appel instantané)

```bash
echo ">>> Premier appel (lent)..."
time curl -s -X POST "http://localhost:8000/debug/enrich/explain/$WAZUH_ID" \
  | jq '{enrichment_id, _cache_hit, validated}'

echo ""
echo ">>> Deuxième appel (cache hit, instantané)..."
time curl -s -X POST "http://localhost:8000/debug/enrich/explain/$WAZUH_ID" \
  | jq '{enrichment_id, _cache_hit, validated}'
```

**Attendu** :
- 1er : 60-120s, `_cache_hit` absent (donc null en jq) ou false
- 2e : < 1s, `_cache_hit: true`, même `enrichment_id`

### Test 4 — Alert inexistant → 404

```bash
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  "http://localhost:8000/debug/enrich/explain/does-not-exist-xyz"
```

**Attendu** : HTTP 404, detail `Alert 'does-not-exist-xyz' not found`.

### Test 5 — Usage différent sur le même alerte (pas de cache hit, dédup composite)

```bash
# remediate avec le même alert ID → nouvel enrichment, pas de cache hit
time curl -s -X POST "http://localhost:8000/debug/enrich/remediate/$WAZUH_ID" \
  | jq '{
    enrichment_id,
    validated,
    _cache_hit,
    response: .response | {primary_action, confidence}
  }'
```

**Attendu** : nouvel `enrichment_id` (différent de l'explain), `_cache_hit: null`, `primary_action` dans la liste fixe.

### Test 6 — Investigate

```bash
curl -s -X POST "http://localhost:8000/debug/enrich/investigate/$WAZUH_ID" \
  | jq '{
    enrichment_id,
    validated,
    queries_count: (.response.queries | length),
    rationale: .response.rationale
  }'
```

**Attendu** : 1 à 3 requêtes, rationale en français.

### Test 7 — Index ES rempli

```bash
# Liste les enrichments persistés
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
     -u elastic:'SocSiem2024!' \
     "https://10.110.188.110:9200/soc-ai-enrichments-*/_search?size=10" \
     -H 'Content-Type: application/json' \
     -d '{"sort":[{"@timestamp":{"order":"desc"}}]}' \
  | jq '.hits.hits[] | {id: ._id, validated: ._source.validated, usage: ._source.usage, risk_score: ._source.risk_score, score_category: ._source.risk_category}'

# Compte par usage
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
     -u elastic:'SocSiem2024!' \
     "https://10.110.188.110:9200/soc-ai-enrichments-*/_search?size=0" \
     -H 'Content-Type: application/json' \
     -d '{"aggs":{"by_usage":{"terms":{"field":"usage"}}}}' \
  | jq '.aggregations.by_usage.buckets'
```

**Attendu** : 3+ documents, répartis sur explain, remediate, investigate.

### Test 8 — Logs structurés des étapes

```bash
sudo journalctl -u soc-ai-fastapi -n 100 --no-pager \
  | grep -oE '"message":"[^"]+"' | grep -E "(Enrichment started|Context built|Score computed|Prompt built|Validation result|Enrichment completed)" \
  | tail -20
```

**Attendu** : voir les étapes successives dans l'ordre pour chaque enrichment.

---

## Critères de validation Étape 8

| Critère | Statut |
|---|---|
| Template `soc-ai-enrichments-template` créé (`{"acknowledged": true}`) | ☐ |
| `pytest -v` toujours vert (les anciens tests) | ☐ |
| Premier enrichment explain : `validated: true` | ☐ |
| `risk_score` et `incident_key` présents AVANT appel LLM (visible dans logs avant `LLM generation complete`) | ☐ |
| GET `/debug/enrichment/{id}` retourne le doc persisté | ☐ |
| 2e appel même (alert, usage) : `_cache_hit: true`, latence < 1s | ☐ |
| Alert inexistant : HTTP 404 (pas 500) | ☐ |
| 3 usages distincts persistés dans ES (vérifié via agg `by_usage`) | ☐ |
| Logs montrent 6 étapes par enrichment (started, context_built, score, prompt, validation, completed) | ☐ |
| Aucun OOM dans `dmesg | tail -20` après plusieurs enrichments | ☐ |
| `/health` répond toujours 200 | ☐ |

---

**Crée les fichiers, redémarre, fais les 8 tests. Donne-moi en retour :**

1. Sortie compact du test 1 (`validated`, `risk_score`, `summary` tronqué)
2. Latence du test 3 (1er appel vs 2e appel — gain attendu : 60-120s → < 1s)
3. Compteur d'usages du test 7 (agg `by_usage`)
4. Tout `OOM` dans `dmesg | tail -20`

Si tout est vert, on passe à **Étape 9 — Endpoint `/enrich` public + liste `/incidents`** où on formalise les routes hors `/debug` et on ajoute l'agrégation pour le futur UI.