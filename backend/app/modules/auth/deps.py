# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""FastAPI dependencies specific to authenticated user and role resolution."""

from collections.abc import Callable
from datetime import datetime, timezone
from typing import overload

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import InvalidTokenError
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.auth.policy import should_enforce_mfa
from app.core.auth.cookies import read_access_cookie
from app.core.config import settings
from app.core.deps import get_db
from app.core.deps import unauthorized, forbidden
from app.core.auth.security import decode_token
from app.modules.auth.models import User, UserSecurityState, UserSession

bearer = HTTPBearer(auto_error=False)
_ROLE_RANK = {"viewer": 0, "member": 1, "moderator": 2, "admin": 3}


def _coerce_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _iat_seconds(payload: dict[str, object]) -> int | None:
    raw = payload.get("iat")
    if isinstance(raw, int):
        return raw
    if isinstance(raw, float):
        return int(raw)
    return None


def _normalize_auth_role(value: object | None) -> str:
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in _ROLE_RANK:
            return normalized
    return "member"


def resolve_user_auth_role(db: Session, user: User | None) -> str:
    if user is None:
        return "member"

    cached = getattr(user, "_auth_role", None)
    if isinstance(cached, str) and cached in _ROLE_RANK:
        return cached

    stored_role = _normalize_auth_role(getattr(user, "global_role", None))

    from app.modules.admin.models import CustomRole, OrganizationItemLink

    role_keys = {
        role_key.strip().lower()
        for role_key, in db.execute(
            select(OrganizationItemLink.parent_id).where(
                OrganizationItemLink.parent_kind == "role",
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.child_id == user.id,
                OrganizationItemLink.active.is_(True),
            )
        ).all()
        if isinstance(role_key, str) and role_key.strip()
    }
    if not role_keys:
        return stored_role

    effective_by_key = {role_key: role_key for role_key in role_keys if role_key in _ROLE_RANK}
    unresolved = sorted(role_keys - effective_by_key.keys())
    if unresolved:
        for role_key, effective_level in db.execute(
            select(CustomRole.role_key, CustomRole.effective_level).where(
                CustomRole.role_key.in_(unresolved),
                CustomRole.active.is_(True),
            )
        ).all():
            if not isinstance(role_key, str) or not isinstance(effective_level, str):
                continue
            effective_by_key[role_key.strip().lower()] = _normalize_auth_role(effective_level)

    best_role = stored_role
    best_rank = _ROLE_RANK.get(best_role, 0)
    for effective_role in effective_by_key.values():
        rank = _ROLE_RANK.get(effective_role, -1)
        if rank > best_rank:
            best_role = effective_role
            best_rank = rank
    return best_role


@overload
def hydrate_user_auth_context(db: Session, user: None) -> None: ...


@overload
def hydrate_user_auth_context(db: Session, user: User) -> User: ...


def hydrate_user_auth_context(db: Session, user: User | None) -> User | None:
    if user is None:
        return None
    setattr(user, "_auth_role", resolve_user_auth_role(db, user))
    return user


def user_auth_role(user: User | None) -> str:
    if user is None:
        return "member"
    cached = getattr(user, "_auth_role", None)
    if isinstance(cached, str) and cached in _ROLE_RANK:
        return cached
    return _normalize_auth_role(getattr(user, "global_role", None))


def user_is_admin(user: User | None) -> bool:
    return user_auth_role(user) == "admin"


def user_is_admin_like(user: User | None) -> bool:
    return user_auth_role(user) in {"admin", "moderator"}


def user_mfa_verified(user: User | None) -> bool:
    if user is None:
        return False
    return bool(getattr(user, "_auth_mfa_verified", False))


def get_current_user(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: Session = Depends(get_db),
) -> User:
    token = (creds.credentials.strip() if creds and creds.credentials else "") or (read_access_cookie(request) or "")
    if not token:
        raise unauthorized()
    try:
        payload = decode_token(token)
    except InvalidTokenError:
        raise unauthorized()
    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise unauthorized()
    u = db.get(User, user_id)
    if not u:
        raise unauthorized()
    if not bool(getattr(u, "is_active", True)):
        raise unauthorized("User account is deactivated")

    now = datetime.now(timezone.utc)
    state = db.get(UserSecurityState, user_id)
    invalid_before = _coerce_utc(getattr(state, "session_invalid_before", None) if state is not None else None)
    token_iat = _iat_seconds(payload)
    if invalid_before is not None and token_iat is not None:
        if token_iat <= int(invalid_before.timestamp()):
            raise unauthorized("Session has expired. Please sign in again.")

    session_id = payload.get("sid")
    normalized_sid = session_id.strip() if isinstance(session_id, str) else ""
    if normalized_sid:
        session = db.get(UserSession, normalized_sid)
        if session is None or session.user_id != user_id:
            raise unauthorized("Session has expired. Please sign in again.")
        if getattr(session, "revoked_at", None) is not None:
            raise unauthorized("Session has expired. Please sign in again.")
        refresh_expires_at = _coerce_utc(getattr(session, "refresh_expires_at", None))
        if refresh_expires_at is None or refresh_expires_at <= now:
            raise unauthorized("Session has expired. Please sign in again.")

    hydrated = hydrate_user_auth_context(db, u)
    setattr(hydrated, "_auth_mfa_verified", bool(payload.get("mfa", False)))
    setattr(hydrated, "_auth_session_id", normalized_sid or None)
    return hydrated


def require_mfa_for_sensitive_action(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    if not settings.mfa_enabled or not should_enforce_mfa():
        return user

    role = resolve_user_auth_role(db, user)
    if role not in {"admin", "moderator"}:
        return user

    state = db.get(UserSecurityState, user.id)
    if state is None or not bool(getattr(state, "mfa_enabled", False)) or not (getattr(state, "mfa_secret", None) or "").strip():
        raise forbidden("MFA enrollment is required for elevated actions")

    if not user_mfa_verified(user):
        raise forbidden("MFA verification is required for this action")
    return user


def require_role(*allowed: str) -> Callable[..., User]:
    def dep(user: User = Depends(get_current_user)) -> User:
        if user_auth_role(user) not in allowed:
            raise forbidden("Insufficient role")
        return user

    return dep
