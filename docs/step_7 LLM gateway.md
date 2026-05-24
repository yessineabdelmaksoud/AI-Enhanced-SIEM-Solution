OK. Étape 7 = 3 fichiers (1 nouveau, 2 réécrits). Le moment où Qwen3 14B commence vraiment à travailler.

---

## Fichier 1 — `app/fastapi/app/services/exceptions.py`

```
nano ~/soc-ai-lab/app/fastapi/app/services/exceptions.py
```

```python
"""Custom exceptions raised by the LLM gateway and validation pipeline."""


class LlmTimeoutError(Exception):
    """LLM call timed out (Ollama did not respond within the budget)."""


class LlmInvalidJsonError(Exception):
    """LLM response field is not valid JSON when json_format=True."""


class LlmHttpError(Exception):
    """LLM endpoint returned a non-2xx HTTP status, or unreachable."""
```

---

## Fichier 2 — `app/fastapi/app/services/llm_gateway.py` (réécriture intégrale)

```
nano ~/soc-ai-lab/app/fastapi/app/services/llm_gateway.py
```

```python
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
```

---

## Fichier 3 — `app/fastapi/app/api/routes_debug.py` (réécriture intégrale)

```
nano ~/soc-ai-lab/app/fastapi/app/api/routes_debug.py
```

```python
"""Debug endpoints for visual validation of intermediate steps."""
import logging

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.models.alert import IncidentContext
from app.services.alert_service import AlertService
from app.services.context_service import ContextService
from app.services.exceptions import (
    LlmHttpError,
    LlmInvalidJsonError,
    LlmTimeoutError,
)
from app.services.llm_gateway import LlmGateway
from app.services.prompt_service import PromptService

logger = logging.getLogger(__name__)

router = APIRouter()


class LlmDebugRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=20000)
    json_format: bool = True


# ---------- Context (step 4) ----------

@router.get("/context/{alert_id}", response_model=IncidentContext)
async def get_context(alert_id: str, request: Request) -> IncidentContext:
    alert_service: AlertService = request.app.state.alert_service
    context_service: ContextService = request.app.state.context_service

    alert = await alert_service.get_alert(alert_id)
    if alert is None:
        raise HTTPException(404, f"Alert '{alert_id}' not found")

    return await context_service.build_context(alert)


# ---------- Prompt (step 6) ----------

@router.get("/prompt/{usage}/{alert_id}")
async def get_prompt(usage: str, alert_id: str, request: Request) -> dict:
    if usage not in ("explain", "investigate", "remediate"):
        raise HTTPException(400, f"Invalid usage '{usage}'")

    alert_service: AlertService = request.app.state.alert_service
    context_service: ContextService = request.app.state.context_service
    prompt_service: PromptService = request.app.state.prompt_service

    alert = await alert_service.get_alert(alert_id)
    if alert is None:
        raise HTTPException(404, f"Alert '{alert_id}' not found")

    context = await context_service.build_context(alert)
    prompt = prompt_service.build(usage, context)  # type: ignore[arg-type]

    return {
        "usage": usage,
        "alert_id": alert_id,
        "prompt_chars": len(prompt),
        "estimated_tokens": len(prompt) // 4,
        "prompt": prompt,
    }


@router.get("/remediation-actions")
async def list_actions(request: Request) -> dict:
    prompt_service: PromptService = request.app.state.prompt_service
    return {"actions": prompt_service.list_remediation_actions()}


# ---------- LLM (step 7) ----------

@router.post("/llm")
async def debug_llm(body: LlmDebugRequest, request: Request) -> dict:
    """Direct call to the LLM Gateway. For latency / format / concurrency testing."""
    llm_gw: LlmGateway = request.app.state.llm_gw

    try:
        result = await llm_gw.generate(body.prompt, json_format=body.json_format)
    except LlmTimeoutError as exc:
        raise HTTPException(504, f"LLM timeout: {exc}")
    except LlmInvalidJsonError as exc:
        raise HTTPException(502, f"LLM returned invalid JSON: {exc}")
    except LlmHttpError as exc:
        raise HTTPException(502, f"LLM HTTP error: {exc}")

    return {"status": "ok", "response": result}
```

---

## Redémarrage

```bash
sudo systemctl restart soc-ai-fastapi
sleep 3
sudo systemctl status soc-ai-fastapi --no-pager | head -10
sudo journalctl -u soc-ai-fastapi -n 20 --no-pager
```

Pas d'erreur d'import attendue.

---

## Validation

### Test 1 — /health toujours OK

```bash
curl -s http://localhost:8000/health | jq
```

Doit retourner 200 avec `ollama: "ok"`.

### Test 2 — Premier appel LLM réel via /debug/llm

```bash
time curl -s -X POST http://localhost:8000/debug/llm \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "Tu es un assistant. Réponds UNIQUEMENT avec ce JSON exact: {\"status\":\"ok\",\"value\":42}",
    "json_format": true
  }' | jq
```

