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