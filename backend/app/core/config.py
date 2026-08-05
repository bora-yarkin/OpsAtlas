# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Environment-backed application settings for backend runtime configuration."""

import json
from pathlib import Path
from typing import Annotated, Any

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


_BACKEND_ROOT = Path(__file__).resolve().parents[2]


def _parse_string_list(value: Any) -> Any:
    if value is None:
        return []
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return []
        if raw.startswith("["):
            try:
                decoded = json.loads(raw)
                if isinstance(decoded, list):
                    return [str(item).strip() for item in decoded if str(item).strip()]
            except json.JSONDecodeError:
                pass
        return [item.strip() for item in raw.split(",") if item.strip()]
    return value


class Settings(BaseSettings):
    app_env: str
    app_name: str
    api_host: str
    api_port: int
    public_api_base_url: str | None = None
    public_web_origin: str | None = None

    database_url: str
    db_echo: bool

    jwt_secret: str
    jwt_issuer: str
    jwt_audience: str
    access_token_minutes: int
    refresh_token_days: int = 14

    cors_origins: Annotated[list[str], NoDecode]
    trusted_hosts: Annotated[list[str], NoDecode] = []
    auto_create_tables: bool
    ai_enabled: bool
    ai_provider: str
    ai_rate_limit_per_minute: int
    ai_max_input_chars: int
    ai_summary_char_limit: int = 400
    media_storage_dir: str
    media_max_upload_mb: int
    media_token_ttl_seconds: int = 3600
    background_workers_enabled: bool
    maintenance_interval_seconds: int
    hsts_max_age_seconds: int = 63072000
    auth_login_max_attempts: int = 5
    auth_login_lockout_base_seconds: int = 60
    auth_login_lockout_max_seconds: int = 1800
    auth_ip_rate_limit_per_minute: int = 60
    auth_refresh_rate_limit_per_minute: int = 30
    password_min_length: int = 10
    password_require_upper: bool = True
    password_require_lower: bool = True
    password_require_digit: bool = True
    password_require_symbol: bool = True
    password_compromised_check_enabled: bool = True
    password_enforce_in_dev: bool = False
    mfa_enabled: bool = True
    mfa_enforce_in_dev: bool = False
    mfa_totp_window: int = 1
    mfa_totp_issuer: str = "OpsAtlas"

    auth_cookie_access_name: str = "opsatlas_access"
    auth_cookie_refresh_name: str = "opsatlas_refresh"
    auth_cookie_session_name: str = "opsatlas_session"
    auth_cookie_path: str = "/"
    auth_cookie_domain: str | None = None
    auth_cookie_samesite: str = "lax"
    auth_cookie_secure: bool = True
    auth_cookie_secure_in_dev: bool = False

    media_allowed_extensions: Annotated[list[str], NoDecode] = []
    media_allowed_mime_types: Annotated[list[str], NoDecode] = []
    media_blocked_extensions: Annotated[list[str], NoDecode] = [
        "html",
        "htm",
        "svg",
        "svgz",
        "js",
        "mjs",
        "xhtml",
    ]
    media_blocked_mime_types: Annotated[list[str], NoDecode] = [
        "text/html",
        "application/xhtml+xml",
        "image/svg+xml",
        "application/javascript",
        "text/javascript",
    ]
    media_quarantine_dir: str = "./instance/media_storage/quarantine"
    media_malware_scan_enabled: bool = False
    media_malware_scan_command: Annotated[list[str], NoDecode] = []

    secret_encryption_keys: Annotated[list[str], NoDecode] = []

    @field_validator(
        "cors_origins",
        "trusted_hosts",
        "media_allowed_extensions",
        "media_allowed_mime_types",
        "media_blocked_extensions",
        "media_blocked_mime_types",
        "media_malware_scan_command",
        "secret_encryption_keys",
        mode="before",
    )
    @classmethod
    def _parse_string_lists(cls, value: Any) -> Any:
        return _parse_string_list(value)

    @field_validator("auth_cookie_samesite", mode="before")
    @classmethod
    def _normalize_cookie_samesite(cls, value: Any) -> str:
        normalized = str(value or "lax").strip().lower()
        if normalized not in {"lax", "strict", "none"}:
            return "lax"
        return normalized

    model_config = SettingsConfigDict(
        env_file=str(_BACKEND_ROOT / "instance" / ".env"),
        case_sensitive=False,
        extra="ignore",  # .env is shared with Makefile dev-tooling variables
    )


# Pylance/pyright doesn't model BaseSettings env-driven construction and flags
# missing required args here; runtime values come from `.env` / environment vars.
settings = Settings()  # pyright: ignore[reportCallIssue]
