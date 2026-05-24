"""Pytest fixtures and factories for SOC AI tests."""
from datetime import datetime, timezone
from typing import Optional

import pytest

from app.models.alert import AlertCore, Entity, IncidentContext


def make_alert(
    *,
    alert_id: str = "test-alert-001",
    severity: int = 10,
    rule_id: Optional[str] = "5763",
    timestamp: Optional[datetime] = None,
    source_engine: str = "wazuh",
    mitre_id: Optional[list[str]] = None,
    source_ip: Optional[str] = "10.110.188.30",
    host_name: Optional[str] = "vm-endp-01",
) -> AlertCore:
    """Build a synthetic AlertCore."""
    if timestamp is None:
        timestamp = datetime.now(timezone.utc)
    return AlertCore(
        id=alert_id,
        index="wazuh-alerts-test",
        timestamp=timestamp,
        source_engine=source_engine,
        rule_id=rule_id,
        severity=severity,
        description="Test alert",
        mitre_id=mitre_id,
        mitre_tactic=None,
        entity=Entity(
            source_ip=source_ip,
            destination_ip=None,
            host_name=host_name,
            user_name=None,
        ),
    )


def make_context(
    *,
    occurrences: int = 1,
    source_alert: Optional[AlertCore] = None,
    **kwargs,
) -> IncidentContext:
    """Build a synthetic IncidentContext."""
    if source_alert is None:
        source_alert = make_alert(**kwargs)
    return IncidentContext(
        source_alert=source_alert,
        related_events=[],
        occurrences=occurrences,
    )


@pytest.fixture
def now() -> datetime:
    """Fixed reference time for deterministic tests."""
    return datetime(2026, 5, 8, 14, 0, 0, tzinfo=timezone.utc)


@pytest.fixture
def alert_factory():
    return make_alert


@pytest.fixture
def context_factory():
    return make_context