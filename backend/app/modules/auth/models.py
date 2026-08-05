# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for users, sessions, MFA state, and related auth records."""

from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column
from app.core.db import Base


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    password_hash: Mapped[str] = mapped_column(String(200), nullable=False)
    global_role: Mapped[str] = mapped_column(String(50), nullable=False, default="admin")
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    must_change_password: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=False,
    )
    invited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    invite_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    invite_token_hash: Mapped[str | None] = mapped_column(
        String(128),
        nullable=True,
        index=True,
    )
    invite_token_issued_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    invited_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    meta_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class UserNotificationPreference(Base):
    __tablename__ = "user_notification_preferences"

    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    include_view: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    include_search: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    include_publish: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    include_task: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    digest_mode: Mapped[str] = mapped_column(String(20), nullable=False, default="realtime")
    digest_hour: Mapped[int] = mapped_column(Integer, nullable=False, default=9)
    digest_minute: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UserNotificationPreferenceAudit(Base):
    __tablename__ = "user_notification_preference_audit"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    actor_user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    changed_keys_csv: Mapped[str] = mapped_column(String(400), nullable=False, default="")
    include_view: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    include_search: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    include_publish: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    include_task: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    digest_mode: Mapped[str] = mapped_column(String(20), nullable=False, default="realtime")
    digest_hour: Mapped[int] = mapped_column(Integer, nullable=False, default=9)
    digest_minute: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    changed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        index=True,
    )


class UserDashboardPreference(Base):
    __tablename__ = "user_dashboard_preferences"

    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    selected_space_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    widget_order_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    hidden_widgets_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    feed_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UserSession(Base):
    __tablename__ = "user_sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    refresh_token_hash: Mapped[str] = mapped_column(
        String(128),
        nullable=False,
        unique=True,
        index=True,
    )
    refresh_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoke_reason: Mapped[str | None] = mapped_column(String(120), nullable=True)
    ip_address: Mapped[str | None] = mapped_column(String(80), nullable=True)
    user_agent: Mapped[str | None] = mapped_column(String(500), nullable=True)
    mfa_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    last_rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class AuthSessionPolicy(Base):
    __tablename__ = "auth_session_policy"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    allow_remember_device: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    default_profile: Mapped[str] = mapped_column(String(40), nullable=False, default="this_browser")
    this_browser_days: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    remember_device_days: Mapped[int] = mapped_column(Integer, nullable=False, default=14)
    warning_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=15)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UserSecurityState(Base):
    __tablename__ = "user_security_state"

    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    failed_login_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_failed_login_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    lockout_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    mfa_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    mfa_secret: Mapped[str | None] = mapped_column(Text, nullable=True)
    mfa_enrolled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_mfa_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    session_invalid_before: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )
