# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for authentication, session, and account security operations."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.orm import Session
from app.core.auth.cookies import (
    clear_auth_cookies,
    read_refresh_cookie,
    set_access_cookie,
    set_auth_cookies,
)
from app.core.deps import get_db, unauthorized
from app.modules.auth.models import User
from .schemas import (
    ChangePasswordIn,
    DashboardPreferencesOut,
    DashboardPreferencesUpdateIn,
    LoginIn,
    MeOut,
    MeUpdateIn,
    MfaDisableIn,
    MfaEnableIn,
    MfaSetupOut,
    MfaStatusOut,
    MfaVerifyIn,
    NotificationPreferencesOut,
    NotificationPreferencesUpdateIn,
    OnboardingCompleteIn,
    OnboardingTokenCompleteIn,
    RefreshIn,
    SessionOut,
    SessionPolicyOut,
    SessionStatusOut,
    TokenOut,
)
from . import service
from app.modules.auth.deps import get_current_user, user_auth_role

router = APIRouter(prefix="/auth", tags=["auth"])


def _apply_session_cookie_bundle(
    response: Response,
    *,
    access_token: str | None,
    refresh_token: str | None,
    session_id: str | None,
    refresh_expires_at: datetime | None = None,
) -> None:
    """Write or clear the auth cookie set based on the token bundle being returned."""
    access = (access_token or "").strip()
    refresh = (refresh_token or "").strip()
    session = (session_id or "").strip()
    if access and refresh and session:
        refresh_max_age_seconds: int | None = None
        if isinstance(refresh_expires_at, datetime):
            expires_at = refresh_expires_at
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
            else:
                expires_at = expires_at.astimezone(timezone.utc)
            refresh_max_age_seconds = max(60, int((expires_at - datetime.now(timezone.utc)).total_seconds()))
        set_auth_cookies(
            response,
            access_token=access,
            refresh_token=refresh,
            session_id=session,
            refresh_max_age_seconds=refresh_max_age_seconds,
        )
        return
    clear_auth_cookies(response)


@router.post("/login", response_model=TokenOut)
def login(payload: LoginIn, request: Request, response: Response, db: Session = Depends(get_db)):
    """Authenticate a user and issue session cookies and token metadata.

    This endpoint may return an onboarding or MFA requirement instead of a fully
    usable access token when policy demands an extra step.
    """
    result = service.login(
        db,
        payload.email,
        payload.password,
        mfa_code=payload.mfa_code,
        session_profile=payload.session_profile,
        remote_addr=(request.client.host if request.client else None),
        user_agent=request.headers.get("user-agent"),
    )
    _apply_session_cookie_bundle(
        response,
        access_token=result.access_token,
        refresh_token=result.refresh_token,
        session_id=result.session_id,
        refresh_expires_at=result.refresh_expires_at,
    )
    return TokenOut(
        access_token=result.access_token,
        refresh_token=result.refresh_token,
        session_id=result.session_id,
        refresh_expires_at=result.refresh_expires_at,
        session_profile=result.session_profile,
        session_warning_seconds=result.session_warning_seconds,
        onboarding_required=result.onboarding_required,
        onboarding_email=result.onboarding_email if result.onboarding_required else None,
        mfa_required=result.mfa_required,
        mfa_setup_required=result.mfa_setup_required,
        mfa_verified=result.mfa_verified,
    )


@router.post("/onboarding/complete", response_model=TokenOut)
def complete_onboarding(payload: OnboardingCompleteIn, request: Request, response: Response, db: Session = Depends(get_db)):
    """Replace a temporary onboarding password with a permanent one and sign in."""
    tokens = service.complete_onboarding_password_reset(
        db,
        email=str(payload.email),
        current_password=payload.current_password,
        new_password=payload.new_password,
        remote_addr=(request.client.host if request.client else None),
        user_agent=request.headers.get("user-agent"),
    )
    _apply_session_cookie_bundle(
        response,
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
    )
    return TokenOut(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
        session_profile=tokens.session_profile,
        session_warning_seconds=tokens.session_warning_seconds,
        onboarding_required=False,
        onboarding_email=None,
        mfa_required=False,
        mfa_setup_required=False,
        mfa_verified=False,
    )


@router.post("/onboarding/token/complete", response_model=TokenOut)
def complete_onboarding_with_token(payload: OnboardingTokenCompleteIn, request: Request, response: Response, db: Session = Depends(get_db)):
    """Complete onboarding from an invite token and immediately start a session."""
    tokens = service.complete_onboarding_with_token(
        db,
        token=payload.token,
        new_password=payload.new_password,
        remote_addr=(request.client.host if request.client else None),
        user_agent=request.headers.get("user-agent"),
    )
    _apply_session_cookie_bundle(
        response,
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
    )
    return TokenOut(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
        session_profile=tokens.session_profile,
        session_warning_seconds=tokens.session_warning_seconds,
        onboarding_required=False,
        onboarding_email=None,
        mfa_required=False,
        mfa_setup_required=False,
        mfa_verified=False,
    )


