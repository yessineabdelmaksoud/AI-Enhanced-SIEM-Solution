"""Deterministic risk scoring (no LLM).

Weighted: 0.4*severity + 0.3*occurrences + 0.2*recency + 0.1*mitre_bonus.
Bounded [0, 100]. Categories: low <40, medium <70, high <90, critical >=90.
See _compute_factors() for exact formula.
"""
import logging
import math
from datetime import datetime, timezone
from typing import Any

from app.models.alert import IncidentContext

logger = logging.getLogger(__name__)


class ScoringService:
    SEVERITY_MAX = 15
    DAY_SECONDS = 86400

    @staticmethod
    def compute(ctx: IncidentContext, now: datetime) -> dict[str, Any]:
        source = ctx.source_alert

        # severity_norm
        severity = source.severity if source.severity is not None else 0
        severity = max(severity, 0)
        severity_norm = min(severity, ScoringService.SEVERITY_MAX) / ScoringService.SEVERITY_MAX

        # occurrence_w (log10 protection)
        occ = max(ctx.occurrences, 0)
        occurrence_w = min(math.log10(occ + 1), 1.0)

        # recency_w (linear decay over 24h, bounded [0, 1])
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        ts = source.timestamp
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)

        age_seconds = (now - ts).total_seconds()
        if age_seconds < 0:
            age_seconds = 0
        recency_w = max(0.0, 1.0 - age_seconds / ScoringService.DAY_SECONDS)
        recency_w = min(recency_w, 1.0)

        # mitre_bonus (flag * 0.1)
        mitre_present = bool(source.mitre_id and len(source.mitre_id) > 0)
        mitre_bonus = 0.1 if mitre_present else 0.0

        weighted = (
            0.4 * severity_norm
            + 0.3 * occurrence_w
            + 0.2 * recency_w
            + 0.1 * mitre_bonus
        )

        score_raw = 100.0 * weighted
        score = round(max(0.0, min(score_raw, 100.0)), 1)

        category = ScoringService._categorize(score)

        result = {
            "score": score,
            "category": category,
            "factors": {
                "severity_norm": round(severity_norm, 3),
                "occurrence_w": round(occurrence_w, 3),
                "recency_w": round(recency_w, 3),
                "mitre_present": mitre_present,
            },
        }

        logger.debug(
            "Score computed",
            extra={
                "alert_id": source.id,
                "score": score,
                "category": category,
            },
        )
        return result

    @staticmethod
    def _categorize(score: float) -> str:
        if score >= 90:
            return "critical"
        if score >= 70:
            return "high"
        if score >= 40:
            return "medium"
        return "low"