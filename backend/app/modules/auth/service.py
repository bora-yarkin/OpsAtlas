# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for authentication, session lifecycle, and account security."""

import json
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.auth.policy import is_dev_environment, should_enforce_mfa
from app.core.config import settings
from app.core.deps import bad_request, not_found, too_many_requests, unauthorized
from app.core.auth.policy import hash_onboarding_token
from app.core.auth.policy import validate_password_policy
from app.core.auth.policy import generate_refresh_token, hash_refresh_token
from app.core.auth.security import (
    build_totp_uri,
    create_access_token,
    generate_totp_secret,
    hash_password,
    verify_password,
    verify_password_and_update,
    verify_totp_code,
)
from app.modules.auth.deps import resolve_user_auth_role

from .models import (
    AuthSessionPolicy,
    User,
    UserDashboardPreference,
    UserNotificationPreference,
    UserNotificationPreferenceAudit,
    UserSecurityState,
    UserSession,
)

_IP_ATTEMPTS: dict[str, list[float]] = {}
_IP_ATTEMPTS_LOCK = threading.Lock()
_REFRESH_ATTEMPTS: dict[str, list[float]] = {}
_REFRESH_ATTEMPTS_LOCK = threading.Lock()

SESSION_PROFILE_THIS_BROWSER = "this_browser"
SESSION_PROFILE_REMEMBER_DEVICE = "remember_device"
_SESSION_POLICY_ROW_ID = 1
_REVOKED_SESSION_RETENTION_DAYS = 7


@dataclass(slots=True)
class LoginResult:
    """Outcome of a login attempt, including onboarding and MFA branches."""

    access_token: str | None
    refresh_token: str | None
    session_id: str | None
    refresh_expires_at: datetime | None
    session_profile: str | None
    session_warning_seconds: int | None
    onboarding_required: bool
    onboarding_email: str | None
    mfa_required: bool = False
    mfa_setup_required: bool = False
    mfa_verified: bool = False


@dataclass(slots=True)
class SessionTokenBundle:
    """Issued token material plus metadata the client needs for session UX."""

    access_token: str
    refresh_token: str
    session_id: str
    refresh_expires_at: datetime
    session_profile: str
    session_warning_seconds: int


@dataclass(slots=True)
class SessionPolicySnapshot:
    """Normalized view of the singleton session policy row."""

    allow_remember_device: bool
    default_profile: str
    this_browser_days: int
    remember_device_days: int
    warning_minutes: int


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _coerce_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _normalize_days(value: int | None, *, fallback: int) -> int:
    candidate = int(value if value is not None else fallback)
    return max(1, min(365, candidate))


def _normalize_warning_minutes(value: int | None, *, fallback: int = 15) -> int:
    candidate = int(value if value is not None else fallback)
    return max(1, min(240, candidate))


def _normalize_session_profile(
    value: str | None,
    *,
    allow_remember_device: bool,
    fallback: str,
) -> str:
    normalized = (value or "").strip().lower()
    if normalized == SESSION_PROFILE_REMEMBER_DEVICE and allow_remember_device:
        return SESSION_PROFILE_REMEMBER_DEVICE
    if normalized == SESSION_PROFILE_THIS_BROWSER:
        return SESSION_PROFILE_THIS_BROWSER
    if fallback == SESSION_PROFILE_REMEMBER_DEVICE and allow_remember_device:
        return SESSION_PROFILE_REMEMBER_DEVICE
    return SESSION_PROFILE_THIS_BROWSER


def _policy_from_row(row: AuthSessionPolicy) -> SessionPolicySnapshot:
    allow_remember_device = bool(getattr(row, "allow_remember_device", True))
    this_browser_days = _normalize_days(getattr(row, "this_browser_days", None), fallback=1)
    remember_fallback = _normalize_days(int(settings.refresh_token_days or 14), fallback=14)
    remember_device_days = _normalize_days(
        getattr(row, "remember_device_days", None),
        fallback=max(this_browser_days, remember_fallback),
    )
    remember_device_days = max(this_browser_days, remember_device_days)
    warning_minutes = _normalize_warning_minutes(getattr(row, "warning_minutes", None), fallback=15)
    default_profile = _normalize_session_profile(
        getattr(row, "default_profile", None),
        allow_remember_device=allow_remember_device,
        fallback=SESSION_PROFILE_THIS_BROWSER,
    )
    return SessionPolicySnapshot(
        allow_remember_device=allow_remember_device,
        default_profile=default_profile,
        this_browser_days=this_browser_days,
        remember_device_days=remember_device_days,
        warning_minutes=warning_minutes,
    )


def _default_policy_snapshot() -> SessionPolicySnapshot:
    remember_device_days = _normalize_days(int(settings.refresh_token_days or 14), fallback=14)
    return SessionPolicySnapshot(
        allow_remember_device=True,
        default_profile=SESSION_PROFILE_THIS_BROWSER,
        this_browser_days=1,
        remember_device_days=max(1, remember_device_days),
        warning_minutes=15,
    )


def _apply_policy_snapshot(row: AuthSessionPolicy, snapshot: SessionPolicySnapshot) -> None:
    row.allow_remember_device = snapshot.allow_remember_device
    row.default_profile = snapshot.default_profile
    row.this_browser_days = snapshot.this_browser_days
    row.remember_device_days = snapshot.remember_device_days
    row.warning_minutes = snapshot.warning_minutes


