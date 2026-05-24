"""Custom exceptions raised by the LLM gateway and validation pipeline."""


class LlmTimeoutError(Exception):
    """LLM call timed out (Ollama did not respond within the budget)."""


class LlmInvalidJsonError(Exception):
    """LLM response field is not valid JSON when json_format=True."""


class LlmHttpError(Exception):
    """LLM endpoint returned a non-2xx HTTP status, or unreachable."""


class AlertNotFound(Exception):
    """Source alert not found in any monitored index."""