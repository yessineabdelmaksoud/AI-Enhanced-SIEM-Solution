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