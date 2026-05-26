"""ValidationService: validate LLM outputs against versioned JSON Schemas."""
import json
import logging
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

logger = logging.getLogger(__name__)


class ValidationService:
    """Cached Draft202012 validators and raw schemas, one per usage."""

    def __init__(self, schemas_dir: Path) -> None:
        self._schemas_dir = Path(schemas_dir)
        self._validator_cache: dict[str, Draft202012Validator] = {}
        self._schema_cache: dict[str, dict] = {}

    def validate(self, usage: str, response: Any) -> tuple[bool, list[str]]:
        if not isinstance(response, dict):
            return False, [
                f"Response must be a JSON object, got {type(response).__name__}"
            ]
        try:
            validator = self._load_validator(usage)
        except (FileNotFoundError, json.JSONDecodeError, KeyError) as exc:
            return False, [f"Schema loading failed: {exc}"]

        errors: list[str] = []
        for err in validator.iter_errors(response):
            path = "/".join(str(p) for p in err.absolute_path) or "(root)"
            errors.append(f"{path}: {err.message}")
        return (len(errors) == 0, errors)

    def get_schema(self, usage: str) -> dict:
        """Return the raw schema dict (used to constrain Ollama generation)."""
        self._load_validator(usage)
        return self._schema_cache[usage]

    def warmup(self) -> None:
        for usage in ("explain", "investigate", "remediate"):
            self._load_validator(usage)
        logger.info("ValidationService warmed up")

    def _load_validator(self, usage: str) -> Draft202012Validator:
        if usage in self._validator_cache:
            return self._validator_cache[usage]

        path = self._schemas_dir / f"{usage}_response.schema.json"
        if not path.exists():
            raise FileNotFoundError(f"Schema not found: {path}")

        schema = json.loads(path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)

        self._schema_cache[usage] = schema
        validator = Draft202012Validator(schema)
        self._validator_cache[usage] = validator
        logger.info("Validator loaded", extra={"usage": usage, "path": str(path)})
        return validator