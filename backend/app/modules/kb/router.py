# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for knowledge-base documents, folders, reviews, and comments."""

from collections.abc import Mapping

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.deps import get_db
from app.core.deps import not_found
from app.modules.auth.models import User
from app.modules.auth.deps import get_current_user
from app.modules.localization import service as localization_service
from app.modules.spaces import service as spaces_service

from . import repo, service
from .schemas import (
    DocCommentIn,
    DocMentionBulkReadIn,
    DocMentionBulkReadOut,
    DocMentionNotificationOut,
    DocCommentOut,
    DocCommentUpdateIn,
    DocCreateIn,
    DocDiffOut,
    DocMetaUpdateIn,
    DocOut,
    DocPublishOut,
    DocReviewSummaryOut,
    DocReviewerSuggestionOut,
    KbSearchSuggestionOut,
    KbSpacePolicyIn,
    KbSpacePolicyOut,
    DocTrashPurgeOut,
    DocTrashOut,
    DocUpdateIn,
    DocVersionOut,
    FolderCreateIn,
    FolderOut,
    FolderUpdateIn,
    TagListOut,
)

router = APIRouter(prefix="/kb", tags=["kb"])


def _localize_doc_out(doc: DocOut, fields: Mapping[str, str] | None) -> DocOut:
    if not fields:
        return doc
    updates: dict[str, str] = {}
    title = fields.get("title")
    if title is not None and title.strip():
        updates["title"] = title
    content_md = fields.get("content")
    if content_md is not None and content_md.strip():
        updates["content_md"] = content_md
    return doc.model_copy(update=updates) if updates else doc


def _localize_doc_comment_out(
    comment: DocCommentOut,
    fields: Mapping[str, str] | None,
) -> DocCommentOut:
    if not fields:
        return comment
    body = fields.get("body")
    if body is None or not body.strip():
        return comment
    return comment.model_copy(update={"body_md": body})


