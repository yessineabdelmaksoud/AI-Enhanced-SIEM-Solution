"""PromptService: load versioned prompts and inject incident context."""
import json
import logging
from pathlib import Path
from typing import Literal

from app.models.alert import IncidentContext

logger = logging.getLogger(__name__)


PromptUsage = Literal["explain", "investigate", "remediate"]

PLACEHOLDER = "<DATA_PLACEHOLDER>"
MAX_TOKENS_ESTIMATE = 6000  # heuristic: 1 token ~ 4 chars
MAX_DATA_CHARS = MAX_TOKENS_ESTIMATE * 4


class PromptService:
    """Load prompts and build full strings to send to the LLM.

    Templates and remediation actions are loaded lazily and cached
    in memory.
    """

    def __init__(self, prompts_dir: Path, actions_path: Path) -> None:
        self._prompts_dir = Path(prompts_dir)
        self._actions_path = Path(actions_path)
        self._template_cache: dict[str, str] = {}
        self._actions_cache: list[dict] | None = None

    # -------- Public API --------

    def build(self, usage: PromptUsage, ctx: IncidentContext) -> str:
        """Build the full prompt string for a given usage and context."""
        template = self._load_template(usage)
        data_json = self._serialize_context(ctx)

        prompt = template.replace(PLACEHOLDER, data_json)

        if PLACEHOLDER in prompt:
            raise ValueError(
                f"Placeholder substitution failed for usage={usage}"
            )

        logger.info(
            "Prompt built",
            extra={
                "usage": usage,
                "alert_id": ctx.source_alert.id,
                "prompt_size_chars": len(prompt),
                "data_size_chars": len(data_json),
            },
        )
        return prompt

    def list_remediation_actions(self) -> list[dict]:
        """Return the fixed list of remediation actions."""
        if self._actions_cache is not None:
            return self._actions_cache
        if not self._actions_path.exists():
            raise FileNotFoundError(
                f"Remediation actions file not found: {self._actions_path}"
            )
        with self._actions_path.open("r", encoding="utf-8") as f:
            self._actions_cache = json.load(f)
        return self._actions_cache

    def warmup(self) -> None:
        """Pre-load all templates and the actions file."""
        for usage in ("explain", "investigate", "remediate"):
            self._load_template(usage)  # type: ignore[arg-type]
        self.list_remediation_actions()
        logger.info("PromptService warmed up")

    # -------- Internals --------

    def _load_template(self, usage: PromptUsage) -> str:
        if usage in self._template_cache:
            return self._template_cache[usage]

        path = self._prompts_dir / f"{usage}_prompt.txt"
        if not path.exists():
            raise FileNotFoundError(f"Prompt template not found: {path}")

        content = path.read_text(encoding="utf-8")
        if PLACEHOLDER not in content:
            raise ValueError(
                f"Placeholder {PLACEHOLDER} missing in template {path}"
            )

        self._template_cache[usage] = content
        logger.info(
            "Prompt template loaded",
            extra={"usage": usage, "path": str(path), "size": len(content)},
        )
        return content

    def _serialize_context(self, ctx: IncidentContext) -> str:
        """Serialize context to compact JSON. Strip internal fields. Truncate if too large."""
        raw = ctx.model_dump(mode="json", exclude_none=True)

        # Strip Elasticsearch-internal fields
        if isinstance(raw.get("source_alert"), dict):
            raw["source_alert"].pop("index", None)
        related = raw.get("related_events", [])
        if isinstance(related, list):
            for evt in related:
                if isinstance(evt, dict):
                    evt.pop("index", None)

        json_str = json.dumps(raw, ensure_ascii=False, separators=(",", ":"))
        if len(json_str) <= MAX_DATA_CHARS:
            return json_str

        logger.warning(
            "Context too large, truncating related_events",
            extra={
                "size_chars": len(json_str),
                "limit": MAX_DATA_CHARS,
                "alert_id": ctx.source_alert.id,
            },
        )

        # Progressive truncation
        for keep in (10, 5, 3, 1, 0):
            raw["related_events"] = related[:keep]
            json_str = json.dumps(raw, ensure_ascii=False, separators=(",", ":"))
            if len(json_str) <= MAX_DATA_CHARS:
                return json_str

        # Last resort: source alert only
        minimal = {
            "source_alert": raw.get("source_alert", {}),
            "related_events": [],
            "occurrences": ctx.occurrences,
            "_truncated": True,
        }
        return json.dumps(minimal, ensure_ascii=False, separators=(",", ":"))
