# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Environment-aware authentication and deployment policy helpers."""

import hashlib
import re
import secrets

from app.core.config import settings
from app.core.deps import bad_request

_DEV_ENV_NAMES = {"dev", "development", "local", "test"}
_COMMON_COMPROMISED_PASSWORDS = {
    "123456",
    "12345678",
    "123456789",
    "1234567890",
    "111111",
    "000000",
    "qwerty",
    "abc123",
    "password",
    "password1",
    "passw0rd",
    "letmein",
    "admin",
    "welcome",
    "iloveyou",
    "monkey",
    "dragon",
    "baseball",
    "football",
    "superman",
    "trustno1",
}


def is_dev_environment() -> bool:
    return (settings.app_env or "").strip().lower() in _DEV_ENV_NAMES


def should_enforce_password_policy() -> bool:
    if is_dev_environment() and not settings.password_enforce_in_dev:
        return False
    return True


def should_enforce_mfa() -> bool:
    if not settings.mfa_enabled:
        return False
    if is_dev_environment() and not settings.mfa_enforce_in_dev:
        return False
    return True


def generate_onboarding_token(num_bytes: int = 32) -> str:
    return secrets.token_urlsafe(max(16, int(num_bytes)))


def hash_onboarding_token(token: str) -> str:
    normalized = (token or "").strip()
    if not normalized:
        return ""
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def generate_refresh_token(num_bytes: int = 48) -> str:
    return secrets.token_urlsafe(max(24, int(num_bytes)))


def hash_refresh_token(token: str) -> str:
    normalized = (token or "").strip()
    if not normalized:
        return ""
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def validate_password_policy(
    password: str,
    *,
    email: str | None = None,
    name: str | None = None,
) -> None:
    candidate = (password or "").strip()
    baseline_min = 6
    configured_min = max(baseline_min, int(settings.password_min_length or baseline_min))

    if len(candidate) < (configured_min if should_enforce_password_policy() else baseline_min):
        raise bad_request(f"Password must be at least {(configured_min if should_enforce_password_policy() else baseline_min)} characters")

    if not should_enforce_password_policy():
        return

    if settings.password_require_upper and re.search(r"[A-Z]", candidate) is None:
        raise bad_request("Password must include at least one uppercase letter")
    if settings.password_require_lower and re.search(r"[a-z]", candidate) is None:
        raise bad_request("Password must include at least one lowercase letter")
    if settings.password_require_digit and re.search(r"\d", candidate) is None:
        raise bad_request("Password must include at least one digit")
    if settings.password_require_symbol and re.search(r"[^A-Za-z0-9]", candidate) is None:
        raise bad_request("Password must include at least one special character")

    lowered = candidate.casefold()
    if settings.password_compromised_check_enabled and lowered in _COMMON_COMPROMISED_PASSWORDS:
        raise bad_request("Password is too common and was rejected")

    if email:
        local_part = email.split("@", 1)[0].strip().casefold()
        if len(local_part) >= 3 and local_part in lowered:
            raise bad_request("Password must not include your email name")

    if name:
        name_tokens = [token.casefold() for token in re.split(r"\s+", name.strip()) if len(token) >= 3]
        for token in name_tokens:
            if token and token in lowered:
                raise bad_request("Password must not include your name")
