# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for authentication and account-management APIs."""

from datetime import datetime

from pydantic import BaseModel, EmailStr, Field


class LoginIn(BaseModel):
    email: EmailStr
    password: str
    mfa_code: str | None = Field(default=None, min_length=6, max_length=12)
    session_profile: str | None = Field(
        default=None,
        pattern="^(this_browser|remember_device)$",
    )


class TokenOut(BaseModel):
    access_token: str | None = None
    refresh_token: str | None = None
    session_id: str | None = None
    refresh_expires_at: datetime | None = None
    session_profile: str | None = None
    session_warning_seconds: int | None = None
    token_type: str = "bearer"
    onboarding_required: bool = False
    onboarding_email: EmailStr | None = None
    mfa_required: bool = False
    mfa_setup_required: bool = False
    mfa_verified: bool = False


class RefreshIn(BaseModel):
    refresh_token: str | None = Field(default=None, min_length=20, max_length=1024)


class SessionOut(BaseModel):
    id: str
    created_at: datetime | None = None
    updated_at: datetime | None = None
    last_seen_at: datetime | None = None
    refresh_expires_at: datetime | None = None
    revoked_at: datetime | None = None
    revoke_reason: str | None = None
    ip_address: str | None = None
    user_agent: str | None = None
    mfa_verified: bool = False
    current: bool = False


class SessionPolicyOut(BaseModel):
    allow_remember_device: bool
    default_profile: str
    this_browser_days: int
    remember_device_days: int
    warning_minutes: int
    available_profiles: list[str] = Field(default_factory=list)


class SessionPolicyUpdateIn(BaseModel):
    allow_remember_device: bool | None = None
    default_profile: str | None = Field(
        default=None,
        pattern="^(this_browser|remember_device)$",
    )
    this_browser_days: int | None = Field(default=None, ge=1, le=365)
    remember_device_days: int | None = Field(default=None, ge=1, le=365)
    warning_minutes: int | None = Field(default=None, ge=1, le=240)


class SessionStatusOut(BaseModel):
    session_id: str
    refresh_expires_at: datetime
    expires_in_seconds: int
    warning_window_seconds: int
    session_profile: str
    warning_active: bool
    policy: SessionPolicyOut


class MeOut(BaseModel):
    id: str
    email: EmailStr
    name: str
    global_role: str
    is_active: bool = True


class OnboardingCompleteIn(BaseModel):
    email: EmailStr
    current_password: str = Field(min_length=1)
    new_password: str = Field(min_length=6, max_length=200)


class OnboardingTokenCompleteIn(BaseModel):
    token: str = Field(min_length=20, max_length=512)
    new_password: str = Field(min_length=6, max_length=200)


class MeUpdateIn(BaseModel):
    email: EmailStr | None = None
    name: str | None = Field(default=None, min_length=1, max_length=200)


class ChangePasswordIn(BaseModel):
    current_password: str = Field(min_length=1)
    new_password: str = Field(min_length=6, max_length=200)


class NotificationPreferencesOut(BaseModel):
    include_view: bool
    include_search: bool
    include_publish: bool
    include_task: bool
    digest_mode: str
    digest_hour: int
    digest_minute: int


class NotificationPreferencesUpdateIn(BaseModel):
    include_view: bool | None = None
    include_search: bool | None = None
    include_publish: bool | None = None
    include_task: bool | None = None
    digest_mode: str | None = Field(default=None, pattern="^(realtime|hourly|daily)$")
    digest_hour: int | None = Field(default=None, ge=0, le=23)
    digest_minute: int | None = Field(default=None, ge=0, le=59)


class DashboardPreferencesOut(BaseModel):
    selected_space_id: str | None = None
    widget_order: list[str] = Field(default_factory=list)
    hidden_widgets: list[str] = Field(default_factory=list)
    feed_seen_at: datetime | None = None


class DashboardPreferencesUpdateIn(BaseModel):
    selected_space_id: str | None = None
    widget_order: list[str] | None = None
    hidden_widgets: list[str] | None = None
    feed_seen_at: datetime | None = None


class MfaStatusOut(BaseModel):
    enabled: bool
    required_for_sensitive_actions: bool
    verified_for_session: bool
    dev_bypass_active: bool


class MfaSetupOut(BaseModel):
    secret: str
    otpauth_url: str
    issuer: str
    account_name: str


class MfaEnableIn(BaseModel):
    code: str = Field(min_length=6, max_length=12)


class MfaDisableIn(BaseModel):
    code: str | None = Field(default=None, min_length=6, max_length=12)


class MfaVerifyIn(BaseModel):
    code: str = Field(min_length=6, max_length=12)