def get_or_create_session_policy(db: Session) -> AuthSessionPolicy:
    """Load the singleton session policy row, creating a normalized default if needed."""
    default_snapshot = _default_policy_snapshot()

    try:
        row = db.get(AuthSessionPolicy, _SESSION_POLICY_ROW_ID)
    except SQLAlchemyError:
        db.rollback()
        return AuthSessionPolicy(
            id=_SESSION_POLICY_ROW_ID,
            allow_remember_device=default_snapshot.allow_remember_device,
            default_profile=default_snapshot.default_profile,
            this_browser_days=default_snapshot.this_browser_days,
            remember_device_days=default_snapshot.remember_device_days,
            warning_minutes=default_snapshot.warning_minutes,
        )

    if row is None:
        row = AuthSessionPolicy(
            id=_SESSION_POLICY_ROW_ID,
            allow_remember_device=default_snapshot.allow_remember_device,
            default_profile=default_snapshot.default_profile,
            this_browser_days=default_snapshot.this_browser_days,
            remember_device_days=default_snapshot.remember_device_days,
            warning_minutes=default_snapshot.warning_minutes,
        )
        try:
            db.add(row)
            db.commit()
            db.refresh(row)
        except SQLAlchemyError:
            db.rollback()
        return row

    snapshot = _policy_from_row(row)
    normalized = (
        bool(getattr(row, "allow_remember_device", True)) == snapshot.allow_remember_device
        and str(getattr(row, "default_profile", "") or "").strip().lower() == snapshot.default_profile
        and int(getattr(row, "this_browser_days", 1) or 1) == snapshot.this_browser_days
        and int(getattr(row, "remember_device_days", snapshot.remember_device_days) or snapshot.remember_device_days)
        == snapshot.remember_device_days
        and int(getattr(row, "warning_minutes", 15) or 15) == snapshot.warning_minutes
    )
    if not normalized:
        _apply_policy_snapshot(row, snapshot)
        try:
            db.commit()
            db.refresh(row)
        except SQLAlchemyError:
            db.rollback()
    return row


def _policy_snapshot(db: Session) -> SessionPolicySnapshot:
    return _policy_from_row(get_or_create_session_policy(db))


def _session_policy_payload(policy: SessionPolicySnapshot) -> dict[str, object]:
    available_profiles = [SESSION_PROFILE_THIS_BROWSER]
    if policy.allow_remember_device:
        available_profiles.append(SESSION_PROFILE_REMEMBER_DEVICE)
    return {
        "allow_remember_device": policy.allow_remember_device,
        "default_profile": policy.default_profile,
        "this_browser_days": policy.this_browser_days,
        "remember_device_days": policy.remember_device_days,
        "warning_minutes": policy.warning_minutes,
        "available_profiles": available_profiles,
    }


def _warning_window_seconds(policy: SessionPolicySnapshot) -> int:
    return max(60, int(policy.warning_minutes) * 60)


def _duration_days_for_profile(policy: SessionPolicySnapshot, *, profile: str | None) -> int:
    normalized_profile = _normalize_session_profile(
        profile,
        allow_remember_device=policy.allow_remember_device,
        fallback=policy.default_profile,
    )
    if normalized_profile == SESSION_PROFILE_REMEMBER_DEVICE:
        return max(1, int(policy.remember_device_days))
    return max(1, int(policy.this_browser_days))


def _session_window_days(session: UserSession, *, now: datetime) -> int:
    expires_at = _coerce_utc(getattr(session, "refresh_expires_at", None))
    if expires_at is None:
        return max(1, int(settings.refresh_token_days or 14))
    anchor = _coerce_utc(getattr(session, "last_rotated_at", None))
    if anchor is None:
        anchor = _coerce_utc(getattr(session, "created_at", None))
    if anchor is None:
        anchor = now
    seconds = max(0, int((expires_at - anchor).total_seconds()))
    if seconds <= 0:
        return 1
    return max(1, int(round(seconds / 86400)))


def _infer_profile_from_window_days(policy: SessionPolicySnapshot, window_days: int) -> str:
    if not policy.allow_remember_device:
        return SESSION_PROFILE_THIS_BROWSER
    this_gap = abs(window_days - policy.this_browser_days)
    remember_gap = abs(window_days - policy.remember_device_days)
    if remember_gap < this_gap:
        return SESSION_PROFILE_REMEMBER_DEVICE
    return SESSION_PROFILE_THIS_BROWSER


def _check_ip_rate_limit(remote_addr: str | None) -> None:
    """Apply coarse in-memory throttling to password attempts per remote address."""
    per_minute = max(0, int(settings.auth_ip_rate_limit_per_minute or 0))
    if per_minute <= 0:
        return

    key = (remote_addr or "unknown").strip() or "unknown"
    now = time.time()
    cutoff = now - 60.0
    with _IP_ATTEMPTS_LOCK:
        events = _IP_ATTEMPTS.setdefault(key, [])
        while events and events[0] < cutoff:
            events.pop(0)
        if len(events) >= per_minute:
            raise unauthorized("Too many login attempts from this network. Try again shortly.")
        events.append(now)


def _check_refresh_rate_limit(user_id: str) -> None:
    """Throttle refresh-token rotations for a single account."""
    per_minute = max(0, int(settings.auth_refresh_rate_limit_per_minute or 0))
    if per_minute <= 0:
        return

    key = (user_id or "").strip()
    if not key:
        return

    now = time.time()
    cutoff = now - 60.0
    with _REFRESH_ATTEMPTS_LOCK:
        events = _REFRESH_ATTEMPTS.setdefault(key, [])
        while events and events[0] < cutoff:
            events.pop(0)
        if len(events) >= per_minute:
            raise too_many_requests("Too many refresh requests for this account. Try again shortly.")
        events.append(now)


def _lockout_seconds_for_attempts(failed_attempts: int) -> int:
    """Calculate the exponential backoff window for repeated login failures."""
    threshold = max(1, int(settings.auth_login_max_attempts or 1))
    if failed_attempts < threshold:
        return 0

    base_seconds = max(1, int(settings.auth_login_lockout_base_seconds or 1))
    max_seconds = max(base_seconds, int(settings.auth_login_lockout_max_seconds or base_seconds))
    exponent = max(0, failed_attempts - threshold)
    return min(max_seconds, base_seconds * (2**exponent))


def _append_auth_audit_event(
    db: Session,
    *,
    action: str,
    user_id: str,
    actor_user_id: str | None,
    summary: str,
    before: dict[str, object] | None = None,
    after: dict[str, object] | None = None,
) -> None:
    """Record an auth-related lifecycle event in the admin audit trail."""
    from app.modules.admin import service as admin_service

    admin_service.append_user_lifecycle_audit_event(
        db,
        action=action,
        user_id=user_id,
        actor_user_id=actor_user_id,
        summary=summary,
        before=before,
        after=after,
    )


