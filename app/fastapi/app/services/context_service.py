"""ContextService: build the correlated context around a source alert."""
import logging
from typing import Literal

from app.core.config import Settings
from app.models.alert import (
    AlertCore,
    ContextEvent,
    IncidentContext,
    from_es_doc,
)
from app.repositories.elastic_repository import ElasticRepository

logger = logging.getLogger(__name__)


class ContextService:
    def __init__(self, repo: ElasticRepository, settings: Settings) -> None:
        self._repo = repo
        self._settings = settings

    async def build_context(self, source: AlertCore) -> IncidentContext:
        """Find related events in the configured time window around source."""
        if source.entity.is_empty():
            logger.info(
                "No correlatable entity in source alert",
                extra={"alert_id": source.id, "context_count": 0},
            )
            return IncidentContext(
                source_alert=source,
                related_events=[],
                occurrences=1,
            )

        entities = {
            "source_ip": source.entity.source_ip,
            "destination_ip": source.entity.destination_ip,
            "host_name": source.entity.host_name,
            "user_name": source.entity.user_name,
        }

        index_pattern = (
            f"{self._settings.es_index_wazuh},{self._settings.es_index_suricata}"
        )

        hits = await self._repo.search_context(
            source_id=source.id,
            timestamp=source.timestamp,
            window_minutes=self._settings.context_window_min,
            entities=entities,
            index_pattern=index_pattern,
        )

        related_events: list[ContextEvent] = []
        occurrences = 1

        for hit in hits:
            engine = self._infer_engine(hit)
            try:
                core = from_es_doc(hit, engine)
            except Exception as exc:
                logger.warning(
                    "Failed to parse context hit",
                    extra={"_id": hit.get("_id"), "error": str(exc)},
                )
                continue

            delta = int((core.timestamp - source.timestamp).total_seconds())

            related_events.append(
                ContextEvent(
                    id=core.id,
                    index=core.index,
                    timestamp=core.timestamp,
                    source_engine=core.source_engine,
                    rule_id=core.rule_id,
                    severity=core.severity,
                    description=core.description,
                    mitre_id=core.mitre_id,
                    mitre_tactic=core.mitre_tactic,
                    entity=core.entity,
                    delta_seconds=delta,
                )
            )

            if core.rule_id is not None and core.rule_id == source.rule_id:
                occurrences += 1

        logger.info(
            "Context built",
            extra={
                "alert_id": source.id,
                "context_count": len(related_events),
                "occurrences": occurrences,
            },
        )

        return IncidentContext(
            source_alert=source,
            related_events=related_events,
            occurrences=occurrences,
        )

    @staticmethod
    def _infer_engine(hit: dict) -> Literal["wazuh", "suricata"]:
        explicit = hit.get("source_engine")
        if explicit in ("wazuh", "suricata"):
            return explicit  # type: ignore[return-value]
        index = hit.get("_index", "") or ""
        return "wazuh" if index.startswith("wazuh") else "suricata"