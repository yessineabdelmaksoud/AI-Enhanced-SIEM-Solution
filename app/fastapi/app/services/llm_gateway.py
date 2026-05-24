"""LLM Gateway: calls Ollama with concurrency limit, timeout, and 1 retry."""
import asyncio
import json
import logging
import time
from typing import Any, Optional

import httpx

from app.core.config import Settings
from app.services.exceptions import (
    LlmHttpError,
    LlmInvalidJsonError,
    LlmTimeoutError,
)

logger = logging.getLogger(__name__)


class LlmGateway:
    """Async client to a local Ollama instance.

    - Concurrency limited by settings.llm_max_concurrent (default 1).
    - Per-call timeout: settings.ollama_timeout_s.
    - 1 retry on httpx.TimeoutException.
    - Validates that Ollama's `response` field is parsable JSON when json_format=True.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: Optional[httpx.AsyncClient] = None
        self._semaphore = asyncio.Semaphore(settings.llm_max_concurrent)

    # ---------- Async context manager ----------

    async def __aenter__(self) -> "LlmGateway":
        await self._ensure_client()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self.close()

    # ---------- Lifecycle ----------

    async def _ensure_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=self._settings.ollama_host,
                timeout=httpx.Timeout(
                    self._settings.ollama_timeout_s, connect=5.0
                ),
            )
            logger.info(
                "Ollama client created",
                extra={
                    "ollama_host": self._settings.ollama_host,
                    "model": self._settings.ollama_model,
                    "timeout_s": self._settings.ollama_timeout_s,
                    "max_concurrent": self._settings.llm_max_concurrent,
                },
            )
        return self._client

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None
            logger.info("Ollama client closed")

    # ---------- Health check ----------

    async def ping(self) -> bool:
        try:
            client = await self._ensure_client()
            response = await client.get("/api/version", timeout=5.0)
            return response.status_code == 200
        except Exception as exc:
            logger.warning("Ollama ping failed", extra={"error": str(exc)})
            return False

    # ---------- Main API ----------

    async def generate(
        self, prompt: str, json_format: bool = True
    ) -> Any:
        """Call Ollama /api/generate and return the parsed result.

        Args:
            prompt: full prompt to send.
            json_format: if True, sets Ollama's format="json" and parses the
                response field with json.loads. If False, returns raw text.

        Returns:
            parsed dict (json_format=True) or raw string (json_format=False).

        Raises:
            LlmTimeoutError: after 1 retry on timeout.
            LlmInvalidJsonError: response is not valid JSON (json_format=True only).
            LlmHttpError: non-2xx status or transport error.
        """
        client = await self._ensure_client()

        payload: dict[str, Any] = {
            "model": self._settings.ollama_model,
            "prompt": prompt,
            "stream": False,
            "keep_alive": "1h",
            "options": {
                "temperature": 0.2,
                "top_p": 0.9,
                "num_predict": 1024,
                "num_ctx": 8192,
            },
        }
        if json_format:
            payload["format"] = "json"

        # ---- Semaphore acquisition (concurrency limiter) ----
        t_queued = time.monotonic()
        async with self._semaphore:
            wait_ms = int((time.monotonic() - t_queued) * 1000)
            if wait_ms > 50:
                logger.info(
                    "LLM call waited for semaphore",
                    extra={
                        "wait_ms": wait_ms,
                        "max_concurrent": self._settings.llm_max_concurrent,
                    },
                )

            response = await self._call_with_retry(client, payload)

        # ---- HTTP status check ----
        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            logger.error(
                "Ollama returned HTTP error",
                extra={
                    "status": response.status_code,
                    "error": str(exc),
                },
            )
            raise LlmHttpError(
                f"Ollama HTTP {response.status_code}: {exc}"
            ) from exc

        # ---- Parse Ollama envelope ----
        try:
            envelope = response.json()
        except json.JSONDecodeError as exc:
            logger.error(
                "Ollama envelope is not JSON",
                extra={"error": str(exc)},
            )
            raise LlmHttpError(f"Ollama envelope not JSON: {exc}") from exc

        # ---- Structured logging of LLM metrics ----
        eval_count = envelope.get("eval_count") or 0
        eval_duration = envelope.get("eval_duration") or 0
        prompt_eval_count = envelope.get("prompt_eval_count") or 0
        prompt_eval_duration = envelope.get("prompt_eval_duration") or 0
        total_duration = envelope.get("total_duration") or 0
        tps = (eval_count / (eval_duration / 1e9)) if eval_duration > 0 else 0.0

        logger.info(
            "LLM generation complete",
            extra={
                "model": self._settings.ollama_model,
                "duration_ms": int(total_duration / 1e6),
                "eval_count": eval_count,
                "eval_duration_ms": int(eval_duration / 1e6),
                "prompt_eval_count": prompt_eval_count,
                "prompt_eval_duration_ms": int(prompt_eval_duration / 1e6),
                "tokens_per_second": round(tps, 2),
                "done_reason": envelope.get("done_reason"),
                "json_format": json_format,
            },
        )

        # ---- Parse the actual model output ----
        response_text = envelope.get("response", "")

        if not json_format:
            return response_text

        try:
            return json.loads(response_text)
        except json.JSONDecodeError as exc:
            logger.error(
                "LLM response is not valid JSON",
                extra={
                    "error": str(exc),
                    "response_preview": response_text[:200],
                },
            )
            raise LlmInvalidJsonError(
                f"LLM response is not valid JSON: {exc}"
            ) from exc

    # ---------- Internals ----------

    async def _call_with_retry(
        self, client: httpx.AsyncClient, payload: dict
    ) -> httpx.Response:
        """POST /api/generate with 1 retry on TimeoutException."""
        max_attempts = 2
        last_exc: Optional[BaseException] = None

        for attempt in range(1, max_attempts + 1):
            t0 = time.monotonic()
            try:
                return await client.post("/api/generate", json=payload)
            except httpx.TimeoutException as exc:
                duration_ms = int((time.monotonic() - t0) * 1000)
                last_exc = exc
                logger.warning(
                    "Ollama timeout",
                    extra={
                        "attempt": attempt,
                        "max_attempts": max_attempts,
                        "duration_ms": duration_ms,
                    },
                )
                if attempt < max_attempts:
                    await asyncio.sleep(1.0)
                    continue
            except httpx.RequestError as exc:
                logger.error(
                    "Ollama request error",
                    extra={
                        "error": str(exc),
                        "type": type(exc).__name__,
                    },
                )
                raise LlmHttpError(f"Ollama request failed: {exc}") from exc

        raise LlmTimeoutError(
            f"Ollama timeout after {max_attempts} attempts"
        ) from last_exc