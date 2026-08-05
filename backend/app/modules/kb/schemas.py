# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for knowledge-base APIs."""

from datetime import datetime

from pydantic import BaseModel, Field


class KbRelevanceBenchmarkCase(BaseModel):
    language_code: str = Field(default="en", min_length=2, max_length=16)
    query: str = Field(min_length=1, max_length=240)
    expected_doc_id: str | None = Field(default=None, min_length=1, max_length=120)
    expected_slug: str | None = Field(default=None, min_length=1, max_length=300)


class KbRelevanceBenchmarkResultOut(BaseModel):
    language_code: str
    query: str
    passed: bool
    matched_doc_id: str | None = None
    matched_slug: str | None = None
    matched_title: str | None = None
    rank: int | None = None


class KbRelevanceBenchmarkSummaryOut(BaseModel):
    total_cases: int = 0
    passed_cases: int = 0
    score: float = 0.0
    last_run_at: datetime | None = None
    results: list[KbRelevanceBenchmarkResultOut] = Field(default_factory=list)


class KbSearchSuggestionOut(BaseModel):
    query: str
    source: str
    language_code: str | None = None
    score: float = 0.0

class FolderOut(BaseModel):
    id: str
    space_id: str
    parent_id: str | None
    name: str
    path: str

class FolderCreateIn(BaseModel):
    space_id: str
    parent_id: str | None = None
    name: str

class FolderUpdateIn(BaseModel):
    parent_id: str | None = None
    name: str

class DocOut(BaseModel):
    id: str
    space_id: str
    folder_id: str | None
    folder_path: str | None = None
    title: str
    slug: str
    status: str
    content_md: str
    tags: list[str] = []
    created_at: datetime | None = None
    updated_at: datetime | None = None
    published_at: datetime | None = None
    deleted_at: datetime | None = None
    deleted_by: str | None = None
    review_due_at: datetime | None = None
    last_reviewed_at: datetime | None = None
    last_reviewed_by: str | None = None
    reviewer_user_id: str | None = None
    reviewer_name: str | None = None
    review_reminder_days: int | None = None
    trash_expires_at: datetime | None = None
    comment_count: int = 0
    is_stale: bool = False

class DocCreateIn(BaseModel):
    space_id: str
    folder_id: str | None = None
    title: str
    slug: str
    content_md: str = ""
    tags: list[str] = []
    review_due_at: datetime | None = None
    reviewer_user_id: str | None = None
    review_reminder_days: int | None = None

class DocUpdateIn(BaseModel):
    title: str
    slug: str
    content_md: str
    folder_id: str | None = None
    tags: list[str] | None = None
    review_due_at: datetime | None = None
    reviewer_user_id: str | None = None
    review_reminder_days: int | None = None
    base_updated_at: datetime | None = None

class DocPublishOut(BaseModel):
    id: str
    status: str

class DocVersionOut(BaseModel):
    id: str
    doc_id: str
    title: str
    content_md: str
    created_by: str
    created_at: datetime


class DocCommentIn(BaseModel):
    body_md: str


class DocCommentUpdateIn(BaseModel):
    body_md: str


class DocCommentOut(BaseModel):
    id: str
    doc_id: str
    user_id: str
    author_name: str | None = None
    body_md: str
    mentions: list[str] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class DocMentionNotificationOut(BaseModel):
    id: str
    doc_id: str
    comment_id: str
    doc_title: str
    doc_slug: str
    comment_excerpt: str
    created_at: datetime
    read_at: datetime | None = None


class KbSpacePolicyOut(BaseModel):
    space_id: str
    trash_retention_days: int
    synonyms: dict[str, list[str]] = Field(default_factory=dict)
    lexicon: list[str] = Field(default_factory=list)
    localized_synonyms: dict[str, dict[str, list[str]]] = Field(default_factory=dict)
    localized_lexicon: dict[str, list[str]] = Field(default_factory=dict)
    relevance_benchmarks: list[KbRelevanceBenchmarkCase] = Field(default_factory=list)
    last_purge_run_at: datetime | None = None
    relevance_benchmark_summary: KbRelevanceBenchmarkSummaryOut = Field(
        default_factory=KbRelevanceBenchmarkSummaryOut,
    )


class KbSpacePolicyIn(BaseModel):
    trash_retention_days: int = Field(default=30, ge=1, le=365)
    synonyms: dict[str, list[str]] = Field(default_factory=dict)
    lexicon: list[str] = Field(default_factory=list)
    localized_synonyms: dict[str, dict[str, list[str]]] = Field(default_factory=dict)
    localized_lexicon: dict[str, list[str]] = Field(default_factory=dict)
    relevance_benchmarks: list[KbRelevanceBenchmarkCase] = Field(default_factory=list)


class DocReviewerSuggestionOut(BaseModel):
    user_id: str
    name: str
    email: str
    global_role: str
    open_reviews: int
    due_soon_reviews: int
    expertise_score: int = 0
    matching_tags: list[str] = Field(default_factory=list)


class DocMetaUpdateIn(BaseModel):
    tags: list[str] | None = None
    review_due_at: datetime | None = None
    reviewer_user_id: str | None = None
    review_reminder_days: int | None = None


class DocDiffRowOut(BaseModel):
    kind: str
    left_line_no: int | None = None
    right_line_no: int | None = None
    left_text: str = ""
    right_text: str = ""


class DocDiffOut(BaseModel):
    doc_id: str
    from_version_id: str | None = None
    to_version_id: str | None = None
    from_label: str
    to_label: str
    diff_html: str
    rows: list[DocDiffRowOut] = Field(default_factory=list)


class DocReviewSummaryOut(BaseModel):
    space_id: str
    total_docs: int
    stale_docs: int
    trashed_docs: int
    docs_due_for_review: int


class DocTrashOut(BaseModel):
    id: str
    deleted_at: datetime | None = None
    deleted_by: str | None = None


class DocTrashPurgeOut(BaseModel):
    deleted_count: int
    retention_days: int


class TagListOut(BaseModel):
    tags: list[str]


class DocMentionBulkReadIn(BaseModel):
    notification_ids: list[str] = Field(default_factory=list)
    doc_id: str | None = None
    unread_only: bool = False
    max_age_days: int | None = Field(default=None, ge=1, le=365)


class DocMentionBulkReadOut(BaseModel):
    marked_count: int
