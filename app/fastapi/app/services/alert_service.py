"""AlertService: fetch a single alert by id from Wazuh or Suricata indices."""
import asyncio
import logging
from typing import Optional

from app.core.config import Settings
from app.models.alert import AlertCore, from_es_doc
from app.repositories.elastic_repository import ElasticRepository

logger = logging.getLogger(__name__)


class AlertService:
    def __init__(self, repo: ElasticRepository, settings: Settings) -> None:
        self._repo = repo
        self._settings = settings

    async def get_alert(self, alert_id: str) -> Optional[AlertCore]:
        """Look up the alert in wazuh and suricata in parallel.

        Returns AlertCore from the first non-None hit, or None.
        Never raises.
        """
        wazuh_task = self._repo.get_alert_by_id(
            alert_id, self._settings.es_index_wazuh
        )
        suricata_task = self._repo.get_alert_by_id(
            alert_id, self._settings.es_index_suricata
        )

        wazuh_doc, suricata_doc = await asyncio.gather(wazuh_task, suricata_task)

        if wazuh_doc is not None:
            logger.info(
                "Alert resolved",
                extra={
                    "alert_id": alert_id,
                    "result": "found",
                    "engine": "wazuh",
                },
            )
            return from_es_doc(wazuh_doc, "wazuh")

        if suricata_doc is not None:
            logger.info(
                "Alert resolved",
                extra={
                    "alert_id": alert_id,
                    "result": "found",
                    "engine": "suricata",
                },
            )
            return from_es_doc(suricata_doc, "suricata")

        logger.info(
            "Alert resolved",
            extra={"alert_id": alert_id, "result": "not_found"},
        )
        return None