# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Helpers for encrypting, decrypting, and rotating application-managed secrets."""

from __future__ import annotations

import base64
import hashlib
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.core.config import settings

_SECRET_FORMAT_VERSION = "v1"
_RELAXED_SECRET_ENV_NAMES = {"dev", "development", "local", "test"}


def _b64_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _b64_decode(value: str) -> bytes:
    padded = value + "=" * ((4 - (len(value) % 4)) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def _normalize_secret_key(raw: str) -> bytes | None:
    value = raw.strip()
    if not value:
        return None

    # Preferred: URL-safe base64 encoded 32-byte keys.
    try:
        decoded = _b64_decode(value)
        if len(decoded) == 32:
            return decoded
    except Exception:
        pass

    # Fallback for plaintext key material: hash to a fixed 32-byte AES key.
    return hashlib.sha256(value.encode("utf-8")).digest()


def _fallback_key() -> bytes:
    seed = str(getattr(settings, "jwt_secret", "opsatlas-secret-fallback"))
    return hashlib.sha256(f"opsatlas:secret:{seed}".encode("utf-8")).digest()


def _allows_derived_fallback() -> bool:
    env = str(getattr(settings, "app_env", "") or "").strip().lower()
    return env in _RELAXED_SECRET_ENV_NAMES


def has_configured_secret_encryption_keys() -> bool:
    configured = getattr(settings, "secret_encryption_keys", [])
    for raw in configured:
        if not isinstance(raw, str):
            continue
        if _normalize_secret_key(raw) is not None:
            return True
    return False


def require_secret_encryption_keys() -> None:
    if has_configured_secret_encryption_keys() or _allows_derived_fallback():
        return
    raise RuntimeError(
        "SECRET_ENCRYPTION_KEYS must be configured outside development/test environments; "
        "derived fallback from JWT_SECRET is disabled"
    )


def _key_ring() -> list[tuple[str, bytes]]:
    keys: list[tuple[str, bytes]] = []
    configured = getattr(settings, "secret_encryption_keys", [])
    for idx, raw in enumerate(configured):
        if not isinstance(raw, str):
            continue
        key = _normalize_secret_key(raw)
        if key is None:
            continue
        keys.append((f"k{idx + 1}", key))
    if keys:
        return keys

    require_secret_encryption_keys()
    keys.append(("fallback", _fallback_key()))
    return keys


def _split_payload(value: str) -> tuple[str, str, str, str] | None:
    parts = value.strip().split(":", 3)
    if len(parts) != 4:
        return None
    version, key_id, nonce_b64, cipher_b64 = parts
    if version != _SECRET_FORMAT_VERSION:
        return None
    if not key_id.strip() or not nonce_b64.strip() or not cipher_b64.strip():
        return None
    return version, key_id, nonce_b64, cipher_b64


def encrypt_secret(value: str | None) -> str | None:
    if value is None:
        return None
    raw = value.strip()
    if not raw:
        return None

    key_id, key = _key_ring()[0]
    nonce = os.urandom(12)
    cipher = AESGCM(key).encrypt(nonce, raw.encode("utf-8"), None)
    return ":".join([_SECRET_FORMAT_VERSION, key_id, _b64_encode(nonce), _b64_encode(cipher)])


def decrypt_secret(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None

    payload = _split_payload(raw)
    if payload is None:
        return None
    _, key_id, nonce_b64, cipher_b64 = payload

    try:
        nonce = _b64_decode(nonce_b64)
        cipher = _b64_decode(cipher_b64)
    except Exception:
        return None

    ring = _key_ring()
    by_id = {item_key_id: item_key for item_key_id, item_key in ring}
    candidates: list[tuple[str, bytes]] = []
    if key_id in by_id:
        candidates.append((key_id, by_id[key_id]))
    for item in ring:
        if item[0] != key_id:
            candidates.append(item)

    for _, key in candidates:
        try:
            plain = AESGCM(key).decrypt(nonce, cipher, None)
            return plain.decode("utf-8")
        except Exception:
            continue
    return None


def is_current_secret_encryption(value: str | None) -> bool:
    if not isinstance(value, str):
        return False
    payload = _split_payload(value)
    if payload is None:
        return False
    _, key_id, _, _ = payload
    current_key_id, _ = _key_ring()[0]
    return key_id == current_key_id
