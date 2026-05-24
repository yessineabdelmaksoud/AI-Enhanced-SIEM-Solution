"""Application settings loaded from /home/vm-ai/soc-ai-lab/config/.env"""
from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # --- Elasticsearch ---
    es_host: str = Field(...)
    es_user: str = Field(...)
    es_pass: str = Field(...)
    es_ca_cert: str = Field(...)
    es_index_wazuh: str = "wazuh-alerts-*"
    es_index_suricata: str = "suricata-eve-*"
    es_index_enrich: str = "soc-ai-enrichments"

    # --- Ollama ---
    ollama_host: str = Field(...)
    ollama_model: str = "qwen3:14b"
    ollama_timeout_s: int = 180

    # --- FastAPI ---
    fastapi_host: str = "0.0.0.0"
    fastapi_port: int = 8000
    fastapi_log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"

    # --- Business logic ---
    context_window_min: int = 15
    dedup_ttl_min: int = 30
    llm_max_concurrent: int = 1

    # --- Prompt and schema paths ---
    prompts_dir: str = "/home/vm-ai/soc-ai-lab/config/ai/prompts/v1"
    schemas_dir: str = "/home/vm-ai/soc-ai-lab/config/ai/schemas/v1"
    remediation_actions_path: str = "/home/vm-ai/soc-ai-lab/config/ai/remediation_actions.json"

    model_config = SettingsConfigDict(
        env_file="/home/vm-ai/soc-ai-lab/config/.env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
