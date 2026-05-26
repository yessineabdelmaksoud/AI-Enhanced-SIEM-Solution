"""Public enrichment API."""
import logging
from typing import Literal

from fastapi import APIRouter, HTTPException, Request

from app.repositories.elastic_repository import ElasticRepository
from app.services.enrichment_service import EnrichmentService
from app.services.exceptions import (
    AlertNotFound,
    LlmHttpError,
    LlmTimeoutError,
)

logger = logging.getLogger(__name__)

router = APIRouter()

EnrichUsage = Literal["explain", "investigate", "remediate"]


@router.post("/enrich/{alert_id}/{usage}")
async def enrich(alert_id: str, usage: EnrichUsage, request: Request) -> dict:
    """Run the enrichment flow for a given alert and usage.

    Returns the full enrichment document (200), even when the LLM output
    could not be validated (validated=false in the body).

    Errors:
        404 AlertNotFound, 504 LlmTimeoutError, 502 LlmHttpError.
    """
    enrichment_service: EnrichmentService = request.app.state.enrichment_service

    try:
        return await enrichment_service.enrich(alert_id, usage)
    except AlertNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    except LlmTimeoutError as exc:
        raise HTTPException(status_code=504, detail=f"LLM timeout: {exc}")
    except LlmHttpError as exc:
        raise HTTPException(status_code=502, detail=f"LLM unavailable: {exc}")


@router.get("/enrichments/{enrichment_id}")
async def get_enrichment(enrichment_id: str, request: Request) -> dict:
    """Retrieve a previously generated enrichment by id."""
    es_repo: ElasticRepository = request.app.state.es_repo
    doc = await es_repo.get_enrichment(enrichment_id)
    if doc is None:
        raise HTTPException(
            status_code=404,
            detail=f"Enrichment '{enrichment_id}' not found",
        )
    return doc