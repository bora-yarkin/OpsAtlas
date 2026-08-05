# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for localization runtime payloads, catalog admin, and translation tooling."""

from collections.abc import Mapping
from typing import Any

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.core.deps import get_db
from app.core.deps import not_found
from app.modules.auth.models import User
from app.modules.auth.deps import get_current_user, require_role

from . import service
from .schemas import (
    LocalizationBulkRetranslateIn,
    LocalizationBulkRetranslateOut,
    LocalizationCatalogOut,
    LocalizationCatalogUpdateIn,
    LocalizationExportOut,
    LocalizationHealthOut,
    LocalizationTranslationQueueProcessOut,
    LocalizationTranslationQueueStatusOut,
    LocalizationTranslationSettingsOut,
    LocalizationTranslationSettingsUpdateIn,
    LocalizationTranslationVariantListOut,
    LocalizationTranslationVariantOut,
    LocalizationTranslationVariantUpdateIn,
    LocalizationTranslateMissingIn,
    LocalizationTranslateMissingOut,
    LocalizationImportLanguageResultOut,
    LocalizationImportResultOut,
    LocalizationBundleImportIn,
    LocalizationRuntimeOut,
    LocalizationUserPreferenceOut,
    LocalizationUserPreferenceUpdateIn,
    LocalizationValidationIssueOut,
)

router = APIRouter(prefix="/localization", tags=["localization"])


def _issue_out(value: object) -> LocalizationValidationIssueOut:
    """Normalize raw validation issue objects into the public response schema."""
    if isinstance(value, service.ValidationIssue):
        return LocalizationValidationIssueOut(code=value.code, message=value.message)
    if isinstance(value, Mapping):
        return LocalizationValidationIssueOut(
            code=str(value.get("code", "invalid_issue")),
            message=str(value.get("message", "Unknown validation issue")),
        )
    return LocalizationValidationIssueOut(
        code="invalid_issue",
        message=str(value),
    )


def _import_language_out(value: object) -> LocalizationImportLanguageResultOut:
    """Normalize one per-language import result into the public response schema."""
    if isinstance(value, service.ImportLanguageResult):
        return LocalizationImportLanguageResultOut(
            code=value.code,
            entry_count=value.entry_count,
            bundle_version=value.bundle_version,
        )
    if isinstance(value, Mapping):
        return LocalizationImportLanguageResultOut(
            code=str(value.get("code", "")),
            entry_count=int(value.get("entry_count", 0)),
            bundle_version=int(value.get("bundle_version", 1)),
        )
    return LocalizationImportLanguageResultOut(
        code="",
        entry_count=0,
        bundle_version=1,
    )


def _import_result_out(raw: Mapping[str, Any]) -> LocalizationImportResultOut:
    """Normalize a service-level import result into the public response payload."""
    errors = [_issue_out(item) for item in raw.get("errors", [])]
    warnings = [_issue_out(item) for item in raw.get("warnings", [])]
    updated_languages = [
        _import_language_out(item)
        for item in raw.get("updated_languages", [])
    ]
    return LocalizationImportResultOut(
        applied=bool(raw.get("applied", False)),
        dry_run=bool(raw.get("dry_run", False)),
        errors=errors,
        warnings=warnings,
        updated_languages=updated_languages,
    )


