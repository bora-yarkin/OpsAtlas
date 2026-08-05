# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models backing localization catalog, bundles, preferences, and translation queue state."""

from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class OrganizationLocalizationSetting(Base):
    """Stores organization-wide localization defaults and catalog versioning."""
    __tablename__ = "organization_localization_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    default_language_code: Mapped[str] = mapped_column(
        String(16),
        nullable=False,
        default="en",
    )
    fallback_order_json: Mapped[str] = mapped_column(
        Text,
        nullable=False,
        default='["en"]',
    )
    updated_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class LocalizationLanguage(Base):
    """Represents a language available in the organization's localization catalog."""
    __tablename__ = "localization_languages"

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    is_default: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_rtl: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    fallback_order_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    bundle_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class LocalizationBundle(Base):
    """Persists the translation bundle entries for a specific language code."""
    __tablename__ = "localization_bundles"

    language_code: Mapped[str] = mapped_column(
        String(16),
        ForeignKey("localization_languages.code", ondelete="CASCADE"),
        primary_key=True,
    )
    entries_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UserLocalizationPreference(Base):
    """Stores a user's language override relative to organization defaults."""
    __tablename__ = "user_localization_preferences"

    user_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    language_code: Mapped[str | None] = mapped_column(String(16), nullable=True)
    use_org_default: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class LocalizationTranslationSetting(Base):
    """Stores provider and queue settings for machine-assisted translation work."""
    __tablename__ = "localization_translation_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    translation_enabled: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
    )
    provider: Mapped[str] = mapped_column(String(32), nullable=False, default="openai")
    model: Mapped[str] = mapped_column(String(160), nullable=False, default="gpt-4.1-mini")
    api_base_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    api_key_encrypted: Mapped[str | None] = mapped_column(Text, nullable=True)
    auto_translate_on_write: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    auto_approve: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    auto_retranslate_on_bundle_change: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=False,
    )
    fallback_to_source: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    queue_max_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=4)
    queue_backoff_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=30)
    queue_batch_size: Mapped[int] = mapped_column(Integer, nullable=False, default=20)
    glossary_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    translation_prompt: Mapped[str | None] = mapped_column(Text, nullable=True)
    provider_options_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    updated_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class LocalizationTranslationSource(Base):
    """Captures the canonical source text for a translatable content field."""
    __tablename__ = "localization_translation_sources"
    __table_args__ = (
        UniqueConstraint(
            "content_kind",
            "content_id",
            "field_key",
            name="uq_localization_translation_source",
        ),
    )

    id: Mapped[str] = mapped_column(String(180), primary_key=True)
    content_kind: Mapped[str] = mapped_column(String(80), nullable=False, index=True)
    content_id: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    field_key: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    source_language_code: Mapped[str] = mapped_column(String(16), nullable=False, default="en")
    source_text: Mapped[str] = mapped_column(Text, nullable=False, default="")
    source_hash: Mapped[str] = mapped_column(String(64), nullable=False, default="")
    source_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    updated_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class LocalizationTranslationVariant(Base):
    """Stores a translated variant of a source field for one target language."""
    __tablename__ = "localization_translation_variants"
    __table_args__ = (
        UniqueConstraint(
            "content_kind",
            "content_id",
            "field_key",
            "language_code",
            name="uq_localization_translation_variant",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    source_id: Mapped[str] = mapped_column(
        String(180),
        ForeignKey("localization_translation_sources.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    content_kind: Mapped[str] = mapped_column(String(80), nullable=False, index=True)
    content_id: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    field_key: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    language_code: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    translated_text: Mapped[str] = mapped_column(Text, nullable=False, default="")
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="pending")
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    provider: Mapped[str | None] = mapped_column(String(32), nullable=True)
    model: Mapped[str | None] = mapped_column(String(160), nullable=True)
    source_language_code: Mapped[str | None] = mapped_column(String(16), nullable=True)
    source_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    translated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reviewed_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    locked: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
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


class LocalizationTranslationJob(Base):
    """Represents queued or completed machine translation work for a variant."""
    __tablename__ = "localization_translation_jobs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    source_id: Mapped[str] = mapped_column(
        String(180),
        ForeignKey("localization_translation_sources.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    content_kind: Mapped[str] = mapped_column(String(80), nullable=False, index=True)
    content_id: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    field_key: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    language_code: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    source_language_code: Mapped[str] = mapped_column(String(16), nullable=False, default="en")
    source_text: Mapped[str] = mapped_column(Text, nullable=False, default="")
    source_hash: Mapped[str] = mapped_column(String(64), nullable=False, default="")
    source_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    provider: Mapped[str] = mapped_column(String(32), nullable=False, default="openai")
    model: Mapped[str] = mapped_column(String(160), nullable=False, default="gpt-4.1-mini")
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="queued", index=True)
    idempotency_key: Mapped[str] = mapped_column(
        String(220),
        nullable=False,
        unique=True,
        index=True,
    )
    attempt_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=4)
    backoff_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=30)
    next_attempt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    triggered_by: Mapped[str] = mapped_column(String(50), nullable=False, default="auto_write")
    actor_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
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
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
