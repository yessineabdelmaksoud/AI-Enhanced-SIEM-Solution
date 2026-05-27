"""Async Elasticsearch repository."""
import asyncio
import logging
from typing import Optional

from elasticsearch import AsyncElasticsearch
from elasticsearch.exceptions import NotFoundError
from datetime import datetime 
from app.core.config import Settings
import time
from datetime import datetime, timedelta

logger = logging.getLogger(__name__)


class ElasticRepository:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: Optional[AsyncElasticsearch] = None

    async def connect(self) -> None:
        if self._client is not None:
            return
        self._client = AsyncElasticsearch(
            hosts=[self._settings.es_host],
            basic_auth=(self._settings.es_user, self._settings.es_pass),
            ca_certs=self._settings.es_ca_cert,
            verify_certs=True,
            request_timeout=10,
            retry_on_timeout=True,
            max_retries=2,
        )
        logger.info(
            "Elasticsearch client created",
            extra={"es_host": self._settings.es_host},
        )

    async def close(self) -> None:
        if self._client is not None:
            await self._client.close()
            self._client = None
            logger.info("Elasticsearch client closed")

    async def ping(self) -> bool:
        if self._client is None:
            return False
        try:
            return await asyncio.wait_for(self._client.ping(), timeout=5.0)
        except asyncio.TimeoutError:
            logger.warning("Elasticsearch ping timeout")
            return False
        except Exception as exc:
            logger.warning("Elasticsearch ping failed", extra={"error": str(exc)})
            return False

    async def get_alert_by_id(
        self, alert_id: str, index_pattern: str
    ) -> Optional[dict]:
        if self._client is None:
            return None
        try:
            response = await self._client.search(
                index=index_pattern,
                size=1,
                query={"term": {"_id": alert_id}},
            )
            hits = response.get("hits", {}).get("hits", [])
            if not hits:
                return None
            doc = hits[0].get("_source", {})
            doc["_id"] = hits[0].get("_id")
            doc["_index"] = hits[0].get("_index")
            return doc
        except NotFoundError:
            return None
        except Exception as exc:
            logger.error(
                "get_alert_by_id failed",
                extra={
                    "alert_id": alert_id,
                    "index": index_pattern,
                    "error": str(exc),
                },
            )
            return None

    async def search_context(
            self,
            source_id: str,
            timestamp: "datetime",
            window_minutes: int,
            entities: dict,
            index_pattern: str,
            size: int = 20,
        ) -> list[dict]:
            """Search for correlated events around a source alert.

            Returns a list of dicts where _id and _index are merged into _source.
            Returns [] on any failure.
            """
            if self._client is None:
                return []

            from datetime import timedelta

            start = (timestamp - timedelta(minutes=window_minutes)).isoformat()
            end = (timestamp + timedelta(minutes=window_minutes)).isoformat()

            should: list[dict] = []
            if entities.get("source_ip"):
                should.append({"term": {"source.ip": entities["source_ip"]}})
            if entities.get("destination_ip"):
                should.append({"term": {"destination.ip": entities["destination_ip"]}})
            if entities.get("host_name"):
                should.append({"term": {"host.name": entities["host_name"]}})
                should.append({"term": {"wazuh.agent_name": entities["host_name"]}})
            if entities.get("user_name"):
                should.append({"term": {"user.name": entities["user_name"]}})

            if not should:
                return []

            query = {
                "bool": {
                    "must": [
                        {"range": {"@timestamp": {"gte": start, "lte": end}}}
                    ],
                    "should": should,
                    "minimum_should_match": 1,
                    "must_not": [
                        {"term": {"_id": source_id}}
                    ],
                }
            }

            try:
                response = await self._client.search(
                    index=index_pattern,
                    size=size,
                    query=query,
                    sort=[{"@timestamp": "asc"}],
                    timeout="3s",
                )
            except Exception as exc:
                logger.error(
                    "search_context failed",
                    extra={
                        "source_id": source_id,
                        "index": index_pattern,
                        "error": str(exc),
                    },
                )
                return []

            hits = response.get("hits", {}).get("hits", [])
            merged: list[dict] = []
            for hit in hits:
                doc = dict(hit.get("_source", {}))
                doc["_id"] = hit.get("_id")
                doc["_index"] = hit.get("_index")
                merged.append(doc)
            return merged
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
    async def search_raw(
        self,
        index_pattern: str,
        *,
        size: int = 0,
        query: Optional[dict] = None,
        aggs: Optional[dict] = None,
        sort: Optional[list] = None,
        timeout: str = "10s",
    ) -> dict:
        """Run a raw search/aggregation. Returns the full response or {} on error."""
        if self._client is None:
            return {}
        kwargs: dict = {"index": index_pattern, "size": size, "timeout": timeout}
        if query is not None:
            kwargs["query"] = query
        if aggs is not None:
            kwargs["aggregations"] = aggs
        if sort is not None:
            kwargs["sort"] = sort
        try:
            return dict(await self._client.search(**kwargs))
        except Exception as exc:
            logger.error(
                "search_raw failed",
                extra={"index": index_pattern, "error": str(exc)},
            )
            return {}
    async def get_enrichments_by_alert(
        self, alert_id: str, limit: int = 30
    ) -> list[dict]:
        """Return recent enrichments for a source alert, newest first."""
        if self._client is None:
            return []
        try:
            response = await self._client.search(
                index=f"{self._settings.es_index_enrich}-*",
                size=limit,
                query={"term": {"source_alert_id": alert_id}},
                sort=[{"@timestamp": {"order": "desc"}}],
            )
            hits = response.get("hits", {}).get("hits", [])
            results = []
            for h in hits:
                doc = dict(h.get("_source", {}))
                doc["_id"] = h.get("_id")
                doc["_index"] = h.get("_index")
                results.append(doc)
            return results
        except Exception as exc:
            logger.error(
                "get_enrichments_by_alert failed",
                extra={"alert_id": alert_id, "error": str(exc)},
            )
            return []