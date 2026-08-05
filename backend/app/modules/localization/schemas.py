# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for localization catalog, runtime, and translation management APIs."""

from datetime import datetime

from pydantic import BaseModel, Field


class LocalizationLanguageCatalogOut(BaseModel):
    """Describes one language entry in the admin-visible localization catalog."""
    code: str
    name: str
    enabled: bool
    is_default: bool
    is_rtl: bool
    fallback_order: list[str] = Field(default_factory=list)
    bundle_version: int
    updated_at: datetime | None = None


class LocalizationCatalogOut(BaseModel):
    """Returns the organization localization catalog and supported languages."""
    default_language_code: str
    organization_fallback_order: list[str] = Field(default_factory=list)
    version: int
    languages: list[LocalizationLanguageCatalogOut] = Field(default_factory=list)


class LocalizationUserPreferenceOut(BaseModel):
    """Represents a persisted or effective language preference for one user."""
    language_code: str | None = None
    use_org_default: bool = True
    effective_language_code: str
    updated_at: datetime | None = None


class LocalizationRuntimeOut(BaseModel):
    """Runtime localization payload used by signed-in clients to hydrate UI strings."""
    catalog: LocalizationCatalogOut
    user_preference: LocalizationUserPreferenceOut
    bundles: dict[str, dict[str, str]] = Field(default_factory=dict)
    generated_at: datetime


class LocalizationUserPreferenceUpdateIn(BaseModel):
    """Patch payload for updating a user's localization preference."""
    language_code: str | None = Field(default=None, min_length=2, max_length=16)
    use_org_default: bool | None = None


class LocalizationLanguageCatalogUpdateIn(BaseModel):
    """Patch payload for creating or updating one catalog language entry."""
    code: str = Field(min_length=2, max_length=16)
    name: str | None = Field(default=None, min_length=1, max_length=120)
    enabled: bool | None = None
    is_default: bool | None = None
    is_rtl: bool | None = None
    fallback_order: list[str] | None = None


class LocalizationCatalogUpdateIn(BaseModel):
    """Patch payload for updating organization-wide localization catalog settings."""
    default_language_code: str | None = Field(default=None, min_length=2, max_length=16)
    organization_fallback_order: list[str] | None = None
    languages: list[LocalizationLanguageCatalogUpdateIn] | None = None


class LocalizationValidationIssueOut(BaseModel):
    """Machine-readable validation issue returned by import and audit workflows."""
    code: str
    message: str


class LocalizationExportOut(BaseModel):
    """Response payload for exporting localization bundles."""
    format: str
    generated_at: datetime
    catalog: LocalizationCatalogOut
    bundles: dict[str, dict[str, str]] = Field(default_factory=dict)


class LocalizationBundleImportIn(BaseModel):
    """Request payload for validating or importing localization bundles."""
    format: str = Field(pattern="^(arb|icu)$")
    bundles: dict[str, dict[str, object]] = Field(default_factory=dict)
    dry_run: bool = False


class LocalizationImportLanguageResultOut(BaseModel):
    """Describes how one language bundle changed during an import operation."""
    code: str
    entry_count: int
    bundle_version: int


class LocalizationImportResultOut(BaseModel):
    """Summarizes the result of a bundle import or dry-run validation pass."""
    applied: bool
    dry_run: bool
    errors: list[LocalizationValidationIssueOut] = Field(default_factory=list)
    warnings: list[LocalizationValidationIssueOut] = Field(default_factory=list)
    updated_languages: list[LocalizationImportLanguageResultOut] = Field(default_factory=list)


class LocalizationLanguageHealthOut(BaseModel):
    """Coverage and freshness summary for one catalog language."""
    code: str
    enabled: bool
    coverage_pct: float
    key_count: int
    missing_key_count: int
    missing_keys_sample: list[str] = Field(default_factory=list)
    bundle_version: int
    stale_bundle: bool


class LocalizationHealthOut(BaseModel):
    """Health overview for the localization catalog and stored bundles."""
    reference_key_count: int
    default_language_code: str
    stale_bundle_versions: list[str] = Field(default_factory=list)
    languages: list[LocalizationLanguageHealthOut] = Field(default_factory=list)