@router.get("/runtime", response_model=LocalizationRuntimeOut)
def runtime_payload(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return the runtime localization payload for the authenticated user."""
    return service.read_runtime_payload(db, user_id=user.id)


@router.get("/preferences/me", response_model=LocalizationUserPreferenceOut)
def user_preference(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return the authenticated user's effective localization preference."""
    runtime = service.read_runtime_payload(db, user_id=user.id)
    preference = runtime.get("user_preference")
    if isinstance(preference, Mapping):
        return dict(preference)
    return {
        "language_code": None,
        "use_org_default": True,
        "effective_language_code": runtime.get("catalog", {}).get(
            "default_language_code",
            "en",
        ),
        "updated_at": None,
    }


@router.patch("/preferences/me", response_model=LocalizationUserPreferenceOut)
def update_user_preference(
    payload: LocalizationUserPreferenceUpdateIn,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Update the authenticated user's localization preference."""
    return service.update_user_preference(
        db,
        user_id=user.id,
        language_code=payload.language_code,
        use_org_default=payload.use_org_default,
        apply_language_code="language_code" in payload.model_fields_set,
        apply_use_org_default="use_org_default" in payload.model_fields_set,
    )


@router.get("/preferences/users/{user_id}", response_model=LocalizationUserPreferenceOut)
def user_preference_for_user(
    user_id: str,
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Return another user's effective localization preference for admin tooling."""
    user = db.get(User, user_id)
    if user is None:
        raise not_found("User not found")
    runtime = service.read_runtime_payload(db, user_id=user.id)
    preference = runtime.get("user_preference")
    if isinstance(preference, Mapping):
        return dict(preference)
    return {
        "language_code": None,
        "use_org_default": True,
        "effective_language_code": runtime.get("catalog", {}).get(
            "default_language_code",
            "en",
        ),
        "updated_at": None,
    }


@router.patch("/preferences/users/{user_id}", response_model=LocalizationUserPreferenceOut)
def update_user_preference_for_user(
    user_id: str,
    payload: LocalizationUserPreferenceUpdateIn,
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Allow an admin to update another user's localization preference."""
    user = db.get(User, user_id)
    if user is None:
        raise not_found("User not found")
    return service.update_user_preference(
        db,
        user_id=user.id,
        language_code=payload.language_code,
        use_org_default=payload.use_org_default,
        apply_language_code="language_code" in payload.model_fields_set,
        apply_use_org_default="use_org_default" in payload.model_fields_set,
    )


@router.get("/catalog", response_model=LocalizationCatalogOut)
def catalog(
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Return the admin-visible localization catalog."""
    return service.read_catalog(db)


@router.patch("/catalog", response_model=LocalizationCatalogOut)
def update_catalog(
    payload: LocalizationCatalogUpdateIn,
    actor: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Apply admin changes to catalog languages and fallback behavior."""
    languages_payload = None
    if payload.languages is not None:
        languages_payload = [
            language.model_dump(exclude_none=True)
            for language in payload.languages
        ]
    return service.update_catalog(
        db,
        default_language_code=payload.default_language_code,
        organization_fallback_order=payload.organization_fallback_order,
        languages=languages_payload,
        actor_user_id=actor.id,
    )


@router.get("/bundles/export", response_model=LocalizationExportOut)
def export_bundles(
    format_name: str = Query(default="arb", pattern="^(arb|icu)$"),
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Export stored localization bundles in ARB or ICU-compatible format."""
    return service.export_bundles(db, format_name=format_name)


@router.post("/bundles/import", response_model=LocalizationImportResultOut)
def import_bundles(
    payload: LocalizationBundleImportIn,
    actor: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Validate or import localization bundles provided by an admin client."""
    prepared: dict[str, dict[str, object]] = {}
    for code, entries in payload.bundles.items():
        if not isinstance(entries, Mapping):
            prepared[str(code)] = {}
            continue
        prepared[str(code)] = {
            str(key): value for key, value in entries.items()
        }
    raw = service.import_bundles(
        db,
        format_name=payload.format,
        bundles=prepared,
        dry_run=bool(payload.dry_run),
        actor_user_id=actor.id,
    )
    return _import_result_out(raw)


@router.get("/health", response_model=LocalizationHealthOut)
def health(
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Return bundle coverage and staleness diagnostics for admins."""
    return service.health_report(db)


@router.get("/ai-settings", response_model=LocalizationTranslationSettingsOut)
def translation_settings(
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Return translation provider and queue settings for admin tooling."""
    return service.read_translation_settings(db)


@router.patch("/ai-settings", response_model=LocalizationTranslationSettingsOut)
def update_translation_settings(
    payload: LocalizationTranslationSettingsUpdateIn,
    actor: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Persist translation provider and queue settings."""
    return service.update_translation_settings(
        db,
        changes=payload.model_dump(exclude_none=False),
        fields_set=set(payload.model_fields_set),
        actor_user_id=actor.id,
    )


@router.get("/translations/variants", response_model=LocalizationTranslationVariantListOut)
def list_translation_variants(
    content_kind: str | None = None,
    content_id: str | None = None,
    field_key: str | None = None,
    language_code: str | None = None,
    status: str | None = None,
    limit: int = Query(default=200, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """List translation variants with optional filters for admin review workflows."""
    return service.list_translation_variants(
        db,
        content_kind=content_kind,
        content_id=content_id,
        field_key=field_key,
        language_code=language_code,
        status=status,
        limit=limit,
        offset=offset,
    )


@router.patch(
    "/translations/variants/{variant_id}",
    response_model=LocalizationTranslationVariantOut,
)
def update_translation_variant(
    variant_id: str,
    payload: LocalizationTranslationVariantUpdateIn,
    actor: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Apply a reviewer action to one translation variant."""
    return service.update_translation_variant(
        db,
        variant_id=variant_id,
        action=payload.action,
        actor_user_id=actor.id,
        translated_text=payload.translated_text,
        note=payload.note,
    )


@router.post("/translations/retranslate", response_model=LocalizationBulkRetranslateOut)
def bulk_retranslate(
    payload: LocalizationBulkRetranslateIn,
    actor: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Force a retranslation pass for variants matching the provided filters."""
    return service.bulk_retranslate(
        db,
        actor_user_id=actor.id,
        content_kind=payload.content_kind,
        content_id=payload.content_id,
        language_codes=payload.language_codes,
        include_locked=payload.include_locked,
        reason=payload.reason,
    )


@router.post(
    "/translations/translate-missing",
    response_model=LocalizationTranslateMissingOut,
)
def translate_missing(
    payload: LocalizationTranslateMissingIn,
    actor: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Queue translations only for missing or stale variant coverage."""
    return service.translate_missing_content(
        db,
        actor_user_id=actor.id,
        content_kind=payload.content_kind,
        content_id=payload.content_id,
        language_codes=payload.language_codes,
        include_locked=payload.include_locked,
    )


@router.get("/translations/queue", response_model=LocalizationTranslationQueueStatusOut)
def translation_queue_status(
    limit: int = Query(default=40, ge=1, le=200),
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Return queue counters and recent jobs for translation operations."""
    return service.translation_queue_status(db, limit=limit)


@router.post(
    "/translations/queue/process",
    response_model=LocalizationTranslationQueueProcessOut,
)
def process_translation_queue(
    limit: int = Query(default=50, ge=1, le=250),
    _: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    """Process due translation jobs in a synchronous admin-triggered batch."""
    return service.process_due_translation_jobs(db, batch_size=limit)
