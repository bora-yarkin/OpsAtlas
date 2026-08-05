# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for uploaded media assets and related metadata."""

from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class MediaAsset(Base):
    __tablename__ = "media_assets"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    space_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("spaces.id"), nullable=True, index=True)
    usage: Mapped[str] = mapped_column(String(100), nullable=False, default="general", index=True)
    original_filename: Mapped[str] = mapped_column(String(512), nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(200), nullable=True)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    storage_key: Mapped[str] = mapped_column(String(500), nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class MediaAssetMeta(Base):
    __tablename__ = "media_asset_meta"

    asset_id: Mapped[str] = mapped_column(String(36), ForeignKey("media_assets.id"), primary_key=True)
    access_mode: Mapped[str] = mapped_column(String(20), nullable=False, default="private", index=True)
    folder_path: Mapped[str | None] = mapped_column(String(220), nullable=True, index=True)
    tags_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    retention_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class MediaAttachment(Base):
    __tablename__ = "media_attachments"
    __table_args__ = (
        UniqueConstraint("asset_id", "entity_type", "entity_id", name="uq_media_attachment_target"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    asset_id: Mapped[str] = mapped_column(String(36), ForeignKey("media_assets.id"), nullable=False, index=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), nullable=False, index=True)
    entity_type: Mapped[str] = mapped_column(String(30), nullable=False, index=True)
    entity_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    attached_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class MediaUsage(Base):
    __tablename__ = "media_usage"
    __table_args__ = (
        UniqueConstraint("asset_id", "entity_type", "entity_id", "field_name", name="uq_media_usage_ref"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    asset_id: Mapped[str] = mapped_column(String(36), ForeignKey("media_assets.id"), nullable=False, index=True)
    space_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("spaces.id"), nullable=True, index=True)
    entity_type: Mapped[str] = mapped_column(String(30), nullable=False, index=True)
    entity_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    field_name: Mapped[str] = mapped_column(String(40), nullable=False, default="content", index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
