# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for organization graph, branding, and admin audit records."""

from datetime import datetime

from sqlalchemy import Boolean, DateTime, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class CustomRole(Base):
    __tablename__ = "custom_roles"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    role_key: Mapped[str] = mapped_column(String(100), unique=True, index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(String(600), nullable=True)
    effective_level: Mapped[str] = mapped_column(String(50), nullable=False, default="member")
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    meta_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class OrganizationItem(Base):
    __tablename__ = "organization_items"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)
    kind: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    entity_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    slug: Mapped[str | None] = mapped_column(String(320), nullable=True, index=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    meta_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class BrandingSettings(Base):
    __tablename__ = "branding_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    company_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    application_title: Mapped[str | None] = mapped_column(String(200), nullable=True)
    application_short_name: Mapped[str | None] = mapped_column(String(80), nullable=True)
    web_description: Mapped[str | None] = mapped_column(String(600), nullable=True)
    apple_web_app_title: Mapped[str | None] = mapped_column(String(80), nullable=True)
    logo_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    light_logo_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    dark_logo_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    favicon_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    login_background_url: Mapped[str | None] = mapped_column(
        String(1000),
        nullable=True,
    )
    light_seed_hex: Mapped[str | None] = mapped_column(String(9), nullable=True)
    dark_accent_hex: Mapped[str | None] = mapped_column(String(9), nullable=True)
    dark_bg_hex: Mapped[str | None] = mapped_column(String(9), nullable=True)
    browser_theme_hex: Mapped[str | None] = mapped_column(String(9), nullable=True)
    install_background_hex: Mapped[str | None] = mapped_column(String(9), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class BrandingDraft(Base):
    __tablename__ = "branding_drafts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    snapshot_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class BrandingRevision(Base):
    __tablename__ = "branding_revisions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    revision_number: Mapped[int] = mapped_column(Integer, nullable=False, index=True, unique=True)
    source_kind: Mapped[str] = mapped_column(String(30), nullable=False, default="publish")
    source_revision_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    summary: Mapped[str | None] = mapped_column(String(300), nullable=True)
    snapshot_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    published_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    published_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class OrganizationUnit(Base):
    __tablename__ = "organization_units"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    slug: Mapped[str] = mapped_column(String(200), unique=True, index=True, nullable=False)
    unit_type: Mapped[str] = mapped_column(String(50), nullable=False, default="team", index=True)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    meta_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class OrganizationItemLink(Base):
    __tablename__ = "organization_item_links"
    __table_args__ = (
        UniqueConstraint(
            "parent_kind",
            "parent_id",
            "child_kind",
            "child_id",
            name="uq_organization_item_link",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    parent_kind: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    parent_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    child_kind: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    child_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    grant_role: Mapped[str] = mapped_column(String(50), nullable=False, default="viewer")
    inherit_to_descendants: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class OrganizationAuditEvent(Base):
    __tablename__ = "organization_audit_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    scope_kind: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    action: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    item_kind: Mapped[str | None] = mapped_column(String(50), nullable=True, index=True)
    item_id: Mapped[str | None] = mapped_column(String(120), nullable=True, index=True)
    link_parent_kind: Mapped[str | None] = mapped_column(String(50), nullable=True, index=True)
    link_parent_id: Mapped[str | None] = mapped_column(String(120), nullable=True, index=True)
    link_child_kind: Mapped[str | None] = mapped_column(String(50), nullable=True, index=True)
    link_child_id: Mapped[str | None] = mapped_column(String(120), nullable=True, index=True)
    actor_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    summary: Mapped[str | None] = mapped_column(String(400), nullable=True)
    before_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    after_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        index=True,
    )