class LocalizationTranslationSettingsOut(BaseModel):
    """Admin-visible translation provider and queue configuration."""
    translation_enabled: bool = True
    provider: str
    model: str
    api_base_url: str | None = None
    resolved_api_base_url: str | None = None
    has_api_key: bool = False
    provider_defaults: dict[str, dict[str, object]] = Field(default_factory=dict)
    auto_translate_on_write: bool = True
    auto_approve: bool = False
    auto_retranslate_on_bundle_change: bool = False
    fallback_to_source: bool = True
    queue_max_attempts: int = 4
    queue_backoff_seconds: int = 30
    queue_batch_size: int = 20
    glossary: dict[str, str] = Field(default_factory=dict)
    translation_prompt: str | None = None
    provider_options: dict[str, object] = Field(default_factory=dict)
    updated_at: datetime | None = None


class LocalizationTranslationSettingsUpdateIn(BaseModel):
    """Patch payload for changing translation provider and queue settings."""
    translation_enabled: bool | None = None
    provider: str | None = Field(default=None, min_length=2, max_length=32)
    model: str | None = Field(default=None, min_length=1, max_length=160)
    api_base_url: str | None = Field(default=None, max_length=1000)
    api_key: str | None = Field(default=None, max_length=4000)
    clear_api_key: bool | None = None
    auto_translate_on_write: bool | None = None
    auto_approve: bool | None = None
    auto_retranslate_on_bundle_change: bool | None = None
    fallback_to_source: bool | None = None
    queue_max_attempts: int | None = Field(default=None, ge=1, le=10)
    queue_backoff_seconds: int | None = Field(default=None, ge=1, le=3600)
    queue_batch_size: int | None = Field(default=None, ge=1, le=250)
    glossary: dict[str, str] | None = None
    translation_prompt: str | None = Field(default=None, max_length=4000)
    provider_options: dict[str, object] | None = None


class LocalizationTranslationVariantOut(BaseModel):
    """One translated variant enriched with source and review metadata."""
    id: str
    content_kind: str
    content_id: str
    field_key: str
    language_code: str
    source_language_code: str | None = None
    source_version: int = 1
    source_text: str
    translated_text: str
    status: str
    confidence: float | None = None
    provider: str | None = None
    model: str | None = None
    locked: bool = False
    last_error: str | None = None
    translated_at: datetime | None = None
    reviewed_by_user_id: str | None = None
    reviewed_at: datetime | None = None
    updated_at: datetime | None = None


class LocalizationTranslationVariantUpdateIn(BaseModel):
    """Reviewer action payload for a translation variant."""
    action: str = Field(pattern="^(approve|edit|lock|unlock|retranslate)$")
    translated_text: str | None = None
    note: str | None = Field(default=None, max_length=1000)


class LocalizationTranslationVariantListOut(BaseModel):
    """Paged list of translation variants."""
    items: list[LocalizationTranslationVariantOut] = Field(default_factory=list)
    total: int = 0


class LocalizationBulkRetranslateIn(BaseModel):
    """Request payload for force-requeueing translation work."""
    content_kind: str | None = Field(default=None, min_length=2, max_length=80)
    content_id: str | None = Field(default=None, min_length=1, max_length=120)
    language_codes: list[str] | None = None
    include_locked: bool = False
    reason: str = Field(default="manual_bulk", min_length=3, max_length=80)


class LocalizationBulkRetranslateOut(BaseModel):
    """Summary of jobs queued by a bulk retranslation request."""
    queued_jobs: int = 0
    target_variants: int = 0


class LocalizationTranslateMissingIn(BaseModel):
    """Request payload for filling missing or stale translation coverage."""
    content_kind: str | None = Field(default=None, min_length=2, max_length=80)
    content_id: str | None = Field(default=None, min_length=1, max_length=120)
    language_codes: list[str] | None = None
    include_locked: bool = False


class LocalizationTranslateMissingOut(BaseModel):
    """Summary of jobs queued while backfilling missing translations."""
    queued_jobs: int = 0
    target_variants: int = 0


class LocalizationTranslationQueueJobOut(BaseModel):
    """Public view of one translation queue job."""
    id: str
    content_kind: str
    content_id: str
    field_key: str
    language_code: str
    status: str
    attempt_count: int
    max_attempts: int
    next_attempt_at: datetime | None = None
    last_error: str | None = None
    triggered_by: str
    created_at: datetime | None = None
    updated_at: datetime | None = None


class LocalizationTranslationQueueStatusOut(BaseModel):
    """Operational summary for the translation queue."""
    translation_enabled: bool = True
    queued: int
    processing: int
    retry: int
    failed: int
    done: int
    due_now: int
    recent_jobs: list[LocalizationTranslationQueueJobOut] = Field(default_factory=list)


class LocalizationTranslationQueueProcessOut(BaseModel):
    """Summary returned after processing due translation jobs."""
    processed: int
    succeeded: int
    retried: int
    failed: int
    fallback_applied: int