@router.get("/spaces/{space_id}/folders", response_model=list[FolderOut])
def list_folders(
    space_id: str,
    parent_id: str | None = None,
    flat: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return KB folders as either a tree slice or a flat navigation list."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = repo.list_all_folders(db, space_id) if flat else repo.list_folders(db, space_id, parent_id)
    return [FolderOut(id=f.id, space_id=f.space_id, parent_id=f.parent_id, name=f.name, path=f.path) for f in rows]


@router.post("/folders", response_model=FolderOut)
def create_folder(
    payload: FolderCreateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a new knowledge-base folder inside the target space."""
    spaces_service.require_space_role(db, payload.space_id, user.id, {"admin", "moderator", "member"})
    folder = service.create_folder(db, payload.space_id, payload.parent_id, payload.name)
    return FolderOut(
        id=folder.id,
        space_id=folder.space_id,
        parent_id=folder.parent_id,
        name=folder.name,
        path=folder.path,
    )


@router.put("/folders/{folder_id}", response_model=FolderOut)
def update_folder(
    folder_id: str,
    payload: FolderUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Rename or move a shared workspace folder inside the same space."""
    current = repo.get_folder(db, folder_id)
    if not current:
        raise not_found("Folder not found")
    spaces_service.require_space_role(
        db,
        current.space_id,
        user.id,
        {"admin", "moderator", "member"},
    )
    folder = service.update_folder(
        db,
        folder_id,
        name=payload.name,
        parent_id=payload.parent_id,
    )
    return FolderOut(
        id=folder.id,
        space_id=folder.space_id,
        parent_id=folder.parent_id,
        name=folder.name,
        path=folder.path,
    )


@router.get("/spaces/{space_id}/docs", response_model=list[DocOut])
def list_docs(
    space_id: str,
    folder_id: str | None = None,
    all_folders: bool = False,
    published_only: bool = True,
    q: str | None = None,
    tag: str | None = None,
    include_deleted: bool = False,
    trash_only: bool = False,
    only_stale: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """List KB docs with folder, query, tag, trash, and stale-review filters."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    if include_deleted or trash_only or only_stale:
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
        published_only = False
    docs = service.list_docs_filtered(
        db,
        space_id=space_id,
        folder_id=folder_id,
        published_only=published_only,
        all_folders=all_folders,
        query=q,
        tag=tag,
        include_deleted=include_deleted,
        trash_only=trash_only,
        only_stale=only_stale,
    )
    localized_by_doc_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="doc",
        content_ids=[doc.id for doc in docs],
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return [
        _localize_doc_out(doc, localized_by_doc_id.get(doc.id, {}))
        for doc in docs
    ]


@router.get("/spaces/{space_id}/search", response_model=list[DocOut])
def search_docs(
    space_id: str,
    q: str,
    limit: int = 25,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Run ranked KB search for a space and return localized doc summaries."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    docs = service.search_docs(db, user_id=user.id, space_id=space_id, query=q, limit=limit)
    localized_by_doc_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="doc",
        content_ids=[doc.id for doc in docs],
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return [
        _localize_doc_out(doc, localized_by_doc_id.get(doc.id, {}))
        for doc in docs
    ]


@router.get("/spaces/{space_id}/search-suggestions", response_model=list[KbSearchSuggestionOut])
def search_suggestions(
    space_id: str,
    q: str = "",
    limit: int = 8,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return autocomplete suggestions derived from KB search behavior and content."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.search_suggestions(
        db,
        user_id=user.id,
        space_id=space_id,
        query=q,
        limit=limit,
    )


@router.get("/spaces/{space_id}/tags", response_model=TagListOut)
def list_tags(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return TagListOut(tags=service.list_tags(db, space_id))


@router.get("/spaces/{space_id}/review-summary", response_model=DocReviewSummaryOut)
def review_summary(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return document-review backlog counts for reviewer-facing dashboards."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    return service.get_review_summary(db, space_id=space_id)


@router.get("/spaces/{space_id}/policy", response_model=KbSpacePolicyOut)
def get_space_policy(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return KB policy settings such as retention, synonyms, and relevance data."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    return service.get_space_policy(db, space_id=space_id)


@router.put("/spaces/{space_id}/policy", response_model=KbSpacePolicyOut)
def set_space_policy(
    space_id: str,
    payload: KbSpacePolicyIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update KB policy knobs that shape review, lexicon, and search behavior."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator"})
    return service.update_space_policy(
        db,
        space_id=space_id,
        trash_retention_days=payload.trash_retention_days,
        synonyms=payload.synonyms,
        lexicon=payload.lexicon,
        localized_synonyms=payload.localized_synonyms,
        localized_lexicon=payload.localized_lexicon,
        relevance_benchmarks=payload.relevance_benchmarks,
    )


@router.get("/spaces/{space_id}/reviewer-suggestions", response_model=list[DocReviewerSuggestionOut])
def reviewer_suggestions(
    space_id: str,
    limit: int = 5,
    doc_id: str | None = None,
    tag: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    tags = [item.strip() for item in (tag or "").split(",") if item.strip()]
    return service.reviewer_suggestions(db, space_id=space_id, doc_id=doc_id, tags=tags, limit=limit)


@router.get("/spaces/{space_id}/mentions", response_model=list[DocMentionNotificationOut])
def mention_inbox(
    space_id: str,
    unread_only: bool = False,
    doc_id: str | None = None,
    max_age_days: int | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.list_mention_inbox(
        db,
        user_id=user.id,
        space_id=space_id,
        doc_id=doc_id,
        unread_only=unread_only,
        max_age_days=max_age_days,
    )


@router.post("/mentions/read", response_model=DocMentionBulkReadOut)
def bulk_mark_mentions_read(
    payload: DocMentionBulkReadIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return DocMentionBulkReadOut(
        marked_count=service.bulk_mark_mentions_read(
            db,
            user_id=user.id,
            notification_ids=payload.notification_ids,
            doc_id=payload.doc_id,
            unread_only=payload.unread_only,
            max_age_days=payload.max_age_days,
        )
    )


@router.get("/spaces/{space_id}/docs/{slug}", response_model=DocOut)
def get_doc(space_id: str, slug: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    doc = repo.get_doc_by_slug(db, space_id, slug)
    if not doc:
        raise not_found("Doc not found")
    detail = service.get_doc_detail(db, doc_id=doc.id)
    if detail.deleted_at is not None:
        raise not_found("Doc not found")
    if detail.status != "published":
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc",
        content_id=detail.id,
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return _localize_doc_out(detail, localized)


@router.get("/docs/{doc_id}/detail", response_model=DocOut)
def get_doc_detail(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return full doc detail for editing, review, diff, and comment workflows."""
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, doc.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    detail = service.get_doc_detail(db, doc_id=doc_id)
    if detail.deleted_at is not None:
        spaces_service.require_space_role(db, doc.space_id, user.id, {"admin", "moderator", "member"})
    elif detail.status != "published":
        spaces_service.require_space_role(db, doc.space_id, user.id, {"admin", "moderator", "member"})
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc",
        content_id=detail.id,
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return _localize_doc_out(detail, localized)


@router.post("/docs", response_model=DocOut)
def create_doc(payload: DocCreateIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Create a new KB document draft inside a space or folder."""
    spaces_service.require_space_role(db, payload.space_id, user.id, {"admin", "moderator", "member"})
    doc = service.create_doc(
        db,
        user.id,
        payload.space_id,
        payload.folder_id,
        payload.title,
        payload.slug,
        payload.content_md,
        tags=payload.tags,
        review_due_at=payload.review_due_at,
        reviewer_user_id=payload.reviewer_user_id,
        review_reminder_days=payload.review_reminder_days,
    )
    detail = service.get_doc_detail(db, doc_id=doc.id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc",
        content_id=detail.id,
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return _localize_doc_out(detail, localized)


@router.put("/docs/{doc_id}", response_model=DocOut)
def update_doc(
    doc_id: str,
    payload: DocUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update the main KB document body and publishing-related workflow fields."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    doc = service.update_doc(
        db,
        user.id,
        doc_id,
        payload.title,
        payload.slug,
        payload.content_md,
        payload.folder_id,
        tags=payload.tags,
        review_due_at=payload.review_due_at,
        reviewer_user_id=payload.reviewer_user_id,
        review_reminder_days=payload.review_reminder_days,
        base_updated_at=payload.base_updated_at,
    )
    detail = service.get_doc_detail(db, doc_id=doc.id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc",
        content_id=detail.id,
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return _localize_doc_out(detail, localized)


@router.patch("/docs/{doc_id}/meta", response_model=DocOut)
def patch_doc_meta(
    doc_id: str,
    payload: DocMetaUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Apply targeted metadata edits without replacing the entire document payload."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    detail = service.update_doc_meta(
        db,
        user_id=user.id,
        doc_id=doc_id,
        tags=payload.tags,
        review_due_at=payload.review_due_at,
        reviewer_user_id=payload.reviewer_user_id,
        review_reminder_days=payload.review_reminder_days,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc",
        content_id=detail.id,
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return _localize_doc_out(detail, localized)


@router.get("/spaces/{space_id}/review-reminders", response_model=list[DocOut])
def review_reminders(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    docs = service.list_review_reminders(db, space_id=space_id, reviewer_user_id=user.id)
    localized_by_doc_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="doc",
        content_ids=[doc.id for doc in docs],
        field_keys=["title", "content"],
        user_id=user.id,
    )
    return [
        _localize_doc_out(doc, localized_by_doc_id.get(doc.id, {}))
        for doc in docs
    ]


@router.post("/docs/{doc_id}/trash", response_model=DocTrashOut)
def trash_doc(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    meta = service.trash_doc(db, user_id=user.id, doc_id=doc_id)
    return DocTrashOut(id=doc_id, deleted_at=meta.deleted_at, deleted_by=meta.deleted_by)


@router.post("/docs/{doc_id}/restore", response_model=DocTrashOut)
def restore_doc(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    meta = service.restore_doc(db, user_id=user.id, doc_id=doc_id)
    return DocTrashOut(id=doc_id, deleted_at=meta.deleted_at, deleted_by=meta.deleted_by)


@router.post("/spaces/{space_id}/trash/purge", response_model=DocTrashPurgeOut)
def purge_trash(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    deleted_count = service.purge_trashed_docs(db, space_id=space_id, only_expired=False)
    return DocTrashPurgeOut(deleted_count=deleted_count, retention_days=service.TRASH_RETENTION_DAYS)


@router.post("/docs/{doc_id}/publish", response_model=DocPublishOut)
def publish(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Publish a KB document so viewer-role users can consume it."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    doc = service.publish_doc(db, doc_id)
    return DocPublishOut(id=doc.id, status=doc.status)


@router.post("/docs/{doc_id}/unpublish", response_model=DocPublishOut)
def unpublish(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    doc = service.unpublish_doc(db, doc_id)
    return DocPublishOut(id=doc.id, status=doc.status)


@router.get("/docs/{doc_id}/versions", response_model=list[DocVersionOut])
def versions(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return document version history for comparison and review tooling."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = repo.list_versions(db, doc_id)
    return [
        DocVersionOut(
            id=row.id,
            doc_id=row.doc_id,
            title=row.title,
            content_md=row.content_md,
            created_by=row.created_by,
            created_at=row.created_at,
        )
        for row in rows
    ]


@router.get("/docs/{doc_id}/diff", response_model=DocDiffOut)
def diff_doc(
    doc_id: str,
    from_version_id: str | None = None,
    to_version_id: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return a rendered diff between two KB document versions."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.build_diff(
        db,
        doc_id=doc_id,
        from_version_id=from_version_id,
        to_version_id=to_version_id,
    )


@router.get("/docs/{doc_id}/comments", response_model=list[DocCommentOut])
def list_doc_comments(doc_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """List threaded comments attached to a KB document."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    comments = service.list_comments(db, doc_id=doc_id)
    localized_by_comment_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="doc_comment",
        content_ids=[comment.id for comment in comments],
        field_keys=["body"],
        user_id=user.id,
    )
    return [
        _localize_doc_comment_out(
            comment,
            localized_by_comment_id.get(comment.id, {}),
        )
        for comment in comments
    ]


@router.post("/docs/{doc_id}/comments", response_model=DocCommentOut)
def create_doc_comment(
    doc_id: str,
    payload: DocCommentIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a review or discussion comment on a KB document."""
    current = repo.get_doc(db, doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    comment = service.create_comment(db, user_id=user.id, doc_id=doc_id, body_md=payload.body_md)
    detail = service.get_comment_detail(db, comment_id=comment.id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc_comment",
        content_id=detail.id,
        field_keys=["body"],
        user_id=user.id,
    )
    return _localize_doc_comment_out(detail, localized)


@router.put("/comments/{comment_id}", response_model=DocCommentOut)
def update_doc_comment(
    comment_id: str,
    payload: DocCommentUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    comment = repo.get_doc_comment(db, comment_id)
    if not comment:
        raise not_found("Comment not found")
    current = repo.get_doc(db, comment.doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    updated = service.update_comment(db, user_id=user.id, comment_id=comment_id, body_md=payload.body_md)
    detail = service.get_comment_detail(db, comment_id=updated.id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="doc_comment",
        content_id=detail.id,
        field_keys=["body"],
        user_id=user.id,
    )
    return _localize_doc_comment_out(detail, localized)


@router.delete("/comments/{comment_id}")
def delete_doc_comment(comment_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    comment = repo.get_doc_comment(db, comment_id)
    if not comment:
        raise not_found("Comment not found")
    current = repo.get_doc(db, comment.doc_id)
    if not current:
        raise not_found("Doc not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    service.delete_comment(db, user_id=user.id, comment_id=comment_id)
    return {"ok": True}


@router.post("/mentions/{notification_id}/read", response_model=DocMentionNotificationOut)
def read_mention_notification(
    notification_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    return service.mark_mention_read(db, notification_id=notification_id, user_id=user.id)
