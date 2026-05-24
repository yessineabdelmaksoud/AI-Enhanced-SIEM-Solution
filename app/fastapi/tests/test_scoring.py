"""Tests for ScoringService deterministic risk score."""
from datetime import timedelta

from app.services.scoring_service import ScoringService


def test_critical_score(now, alert_factory, context_factory):
    """Severity 15 + 100 occurrences + now + MITRE -> critical (>=90)."""
    alert = alert_factory(
        severity=15,
        timestamp=now,
        mitre_id=["T1110"],
    )
    ctx = context_factory(source_alert=alert, occurrences=100)

    result = ScoringService.compute(ctx, now)

    assert result["score"] >= 90, f"score={result['score']}"
    assert result["category"] == "critical"
    assert result["factors"]["mitre_present"] is True


def test_low_score(now, alert_factory, context_factory):
    """Severity 3 + 1 occurrence + 23h ago + no MITRE -> low (<40)."""
    alert = alert_factory(
        severity=3,
        timestamp=now - timedelta(hours=23),
        mitre_id=None,
    )
    ctx = context_factory(source_alert=alert, occurrences=1)

    result = ScoringService.compute(ctx, now)

    assert result["score"] < 40, f"score={result['score']}"
    assert result["category"] == "low"
    assert result["factors"]["mitre_present"] is False


def test_medium_or_high_score(now, alert_factory, context_factory):
    """Severity 8 + 5 occurrences + 1h ago + MITRE -> 50-80."""
    alert = alert_factory(
        severity=8,
        timestamp=now - timedelta(hours=1),
        mitre_id=["T1059"],
    )
    ctx = context_factory(source_alert=alert, occurrences=5)

    result = ScoringService.compute(ctx, now)

    assert 50 <= result["score"] <= 80, f"score={result['score']}"
    assert result["category"] in ("medium", "high")


def test_zero_occurrences_no_crash(now, alert_factory, context_factory):
    """occurrences=0 must not crash (log10 protection)."""
    alert = alert_factory(severity=5, timestamp=now)
    ctx = context_factory(source_alert=alert, occurrences=0)

    # Must not raise
    result = ScoringService.compute(ctx, now)

    assert 0 <= result["score"] <= 100
    assert result["category"] in ("low", "medium", "high", "critical")
    # log10(0+1) = 0
    assert result["factors"]["occurrence_w"] == 0.0


def test_future_timestamp_recency_bounded(now, alert_factory, context_factory):
    """Future timestamp must not crash. recency_w bounded [0, 1]."""
    alert = alert_factory(
        severity=10,
        timestamp=now + timedelta(hours=2),  # in the future
    )
    ctx = context_factory(source_alert=alert, occurrences=1)

    # Must not raise
    result = ScoringService.compute(ctx, now)

    assert 0 <= result["score"] <= 100
    assert 0.0 <= result["factors"]["recency_w"] <= 1.0
    # Future should be clamped to "as fresh as possible"
    assert result["factors"]["recency_w"] == 1.0