# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for knowledge-base documents, folders, reviews, and comments."""

from datetime import datetime

from sqlalchemy import String, DateTime, Float, func, ForeignKey, Text, Index
from sqlalchemy.orm import Mapped, mapped_column
from app.core.db import Base


class Folder(Base):
    __tablename__ = "folders"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    parent_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("folders.id"), nullable=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    path: Mapped[str] = mapped_column(String(800), index=True, nullable=False)

class Doc(Base):
    __tablename__ = "docs"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    folder_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("folders.id"), index=True, nullable=True)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    slug: Mapped[str] = mapped_column(String(300), index=True, nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False, default="draft")
    content_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    updated_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

Index("ix_docs_space_slug", Doc.space_id, Doc.slug, unique=True)

class DocVersion(Base):
    __tablename__ = "doc_versions"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    doc_id: Mapped[str] = mapped_column(String(36), ForeignKey("docs.id"), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    content_md: Mapped[str] = mapped_column(Text, nullable=False)
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class DocMeta(Base):
    __tablename__ = "doc_meta"
    doc_id: Mapped[str] = mapped_column(String(36), ForeignKey("docs.id"), primary_key=True)
    tags_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    deleted_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    review_due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    last_reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_reviewed_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)


class DocReviewAssignment(Base):
    __tablename__ = "doc_review_assignments"
    doc_id: Mapped[str] = mapped_column(String(36), ForeignKey("docs.id"), primary_key=True)
    reviewer_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    reminder_days: Mapped[int] = mapped_column(nullable=False, default=3)


class DocComment(Base):
    __tablename__ = "doc_comments"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    doc_id: Mapped[str] = mapped_column(String(36), ForeignKey("docs.id"), index=True, nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    body_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )


class DocMentionNotification(Base):
    __tablename__ = "doc_mention_notifications"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    doc_id: Mapped[str] = mapped_column(String(36), ForeignKey("docs.id"), index=True, nullable=False)
    comment_id: Mapped[str] = mapped_column(String(36), ForeignKey("doc_comments.id"), index=True, nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), index=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)


class KbSpacePolicy(Base):
    __tablename__ = "kb_space_policy"
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), primary_key=True)
    trash_retention_days: Mapped[int] = mapped_column(nullable=False, default=30)
    synonyms_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    lexicon_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    localized_synonyms_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    localized_lexicon_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    relevance_benchmarks_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    last_purge_run_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_relevance_benchmark_run_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_relevance_benchmark_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    last_relevance_benchmark_results_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
