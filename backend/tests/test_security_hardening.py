# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import hashlib
import hmac
import json
import time

import pytest
from fastapi import HTTPException
from passlib.context import CryptContext

from app.core.auth.security import verify_password_and_update
from app.core.config import settings
from app.core.secret_crypto import encrypt_secret, require_secret_encryption_keys
from app.modules.auth.service import _REFRESH_ATTEMPTS, _REFRESH_ATTEMPTS_LOCK, _check_refresh_rate_limit
from app.modules.media.service import _urlsafe_b64encode, create_signed_media_token, validate_signed_media_token


def test_secret_encryption_requires_explicit_keys_outside_dev(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "app_env", "production")
    monkeypatch.setattr(settings, "secret_encryption_keys", [])

    with pytest.raises(RuntimeError, match="SECRET_ENCRYPTION_KEYS"):
        require_secret_encryption_keys()


def test_secret_encryption_uses_derived_fallback_in_dev(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "app_env", "dev")
    monkeypatch.setattr(settings, "secret_encryption_keys", [])
    monkeypatch.setattr(settings, "jwt_secret", "opsatlas-dev-secret")

    encrypted = encrypt_secret("s3cr3t")

    assert isinstance(encrypted, str)
    assert encrypted.startswith("v1:")


def test_verify_password_and_update_upgrades_legacy_pbkdf2_hash() -> None:
    legacy_context = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")
    legacy_hash = legacy_context.hash("correct horse battery staple")

    ok, upgraded_hash = verify_password_and_update(
        "correct horse battery staple",
        legacy_hash,
    )

    assert ok is True
    assert isinstance(upgraded_hash, str)
    assert upgraded_hash.startswith("$argon2")


def test_create_signed_media_token_uses_jwt_claims(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "jwt_secret", "opsatlas-media-secret-32-bytes-ok")
    monkeypatch.setattr(settings, "jwt_issuer", "opsatlas-tests")
    monkeypatch.setattr(settings, "jwt_audience", "opsatlas-client")

    token, expires_at = create_signed_media_token("asset-123", ttl_seconds=120)

    assert token.count(".") == 2
    assert validate_signed_media_token(token, "asset-123") is True
    assert validate_signed_media_token(token, "asset-999") is False
    assert expires_at.timestamp() > time.time()


def test_validate_signed_media_token_accepts_legacy_hmac_tokens(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "jwt_secret", "opsatlas-media-secret-32-bytes-ok")

    payload = {
        "asset_id": "asset-legacy",
        "exp": int(time.time()) + 120,
    }
    payload_bytes = json.dumps(
        payload,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    payload_segment = _urlsafe_b64encode(payload_bytes)
    signature = hmac.new(
        settings.jwt_secret.encode("utf-8"),
        payload_segment.encode("utf-8"),
        hashlib.sha256,
    ).digest()
    token = f"{payload_segment}.{_urlsafe_b64encode(signature)}"

    assert validate_signed_media_token(token, "asset-legacy") is True


def test_refresh_rate_limit_is_enforced_per_user(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "auth_refresh_rate_limit_per_minute", 2)
    with _REFRESH_ATTEMPTS_LOCK:
        _REFRESH_ATTEMPTS.clear()

    _check_refresh_rate_limit("user-1")
    _check_refresh_rate_limit("user-1")
    _check_refresh_rate_limit("user-2")

    with pytest.raises(HTTPException) as exc_info:
        _check_refresh_rate_limit("user-1")

    assert exc_info.value.status_code == 429
