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
        # Schema used to constrain Ollama generation (structured output)
        response_schema = self._validation_svc.get_schema(usage)
        
        for attempt in (1, 2):
            t_llm = time.monotonic()
            try:
                llm_response = await self._llm_gw.generate(
                    prompt, response_schema=response_schema
                )
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