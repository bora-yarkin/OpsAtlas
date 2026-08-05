# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Password, token, and MFA security primitives used by authentication flows."""

import base64
import hashlib
import hmac
import secrets
import struct
import time
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import quote

import jwt
from passlib.context import CryptContext

from ..config import settings

# Keep PBKDF2-SHA256 available for legacy password verification while issuing
# new hashes with Argon2.
pwd_context = CryptContext(schemes=["argon2", "pbkdf2_sha256"], deprecated="auto")


def hash_password(pw: str) -> str:
    """Hash a plaintext password using the strongest configured algorithm."""
    return pwd_context.hash(pw)


def verify_password(pw: str, pw_hash: str) -> bool:
    """Verify a plaintext password against a stored hash."""
    return pwd_context.verify(pw, pw_hash)


def verify_password_and_update(pw: str, pw_hash: str) -> tuple[bool, str | None]:
    """Verify a password and optionally return a migrated hash for legacy schemes."""
    return pwd_context.verify_and_update(pw, pw_hash)


def create_access_token(
    *,
    sub: str,
    role: str,
    mfa_verified: bool = False,
    session_id: str | None = None,
) -> str:
    """Create a signed JWT carrying subject, role, MFA, and session claims."""
    now = datetime.now(timezone.utc)
    exp = now + timedelta(minutes=settings.access_token_minutes)
    payload = {
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
        "iat": int(now.timestamp()),
        "exp": int(exp.timestamp()),
        "sub": sub,
        "role": role,
        "mfa": bool(mfa_verified),
        "sid": session_id,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> dict[str, Any]:
    """Decode and validate a JWT against the configured issuer and audience."""
    payload = jwt.decode(
        token,
        settings.jwt_secret,
        algorithms=["HS256"],
        audience=settings.jwt_audience,
        issuer=settings.jwt_issuer,
    )
    return dict(payload)


def generate_totp_secret(num_bytes: int = 20) -> str:
    """Generate a Base32 TOTP secret suitable for authenticator apps."""
    secret = base64.b32encode(secrets.token_bytes(max(10, num_bytes))).decode("ascii")
    return secret.rstrip("=")


def build_totp_uri(*, secret: str, account_name: str, issuer: str) -> str:
    """Build an ``otpauth://`` enrollment URI for QR-code based MFA setup."""
    normalized_secret = _normalize_secret(secret)
    safe_issuer = issuer.strip() or "OpsAtlas"
    safe_account = account_name.strip() or "user"
    label = f"{quote(safe_issuer)}:{quote(safe_account)}"
    return f"otpauth://totp/{label}?secret={quote(normalized_secret)}" f"&issuer={quote(safe_issuer)}&algorithm=SHA1&digits=6&period=30"


def verify_totp_code(
    *,
    secret: str,
    code: str,
    window: int = 1,
    at_time: float | None = None,
) -> bool:
    """Verify a six-digit TOTP code across a bounded clock-drift window."""
    normalized_code = (code or "").strip()
    if len(normalized_code) != 6 or not normalized_code.isdigit():
        return False

    normalized_secret = _normalize_secret(secret)
    if not normalized_secret:
        return False

    ts = time.time() if at_time is None else at_time
    counter = int(ts // 30)
    safe_window = max(0, min(int(window), 5))
    for offset in range(-safe_window, safe_window + 1):
        expected = _totp_code(normalized_secret, counter + offset)
        if hmac.compare_digest(expected, normalized_code):
            return True
    return False


def _normalize_secret(secret: str) -> str:
    """Canonicalize a Base32 secret before decoding or serializing it."""
    cleaned = "".join((secret or "").split()).upper().rstrip("=")
    if not cleaned:
        return ""
    padding = "=" * ((8 - (len(cleaned) % 8)) % 8)
    return cleaned + padding


def _totp_code(secret: str, counter: int) -> str:
    """Compute the RFC-compatible six-digit TOTP code for a given time counter."""
    key = base64.b32decode(secret, casefold=True)
    msg = struct.pack(">Q", max(0, counter))
    digest = hmac.new(key, msg, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    binary = ((digest[offset] & 0x7F) << 24) | (digest[offset + 1] << 16) | (digest[offset + 2] << 8) | digest[offset + 3]
    return str(binary % 1_000_000).zfill(6)
