# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import base64
import hashlib
import hmac
import re
import struct
from urllib.parse import parse_qs, unquote, urlparse

from app.core.auth.security import build_totp_uri, generate_totp_secret, verify_totp_code


def _totp_code(secret: str, counter: int) -> str:
    padded = secret + ("=" * ((8 - (len(secret) % 8)) % 8))
    key = base64.b32decode(padded, casefold=True)
    msg = struct.pack(">Q", max(0, counter))
    digest = hmac.new(key, msg, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    binary = (
        ((digest[offset] & 0x7F) << 24)
        | (digest[offset + 1] << 16)
        | (digest[offset + 2] << 8)
        | digest[offset + 3]
    )
    return str(binary % 1_000_000).zfill(6)


def test_generate_totp_secret_uses_base32_without_padding() -> None:
    secret = generate_totp_secret(num_bytes=20)

    assert secret
    assert "=" not in secret
    assert re.fullmatch(r"[A-Z2-7]+", secret) is not None

    padded = secret + ("=" * ((8 - (len(secret) % 8)) % 8))
    decoded = base64.b32decode(padded, casefold=True)
    assert len(decoded) >= 10


def test_build_totp_uri_encodes_identity_and_defaults() -> None:
    uri = build_totp_uri(
        secret="abcd efgh",
        account_name="user+mail@example.com",
        issuer="Ops Atlas",
    )
    parsed = urlparse(uri)
    params = parse_qs(parsed.query)

    assert parsed.scheme == "otpauth"
    assert parsed.netloc == "totp"
    assert unquote(parsed.path.lstrip("/")) == "Ops Atlas:user+mail@example.com"
    assert params["secret"] == ["ABCDEFGH"]
    assert params["issuer"] == ["Ops Atlas"]
    assert params["algorithm"] == ["SHA1"]
    assert params["digits"] == ["6"]
    assert params["period"] == ["30"]

    fallback_uri = build_totp_uri(secret="abc", account_name=" ", issuer=" ")
    fallback_params = parse_qs(urlparse(fallback_uri).query)
    assert fallback_params["issuer"] == ["OpsAtlas"]


def test_verify_totp_code_accepts_current_and_windowed_tokens() -> None:
    secret = "JBSWY3DPEHPK3PXP"
    ts = 1_700_000_000.0
    counter = int(ts // 30)

    current_code = _totp_code(secret, counter)
    previous_code = _totp_code(secret, counter - 1)

    assert verify_totp_code(secret=secret, code=current_code, window=0, at_time=ts)
    assert verify_totp_code(secret=secret, code=previous_code, window=1, at_time=ts)
    assert not verify_totp_code(secret=secret, code=previous_code, window=0, at_time=ts)
    assert not verify_totp_code(secret=secret, code="12ab56", window=1, at_time=ts)
    assert not verify_totp_code(secret="", code=current_code, window=1, at_time=ts)
