"""Health check endpoint."""
import asyncio
import logging
from typing import Any

from fastapi import APIRouter, Request, Response

from app.core.config import get_settings
from app.repositories.elastic_repository import ElasticRepository
from app.services.llm_gateway import LlmGateway

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/health")
async def health(request: Request, response: Response) -> dict[str, Any]:
    settings = get_settings()
    es_repo: ElasticRepository = request.app.state.es_repo
    llm_gw: LlmGateway = request.app.state.llm_gw

    es_ok, llm_ok = await asyncio.gather(
        es_repo.ping(),
        llm_gw.ping(),
    )

    body: dict[str, Any] = {
        "status": "ok" if (es_ok and llm_ok) else "degraded",
        "elasticsearch": "ok" if es_ok else "down",
        "ollama": "ok" if llm_ok else "down",
        "model": settings.ollama_model,
        "version": "0.1.0",
    }

    if not (es_ok and llm_ok):
        response.status_code = 503

    return body
