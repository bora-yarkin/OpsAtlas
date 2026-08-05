# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Focused persistence helpers for knowledge-base queries and projections."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import (
    Doc,
    DocComment,
    DocMentionNotification,
    DocMeta,
    DocReviewAssignment,
    DocVersion,
    Folder,
    KbSpacePolicy,
)


def _normalize_optional_id(value: str | None) -> str | None:
    normalized = (value or "").strip()
    return normalized or None


def get_folder(db: Session, folder_id: str) -> Folder | None:
    return db.get(Folder, folder_id)


def list_folders(db: Session, space_id: str, parent_id: str | None) -> list[Folder]:
    parent_id = _normalize_optional_id(parent_id)
    q = select(Folder).where(Folder.space_id == space_id)
    if parent_id is None:
        q = q.where(Folder.parent_id.is_(None))
    else:
        q = q.where(Folder.parent_id == parent_id)
    return list(db.execute(q.order_by(Folder.name)).scalars().all())


def list_all_folders(db: Session, space_id: str) -> list[Folder]:
    q = select(Folder).where(Folder.space_id == space_id).order_by(Folder.path.asc(), Folder.name.asc())
    return list(db.execute(q).scalars().all())


def list_docs(db: Session, space_id: str, folder_id: str | None, published_only: bool) -> list[Doc]:
    folder_id = _normalize_optional_id(folder_id)
    q = select(Doc).where(Doc.space_id == space_id)
    if folder_id is None:
        q = q.where(Doc.folder_id.is_(None))
    else:
        q = q.where(Doc.folder_id == folder_id)
    if published_only:
        q = q.where(Doc.status == "published")
    return list(db.execute(q.order_by(Doc.updated_at.desc())).scalars().all())


def list_all_docs(db: Session, space_id: str) -> list[Doc]:
    q = select(Doc).where(Doc.space_id == space_id).order_by(Doc.updated_at.desc(), Doc.title.asc())
    return list(db.execute(q).scalars().all())


def get_doc_by_slug(db: Session, space_id: str, slug: str) -> Doc | None:
    return db.scalar(select(Doc).where(Doc.space_id == space_id, Doc.slug == slug))


def get_doc(db: Session, doc_id: str) -> Doc | None:
    return db.get(Doc, doc_id)


def list_versions(db: Session, doc_id: str) -> list[DocVersion]:
    q = select(DocVersion).where(DocVersion.doc_id == doc_id).order_by(DocVersion.created_at.desc())
    return list(db.execute(q).scalars().all())


def get_version(db: Session, version_id: str) -> DocVersion | None:
    return db.get(DocVersion, version_id)


def get_doc_meta(db: Session, doc_id: str) -> DocMeta | None:
    return db.get(DocMeta, doc_id)


def get_review_assignment(db: Session, doc_id: str) -> DocReviewAssignment | None:
    return db.get(DocReviewAssignment, doc_id)


def get_doc_comment(db: Session, comment_id: str) -> DocComment | None:
    return db.get(DocComment, comment_id)


def list_comments(db: Session, doc_id: str) -> list[DocComment]:
    q = select(DocComment).where(DocComment.doc_id == doc_id).order_by(DocComment.created_at.asc())
    return list(db.execute(q).scalars().all())


def get_mention_notification(db: Session, notification_id: str) -> DocMentionNotification | None:
    return db.get(DocMentionNotification, notification_id)


def list_mention_notifications(db: Session, user_id: str, *, unread_only: bool = False) -> list[DocMentionNotification]:
    q = select(DocMentionNotification).where(DocMentionNotification.user_id == user_id)
    if unread_only:
        q = q.where(DocMentionNotification.read_at.is_(None))
    q = q.order_by(DocMentionNotification.created_at.desc())
    return list(db.execute(q).scalars().all())


def get_space_policy(db: Session, space_id: str) -> KbSpacePolicy | None:
    return db.get(KbSpacePolicy, space_id)
