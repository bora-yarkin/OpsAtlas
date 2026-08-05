# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

import pytest
from jwt import InvalidTokenError

from app.core.auth.security import create_access_token, decode_token
from app.core.config import settings


def _configure_jwt(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "jwt_secret", "opsatlas-test-secret-opsatlas-test-secret")
    monkeypatch.setattr(settings, "jwt_issuer", "opsatlas-tests")
    monkeypatch.setattr(settings, "jwt_audience", "opsatlas-client")
    monkeypatch.setattr(settings, "access_token_minutes", 30)


def test_create_access_token_round_trips(monkeypatch: pytest.MonkeyPatch) -> None:
    _configure_jwt(monkeypatch)

    token = create_access_token(
        sub="user-123",
        role="admin",
        mfa_verified=True,
        session_id="session-456",
    )

    payload = decode_token(token)

    assert payload["sub"] == "user-123"
    assert payload["role"] == "admin"
    assert payload["mfa"] is True
    assert payload["sid"] == "session-456"
    assert payload["iss"] == settings.jwt_issuer
    assert payload["aud"] == settings.jwt_audience
    assert isinstance(payload["iat"], int)
    assert isinstance(payload["exp"], int)
    assert payload["exp"] > payload["iat"]


def test_decode_token_rejects_tampering(monkeypatch: pytest.MonkeyPatch) -> None:
    _configure_jwt(monkeypatch)

    token = create_access_token(sub="user-123", role="member")
    header, payload, signature = token.split(".")
    tampered_signature = ("a" if signature[0] != "a" else "b") + signature[1:]
    tampered = ".".join((header, payload, tampered_signature))

    with pytest.raises(InvalidTokenError):
        decode_token(tampered)
