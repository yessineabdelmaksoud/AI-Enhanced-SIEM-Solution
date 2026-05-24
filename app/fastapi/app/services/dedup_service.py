"""In-memory deduplication cache with TTL.

Avoids calling the LLM twice for the same logical incident
(same entity + rule + 15-minute time bucket).
"""
import asyncio
import hashlib
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from app.models.alert import AlertCore

logger = logging.getLogger(__name__)


class DedupService:
    BUCKET_SECONDS = 15 * 60  # 15 minutes

    def __init__(self, ttl_minutes: int) -> None:
        self._ttl = timedelta(minutes=ttl_minutes)
        # key -> (enrichment_id, expires_at)
        self._cache: dict[str, tuple[str, datetime]] = {}
        self._lock = asyncio.Lock()

    @staticmethod
    def compute_key(alert: AlertCore) -> str:
        """sha256(entity_primary | rule_id | time_bucket_15min)[:16]."""
        entity_primary = (
            alert.entity.source_ip
            or alert.entity.host_name
            or "unknown"
        )
        rule_id = alert.rule_id or "unknown"

        ts = alert.timestamp
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        epoch = int(ts.timestamp())
        time_bucket = epoch // DedupService.BUCKET_SECONDS

        raw = f"{entity_primary}|{rule_id}|{time_bucket}"
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]

    async def check(self, key: str) -> Optional[str]:
        """Return enrichment_id if a fresh entry exists, else None."""
        now = datetime.now(timezone.utc)
        async with self._lock:
            self._purge_expired(now)
            entry = self._cache.get(key)
            if entry is None:
                logger.debug(
                    "Dedup miss",
                    extra={"key": key, "cache_size": len(self._cache)},
                )
                return None
            enrichment_id, expires_at = entry
            if now >= expires_at:
                self._cache.pop(key, None)
                logger.debug("Dedup miss (expired)", extra={"key": key})
                return None
            logger.debug(
                "Dedup hit",
                extra={"key": key, "enrichment_id": enrichment_id},
            )
            return enrichment_id

    async def register(self, key: str, enrichment_id: str) -> None:
        """Register an enrichment for a key, with TTL."""
        now = datetime.now(timezone.utc)
        expires_at = now + self._ttl
        async with self._lock:
            self._purge_expired(now)
            self._cache[key] = (enrichment_id, expires_at)
        logger.debug(
            "Dedup register",
            extra={
                "key": key,
                "enrichment_id": enrichment_id,
                "expires_at": expires_at.isoformat(),
            },
        )

    async def size(self) -> int:
        """Return current number of fresh entries (utility for tests)."""
        now = datetime.now(timezone.utc)
        async with self._lock:
            self._purge_expired(now)
            return len(self._cache)

    def _purge_expired(self, now: datetime) -> None:
        """Remove expired entries. Caller must hold the lock."""
        expired = [k for k, (_, exp) in self._cache.items() if now >= exp]
        for k in expired:
            self._cache.pop(k, None)
        if expired:
            logger.debug(
                "Purged expired entries",
                extra={"count": len(expired)},
            )