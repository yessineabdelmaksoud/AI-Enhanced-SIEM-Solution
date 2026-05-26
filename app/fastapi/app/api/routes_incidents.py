"""Aggregated incidents list to feed the analyst UI."""
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Query, Request

from app.core.config import get_settings
from app.models.alert import IncidentContext, from_es_doc
from app.repositories.elastic_repository import ElasticRepository
from app.services.dedup_service import DedupService
from app.services.scoring_service import ScoringService

logger = logging.getLogger(__name__)

router = APIRouter()


def _infer_engine(doc: dict) -> str:
    explicit = doc.get("source_engine")
    if explicit in ("wazuh", "suricata"):
        return explicit
    index = doc.get("_index", "") or ""
    return "wazuh" if index.startswith("wazuh") else "suricata"


@router.get("/incidents")
async def list_incidents(
    request: Request,
    hours: int = Query(default=24, ge=1, le=168),
    limit: int = Query(default=50, ge=1, le=200),
) -> dict:
    """Aggregate recent alerts into incidents, scored and sorted by risk."""
    es_repo: ElasticRepository = request.app.state.es_repo
    dedup_service: DedupService = request.app.state.dedup_service
    settings = get_settings()

    index_pattern = f"{settings.es_index_wazuh},{settings.es_index_suricata}"

    # ---- 1. Aggregate alerts by source.ip in last N hours ----
    agg_response = await es_repo.search_raw(
        index_pattern=index_pattern,
        size=0,
        query={"range": {"@timestamp": {"gte": f"now-{hours}h"}}},
        aggs={
            "incidents": {
                "terms": {
                    "field": "source.ip",
                    "size": limit,
                    "order": {"_count": "desc"},
                    "missing": "0.0.0.0",
                },
                "aggs": {
                    "representative": {
                        "top_hits": {
                            "size": 1,
                            "sort": [{"@timestamp": {"order": "desc"}}],
                        }
                    },
                    "last_seen": {"max": {"field": "@timestamp"}},
                },
            }
        },
    )

    buckets = (
        agg_response.get("aggregations", {})
        .get("incidents", {})
        .get("buckets", [])
    )

    # ---- 2. Collect incident_keys that already have enrichments ----
    enrich_response = await es_repo.search_raw(
        index_pattern=f"{settings.es_index_enrich}-*",
        size=0,
        query={"range": {"@timestamp": {"gte": f"now-{hours}h"}}},
        aggs={"keys": {"terms": {"field": "incident_key", "size": 2000}}},
    )
    enriched_keys = {
        b["key"]
        for b in enrich_response.get("aggregations", {})
        .get("keys", {})
        .get("buckets", [])
    }

    # ---- 3. Build incident summaries ----
    now = datetime.now(timezone.utc)
    incidents: list[dict] = []

    for bucket in buckets:
        hits = bucket.get("representative", {}).get("hits", {}).get("hits", [])
        if not hits:
            continue

        hit = hits[0]
        doc = dict(hit.get("_source", {}))
        doc["_id"] = hit.get("_id")
        doc["_index"] = hit.get("_index")

        engine = _infer_engine(doc)
        try:
            alert = from_es_doc(doc, engine)
        except Exception as exc:
            logger.warning(
                "Failed to parse representative alert",
                extra={"error": str(exc)},
            )
            continue

        occurrences = bucket.get("doc_count", 1)
        ctx = IncidentContext(
            source_alert=alert,
            related_events=[],
            occurrences=occurrences,
        )
        score_info = ScoringService.compute(ctx, now)
        incident_key = dedup_service.compute_key(alert)

        incidents.append({
            "incident_key": incident_key,
            "alert_id": alert.id,
            "source_engine": alert.source_engine,
            "rule_id": alert.rule_id,
            "description": alert.description,
            "entity": alert.entity.model_dump(exclude_none=True),
            "severity": alert.severity,
            "occurrences": occurrences,
            "last_seen": bucket.get("last_seen", {}).get("value_as_string"),
            "risk_score": score_info["score"],
            "risk_category": score_info["category"],
            "has_enrichment": incident_key in enriched_keys,
        })

    # ---- 4. Sort by risk_score desc, then occurrences desc ----
    incidents.sort(
        key=lambda x: (x["risk_score"], x["occurrences"]),
        reverse=True,
    )

    logger.info(
        "Incidents listed",
        extra={"hours": hours, "count": len(incidents)},
    )

    return {
        "hours": hours,
        "count": len(incidents),
        "incidents": incidents[:limit],
    }