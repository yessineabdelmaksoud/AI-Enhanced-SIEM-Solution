"""Pydantic models for SOC alerts and incident context."""
from datetime import datetime, timezone
from typing import Any, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field


SourceEngine = Literal["wazuh", "suricata"]


def _parse_timestamp(value: Any) -> Optional[datetime]:
    """Best-effort timestamp parsing. Always returns UTC datetime."""
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    if isinstance(value, str):
        try:
            if value.endswith("Z"):
                value = value[:-1] + "+00:00"
            dt = datetime.fromisoformat(value)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except (ValueError, TypeError):
            return None
    return None


def _coalesce(*values: Any) -> Any:
    """Return the first non-None and non-empty value."""
    for v in values:
        if v is not None and v != "":
            return v
    return None


def _ensure_list(value: Any) -> Optional[list[str]]:
    """Normalize to list[str] or None."""
    if value is None:
        return None
    if isinstance(value, list):
        return [str(v) for v in value if v is not None]
    if isinstance(value, str) and value:
        return [value]
    if value:
        return [str(value)]
    return None


# ============================================================
# Models
# ============================================================

class AlertRef(BaseModel):
    """Lightweight reference to an alert."""
    model_config = ConfigDict(extra="ignore")

    id: str
    index: str
    timestamp: datetime
    source_engine: SourceEngine


class Entity(BaseModel):
    """Network / host / user entities extracted from an alert."""
    model_config = ConfigDict(extra="ignore")

    source_ip: Optional[str] = None
    destination_ip: Optional[str] = None
    host_name: Optional[str] = None
    user_name: Optional[str] = None

    def is_empty(self) -> bool:
        return all(
            v is None
            for v in (
                self.source_ip,
                self.destination_ip,
                self.host_name,
                self.user_name,
            )
        )


class AlertCore(BaseModel):
    """Core normalized alert."""
    model_config = ConfigDict(extra="ignore")

    id: str
    index: Optional[str] = None
    timestamp: datetime
    source_engine: SourceEngine
    rule_id: Optional[str] = None
    severity: Optional[int] = None
    description: Optional[str] = None
    mitre_id: Optional[list[str]] = None
    mitre_tactic: Optional[list[str]] = None
    entity: Entity = Field(default_factory=Entity)


class ContextEvent(AlertCore):
    """An alert that appears in the context window of a source alert."""
    model_config = ConfigDict(extra="ignore")

    delta_seconds: int


class IncidentContext(BaseModel):
    """A source alert and its correlated events."""
    model_config = ConfigDict(extra="ignore")

    source_alert: AlertCore
    related_events: list[ContextEvent] = Field(default_factory=list)
    occurrences: int = 1


# ============================================================
# Helper: ES doc → AlertCore
# ============================================================

def from_es_doc(doc: dict, source_engine: SourceEngine) -> AlertCore:
    """Map an Elasticsearch document (with _id and _index merged) to AlertCore."""
    doc_id = str(doc.get("_id", ""))
    doc_index = doc.get("_index")

    ts = _parse_timestamp(doc.get("@timestamp"))
    if ts is None:
        ts = datetime.now(timezone.utc)

    if source_engine == "wazuh":
        wazuh = doc.get("wazuh", {}) or {}
        rule = doc.get("rule", {}) or {}
        rule_id = _coalesce(wazuh.get("rule_id"), rule.get("id"))
        severity = _coalesce(wazuh.get("severity"), rule.get("level"))
        description = _coalesce(wazuh.get("rule_description"), rule.get("description"))
    else:  # suricata
        suri = doc.get("suricata", {}) or {}
        alert = doc.get("alert", {}) or {}
        rule_id = _coalesce(suri.get("rule_id"), alert.get("signature_id"))
        severity = _coalesce(suri.get("severity"), alert.get("severity"))
        description = _coalesce(suri.get("signature"), alert.get("signature"))

    rule_block = doc.get("rule", {}) or {}
    mitre = rule_block.get("mitre", {}) or {}
    mitre_id = _ensure_list(mitre.get("id"))
    mitre_tactic = _ensure_list(mitre.get("tactic"))

    source = doc.get("source", {}) or {}
    destination = doc.get("destination", {}) or {}
    host = doc.get("host", {}) or {}
    user = doc.get("user", {}) or {}
    wazuh_obj = doc.get("wazuh", {}) or {}

    entity = Entity(
        source_ip=source.get("ip"),
        destination_ip=destination.get("ip"),
        host_name=_coalesce(host.get("name"), wazuh_obj.get("agent_name")),
        user_name=user.get("name"),
    )

    sev_int: Optional[int] = None
    if severity is not None:
        try:
            sev_int = int(severity)
        except (ValueError, TypeError):
            sev_int = None

    return AlertCore(
        id=doc_id,
        index=doc_index,
        timestamp=ts,
        source_engine=source_engine,
        rule_id=str(rule_id) if rule_id is not None else None,
        severity=sev_int,
        description=description,
        mitre_id=mitre_id,
        mitre_tactic=mitre_tactic,
        entity=entity,
    )