def get_or_create_user_security_state(db: Session, user_id: str) -> UserSecurityState:
    """Return the per-user security row that stores lockout and MFA state."""
    get_user_or_404(db, user_id)
    state = db.get(UserSecurityState, user_id)
    if state:
        return state
    state = UserSecurityState(user_id=user_id)
    db.add(state)
    db.commit()
    db.refresh(state)
    return state


def _assert_not_locked(user: User, state: UserSecurityState) -> None:
    """Abort authentication while a temporary account lockout is active."""
    lockout_until = _coerce_utc(getattr(state, "lockout_until", None))
    now = _now_utc()
    if lockout_until is not None and lockout_until > now:
        remaining_seconds = int((lockout_until - now).total_seconds())
        remaining_minutes = max(1, remaining_seconds // 60)
        raise unauthorized(f"Account temporarily locked. Try again in {remaining_minutes} minute(s).")


def _record_failed_login(
    db: Session,
    *,
    user: User,
    state: UserSecurityState,
    reason: str,
) -> None:
    """Increment failed-attempt counters, update lockout state, and audit the event."""
    before_attempts = int(getattr(state, "failed_login_attempts", 0) or 0)
    before_lockout_until = _coerce_utc(getattr(state, "lockout_until", None))
    now = _now_utc()
    next_attempts = before_attempts + 1

    state.failed_login_attempts = next_attempts
    state.last_failed_login_at = now

    lockout_seconds = _lockout_seconds_for_attempts(next_attempts)
    lockout_until = now + timedelta(seconds=lockout_seconds) if lockout_seconds > 0 else None
    state.lockout_until = lockout_until

    _append_auth_audit_event(
        db,
        action="auth_login_failed",
        user_id=user.id,
        actor_user_id=user.id,
        summary="Failed login attempt recorded",
        before={
            "failed_login_attempts": before_attempts,
            "lockout_until": before_lockout_until.isoformat() if before_lockout_until is not None else None,
        },
        after={
            "failed_login_attempts": next_attempts,
            "lockout_until": lockout_until.isoformat() if lockout_until is not None else None,
            "reason": reason,
        },
    )

    if lockout_until is not None:
        _append_auth_audit_event(
            db,
            action="auth_lockout",
            user_id=user.id,
            actor_user_id=user.id,
            summary="Account lockout enforced after repeated failures",
            before={"failed_login_attempts": before_attempts},
            after={
                "failed_login_attempts": next_attempts,
                "lockout_until": lockout_until.isoformat(),
                "reason": reason,
            },
        )

    db.commit()


def _record_successful_login(
    db: Session,
    *,
    user: User,
    state: UserSecurityState,
    mfa_verified: bool,
    mfa_setup_required: bool,
) -> None:
    """Reset lockout counters and persist last-login / MFA verification timestamps."""
    now = _now_utc()
    before_attempts = int(getattr(state, "failed_login_attempts", 0) or 0)

    state.failed_login_attempts = 0
    state.lockout_until = None
    state.last_login_at = now
    if mfa_verified:
        state.last_mfa_verified_at = now

    _append_auth_audit_event(
        db,
        action="auth_login_success",
        user_id=user.id,
        actor_user_id=user.id,
        summary="Login successful",
        before={"failed_login_attempts": before_attempts},
        after={
            "failed_login_attempts": 0,
            "mfa_verified": bool(mfa_verified),
            "mfa_setup_required": bool(mfa_setup_required),
        },
    )
    db.commit()


def _mfa_issuer() -> str:
    configured = (settings.mfa_totp_issuer or "").strip()
    if configured:
        return configured
    app_name = (settings.app_name or "").strip()
    return app_name or "OpsAtlas"


def _is_mfa_enabled_for_account(state: UserSecurityState) -> bool:
    return bool(getattr(state, "mfa_enabled", False) and (getattr(state, "mfa_secret", None) or "").strip())


def _refresh_token_expiry(
    now: datetime | None = None,
    *,
    duration_days: int | None = None,
) -> datetime:
    """Compute the refresh-token expiry timestamp for the chosen session profile."""
    baseline = _now_utc() if now is None else now
    days = max(1, int(duration_days if duration_days is not None else settings.refresh_token_days or 14))
    return baseline + timedelta(days=days)


def _issue_tokens_for_session(
    *,
    user_id: str,
    role: str,
    mfa_verified: bool,
    session_id: str,
    refresh_token: str,
    refresh_expires_at: datetime,
    session_profile: str,
    session_warning_seconds: int,
) -> SessionTokenBundle:
    """Build the access/refresh token bundle returned to clients after auth flows."""
    return SessionTokenBundle(
        access_token=create_access_token(
            sub=user_id,
            role=role,
            mfa_verified=mfa_verified,
            session_id=session_id,
        ),
        refresh_token=refresh_token,
        session_id=session_id,
        refresh_expires_at=refresh_expires_at,
        session_profile=session_profile,
        session_warning_seconds=session_warning_seconds,
    )


def _create_session_and_issue_tokens(
    db: Session,
    *,
    user: User,
    role: str,
    mfa_verified: bool,
    requested_session_profile: str | None = None,
    remote_addr: str | None = None,
    user_agent: str | None = None,
) -> SessionTokenBundle:
    """Persist a new session row and mint the first access/refresh token pair."""
    now = _now_utc()
    policy = _policy_snapshot(db)
    session_profile = _normalize_session_profile(
        requested_session_profile,
        allow_remember_device=policy.allow_remember_device,
        fallback=policy.default_profile,
    )
    duration_days = _duration_days_for_profile(policy, profile=session_profile)
    refresh_expires_at = _refresh_token_expiry(now, duration_days=duration_days)
    refresh_token = generate_refresh_token()
    refresh_token_hash = hash_refresh_token(refresh_token)
    if not refresh_token_hash:
        raise unauthorized("Failed to issue session token")

    session = UserSession(
        id=str(uuid.uuid4()),
        user_id=user.id,
        refresh_token_hash=refresh_token_hash,
        refresh_expires_at=refresh_expires_at,
        ip_address=(remote_addr or "").strip() or None,
        user_agent=(user_agent or "").strip()[:500] or None,
        last_seen_at=now,
        last_rotated_at=now,
        mfa_verified_at=(now if mfa_verified else None),
    )
    db.add(session)
    db.commit()
    db.refresh(session)
    return _issue_tokens_for_session(
        user_id=user.id,
        role=role,
        mfa_verified=mfa_verified,
        session_id=session.id,
        refresh_token=refresh_token,
        refresh_expires_at=refresh_expires_at,
        session_profile=session_profile,
        session_warning_seconds=_warning_window_seconds(policy),
    )


def revoke_user_sessions(
    db: Session,
    *,
    user_id: str,
    reason: str,
    except_session_id: str | None = None,
    advance_invalid_before: bool = True,
    commit: bool = True,
) -> int:
    """Revoke every active session for a user, optionally preserving one session."""
    purge_expired_revoked_sessions(db, user_id=user_id, commit=False)
    now = _now_utc()
    if advance_invalid_before:
        state = db.get(UserSecurityState, user_id)
        if state is None:
            state = UserSecurityState(user_id=user_id)
            db.add(state)
        state.session_invalid_before = now

    rows = (
        db.execute(
            select(UserSession).where(
                UserSession.user_id == user_id,
                UserSession.revoked_at.is_(None),
            )
        )
        .scalars()
        .all()
    )
    revoked = 0
    for row in rows:
        if except_session_id is not None and row.id == except_session_id:
            continue
        row.revoked_at = now
        row.revoke_reason = reason[:120]
        revoked += 1
    if commit:
        db.commit()
    return revoked


def purge_expired_revoked_sessions(
    db: Session,
    *,
    user_id: str | None = None,
    commit: bool = True,
) -> int:
    """Delete revoked sessions once they pass the configured retention window."""
    cutoff = _now_utc() - timedelta(days=_REVOKED_SESSION_RETENTION_DAYS)
    query = delete(UserSession).where(
        UserSession.revoked_at.is_not(None),
        UserSession.revoked_at <= cutoff,
    )
    if user_id is not None and user_id.strip():
        query = query.where(UserSession.user_id == user_id.strip())
    result = db.execute(query.execution_options(synchronize_session=False))
    removed = int(result.rowcount or 0)
    if commit and removed > 0:
        db.commit()
    return removed


def refresh_session_tokens(
    db: Session,
    *,
    refresh_token: str,
    remote_addr: str | None = None,
    user_agent: str | None = None,
) -> SessionTokenBundle:
    """Rotate a refresh token for a live session and issue a fresh token bundle."""
    refresh_token_hash = hash_refresh_token(refresh_token)
    if not refresh_token_hash:
        raise unauthorized("Invalid refresh token")

    session = db.scalar(select(UserSession).where(UserSession.refresh_token_hash == refresh_token_hash))
    if session is None:
        raise unauthorized("Invalid refresh token")

    now = _now_utc()
    expires_at = _coerce_utc(getattr(session, "refresh_expires_at", None))
    if getattr(session, "revoked_at", None) is not None or expires_at is None or expires_at <= now:
        raise unauthorized("Session has expired. Please sign in again.")

    user = db.get(User, session.user_id)
    if user is None or not bool(getattr(user, "is_active", True)):
        raise unauthorized("Session has expired. Please sign in again.")

    _check_refresh_rate_limit(session.user_id)

    next_refresh_token = generate_refresh_token()
    next_refresh_hash = hash_refresh_token(next_refresh_token)
    if not next_refresh_hash:
        raise unauthorized("Invalid refresh token")

    policy = _policy_snapshot(db)
    window_days = _session_window_days(session, now=now)
    session_profile = _infer_profile_from_window_days(policy, window_days)
    duration_days = _duration_days_for_profile(policy, profile=session_profile)
    refresh_expires_at = _refresh_token_expiry(now, duration_days=duration_days)

    session.refresh_token_hash = next_refresh_hash
    session.refresh_expires_at = refresh_expires_at
    session.last_seen_at = now
    session.last_rotated_at = now
    if remote_addr is not None:
        session.ip_address = (remote_addr or "").strip() or None
    if user_agent is not None:
        session.user_agent = (user_agent or "").strip()[:500] or None

    role = resolve_user_auth_role(db, user)
    mfa_verified = bool(getattr(session, "mfa_verified_at", None))
    db.commit()
    return _issue_tokens_for_session(
        user_id=user.id,
        role=role,
        mfa_verified=mfa_verified,
        session_id=session.id,
        refresh_token=next_refresh_token,
        refresh_expires_at=refresh_expires_at,
        session_profile=session_profile,
        session_warning_seconds=_warning_window_seconds(policy),
    )


def get_session_policy(db: Session) -> dict[str, object]:
    """Expose the normalized session policy payload used by the web client."""
    return _session_policy_payload(_policy_snapshot(db))


def update_session_policy(
    db: Session,
    *,
    allow_remember_device: bool | None = None,
    apply_allow_remember_device: bool = False,
    default_profile: str | None = None,
    apply_default_profile: bool = False,
    this_browser_days: int | None = None,
    apply_this_browser_days: bool = False,
    remember_device_days: int | None = None,
    apply_remember_device_days: bool = False,
    warning_minutes: int | None = None,
    apply_warning_minutes: bool = False,
) -> dict[str, object]:
    """Update the singleton session policy while preserving valid profile combinations."""
    row = get_or_create_session_policy(db)

    current = _policy_from_row(row)
    next_allow_remember = current.allow_remember_device
    if apply_allow_remember_device and allow_remember_device is not None:
        next_allow_remember = bool(allow_remember_device)

    next_this_browser_days = current.this_browser_days
    if apply_this_browser_days and this_browser_days is not None:
        next_this_browser_days = _normalize_days(this_browser_days, fallback=current.this_browser_days)

    next_remember_device_days = current.remember_device_days
    if apply_remember_device_days and remember_device_days is not None:
        next_remember_device_days = _normalize_days(remember_device_days, fallback=current.remember_device_days)
    next_remember_device_days = max(next_this_browser_days, next_remember_device_days)

    next_warning_minutes = current.warning_minutes
    if apply_warning_minutes and warning_minutes is not None:
        next_warning_minutes = _normalize_warning_minutes(warning_minutes, fallback=current.warning_minutes)

    fallback_default = current.default_profile if current.default_profile else SESSION_PROFILE_THIS_BROWSER
    requested_default = current.default_profile
    if apply_default_profile and default_profile is not None:
        requested_default = default_profile
    next_default_profile = _normalize_session_profile(
        requested_default,
        allow_remember_device=next_allow_remember,
        fallback=fallback_default,
    )

    next_snapshot = SessionPolicySnapshot(
        allow_remember_device=next_allow_remember,
        default_profile=next_default_profile,
        this_browser_days=next_this_browser_days,
        remember_device_days=next_remember_device_days,
        warning_minutes=next_warning_minutes,
    )

    if next_snapshot != current:
        _apply_policy_snapshot(row, next_snapshot)
        try:
            db.commit()
            db.refresh(row)
        except SQLAlchemyError:
            db.rollback()

    return _session_policy_payload(next_snapshot)


def get_current_session_status(
    db: Session,
    *,
    user_id: str,
    session_id: str | None,
) -> dict[str, object]:
    """Return expiry and warning-window details for the currently authenticated session."""
    normalized_session_id = (session_id or "").strip()
    if not normalized_session_id:
        raise unauthorized("Session has expired. Please sign in again.")

    row = db.get(UserSession, normalized_session_id)
    if row is None or row.user_id != user_id or getattr(row, "revoked_at", None) is not None:
        raise unauthorized("Session has expired. Please sign in again.")

    now = _now_utc()
    refresh_expires_at = _coerce_utc(getattr(row, "refresh_expires_at", None))
    if refresh_expires_at is None or refresh_expires_at <= now:
        raise unauthorized("Session has expired. Please sign in again.")

    policy = _policy_snapshot(db)
    window_days = _session_window_days(row, now=now)
    session_profile = _infer_profile_from_window_days(policy, window_days)
    warning_window_seconds = _warning_window_seconds(policy)
    expires_in_seconds = max(0, int((refresh_expires_at - now).total_seconds()))

    return {
        "session_id": row.id,
        "refresh_expires_at": refresh_expires_at,
        "expires_in_seconds": expires_in_seconds,
        "warning_window_seconds": warning_window_seconds,
        "session_profile": session_profile,
        "warning_active": expires_in_seconds <= warning_window_seconds,
        "policy": _session_policy_payload(policy),
    }


def list_user_sessions(
    db: Session,
    *,
    user_id: str,
    scope: str = "active",
) -> list[UserSession]:
    """List a user's current and/or revoked sessions for account-management screens."""
    normalized_scope = scope.strip().lower()
    if normalized_scope not in {"active", "revoked", "all"}:
        raise bad_request("Unsupported session scope")

    purge_expired_revoked_sessions(db, user_id=user_id)

    query = select(UserSession).where(UserSession.user_id == user_id)
    if normalized_scope == "active":
        query = query.where(UserSession.revoked_at.is_(None)).order_by(
            UserSession.created_at.desc(),
        )
    elif normalized_scope == "revoked":
        query = query.where(UserSession.revoked_at.is_not(None)).order_by(
            UserSession.revoked_at.desc(),
            UserSession.created_at.desc(),
        )
    else:
        query = query.order_by(UserSession.created_at.desc())
    return list(db.execute(query).scalars().all())


def revoke_single_session(
    db: Session,
    *,
    user_id: str,
    session_id: str,
    reason: str,
) -> bool:
    """Revoke one specific session owned by the current user."""
    purge_expired_revoked_sessions(db, user_id=user_id, commit=False)
    row = db.get(UserSession, session_id)
    if row is None or row.user_id != user_id:
        raise not_found("Session not found")
    if getattr(row, "revoked_at", None) is not None:
        return False
    row.revoked_at = _now_utc()
    row.revoke_reason = reason[:120]
    db.commit()
    return True


def register(db: Session, email: str, name: str, password: str) -> User:
    """Create a new user account and provision its baseline organization records."""
    next_email = email.strip().lower()
    next_name = name.strip()
    if not next_name:
        raise bad_request("Name is required")
    validate_password_policy(password, email=next_email, name=next_name)
    exists = db.scalar(select(User).where(User.email == next_email))
    if exists:
        raise bad_request("Email already registered")
    first_user = db.scalar(select(User.id).limit(1)) is None
    u = User(
        id=str(uuid.uuid4()),
        email=next_email,
        name=next_name,
        password_hash=hash_password(password),
        global_role="admin" if first_user else "member",
    )
    db.add(u)
    from app.modules.admin import service as admin_service

    admin_service.sync_user_organization_item(db, u)
    admin_service.sync_user_builtin_role_binding(db, u)
    db.commit()
    db.refresh(u)
    return u


def login(
    db: Session,
    email: str,
    password: str,
    *,
    mfa_code: str | None = None,
    session_profile: str | None = None,
    remote_addr: str | None = None,
    user_agent: str | None = None,
) -> LoginResult:
    """Authenticate credentials, enforce lockout/MFA policy, and create a tracked session."""
    _check_ip_rate_limit(remote_addr)

    lookup_email = email.strip().lower()
    u = db.scalar(select(User).where(User.email == lookup_email))
    if not u:
        raise unauthorized("Invalid credentials")

    state = get_or_create_user_security_state(db, u.id)
    _assert_not_locked(u, state)

    password_ok, updated_password_hash = verify_password_and_update(password, u.password_hash)
    if not password_ok:
        _record_failed_login(db, user=u, state=state, reason="invalid_credentials")
        raise unauthorized("Invalid credentials")
    if updated_password_hash:
        u.password_hash = updated_password_hash

    if not bool(getattr(u, "is_active", True)):
        raise unauthorized("User account is deactivated")

    if bool(getattr(u, "must_change_password", False)):
        state.failed_login_attempts = 0
        state.lockout_until = None
        state.last_login_at = _now_utc()
        db.commit()
        return LoginResult(
            access_token=None,
            refresh_token=None,
            session_id=None,
            refresh_expires_at=None,
            session_profile=None,
            session_warning_seconds=None,
            onboarding_required=True,
            onboarding_email=u.email,
            mfa_required=False,
            mfa_setup_required=False,
            mfa_verified=False,
        )

    role = resolve_user_auth_role(db, u)
    mfa_required = False
    mfa_setup_required = False
    mfa_verified = False

    if should_enforce_mfa() and role in {"admin", "moderator"}:
        if not _is_mfa_enabled_for_account(state):
            mfa_setup_required = True
        else:
            mfa_required = True
            submitted_code = (mfa_code or "").strip()
            if submitted_code:
                if not verify_totp_code(
                    secret=state.mfa_secret or "",
                    code=submitted_code,
                    window=max(0, int(settings.mfa_totp_window or 1)),
                ):
                    _record_failed_login(db, user=u, state=state, reason="invalid_mfa")
                    raise unauthorized("Invalid MFA code")
                mfa_verified = True

    tokens = _create_session_and_issue_tokens(
        db,
        user=u,
        role=role,
        mfa_verified=mfa_verified,
        requested_session_profile=session_profile,
        remote_addr=remote_addr,
        user_agent=user_agent,
    )
    _record_successful_login(
        db,
        user=u,
        state=state,
        mfa_verified=mfa_verified,
        mfa_setup_required=mfa_setup_required,
    )
    return LoginResult(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
        session_profile=tokens.session_profile,
        session_warning_seconds=tokens.session_warning_seconds,
        onboarding_required=False,
        onboarding_email=u.email,
        mfa_required=mfa_required,
        mfa_setup_required=mfa_setup_required,
        mfa_verified=mfa_verified,
    )


def complete_onboarding_password_reset(
    db: Session,
    *,
    email: str,
    current_password: str,
    new_password: str,
    remote_addr: str | None = None,
    user_agent: str | None = None,
) -> SessionTokenBundle:
    """Finish first-login onboarding by replacing a temporary password and signing in."""
    lookup_email = email.strip().lower()
    user = db.scalar(select(User).where(User.email == lookup_email))
    if user is None or not verify_password(current_password, user.password_hash):
        raise unauthorized("Invalid credentials")
    if not bool(getattr(user, "is_active", True)):
        raise unauthorized("User account is deactivated")
    if not bool(getattr(user, "must_change_password", False)):
        raise bad_request("Onboarding password setup is not required for this account")
    expires_at = getattr(user, "invite_expires_at", None)
    if isinstance(expires_at, datetime):
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        if expires_at < datetime.now(timezone.utc):
            raise bad_request("Temporary credential expired. Ask your admin to resend invite.")

    validate_password_policy(new_password, email=user.email, name=user.name)
    if verify_password(new_password, user.password_hash):
        raise bad_request("New password must be different from the current password")

    user.password_hash = hash_password(new_password)
    user.must_change_password = False
    user.invite_expires_at = None
    user.invite_token_hash = None
    user.invite_token_issued_at = None

    from app.modules.admin import service as admin_service

    admin_service.append_user_lifecycle_audit_event(
        db,
        action="onboarding_complete",
        user_id=user.id,
        actor_user_id=user.id,
        summary="User completed onboarding password setup",
        before={
            "must_change_password": True,
        },
        after={
            "must_change_password": False,
        },
    )

    revoke_user_sessions(
        db,
        user_id=user.id,
        reason="onboarding_complete",
        commit=False,
    )
    db.commit()
    db.refresh(user)
    return _create_session_and_issue_tokens(
        db,
        user=user,
        role=resolve_user_auth_role(db, user),
        mfa_verified=False,
        remote_addr=remote_addr,
        user_agent=user_agent,
    )


def complete_onboarding_with_token(
    db: Session,
    *,
    token: str,
    new_password: str,
    remote_addr: str | None = None,
    user_agent: str | None = None,
) -> SessionTokenBundle:
    """Complete onboarding from an invite token, then create the user's first session."""
    token_hash = hash_onboarding_token(token)
    if not token_hash:
        raise unauthorized("Invalid or expired onboarding token")

    user = db.scalar(select(User).where(User.invite_token_hash == token_hash))
    if user is None:
        raise unauthorized("Invalid or expired onboarding token")
    if not bool(getattr(user, "is_active", True)):
        raise unauthorized("User account is deactivated")
    if not bool(getattr(user, "must_change_password", False)):
        raise bad_request("Onboarding password setup is not required for this account")

    expires_at = _coerce_utc(getattr(user, "invite_expires_at", None))
    now = _now_utc()
    if expires_at is None or expires_at < now:
        raise unauthorized("Invalid or expired onboarding token")

    validate_password_policy(new_password, email=user.email, name=user.name)
    if verify_password(new_password, user.password_hash):
        raise bad_request("New password must be different from the current password")

    user.password_hash = hash_password(new_password)
    user.must_change_password = False
    user.invite_expires_at = None
    user.invite_token_hash = None
    user.invite_token_issued_at = None

    from app.modules.admin import service as admin_service

    admin_service.append_user_lifecycle_audit_event(
        db,
        action="onboarding_complete_token",
        user_id=user.id,
        actor_user_id=user.id,
        summary="User completed onboarding password setup via token",
        before={
            "must_change_password": True,
            "invite_token_present": True,
        },
        after={
            "must_change_password": False,
            "invite_token_present": False,
        },
    )

    revoke_user_sessions(
        db,
        user_id=user.id,
        reason="onboarding_complete_token",
        commit=False,
    )
    db.commit()
    db.refresh(user)
    return _create_session_and_issue_tokens(
        db,
        user=user,
        role=resolve_user_auth_role(db, user),
        mfa_verified=False,
        remote_addr=remote_addr,
        user_agent=user_agent,
    )


def get_user_or_404(db: Session, user_id: str) -> User:
    """Load a user by primary key or raise the standard 404 helper."""
    u = db.get(User, user_id)
    if not u:
        raise not_found("User not found")
    return u


def update_me(db: Session, user_id: str, *, email: str | None = None, name: str | None = None) -> User:
    """Update the authenticated user's profile and keep org-directory mirrors in sync."""
    u = get_user_or_404(db, user_id)
    next_email = u.email if email is None else email.strip().lower()
    next_name = u.name if name is None else name.strip()
    if not next_name:
        raise bad_request("Name is required")
    if next_email != u.email:
        exists = db.scalar(select(User).where(User.email == next_email))
        if exists and exists.id != u.id:
            raise bad_request("Email already registered")
    u.email = next_email
    u.name = next_name
    from app.modules.admin import service as admin_service

    admin_service.sync_user_organization_item(db, u)
    db.commit()
    db.refresh(u)
    return u


def change_password(
    db: Session,
    user_id: str,
    *,
    current_password: str,
    new_password: str,
) -> int:
    """Change a user's password and revoke every existing session afterward."""
    u = get_user_or_404(db, user_id)
    if not verify_password(current_password, u.password_hash):
        raise unauthorized("Current password is incorrect")
    validate_password_policy(new_password, email=u.email, name=u.name)
    if verify_password(new_password, u.password_hash):
        raise bad_request("New password must be different from the current password")
    u.password_hash = hash_password(new_password)
    revoked_sessions = revoke_user_sessions(
        db,
        user_id=u.id,
        reason="password_change",
        except_session_id=None,
        commit=False,
    )
    db.commit()
    return revoked_sessions


def mfa_status(
    db: Session,
    *,
    user_id: str,
    verified_for_session: bool,
) -> dict[str, bool]:
    """Describe whether MFA is enabled, required, and verified for the active session."""
    user = get_user_or_404(db, user_id)
    state = get_or_create_user_security_state(db, user.id)
    role = resolve_user_auth_role(db, user)
    return {
        "enabled": _is_mfa_enabled_for_account(state),
        "required_for_sensitive_actions": bool(should_enforce_mfa() and role in {"admin", "moderator"}),
        "verified_for_session": bool(verified_for_session),
        "dev_bypass_active": bool(is_dev_environment() and not settings.mfa_enforce_in_dev),
    }


def begin_mfa_setup(db: Session, *, user_id: str) -> dict[str, str]:
    """Generate a fresh TOTP secret and enrollment URI for authenticator setup."""
    user = get_user_or_404(db, user_id)
    state = get_or_create_user_security_state(db, user.id)

    issuer = _mfa_issuer()
    secret = generate_totp_secret()
    state.mfa_secret = secret
    state.mfa_enabled = False
    state.mfa_enrolled_at = None
    state.last_mfa_verified_at = None

    db.commit()

    account_name = user.email.strip() or user.id
    return {
        "secret": secret,
        "otpauth_url": build_totp_uri(secret=secret, account_name=account_name, issuer=issuer),
        "issuer": issuer,
        "account_name": account_name,
    }


def enable_mfa(db: Session, *, user_id: str, code: str) -> dict[str, bool]:
    """Verify the enrollment code and permanently enable MFA for the account."""
    user = get_user_or_404(db, user_id)
    state = get_or_create_user_security_state(db, user.id)
    secret = (state.mfa_secret or "").strip()
    if not secret:
        raise bad_request("MFA setup has not been initialized")

    if not verify_totp_code(
        secret=secret,
        code=code,
        window=max(0, int(settings.mfa_totp_window or 1)),
    ):
        raise bad_request("Invalid MFA code")

    now = _now_utc()
    state.mfa_enabled = True
    state.mfa_enrolled_at = now
    state.last_mfa_verified_at = now

    _append_auth_audit_event(
        db,
        action="mfa_enabled",
        user_id=user.id,
        actor_user_id=user.id,
        summary="MFA enabled for account",
        before={"mfa_enabled": False},
        after={"mfa_enabled": True},
    )
    db.commit()

    return mfa_status(db, user_id=user.id, verified_for_session=True)


def disable_mfa(db: Session, *, user_id: str, code: str | None) -> dict[str, bool]:
    """Disable MFA after a final code check, then revoke existing sessions."""
    user = get_user_or_404(db, user_id)
    state = get_or_create_user_security_state(db, user.id)

    if _is_mfa_enabled_for_account(state):
        submitted = (code or "").strip()
        if not submitted:
            raise bad_request("MFA code is required to disable MFA")
        if not verify_totp_code(
            secret=state.mfa_secret or "",
            code=submitted,
            window=max(0, int(settings.mfa_totp_window or 1)),
        ):
            raise bad_request("Invalid MFA code")

    state.mfa_enabled = False
    state.mfa_secret = None
    state.mfa_enrolled_at = None
    state.last_mfa_verified_at = None

    _append_auth_audit_event(
        db,
        action="mfa_disabled",
        user_id=user.id,
        actor_user_id=user.id,
        summary="MFA disabled for account",
        before={"mfa_enabled": True},
        after={"mfa_enabled": False},
    )
    revoke_user_sessions(
        db,
        user_id=user.id,
        reason="mfa_disabled",
        commit=False,
    )
    db.commit()

    return mfa_status(db, user_id=user.id, verified_for_session=False)


def verify_mfa_for_session(
    db: Session,
    *,
    user_id: str,
    code: str,
    session_id: str | None,
) -> str:
    """Mark the active session as MFA-verified and return an upgraded access token."""
    user = get_user_or_404(db, user_id)
    state = get_or_create_user_security_state(db, user.id)

    if not settings.mfa_enabled:
        raise bad_request("MFA is disabled in configuration")
    if not _is_mfa_enabled_for_account(state):
        raise bad_request("MFA is not enabled for this account")

    if not verify_totp_code(
        secret=state.mfa_secret or "",
        code=code,
        window=max(0, int(settings.mfa_totp_window or 1)),
    ):
        raise unauthorized("Invalid MFA code")

    now = _now_utc()
    state.last_mfa_verified_at = now

    effective_session_id = (session_id or "").strip()
    if not effective_session_id:
        raise unauthorized("Session context missing. Please sign in again.")

    row = db.get(UserSession, effective_session_id)
    if row is None or row.user_id != user.id:
        raise unauthorized("Session has expired. Please sign in again.")
    if getattr(row, "revoked_at", None) is not None:
        raise unauthorized("Session has expired. Please sign in again.")

    row.last_seen_at = now
    row.mfa_verified_at = now
    db.commit()

    return create_access_token(
        sub=user.id,
        role=resolve_user_auth_role(db, user),
        mfa_verified=True,
        session_id=effective_session_id,
    )


def get_or_create_notification_preferences(db: Session, user_id: str) -> UserNotificationPreference:
    """Load or create the per-user notification preference row."""
    get_user_or_404(db, user_id)
    prefs = db.get(UserNotificationPreference, user_id)
    if prefs:
        return prefs
    prefs = UserNotificationPreference(user_id=user_id)
    db.add(prefs)
    db.commit()
    db.refresh(prefs)
    return prefs


def update_notification_preferences(
    db: Session,
    user_id: str,
    *,
    include_view: bool | None = None,
    include_search: bool | None = None,
    include_publish: bool | None = None,
    include_task: bool | None = None,
    digest_mode: str | None = None,
    digest_hour: int | None = None,
    digest_minute: int | None = None,
) -> UserNotificationPreference:
    """Persist notification settings and audit which preference keys changed."""
    if digest_mode is not None and digest_mode not in {"realtime", "hourly", "daily"}:
        raise bad_request("Invalid digest mode")
    if digest_hour is not None and (digest_hour < 0 or digest_hour > 23):
        raise bad_request("Delivery hour must be between 0 and 23")
    if digest_minute is not None and (digest_minute < 0 or digest_minute > 59):
        raise bad_request("Delivery minute must be between 0 and 59")
    prefs = get_or_create_notification_preferences(db, user_id)
    changed_keys: list[str] = []
    if include_view is not None:
        if prefs.include_view != include_view:
            changed_keys.append("include_view")
        prefs.include_view = include_view
    if include_search is not None:
        if prefs.include_search != include_search:
            changed_keys.append("include_search")
        prefs.include_search = include_search
    if include_publish is not None:
        if prefs.include_publish != include_publish:
            changed_keys.append("include_publish")
        prefs.include_publish = include_publish
    if include_task is not None:
        if prefs.include_task != include_task:
            changed_keys.append("include_task")
        prefs.include_task = include_task
    if digest_mode is not None:
        if prefs.digest_mode != digest_mode:
            changed_keys.append("digest_mode")
        prefs.digest_mode = digest_mode
    if digest_hour is not None:
        if prefs.digest_hour != digest_hour:
            changed_keys.append("digest_hour")
        prefs.digest_hour = digest_hour
    if digest_minute is not None:
        if prefs.digest_minute != digest_minute:
            changed_keys.append("digest_minute")
        prefs.digest_minute = digest_minute
    if changed_keys:
        db.add(
            UserNotificationPreferenceAudit(
                id=str(uuid.uuid4()),
                user_id=user_id,
                actor_user_id=user_id,
                changed_keys_csv=",".join(changed_keys),
                include_view=prefs.include_view,
                include_search=prefs.include_search,
                include_publish=prefs.include_publish,
                include_task=prefs.include_task,
                digest_mode=prefs.digest_mode,
                digest_hour=prefs.digest_hour,
                digest_minute=prefs.digest_minute,
            )
        )
    db.commit()
    db.refresh(prefs)
    return prefs


def _normalize_widget_ids(raw: list[str] | None) -> list[str]:
    if raw is None:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        value = str(item).strip().lower()
        if not value:
            continue
        if len(value) > 60:
            value = value[:60]
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
        if len(out) >= 32:
            break
    return out


def _parse_widget_ids(raw: str | None) -> list[str]:
    if raw is None or raw.strip() == "":
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    return _normalize_widget_ids([str(item) for item in decoded])


def _widget_ids_to_json(value: list[str] | None) -> str:
    return json.dumps(_normalize_widget_ids(value), separators=(",", ":"))


def get_or_create_dashboard_preferences(
    db: Session,
    user_id: str,
) -> UserDashboardPreference:
    """Load or create dashboard personalization state for a user."""
    get_user_or_404(db, user_id)
    prefs = db.get(UserDashboardPreference, user_id)
    if prefs:
        return prefs
    prefs = UserDashboardPreference(user_id=user_id)
    db.add(prefs)
    db.commit()
    db.refresh(prefs)
    return prefs


def dashboard_widget_order(prefs: UserDashboardPreference) -> list[str]:
    """Return the stored dashboard widget order as a normalized list."""
    return _parse_widget_ids(prefs.widget_order_json)


def dashboard_hidden_widgets(prefs: UserDashboardPreference) -> list[str]:
    """Return the stored dashboard hidden-widget list as normalized IDs."""
    return _parse_widget_ids(prefs.hidden_widgets_json)


def update_dashboard_preferences(
    db: Session,
    user_id: str,
    *,
    selected_space_id: str | None = None,
    apply_selected_space_id: bool = False,
    widget_order: list[str] | None = None,
    apply_widget_order: bool = False,
    hidden_widgets: list[str] | None = None,
    apply_hidden_widgets: bool = False,
    feed_seen_at: datetime | None = None,
    apply_feed_seen_at: bool = False,
) -> UserDashboardPreference:
    """Persist dashboard layout, selected space, and feed-read markers for the user."""
    prefs = get_or_create_dashboard_preferences(db, user_id)
    if apply_selected_space_id:
        cleaned_space_id = (selected_space_id or "").strip()
        prefs.selected_space_id = cleaned_space_id or None
    if apply_widget_order:
        prefs.widget_order_json = _widget_ids_to_json(widget_order)
    if apply_hidden_widgets:
        prefs.hidden_widgets_json = _widget_ids_to_json(hidden_widgets)
    if apply_feed_seen_at:
        prefs.feed_seen_at = feed_seen_at
    db.commit()
    db.refresh(prefs)
    return prefs
