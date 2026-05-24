
"""Tests for JSON schemas and remediation actions."""
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError


PROJECT_ROOT = Path("/home/vm-ai/soc-ai-lab")
SCHEMAS_DIR = PROJECT_ROOT / "config" / "ai" / "schemas" / "v1"
ACTIONS_PATH = PROJECT_ROOT / "config" / "ai" / "remediation_actions.json"


def load_schema(name: str) -> dict:
    return json.loads((SCHEMAS_DIR / f"{name}_response.schema.json").read_text())


# ---------- Schema syntax ----------

def test_schemas_are_valid_json_schema():
    for name in ("explain", "investigate", "remediate"):
        schema = load_schema(name)
        Draft202012Validator.check_schema(schema)


# ---------- explain ----------

def test_explain_valid_instance():
    schema = load_schema("explain")
    validator = Draft202012Validator(schema)
    instance = {
        "summary": "Multiples tentatives SSH brute force depuis 192.168.56.30 suivies d'une connexion root réussie sur vm-endp-01.",
        "severity_assessment": "high",
        "key_iocs": ["192.168.56.30", "root", "vm-endp-01"],
        "attack_phase": "credential_access",
        "mitre_techniques": ["T1110", "T1110.001"],
    }
    validator.validate(instance)


def test_explain_rejects_missing_required():
    schema = load_schema("explain")
    validator = Draft202012Validator(schema)
    with pytest.raises(ValidationError):
        validator.validate({"summary": "x" * 60})


def test_explain_rejects_invalid_mitre_format():
    schema = load_schema("explain")
    validator = Draft202012Validator(schema)
    instance = {
        "summary": "x" * 60,
        "severity_assessment": "high",
        "key_iocs": [],
        "attack_phase": "unknown",
        "mitre_techniques": ["BAD_FORMAT"],
    }
    with pytest.raises(ValidationError):
        validator.validate(instance)


# ---------- investigate ----------

def test_investigate_valid_instance():
    schema = load_schema("investigate")
    validator = Draft202012Validator(schema)
    instance = {
        "queries": [
            {
                "title": "Activité IP source 24h",
                "kql": 'source.ip : "192.168.56.30" and @timestamp >= "now-24h"',
                "expected_findings": "Autres tentatives ou scans depuis cette IP.",
            }
        ],
        "rationale": "Vérifier l'historique de l'IP source.",
    }
    validator.validate(instance)


def test_investigate_rejects_zero_queries():
    schema = load_schema("investigate")
    validator = Draft202012Validator(schema)
    with pytest.raises(ValidationError):
        validator.validate({"queries": [], "rationale": "x"})


# ---------- remediate ----------

def test_remediate_valid_instance():
    schema = load_schema("remediate")
    validator = Draft202012Validator(schema)
    instance = {
        "primary_action": "block_source_ip",
        "justification": "Brute force confirmé par 12 occurrences depuis l'IP en 5 minutes.",
        "alternatives": ["isolate_host", "force_password_reset"],
        "confidence": 0.85,
    }
    validator.validate(instance)


def test_remediate_rejects_unknown_action():
    schema = load_schema("remediate")
    validator = Draft202012Validator(schema)
    instance = {
        "primary_action": "delete_everything",
        "justification": "x" * 50,
        "alternatives": [],
    }
    with pytest.raises(ValidationError):
        validator.validate(instance)


def test_remediate_rejects_duplicate_alternatives():
    schema = load_schema("remediate")
    validator = Draft202012Validator(schema)
    instance = {
        "primary_action": "isolate_host",
        "justification": "x" * 50,
        "alternatives": ["block_source_ip", "block_source_ip"],
    }
    with pytest.raises(ValidationError):
        validator.validate(instance)


# ---------- remediation actions list ----------

def test_remediation_actions_list_complete():
    actions = json.loads(ACTIONS_PATH.read_text())
    assert isinstance(actions, list)
    assert len(actions) == 10
    ids = {a["id"] for a in actions}
    expected = {
        "isolate_host",
        "block_source_ip",
        "force_password_reset",
        "disable_user_account",
        "review_file_integrity",
        "increase_logging",
        "escalate_to_l2",
        "collect_forensics",
        "monitor_no_action",
        "close_false_positive",
    }
    assert ids == expected
    for a in actions:
        assert "label_fr" in a and a["label_fr"]
        assert "description_fr" in a and a["description_fr"]