@router.post("/refresh", response_model=TokenOut)
def refresh(request: Request, response: Response, payload: RefreshIn | None = None, db: Session = Depends(get_db)):
    """Rotate the current session's refresh token and issue a fresh access token."""
    body_refresh_token = ((payload.refresh_token if payload is not None else None) or "").strip()
    refresh_token = body_refresh_token or (read_refresh_cookie(request) or "")
    tokens = service.refresh_session_tokens(
        db,
        refresh_token=refresh_token,
        remote_addr=(request.client.host if request.client else None),
        user_agent=request.headers.get("user-agent"),
    )
    _apply_session_cookie_bundle(
        response,
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
    )
    return TokenOut(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        session_id=tokens.session_id,
        refresh_expires_at=tokens.refresh_expires_at,
        session_profile=tokens.session_profile,
        session_warning_seconds=tokens.session_warning_seconds,
        onboarding_required=False,
        onboarding_email=None,
        mfa_required=False,
        mfa_setup_required=False,
        mfa_verified=False,
    )


@router.get("/me/mfa/status", response_model=MfaStatusOut)
def mfa_status(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Return whether MFA is enabled, required, and verified for this session."""
    return service.mfa_status(
        db,
        user_id=user.id,
        verified_for_session=bool(getattr(user, "_auth_mfa_verified", False)),
    )


@router.post("/me/mfa/setup", response_model=MfaSetupOut)
def mfa_setup(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Start MFA enrollment by issuing a new TOTP secret and otpauth URI."""
    return service.begin_mfa_setup(db, user_id=user.id)


@router.post("/me/mfa/enable", response_model=MfaStatusOut)
def mfa_enable(payload: MfaEnableIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Enable MFA after the user proves they enrolled the shared secret correctly."""
    return service.enable_mfa(db, user_id=user.id, code=payload.code)


@router.post("/me/mfa/disable", response_model=MfaStatusOut)
def mfa_disable(payload: MfaDisableIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Disable MFA for the current account after a final verification code check."""
    return service.disable_mfa(db, user_id=user.id, code=payload.code)


@router.post("/me/mfa/verify", response_model=TokenOut)
def mfa_verify(payload: MfaVerifyIn, response: Response, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Upgrade the active session to MFA-verified and return a refreshed access token."""
    token = service.verify_mfa_for_session(
        db,
        user_id=user.id,
        code=payload.code,
        session_id=getattr(user, "_auth_session_id", None),
    )
    if token.strip():
        set_access_cookie(response, access_token=token)
    return TokenOut(
        access_token=token,
        onboarding_required=False,
        onboarding_email=None,
        mfa_required=False,
        mfa_setup_required=False,
        mfa_verified=True,
    )


@router.get("/session/policy", response_model=SessionPolicyOut)
def session_policy(db: Session = Depends(get_db)):
    """Expose session-duration options and warning windows used by the client."""
    return service.get_session_policy(db)


@router.get("/me/session-status", response_model=SessionStatusOut)
def session_status(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Return expiry details for the currently authenticated session."""
    return service.get_current_session_status(
        db,
        user_id=user.id,
        session_id=getattr(user, "_auth_session_id", None),
    )


@router.get("/me", response_model=MeOut)
def me(user: User = Depends(get_current_user)):
    """Return the authenticated user's basic profile and effective global role."""
    return MeOut(
        id=user.id,
        email=user.email,
        name=user.name,
        global_role=user_auth_role(user),
        is_active=bool(getattr(user, "is_active", True)),
    )


@router.patch("/me", response_model=MeOut)
def update_me(payload: MeUpdateIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Update the authenticated user's name and/or email address."""
    u = service.update_me(
        db,
        user.id,
        email=None if payload.email is None else str(payload.email),
        name=payload.name,
    )
    return MeOut(
        id=u.id,
        email=u.email,
        name=u.name,
        global_role=user_auth_role(u),
        is_active=bool(getattr(u, "is_active", True)),
    )


@router.post("/me/password")
def change_password(payload: ChangePasswordIn, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Change the current password and revoke every existing session."""
    revoked_sessions = service.change_password(
        db,
        user.id,
        current_password=payload.current_password,
        new_password=payload.new_password,
    )
    return {"ok": True, "revoked_sessions": int(revoked_sessions)}


@router.post("/logout")
def logout(response: Response, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Clear auth cookies and revoke the current session if one is known."""
    current_session_id = getattr(user, "_auth_session_id", None)
    clear_auth_cookies(response)
    if not isinstance(current_session_id, str) or not current_session_id.strip():
        return {"ok": True, "revoked": False}
    revoked = service.revoke_single_session(
        db,
        user_id=user.id,
        session_id=current_session_id,
        reason="logout",
    )
    return {"ok": True, "revoked": bool(revoked)}


def _session_out(row, *, current_session_id: str | None) -> SessionOut:
    """Translate a session ORM row into the account-management response payload."""
    return SessionOut(
        id=row.id,
        created_at=getattr(row, "created_at", None),
        updated_at=getattr(row, "updated_at", None),
        last_seen_at=getattr(row, "last_seen_at", None),
        refresh_expires_at=getattr(row, "refresh_expires_at", None),
        revoked_at=getattr(row, "revoked_at", None),
        revoke_reason=getattr(row, "revoke_reason", None),
        ip_address=getattr(row, "ip_address", None),
        user_agent=getattr(row, "user_agent", None),
        mfa_verified=bool(getattr(row, "mfa_verified_at", None)),
        current=bool(current_session_id and row.id == current_session_id),
    )


@router.get("/me/sessions", response_model=list[SessionOut])
def sessions(
    scope: str = "active",
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """List the user's active or revoked sessions for account security screens."""
    rows = service.list_user_sessions(db, user_id=user.id, scope=scope)
    current_session_id = getattr(user, "_auth_session_id", None)
    return [_session_out(row, current_session_id=current_session_id) for row in rows]


@router.post("/me/sessions/{session_id}/revoke")
def revoke_session(session_id: str, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Revoke one specific session owned by the current user."""
    revoked = service.revoke_single_session(
        db,
        user_id=user.id,
        session_id=session_id,
        reason="manual_revoke",
    )
    return {"ok": True, "revoked": bool(revoked), "session_id": session_id}


@router.post("/me/sessions/revoke-others")
def revoke_other_sessions(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Revoke every session except the one backing the current request."""
    current_session_id = getattr(user, "_auth_session_id", None)
    normalized_session_id = current_session_id.strip() if isinstance(current_session_id, str) else ""
    if not normalized_session_id:
        raise unauthorized("Session has expired. Please sign in again.")
    revoked_count = service.revoke_user_sessions(
        db,
        user_id=user.id,
        reason="manual_revoke_others",
        except_session_id=normalized_session_id,
        advance_invalid_before=False,
    )
    return {
        "ok": True,
        "revoked_count": int(revoked_count),
        "current_session_id": normalized_session_id,
    }


@router.get("/me/notification-preferences", response_model=NotificationPreferencesOut)
def notification_preferences(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    """Return per-user notification and digest preferences."""
    prefs = service.get_or_create_notification_preferences(db, user.id)
    return NotificationPreferencesOut(
        include_view=prefs.include_view,
        include_search=prefs.include_search,
        include_publish=prefs.include_publish,
        include_task=prefs.include_task,
        digest_mode=prefs.digest_mode,
        digest_hour=prefs.digest_hour,
        digest_minute=prefs.digest_minute,
    )


@router.patch("/me/notification-preferences", response_model=NotificationPreferencesOut)
def update_notification_preferences(
    payload: NotificationPreferencesUpdateIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Persist per-user notification and digest preferences."""
    prefs = service.update_notification_preferences(
        db,
        user.id,
        include_view=payload.include_view,
        include_search=payload.include_search,
        include_publish=payload.include_publish,
        include_task=payload.include_task,
        digest_mode=payload.digest_mode,
        digest_hour=payload.digest_hour,
        digest_minute=payload.digest_minute,
    )
    return NotificationPreferencesOut(
        include_view=prefs.include_view,
        include_search=prefs.include_search,
        include_publish=prefs.include_publish,
        include_task=prefs.include_task,
        digest_mode=prefs.digest_mode,
        digest_hour=prefs.digest_hour,
        digest_minute=prefs.digest_minute,
    )


def _dashboard_prefs_out(row) -> DashboardPreferencesOut:
    """Serialize dashboard personalization state for the frontend."""
    return DashboardPreferencesOut(
        selected_space_id=row.selected_space_id,
        widget_order=service.dashboard_widget_order(row),
        hidden_widgets=service.dashboard_hidden_widgets(row),
        feed_seen_at=row.feed_seen_at,
    )


@router.get("/me/dashboard-preferences", response_model=DashboardPreferencesOut)
def dashboard_preferences(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return dashboard widget layout, selected space, and feed-read markers."""
    prefs = service.get_or_create_dashboard_preferences(db, user.id)
    return _dashboard_prefs_out(prefs)


@router.patch("/me/dashboard-preferences", response_model=DashboardPreferencesOut)
def update_dashboard_preferences(
    payload: DashboardPreferencesUpdateIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Persist dashboard layout and feed state for the current user."""
    prefs = service.update_dashboard_preferences(
        db,
        user.id,
        selected_space_id=payload.selected_space_id,
        apply_selected_space_id="selected_space_id" in payload.model_fields_set,
        widget_order=payload.widget_order,
        apply_widget_order="widget_order" in payload.model_fields_set,
        hidden_widgets=payload.hidden_widgets,
        apply_hidden_widgets="hidden_widgets" in payload.model_fields_set,
        feed_seen_at=payload.feed_seen_at,
        apply_feed_seen_at="feed_seen_at" in payload.model_fields_set,
    )
    return _dashboard_prefs_out(prefs)
