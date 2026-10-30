"""Tests for the enrichment read routes, with Elasticsearch mocked."""
from unittest.mock import AsyncMock

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api import routes_enrich


def make_enrichment(enrichment_id: str, usage: str, timestamp: str) -> dict:
    """Build a stored enrichment as returned by the repository."""
    return {
        "_id": enrichment_id,
        "_index": "soc-ai-enrichments-2026.05.08",
        "@timestamp": timestamp,
        "source_alert_id": "alert-001",
        "usage": usage,
        "validated": True,
        "risk_score": 72,
        "risk_category": "high",
        "latency_ms": 1234,
        "response": {},
        "errors": [],
    }


@pytest.fixture
def es_repo() -> AsyncMock:
    repo = AsyncMock()
    repo.get_enrichments_by_alert.return_value = []
    repo.get_enrichment.return_value = None
    return repo


@pytest.fixture
def client(es_repo) -> TestClient:
    app = FastAPI()
    app.include_router(routes_enrich.router)
    app.state.es_repo = es_repo
    return TestClient(app)


def test_by_alert_keeps_latest_per_usage(client, es_repo):
    # Repository returns newest first
    es_repo.get_enrichments_by_alert.return_value = [
        make_enrichment("e3", "explain", "2026-05-08T14:10:00+00:00"),
        make_enrichment("e2", "remediate", "2026-05-08T14:05:00+00:00"),
        make_enrichment("e1", "explain", "2026-05-08T14:00:00+00:00"),
    ]

    res = client.get("/enrichments/by-alert/alert-001")

    assert res.status_code == 200
    body = res.json()
    assert body["alert_id"] == "alert-001"
    assert body["count"] == 2
    enrichments = body["enrichments"]
    assert set(enrichments) == {"explain", "investigate", "remediate"}
    assert enrichments["explain"]["enrichment_id"] == "e3"
    assert enrichments["remediate"]["enrichment_id"] == "e2"
    assert enrichments["investigate"] is None
    es_repo.get_enrichments_by_alert.assert_awaited_once_with("alert-001")


def test_by_alert_without_enrichments(client, es_repo):
    res = client.get("/enrichments/by-alert/unknown-alert")

    assert res.status_code == 200
    body = res.json()
    assert body["count"] == 0
    assert body["enrichments"] == {
        "explain": None,
        "investigate": None,
        "remediate": None,
    }


def test_by_alert_ignores_unknown_usage(client, es_repo):
    es_repo.get_enrichments_by_alert.return_value = [
        make_enrichment("e9", "summarize", "2026-05-08T14:00:00+00:00"),
    ]

    res = client.get("/enrichments/by-alert/alert-001")

    assert res.status_code == 200
    assert res.json()["count"] == 0


def test_get_enrichment_by_id_still_routed(client, es_repo):
    es_repo.get_enrichment.return_value = make_enrichment(
        "e1", "explain", "2026-05-08T14:00:00+00:00"
    )

    res = client.get("/enrichments/e1")

    assert res.status_code == 200
    assert res.json()["_id"] == "e1"
    es_repo.get_enrichment.assert_awaited_once_with("e1")


def test_get_enrichment_by_id_not_found(client):
    res = client.get("/enrichments/missing")

    assert res.status_code == 404
