# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for media management APIs."""

from datetime import datetime

from pydantic import BaseModel, Field


class MediaAssetOut(BaseModel):
    id: str
    owner_user_id: str
    space_id: str | None = None
    usage: str
    original_filename: str
    content_type: str | None = None
    size_bytes: int
    access_mode: str
    folder_path: str | None = None
    tags: list[str] = Field(default_factory=list)
    retention_days: int | None = None
    expires_at: datetime | None = None
    url: str
    created_at: datetime | None = None


class MediaMetaUpdateIn(BaseModel):
    access_mode: str | None = None
    folder_path: str | None = None
    tags: list[str] | None = None
    retention_days: int | None = Field(default=None, ge=0, le=3650)


class MediaAttachmentIn(BaseModel):
    entity_type: str
    entity_id: str


class MediaSignedUrlOut(BaseModel):
    url: str
    expires_at: datetime


class MediaUploadPolicyOut(BaseModel):
    max_upload_mb: int
    allowed_extensions: list[str] = Field(default_factory=list)
    allowed_mime_types: list[str] = Field(default_factory=list)
    usage_rules: dict[str, dict[str, object]] = Field(default_factory=dict)


class MediaUsageOut(BaseModel):
    asset_id: str
    entity_type: str
    entity_id: str
    field_name: str
    space_id: str | None = None
    updated_at: datetime | None = None


class MediaSummaryEntryOut(BaseModel):
    value: str
    count: int


class MediaSummaryOut(BaseModel):
    total_assets: int
    expired_assets: int
    folders: list[MediaSummaryEntryOut] = Field(default_factory=list)
    tags: list[MediaSummaryEntryOut] = Field(default_factory=list)


class MediaPageOut(BaseModel):
    items: list[MediaAssetOut] = Field(default_factory=list)
    total: int
    limit: int
    offset: int
    has_more: bool


class MediaBulkMetaUpdateIn(BaseModel):
    asset_ids: list[str] = Field(min_length=1, max_length=200)
    access_mode: str | None = None
    folder_path: str | None = None
    tags: list[str] | None = None
    retention_days: int | None = Field(default=None, ge=0, le=3650)
    clear_folder_path: bool = False
    clear_tags: bool = False
    clear_retention_days: bool = False