**Attendu** :
```json
{
  "status": "ok",
  "response": {
    "status": "ok",
    "value": 42
  }
}
```

Latence : 30-90s (cohérent avec le benchmark).

### Test 3 — Logging structuré de la latence

```bash
sudo journalctl -u soc-ai-fastapi -n 5 --no-pager \
  | grep "LLM generation complete"
```

Tu dois voir une ligne JSON avec `duration_ms`, `eval_count`, `eval_duration_ms`, `prompt_eval_count`, `tokens_per_second`, `done_reason`.

### Test 4 — Sémaphore : deux appels simultanés

Dans un terminal :

```bash
# Terminal 1 : surveiller les logs
sudo journalctl -u soc-ai-fastapi -f -o cat
```

Dans un autre terminal :

```bash
# Lancer 2 requêtes simultanées en arrière-plan
for i in 1 2; do
  (time curl -s -X POST http://localhost:8000/debug/llm \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"Réponds UNIQUEMENT: {\\\"id\\\":$i}\"}" \
    > /tmp/llm_$i.json) &
done
wait

cat /tmp/llm_1.json | jq
cat /tmp/llm_2.json | jq
```

**Attendu dans les logs** : la 2e requête doit produire un message `LLM call waited for semaphore` avec un `wait_ms` proche de la durée de la 1re requête (≥ 30000 ms).

**Attendu en latence** : la 1re requête termine en ~60-90s, la 2e en ~120-180s (60-90s d'attente + 60-90s d'exécution).

### Test 5 — Timeout (504)

```bash
# Sauvegarde + force timeout 2s
cp ~/soc-ai-lab/config/.env ~/soc-ai-lab/config/.env.bak
sed -i 's/^OLLAMA_TIMEOUT_S=.*/OLLAMA_TIMEOUT_S=2/' ~/soc-ai-lab/config/.env
sudo systemctl restart soc-ai-fastapi
sleep 3

# Doit timeout (Qwen3 14B met ~90s, on coupe à 2s)
curl -s -w "\nHTTP %{http_code}\n" -X POST http://localhost:8000/debug/llm \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Réponds UNIQUEMENT: {\"x\":1}"}'

# Restaure
cp ~/soc-ai-lab/config/.env.bak ~/soc-ai-lab/config/.env
sudo systemctl restart soc-ai-fastapi
sleep 3
curl -s http://localhost:8000/health | jq -r '.status'
```

**Attendu** :
- HTTP code = `504`
- detail contient `LLM timeout: Ollama timeout after 2 attempts`
- Logs montrent 2 messages `Ollama timeout` (attempt 1 puis 2)
- Après restauration : /health retourne `ok`

### Test 6 — Mode texte brut (json_format=false)

```bash
curl -s -X POST http://localhost:8000/debug/llm \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "Réponds en une phrase: pourquoi le ciel est bleu?",
    "json_format": false
  }' | jq
```

**Attendu** : `response` est une chaîne de texte libre, pas un dict.

---

## Critères de validation Étape 7

| Critère | Statut |
|---|---|
| `/health` répond toujours 200 | ☐ |
| POST `/debug/llm` retourne JSON dans 30-90s | ☐ |
| Logs contiennent `LLM generation complete` avec `duration_ms`, `eval_count`, `tokens_per_second`, `done_reason` | ☐ |
| 2 requêtes simultanées : la 2e attend (`LLM call waited for semaphore` dans les logs) | ☐ |
| Avec OLLAMA_TIMEOUT_S=2 : retourne HTTP 504 (pas 500) | ☐ |
| Logs montrent 2 tentatives sur timeout (retry visible) | ☐ |
| `json_format=false` retourne du texte brut | ☐ |
| `json_format=true` retourne un dict parsé | ☐ |
| Aucun OOM dans `dmesg` après plusieurs appels (num_ctx=8192) | ☐ |

---

## Si OOM (mémoire insuffisante)

Si `dmesg | tail` montre `Out of memory: Killed process`, tu peux dégrader `num_ctx` :

```bash
# Dans llm_gateway.py, change num_ctx: 8192 → 6144 ou 4096
sed -i 's/"num_ctx": 8192/"num_ctx": 4096/' \
  ~/soc-ai-lab/app/fastapi/app/services/llm_gateway.py
sudo systemctl restart soc-ai-fastapi
```

Trade-off : moins de contexte, mais le prompt + sortie restent < 4096 tokens dans la majorité des cas SOC.

---

**Crée les 3 fichiers, redémarre, fais les 6 tests. Donne-moi en retour :**

1. Latence du test 2 (premier appel LLM JSON)
2. Le `wait_ms` du test 4 (sémaphore en attente)
3. Le HTTP code du test 5 (doit être 504)
4. Tout OOM dans `dmesg | tail -20` après les tests

Si tout est vert, on passe à **Étape 8 — Validation des sorties + persistance dans `soc-ai-enrichments-*`** : on combine PromptService + LlmGateway + ValidationService pour produire les premiers enrichissements complets et les stocker dans Elasticsearch.