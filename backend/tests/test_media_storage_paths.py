# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi import HTTPException

from app.core.config import settings
from app.modules.media.models import MediaAsset
from app.modules.media.service import file_path_for


def test_file_path_for_rejects_storage_key_traversal(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    monkeypatch.setattr(settings, "media_storage_dir", str(tmp_path))
    asset = MediaAsset(
        id="asset-1",
        owner_user_id="user-1",
        space_id=None,
        usage="general",
        original_filename="note.txt",
        content_type="text/plain",
        size_bytes=12,
        storage_key="../escape.txt",
    )

    with pytest.raises(HTTPException, match="Invalid media storage path"):
        file_path_for(asset)


def test_file_path_for_accepts_generated_storage_key(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    monkeypatch.setattr(settings, "media_storage_dir", str(tmp_path))
    asset = MediaAsset(
        id="asset-2",
        owner_user_id="user-1",
        space_id=None,
        usage="general",
        original_filename="note.txt",
        content_type="text/plain",
        size_bytes=12,
        storage_key="general/123e4567-e89b-12d3-a456-426614174000.txt",
    )

    assert file_path_for(asset) == Path(tmp_path) / "general" / "123e4567-e89b-12d3-a456-426614174000.txt"


def test_file_path_for_accepts_internal_object_storage_key(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    monkeypatch.setattr(settings, "media_storage_dir", str(tmp_path))
    asset = MediaAsset(
        id="asset-3",
        owner_user_id="user-1",
        space_id=None,
        usage="general",
        original_filename="report.pdf",
        content_type="application/pdf",
        size_bytes=12,
        storage_key="objects/123e4567-e89b-12d3-a456-426614174000.blob",
    )

    assert file_path_for(asset) == Path(tmp_path) / "objects" / "123e4567-e89b-12d3-a456-426614174000.blob"


def test_file_path_for_rejects_symlink_escape(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    storage_root = tmp_path / "storage"
    outside_root = tmp_path / "outside"
    storage_root.mkdir()
    outside_root.mkdir()
    (storage_root / "objects").symlink_to(outside_root, target_is_directory=True)
    monkeypatch.setattr(settings, "media_storage_dir", str(storage_root))
    asset = MediaAsset(
        id="asset-4",
        owner_user_id="user-1",
        space_id=None,
        usage="general",
        original_filename="report.pdf",
        content_type="application/pdf",
        size_bytes=12,
        storage_key="objects/123e4567-e89b-12d3-a456-426614174000.blob",
    )

    with pytest.raises(HTTPException, match="Invalid media storage path"):
        file_path_for(asset)
