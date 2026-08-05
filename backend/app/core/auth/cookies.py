# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP cookie helpers for session and refresh-token handling."""

from http.cookies import SimpleCookie
from typing import Literal

from fastapi import Request, Response

from app.core.auth.policy import is_dev_environment
from app.core.config import settings
from app.core.secret_crypto import decrypt_secret, encrypt_secret


def _cookie_secure() -> bool:
    if is_dev_environment():
        return bool(settings.auth_cookie_secure_in_dev)
    return bool(settings.auth_cookie_secure)


def _cookie_domain() -> str | None:
    value = (settings.auth_cookie_domain or "").strip()
    return value or None


def _cookie_path() -> str:
    raw = (settings.auth_cookie_path or "/").strip()
    if not raw:
        return "/"
    if raw.startswith("/"):
        return raw
    return f"/{raw}"


def _cookie_samesite() -> Literal["lax", "strict", "none"]:
    normalized = (settings.auth_cookie_samesite or "lax").strip().lower()
    if normalized == "strict":
        return "strict"
    if normalized == "none":
        return "none"
    return "lax"


def _encrypted_cookie_value(value: str) -> str:
    encrypted = encrypt_secret(value)
    if not encrypted:
        raise RuntimeError("Auth cookie encryption failed")
    return encrypted


def _set_cookie(response: Response, *, key: str, value: str, max_age: int) -> None:
    cookie = SimpleCookie()
    cookie[key] = _encrypted_cookie_value(value)
    morsel = cookie[key]
    morsel["max-age"] = max(1, int(max_age))
    morsel["httponly"] = True
    if _cookie_secure():
        morsel["secure"] = True
    morsel["samesite"] = _cookie_samesite()
    morsel["path"] = _cookie_path()
    domain = _cookie_domain()
    if domain:
        morsel["domain"] = domain
    response.raw_headers.append((b"set-cookie", morsel.OutputString().encode("latin-1")))


def set_auth_cookies(
    response: Response,
    *,
    access_token: str,
    refresh_token: str,
    session_id: str,
    refresh_max_age_seconds: int | None = None,
) -> None:
    _set_cookie(
        response,
        key=settings.auth_cookie_access_name,
        value=access_token,
        max_age=max(60, int(settings.access_token_minutes) * 60),
    )
    refresh_cookie_max_age = (
        max(3600, int(refresh_max_age_seconds))
        if refresh_max_age_seconds is not None
        else max(3600, int(settings.refresh_token_days) * 24 * 60 * 60)
    )
    _set_cookie(
        response,
        key=settings.auth_cookie_refresh_name,
        value=refresh_token,
        max_age=refresh_cookie_max_age,
    )
    _set_cookie(
        response,
        key=settings.auth_cookie_session_name,
        value=session_id,
        max_age=refresh_cookie_max_age,
    )


def set_access_cookie(response: Response, *, access_token: str) -> None:
    _set_cookie(
        response,
        key=settings.auth_cookie_access_name,
        value=access_token,
        max_age=max(60, int(settings.access_token_minutes) * 60),
    )


def clear_auth_cookies(response: Response) -> None:
    cookie_domain = _cookie_domain()
    cookie_path = _cookie_path()
    for key in (
        settings.auth_cookie_access_name,
        settings.auth_cookie_refresh_name,
        settings.auth_cookie_session_name,
    ):
        response.delete_cookie(
            key=key,
            path=cookie_path,
            domain=cookie_domain,
        )


def read_access_cookie(request: Request) -> str | None:
    return _read_cookie_value(request, settings.auth_cookie_access_name)


def read_refresh_cookie(request: Request) -> str | None:
    return _read_cookie_value(request, settings.auth_cookie_refresh_name)


def read_session_cookie(request: Request) -> str | None:
    return _read_cookie_value(request, settings.auth_cookie_session_name)


def _read_cookie_value(request: Request, cookie_name: str) -> str | None:
    value = (request.cookies.get(cookie_name) or "").strip()
    if not value:
        return None
    decrypted = decrypt_secret(value)
    if isinstance(decrypted, str) and decrypted.strip():
        return decrypted
    return None
