# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for media asset storage, filtering, and retention rules."""

from __future__ import annotations

import base64
from collections import Counter
import hashlib
import hmac
from io import BytesIO
import json
import os
import re
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import HTTPException
import jwt
from PIL import Image, UnidentifiedImageError
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.deps import bad_request, forbidden, not_found
from app.modules.auth.models import User
from app.modules.auth.deps import user_is_admin
from app.modules.spaces import service as spaces_service

from .models import MediaAsset, MediaAssetMeta, MediaAttachment, MediaUsage

ACCESS_PUBLIC = "public"
ACCESS_AUTHENTICATED = "authenticated"
ACCESS_SPACE = "space"
ACCESS_PRIVATE = "private"
ALLOWED_ACCESS_MODES = {ACCESS_PUBLIC, ACCESS_AUTHENTICATED, ACCESS_SPACE, ACCESS_PRIVATE}

ATTACHABLE_ENTITY_TYPES = {
    "doc",
    "sop",
    "incident",
    "sop_run_step",
    "task",
    "task_comment",
}

_STORAGE_NAMESPACE = "objects"
_SAFE_USAGE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,99}$")
_SAFE_FILENAME = re.compile(r"[^a-zA-Z0-9._-]+")
_SAFE_FOLDER = re.compile(r"^[a-z0-9][a-z0-9_./-]{0,219}$")
_SAFE_STORAGE_FILENAME = re.compile(r"^[0-9a-fA-F-]{36}\.(?:blob|[a-z0-9]{1,12})$")
_MEDIA_ID_FROM_URL = re.compile(r"/media/([0-9a-fA-F-]{36})/file(?:\?[^\s\"'<>)]*)?")
_UNSET: object = object()

_DEFAULT_ALLOWED_EXTENSIONS = {
    "png",
    "jpg",
    "jpeg",
    "gif",
    "webp",
    "pdf",
    "txt",
    "md",
    "csv",
    "json",
    "zip",
    "docx",
    "xlsx",
    "pptx",
    "mp4",
    "webm",
    "mov",
    "m4v",
    "mp3",
    "wav",
    "ogg",
    "m4a",
}

_DEFAULT_ALLOWED_MIME_TYPES = {
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "application/pdf",
    "text/plain",
    "text/markdown",
    "text/csv",
    "application/json",
    "application/zip",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "video/mp4",
    "video/webm",
    "video/quicktime",
    "audio/mpeg",
    "audio/wav",
    "audio/ogg",
    "audio/x-m4a",
}

_DEFAULT_BLOCKED_EXTENSIONS = {
    "html",
    "htm",
    "svg",
    "svgz",
    "js",
    "mjs",
    "xhtml",
}

_DEFAULT_BLOCKED_MIME_TYPES = {
    "text/html",
    "application/xhtml+xml",
    "image/svg+xml",
    "application/javascript",
    "text/javascript",
}

_INLINE_SAFE_MIME_TYPES = {
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "text/plain",
}

_BRANDING_UPLOAD_RULES: dict[str, dict[str, object]] = {
    "branding_logo_light": {
        "label": "Light logo",
        "guidance": [
            "Use a wide PNG or WEBP logo that stays readable in compact shell states.",
            "Landscape lockups work best; aim for a ratio between 2:1 and 8:1.",
            "Transparent backgrounds are recommended when possible.",
        ],
        "allowed_extensions": ["png", "jpg", "jpeg", "webp"],
        "allowed_mime_types": ["image/png", "image/jpeg", "image/webp"],
        "max_upload_mb": 4,
        "min_width": 160,
        "min_height": 40,
        "max_width": 3200,
        "max_height": 1400,
        "aspect_ratio_min": 1.5,
        "aspect_ratio_max": 10.0,
    },
    "branding_logo_dark": {
        "label": "Dark logo",
        "guidance": [
            "Use a wide PNG or WEBP logo that stays readable on dark surfaces.",
            "Landscape lockups work best; aim for a ratio between 2:1 and 8:1.",
            "Transparent backgrounds are recommended when possible.",
        ],
        "allowed_extensions": ["png", "jpg", "jpeg", "webp"],
        "allowed_mime_types": ["image/png", "image/jpeg", "image/webp"],
        "max_upload_mb": 4,
        "min_width": 160,
        "min_height": 40,
        "max_width": 3200,
        "max_height": 1400,
        "aspect_ratio_min": 1.5,
        "aspect_ratio_max": 10.0,
    },
    "branding_favicon": {
        "label": "Favicon",
        "guidance": [
            "Upload a square PNG or WEBP icon; 192x192 or larger is recommended.",
            "Avoid text-heavy artwork because browser tabs render favicons very small.",
            "Keep the mark centered with comfortable padding.",
        ],
        "allowed_extensions": ["png", "webp"],
        "allowed_mime_types": ["image/png", "image/webp"],
        "max_upload_mb": 2,
        "min_width": 64,
        "min_height": 64,
        "max_width": 1024,
        "max_height": 1024,
        "aspect_ratio_min": 0.95,
        "aspect_ratio_max": 1.05,
        "square_required": True,
    },
    "branding_login_bg": {
        "label": "Login background",
        "guidance": [
            "Use a large landscape image so the login screen does not blur or crop aggressively.",
            "Keep important subjects away from the center to leave room for the login card.",
            "Subtle contrast works better than busy, high-detail backgrounds.",
        ],
        "allowed_extensions": ["png", "jpg", "jpeg", "webp"],
        "allowed_mime_types": ["image/png", "image/jpeg", "image/webp"],
        "max_upload_mb": 8,
        "min_width": 1280,
        "min_height": 720,
        "max_width": 6000,
        "max_height": 4000,
        "aspect_ratio_min": 1.2,
        "aspect_ratio_max": 2.6,
    },
}


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _storage_root() -> Path:
    root = Path(settings.media_storage_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def _normalized_storage_uuid(asset_id: str) -> str:
    try:
        return str(uuid.UUID(asset_id))
    except ValueError as exc:
        raise bad_request("Invalid media storage path") from exc


def _storage_key_parts(storage_key: str) -> tuple[str, str]:
    value = (storage_key or "").strip().replace("\\", "/")
    parts = [part for part in value.split("/") if part]
    if len(parts) != 2:
        raise bad_request("Invalid media storage path")
    namespace, file_name = parts
    if namespace != _STORAGE_NAMESPACE and _SAFE_USAGE.fullmatch(namespace) is None:
        raise bad_request("Invalid media storage path")
    if _SAFE_STORAGE_FILENAME.fullmatch(file_name) is None:
        raise bad_request("Invalid media storage path")
    return namespace, file_name


def _storage_key_for_upload(asset_id: str) -> str:
    return f"{_STORAGE_NAMESPACE}/{_normalized_storage_uuid(asset_id)}.blob"


def _storage_path(storage_key: str) -> Path:
    usage_key, file_name = _storage_key_parts(storage_key)
    root = _storage_root()
    candidate = (root / usage_key / file_name).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise bad_request("Invalid media storage path") from exc
    return candidate


def _default_access_mode(asset: MediaAsset) -> str:
    return ACCESS_SPACE if asset.space_id else ACCESS_PRIVATE


def _is_branding_asset(asset: MediaAsset) -> bool:
    usage = (asset.usage or "").strip().lower()
    return usage.startswith("branding_")


def _sanitize_usage(raw: str | None) -> str:
    usage = (raw or "general").strip().lower()
    if not _SAFE_USAGE.match(usage):
        raise bad_request("Invalid media usage key")
    return usage


def _safe_filename(raw: str) -> str:
    cleaned = _SAFE_FILENAME.sub("_", raw.strip())[:180]
    return cleaned or "upload.bin"


def _normalize_access_mode(raw: str | None, *, default: str) -> str:
    if raw is None:
        return default
    mode = raw.strip().lower()
    if not mode:
        return default
    if mode not in ALLOWED_ACCESS_MODES:
        raise bad_request(f"Invalid access_mode. Allowed: {', '.join(sorted(ALLOWED_ACCESS_MODES))}")
    return mode


def _normalize_folder_path(raw: str | None) -> str | None:
    if raw is None:
        return None
    folder = raw.strip().lower().strip("/")
    if not folder:
        return None
    if not _SAFE_FOLDER.match(folder):
        raise bad_request("Invalid folder path")
    return folder


def _normalize_tags(raw: list[str] | None) -> list[str]:
    if raw is None:
        return []
    normalized: list[str] = []
    seen: set[str] = set()
    for tag in raw:
        clean = tag.strip().lower()
        if not clean:
            continue
        clean = re.sub(r"[^a-z0-9._-]+", "-", clean).strip("-")
        if not clean or clean in seen:
            continue
        if len(clean) > 50:
            clean = clean[:50]
        seen.add(clean)
        normalized.append(clean)
    return normalized[:30]


def _retention_days(raw: int | None) -> int | None:
    if raw is None:
        return None
    if raw <= 0:
        return None
    if raw > 3650:
        raise bad_request("Retention cannot exceed 3650 days")
    return raw


def _pick_extension(filename: str, content_type: str | None) -> str:
    ext = Path(filename).suffix.strip().lower()
    if ext and len(ext) <= 12:
        return ext
    if content_type:
        fallback = {
            "image/png": ".png",
            "image/jpeg": ".jpg",
            "image/webp": ".webp",
            "image/gif": ".gif",
            "image/svg+xml": ".svg",
            "application/pdf": ".pdf",
            "text/plain": ".txt",
        }
        if content_type in fallback:
            return fallback[content_type]
    return ".bin"


def _normalize_extension(filename: str) -> str:
    return Path(filename).suffix.strip().lower().lstrip(".")


def _normalize_mime(raw: str | None) -> str | None:
    if not isinstance(raw, str):
        return None
    value = raw.strip().lower()
    return value or None


def _sniff_mime(data: bytes) -> str | None:
    if not data:
        return None
    head = data[:512]
    lowered = head.lower()
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith(b"GIF87a") or head.startswith(b"GIF89a"):
        return "image/gif"
    if len(head) >= 12 and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    if head.startswith(b"%PDF"):
        return "application/pdf"
    if head.startswith(b"PK\x03\x04"):
        return "application/zip"
    if b"<svg" in lowered:
        return "image/svg+xml"
    if b"<html" in lowered or b"<!doctype html" in lowered:
        return "text/html"
    return None


def _configured_extensions() -> set[str]:
    configured = {str(item).strip().lower().lstrip(".") for item in settings.media_allowed_extensions if str(item).strip()}
    return configured or set(_DEFAULT_ALLOWED_EXTENSIONS)


def _configured_mime_types() -> set[str]:
    configured = {str(item).strip().lower() for item in settings.media_allowed_mime_types if str(item).strip()}
    return configured or set(_DEFAULT_ALLOWED_MIME_TYPES)


def _blocked_extensions() -> set[str]:
    configured = {str(item).strip().lower().lstrip(".") for item in settings.media_blocked_extensions if str(item).strip()}
    return configured or set(_DEFAULT_BLOCKED_EXTENSIONS)


def _blocked_mime_types() -> set[str]:
    configured = {str(item).strip().lower() for item in settings.media_blocked_mime_types if str(item).strip()}
    return configured or set(_DEFAULT_BLOCKED_MIME_TYPES)


def get_upload_policy() -> dict[str, object]:
    allowed_extensions = sorted(_configured_extensions() - _blocked_extensions())
    allowed_mime_types = sorted(_configured_mime_types() - _blocked_mime_types())
    return {
        "max_upload_mb": max(1, int(settings.media_max_upload_mb or 1)),
        "allowed_extensions": allowed_extensions,
        "allowed_mime_types": allowed_mime_types,
        "usage_rules": get_usage_upload_rules(),
    }


def get_usage_upload_rules() -> dict[str, dict[str, object]]:
    return {
        usage: {
            key: (list(value) if isinstance(value, list) else value)
            for key, value in rule.items()
        }
        for usage, rule in _BRANDING_UPLOAD_RULES.items()
    }


def _quarantine_root() -> Path:
    root = Path(settings.media_quarantine_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def _quarantine_file(
    *,
    filename: str,
    data: bytes,
    content_type: str | None,
    reason: str,
) -> None:
    qid = str(uuid.uuid4())
    ext = Path(filename).suffix.strip().lower() or ".bin"
    safe_reason = reason.strip()[:240] or "security_policy"
    root = _quarantine_root()
    payload_path = root / f"{qid}{ext}"
    payload_path.write_bytes(data)
    meta = {
        "id": qid,
        "filename": filename,
        "content_type": content_type,
        "reason": safe_reason,
        "created_at": _now_utc().isoformat(),
        "size_bytes": len(data),
    }
    (root / f"{qid}.json").write_text(
        json.dumps(meta, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )


def _run_malware_scan_if_enabled(*, filename: str, data: bytes, content_type: str | None) -> None:
    if not settings.media_malware_scan_enabled:
        return
    command_args = [str(part).strip() for part in settings.media_malware_scan_command if str(part).strip()]
    if not command_args:
        raise bad_request("Malware scanning is enabled but MEDIA_MALWARE_SCAN_COMMAND is not configured")
    if any("{file}" in part for part in command_args):
        raise bad_request("MEDIA_MALWARE_SCAN_COMMAND must be configured as a fixed argv list without {file} placeholders")

    tmpdir = os.getenv("TMPDIR") or None
    suffix = Path(filename).suffix if Path(filename).suffix else ".bin"
    temp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, dir=tmpdir, suffix=suffix) as temp:
            temp.write(data)
            temp_path = temp.name

        result = subprocess.run([*command_args, temp_path], capture_output=True, text=True, timeout=90)
        if result.returncode == 0:
            return

        detail = (result.stderr or result.stdout or "scan_failed").strip()
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=content_type,
            reason=f"malware_scan_failed:{result.returncode}:{detail[:180]}",
        )
        raise bad_request("File failed malware scanning and was quarantined")
    except subprocess.TimeoutExpired:
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=content_type,
            reason="malware_scan_timeout",
        )
        raise bad_request("File malware scan timed out and was quarantined")
    finally:
        if temp_path and os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass


def _validate_media_payload(
    *,
    filename: str,
    data: bytes,
    declared_content_type: str | None,
) -> str | None:
    extension = _normalize_extension(filename)
    declared_mime = _normalize_mime(declared_content_type)
    sniffed_mime = _sniff_mime(data)
    effective_mime = sniffed_mime or declared_mime

    blocked_ext = _blocked_extensions()
    blocked_mimes = _blocked_mime_types()

    if extension and extension in blocked_ext:
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=effective_mime,
            reason=f"blocked_extension:{extension}",
        )
        raise bad_request("This file type is blocked by media security policy")

    if effective_mime and effective_mime in blocked_mimes:
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=effective_mime,
            reason=f"blocked_mime:{effective_mime}",
        )
        raise bad_request("This media content type is blocked by security policy")

    allowed_ext = _configured_extensions()
    allowed_mimes = _configured_mime_types()
    if extension and extension not in allowed_ext:
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=effective_mime,
            reason=f"extension_not_allowed:{extension}",
        )
        raise bad_request("File extension is not allowed")

    if effective_mime is None:
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=effective_mime,
            reason="mime_undetected",
        )
        raise bad_request("Unable to verify uploaded content type")

    if effective_mime not in allowed_mimes:
        _quarantine_file(
            filename=filename,
            data=data,
            content_type=effective_mime,
            reason=f"mime_not_allowed:{effective_mime}",
        )
        raise bad_request("Content type is not allowed")

    _run_malware_scan_if_enabled(
        filename=filename,
        data=data,
        content_type=effective_mime,
    )
    return effective_mime


def _read_image_dimensions(data: bytes) -> tuple[int, int] | None:
    try:
        with Image.open(BytesIO(data)) as image:
            image.load()
            return int(image.width), int(image.height)
    except (UnidentifiedImageError, OSError, ValueError):
        return None


def _validate_branding_payload(
    *,
    usage: str,
    filename: str,
    data: bytes,
    content_type: str | None,
) -> None:
    rule = _BRANDING_UPLOAD_RULES.get(usage)
    if rule is None:
        return

    label = str(rule.get("label") or usage).strip() or usage
    extension = _normalize_extension(filename)
    allowed_extensions = {
        str(item).strip().lower()
        for item in (rule.get("allowed_extensions") or [])
        if str(item).strip()
    }
    if extension not in allowed_extensions:
        raise bad_request(
            f"{label} assets must use one of: {', '.join(sorted(allowed_extensions))}"
        )

    normalized_mime = _normalize_mime(content_type)
    allowed_mime_types = {
        str(item).strip().lower()
        for item in (rule.get("allowed_mime_types") or [])
        if str(item).strip()
    }
    if normalized_mime not in allowed_mime_types:
        raise bad_request(
            f"{label} assets must use one of: {', '.join(sorted(allowed_mime_types))}"
        )

    max_upload_mb = int(rule.get("max_upload_mb") or 0)
    if max_upload_mb > 0 and len(data) > max_upload_mb * 1024 * 1024:
        raise bad_request(f"{label} assets cannot exceed {max_upload_mb} MB")

    dimensions = _read_image_dimensions(data)
    if dimensions is None:
        raise bad_request(f"{label} assets must be valid image files")
    width, height = dimensions
    min_width = int(rule.get("min_width") or 0)
    min_height = int(rule.get("min_height") or 0)
    max_width = int(rule.get("max_width") or 0)
    max_height = int(rule.get("max_height") or 0)
    if min_width > 0 and width < min_width:
        raise bad_request(f"{label} assets must be at least {min_width}px wide")
    if min_height > 0 and height < min_height:
        raise bad_request(f"{label} assets must be at least {min_height}px tall")
    if max_width > 0 and width > max_width:
        raise bad_request(f"{label} assets cannot exceed {max_width}px width")
    if max_height > 0 and height > max_height:
        raise bad_request(f"{label} assets cannot exceed {max_height}px height")

    ratio = width / max(height, 1)
    aspect_ratio_min = float(rule.get("aspect_ratio_min") or 0)
    aspect_ratio_max = float(rule.get("aspect_ratio_max") or 0)
    if aspect_ratio_min > 0 and ratio < aspect_ratio_min:
        raise bad_request(f"{label} assets are too tall for the expected aspect ratio")
    if aspect_ratio_max > 0 and ratio > aspect_ratio_max:
        raise bad_request(f"{label} assets are too wide for the expected aspect ratio")
    if rule.get("square_required") and width != height:
        raise bad_request(f"{label} assets must be square")


def is_inline_safe_media(asset: MediaAsset) -> bool:
    mime = _normalize_mime(asset.content_type)
    if mime in _INLINE_SAFE_MIME_TYPES:
        return True
    extension = _normalize_extension(asset.original_filename or "")
    return extension in {"png", "jpg", "jpeg", "gif", "webp", "txt"}


def _safe_tags_json(tags: list[str]) -> str:
    return json.dumps(tags, separators=(",", ":"))


def _parse_tags_json(raw: str | None) -> list[str]:
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    return [str(v) for v in decoded if isinstance(v, str)]


def _meta_for(db: Session, asset: MediaAsset) -> MediaAssetMeta:
    meta = db.get(MediaAssetMeta, asset.id)
    if meta:
        return meta
    meta = MediaAssetMeta(
        asset_id=asset.id,
        access_mode=_default_access_mode(asset),
        folder_path=None,
        tags_json="[]",
        retention_days=None,
    )
    db.add(meta)
    db.flush()
    return meta


def _is_space_member(db: Session, space_id: str, user_id: str) -> bool:
    try:
        spaces_service.require_space_role(db, space_id, user_id, {"admin", "moderator", "member", "viewer"})
    except HTTPException:
        return False
    return True


def is_expired(asset: MediaAsset, meta: MediaAssetMeta | None = None) -> bool:
    expires_at = media_expires_at(asset, meta)
    if expires_at is None:
        return False
    return expires_at <= _now_utc()


def media_expires_at(asset: MediaAsset, meta: MediaAssetMeta | None = None) -> datetime | None:
    if meta is None:
        return None
    if meta.retention_days is None or asset.created_at is None:
        return None
    created_at = asset.created_at
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    return created_at + timedelta(days=meta.retention_days)


def read_access_mode(asset: MediaAsset, meta: MediaAssetMeta | None) -> str:
    if meta:
        return _normalize_access_mode(meta.access_mode, default=_default_access_mode(asset))
    return _default_access_mode(asset)


def can_read_asset(db: Session, user: User | None, asset: MediaAsset, meta: MediaAssetMeta | None = None) -> bool:
    if _is_branding_asset(asset):
        return True
    mode = read_access_mode(asset, meta)
    if mode == ACCESS_PUBLIC:
        return True
    if user is None:
        return False
    if user_is_admin(user):
        return True
    if mode == ACCESS_AUTHENTICATED:
        return True
    if mode == ACCESS_PRIVATE:
        return user.id == asset.owner_user_id
    if mode == ACCESS_SPACE:
        if asset.space_id:
            return _is_space_member(db, asset.space_id, user.id)
        return user.id == asset.owner_user_id
    return False


def require_read_asset(db: Session, user: User | None, asset: MediaAsset, *, signed_ok: bool = False) -> None:
    meta = db.get(MediaAssetMeta, asset.id)
    if is_expired(asset, meta):
        raise forbidden("Media asset is expired by retention policy")
    if signed_ok:
        return
    if not can_read_asset(db, user, asset, meta):
        raise forbidden("You do not have access to this media asset")


def require_manage_asset(db: Session, user: User, asset: MediaAsset) -> None:
    if user_is_admin(user) or asset.owner_user_id == user.id:
        return
    if asset.space_id:
        spaces_service.require_space_role(db, asset.space_id, user.id, {"admin", "moderator", "member"})
        return
    raise forbidden("You do not have permission to modify this media asset")


def create_asset(
    db: Session,
    *,
    owner_user_id: str,
    space_id: str | None,
    usage: str | None,
    original_filename: str,
    content_type: str | None,
    data: bytes,
    access_mode: str | None = None,
    folder_path: str | None = None,
    tags: list[str] | None = None,
    retention_days: int | None = None,
) -> MediaAsset:
    if not data:
        raise bad_request("Uploaded file is empty")
    max_bytes = max(1, settings.media_max_upload_mb) * 1024 * 1024
    if len(data) > max_bytes:
        raise bad_request(f"Uploaded file is too large (max {settings.media_max_upload_mb} MB)")

    usage_key = _sanitize_usage(usage)

    normalized_content_type = _validate_media_payload(
        filename=original_filename,
        data=data,
        declared_content_type=content_type,
    )
    _validate_branding_payload(
        usage=usage_key,
        filename=original_filename,
        data=data,
        content_type=normalized_content_type,
    )
    asset_id = str(uuid.uuid4())
    safe_name = _safe_filename(original_filename)
    _pick_extension(safe_name, normalized_content_type)
    storage_key = _storage_key_for_upload(asset_id)
    file_path = _storage_path(storage_key)
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_bytes(data)

    asset = MediaAsset(
        id=asset_id,
        owner_user_id=owner_user_id,
        space_id=space_id,
        usage=usage_key,
        original_filename=safe_name,
        content_type=normalized_content_type,
        size_bytes=len(data),
        storage_key=storage_key,
    )
    db.add(asset)
    db.flush()

    meta = MediaAssetMeta(
        asset_id=asset.id,
        access_mode=_normalize_access_mode(access_mode, default=_default_access_mode(asset)),
        folder_path=_normalize_folder_path(folder_path),
        tags_json=_safe_tags_json(_normalize_tags(tags)),
        retention_days=_retention_days(retention_days),
    )
    db.add(meta)
    db.commit()
    db.refresh(asset)
    return asset


def get_asset(db: Session, asset_id: str) -> MediaAsset | None:
    return db.get(MediaAsset, asset_id)


def get_asset_meta(db: Session, asset_id: str) -> MediaAssetMeta | None:
    return db.get(MediaAssetMeta, asset_id)


def apply_meta_patch(db: Session, asset: MediaAsset, patch: dict[str, Any]) -> MediaAssetMeta:
    meta = _meta_for(db, asset)
    if "access_mode" in patch:
        meta.access_mode = _normalize_access_mode(
            patch.get("access_mode") if isinstance(patch.get("access_mode"), str) or patch.get("access_mode") is None else None,
            default=_default_access_mode(asset),
        )
    if "folder_path" in patch:
        folder_val = patch.get("folder_path")
        meta.folder_path = _normalize_folder_path(folder_val if isinstance(folder_val, str) or folder_val is None else None)
    if "tags" in patch:
        raw_tags = patch.get("tags")
        if raw_tags is None:
            tags: list[str] = []
        elif isinstance(raw_tags, list):
            tags = [str(v) for v in raw_tags]
        else:
            tags = []
        meta.tags_json = _safe_tags_json(_normalize_tags(tags))
    if "retention_days" in patch:
        raw_days = patch.get("retention_days")
        days: int | None
        if raw_days is None:
            days = None
        elif isinstance(raw_days, int):
            days = raw_days
        else:
            raise bad_request("retention_days must be an integer or null")
        meta.retention_days = _retention_days(days)
    db.add(meta)
    db.commit()
    db.refresh(meta)
    return meta


def list_assets(
    db: Session,
    *,
    space_id: str | None = None,
    usage: str | None = None,
    folder_path: str | None = None,
    tag: str | None = None,
    limit: int = 30,
    include_expired: bool = False,
) -> list[MediaAsset]:
    q = select(MediaAsset)
    if space_id is not None:
        q = q.where(MediaAsset.space_id == space_id)
    if usage:
        q = q.where(MediaAsset.usage == _sanitize_usage(usage))
    q = q.order_by(MediaAsset.created_at.desc()).limit(max(1, min(limit * 4, 500)))
    rows = list(db.execute(q).scalars().all())

    folder = _normalize_folder_path(folder_path) if folder_path is not None else _UNSET
    wanted_tag = tag.strip().lower() if tag and tag.strip() else None
    out: list[MediaAsset] = []
    for asset in rows:
        meta = db.get(MediaAssetMeta, asset.id)
        if not include_expired and is_expired(asset, meta):
            continue
        if folder is not _UNSET:
            folder_value = folder if isinstance(folder, str) else None
            if (meta.folder_path if meta else None) != folder_value:
                continue
        if wanted_tag:
            tags = set(_parse_tags_json(meta.tags_json) if meta else [])
            if wanted_tag not in tags:
                continue
        out.append(asset)
        if len(out) >= max(1, min(limit, 200)):
            break
    return out


def list_assets_page(
    db: Session,
    *,
    space_id: str | None = None,
    usage: str | None = None,
    folder_path: str | None = None,
    tag: str | None = None,
    limit: int = 30,
    offset: int = 0,
    include_expired: bool = False,
    only_expired: bool = False,
) -> dict[str, object]:
    page_limit = max(1, min(limit, 200))
    page_offset = max(0, offset)

    base_q = select(MediaAsset)
    if space_id is not None:
        base_q = base_q.where(MediaAsset.space_id == space_id)
    if usage:
        base_q = base_q.where(MediaAsset.usage == _sanitize_usage(usage))
    base_q = base_q.order_by(MediaAsset.created_at.desc(), MediaAsset.id.desc())

    folder = _normalize_folder_path(folder_path) if folder_path is not None else _UNSET
    wanted_tag = tag.strip().lower() if tag and tag.strip() else None

    batch_size = max(200, page_limit * 4)
    scan_offset = 0
    seen = 0
    page_rows: list[MediaAsset] = []

    while True:
        chunk = list(db.execute(base_q.limit(batch_size).offset(scan_offset)).scalars().all())
        if not chunk:
            break
        scan_offset += len(chunk)

        for asset in chunk:
            meta = db.get(MediaAssetMeta, asset.id)
            expired = is_expired(asset, meta)
            if only_expired and not expired:
                continue
            if not include_expired and expired:
                continue
            if folder is not _UNSET:
                folder_value = folder if isinstance(folder, str) else None
                if (meta.folder_path if meta else None) != folder_value:
                    continue
            if wanted_tag:
                tags = set(_parse_tags_json(meta.tags_json) if meta else [])
                if wanted_tag not in tags:
                    continue

            if seen >= page_offset and len(page_rows) < page_limit:
                page_rows.append(asset)
            seen += 1

        if len(chunk) < batch_size:
            break

    return {
        "items": page_rows,
        "total": seen,
        "limit": page_limit,
        "offset": page_offset,
        "has_more": (page_offset + len(page_rows)) < seen,
    }


def file_path_for(asset: MediaAsset) -> Path:
    return _storage_path(asset.storage_key)


def delete_asset_file(asset: MediaAsset) -> None:
    path = file_path_for(asset)
    if path.exists():
        os.remove(path)


def _urlsafe_b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _urlsafe_b64decode(raw: str) -> bytes:
    pad = "=" * ((4 - (len(raw) % 4)) % 4)
    return base64.urlsafe_b64decode(raw + pad)


def _media_token_audience() -> str:
    audience = str(getattr(settings, "jwt_audience", "") or "").strip() or "opsatlas-client"
    return f"{audience}:media"


def create_signed_media_token(asset_id: str, *, ttl_seconds: int = 900) -> tuple[str, datetime]:
    ttl = max(30, min(ttl_seconds, 7 * 24 * 3600))
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(seconds=ttl)
    payload = {
        "iss": settings.jwt_issuer,
        "aud": _media_token_audience(),
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "sub": asset_id,
        "scope": "media:file",
    }
    token = jwt.encode(payload, settings.jwt_secret, algorithm="HS256")
    return token, expires_at


def _validate_legacy_signed_media_token(token: str, asset_id: str) -> bool:
    if not token or "." not in token:
        return False
    payload_segment, signature_segment = token.split(".", 1)
    expected_sig = hmac.new(settings.jwt_secret.encode("utf-8"), payload_segment.encode("utf-8"), hashlib.sha256).digest()
    try:
        given_sig = _urlsafe_b64decode(signature_segment)
    except Exception:
        return False
    if not hmac.compare_digest(expected_sig, given_sig):
        return False
    try:
        payload_raw = _urlsafe_b64decode(payload_segment)
        payload = json.loads(payload_raw)
    except Exception:
        return False
    if not isinstance(payload, dict):
        return False
    token_asset_id = payload.get("asset_id")
    exp = payload.get("exp")
    if token_asset_id != asset_id:
        return False
    if not isinstance(exp, int):
        return False
    return exp >= int(time.time())


def validate_signed_media_token(token: str, asset_id: str) -> bool:
    if not token:
        return False
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=["HS256"],
            audience=_media_token_audience(),
            issuer=settings.jwt_issuer,
        )
    except jwt.InvalidTokenError:
        return _validate_legacy_signed_media_token(token, asset_id)

    if not isinstance(payload, dict):
        return False
    return payload.get("sub") == asset_id and payload.get("scope") == "media:file"


def resolve_entity_space_id(db: Session, entity_type: str, entity_id: str) -> str:
    e = entity_type.strip().lower()
    if e == "sop":
        from app.modules.sop.models import Sop

        sop = db.get(Sop, entity_id)
        if not sop:
            raise not_found("SOP not found")
        return sop.space_id
    if e == "doc":
        from app.modules.kb.models import Doc

        doc = db.get(Doc, entity_id)
        if not doc:
            raise not_found("Doc not found")
        return doc.space_id
    if e == "incident":
        from app.modules.incidents.models import Incident

        incident = db.get(Incident, entity_id)
        if not incident:
            raise not_found("Incident not found")
        return incident.space_id
    if e == "sop_step":
        from app.modules.sop.models import Sop, SopStep

        step = db.get(SopStep, entity_id)
        if not step:
            raise not_found("SOP step not found")
        sop = db.get(Sop, step.sop_id)
        if not sop:
            raise not_found("SOP not found")
        return sop.space_id
    if e == "sop_run_step":
        from app.modules.sop.models import Sop, SopRun, SopRunStep

        run_step = db.get(SopRunStep, entity_id)
        if not run_step:
            raise not_found("SOP run step not found")
        run = db.get(SopRun, run_step.run_id)
        if not run:
            raise not_found("SOP run not found")
        sop = db.get(Sop, run.sop_id)
        if not sop:
            raise not_found("SOP not found")
        return sop.space_id
    if e == "incident_timeline":
        from app.modules.incidents.models import Incident, IncidentTimeline

        timeline = db.get(IncidentTimeline, entity_id)
        if not timeline:
            raise not_found("Incident timeline entry not found")
        incident = db.get(Incident, timeline.incident_id)
        if not incident:
            raise not_found("Incident not found")
        return incident.space_id
    if e == "task":
        from app.modules.tasks.models import Task

        task = db.get(Task, entity_id)
        if not task:
            raise not_found("Task not found")
        return task.space_id
    if e == "task_comment":
        from app.modules.tasks.models import Task, TaskComment

        comment = db.get(TaskComment, entity_id)
        if not comment:
            raise not_found("Task comment not found")
        task = db.get(Task, comment.task_id)
        if not task:
            raise not_found("Task not found")
        return task.space_id
    raise bad_request(f"Unsupported entity_type '{entity_type}' for attachments")


def attach_asset_to_entity(
    db: Session,
    *,
    asset: MediaAsset,
    entity_type: str,
    entity_id: str,
    space_id: str,
    attached_by: str,
) -> MediaAttachment:
    normalized_entity = entity_type.strip().lower()
    if normalized_entity not in ATTACHABLE_ENTITY_TYPES:
        raise bad_request(f"Unsupported entity_type '{entity_type}'")
    if asset.space_id and asset.space_id != space_id:
        raise bad_request("Cannot attach a space-scoped asset to a different space")
    existing = db.scalar(
        select(MediaAttachment).where(
            MediaAttachment.asset_id == asset.id,
            MediaAttachment.entity_type == normalized_entity,
            MediaAttachment.entity_id == entity_id,
        )
    )
    if existing:
        return existing
    row = MediaAttachment(
        id=str(uuid.uuid4()),
        asset_id=asset.id,
        space_id=space_id,
        entity_type=normalized_entity,
        entity_id=entity_id,
        attached_by=attached_by,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def detach_asset_from_entity(db: Session, *, asset_id: str, entity_type: str, entity_id: str) -> bool:
    normalized_entity = entity_type.strip().lower()
    row = db.scalar(
        select(MediaAttachment).where(
            MediaAttachment.asset_id == asset_id,
            MediaAttachment.entity_type == normalized_entity,
            MediaAttachment.entity_id == entity_id,
        )
    )
    if not row:
        return False
    db.delete(row)
    db.commit()
    return True


def list_entity_attachments(db: Session, *, entity_type: str, entity_id: str) -> list[MediaAsset]:
    normalized_entity = entity_type.strip().lower()
    q = select(MediaAsset).join(MediaAttachment, MediaAttachment.asset_id == MediaAsset.id).where(MediaAttachment.entity_type == normalized_entity, MediaAttachment.entity_id == entity_id).order_by(MediaAttachment.created_at.desc())
    return list(db.execute(q).scalars().all())


def list_asset_attachments(db: Session, *, asset_id: str) -> list[MediaAttachment]:
    q = select(MediaAttachment).where(MediaAttachment.asset_id == asset_id).order_by(MediaAttachment.created_at.desc())
    return list(db.execute(q).scalars().all())


def extract_asset_ids_from_content(raw_content: str) -> set[str]:
    if not raw_content:
        return set()
    found = _MEDIA_ID_FROM_URL.findall(raw_content)
    return {v.lower() for v in found if v}


def clear_usage_refs(db: Session, *, entity_type: str, entity_id: str, field_name: str | None = None) -> None:
    stmt = delete(MediaUsage).where(MediaUsage.entity_type == entity_type, MediaUsage.entity_id == entity_id)
    if field_name is not None:
        stmt = stmt.where(MediaUsage.field_name == field_name)
    db.execute(stmt)


def sync_usage_refs(
    db: Session,
    *,
    entity_type: str,
    entity_id: str,
    field_name: str,
    content: str,
    space_id: str | None,
) -> None:
    desired_asset_ids = extract_asset_ids_from_content(content)
    existing_rows = list(
        db.execute(
            select(MediaUsage).where(
                MediaUsage.entity_type == entity_type,
                MediaUsage.entity_id == entity_id,
                MediaUsage.field_name == field_name,
            )
        )
        .scalars()
        .all()
    )
    existing_ids = {row.asset_id for row in existing_rows}

    for row in existing_rows:
        if row.asset_id not in desired_asset_ids:
            db.delete(row)

    for asset_id in desired_asset_ids - existing_ids:
        if not db.get(MediaAsset, asset_id):
            continue
        db.add(
            MediaUsage(
                id=str(uuid.uuid4()),
                asset_id=asset_id,
                space_id=space_id,
                entity_type=entity_type,
                entity_id=entity_id,
                field_name=field_name,
            )
        )


def list_asset_usage(db: Session, asset_id: str) -> list[MediaUsage]:
    q = select(MediaUsage).where(MediaUsage.asset_id == asset_id).order_by(MediaUsage.updated_at.desc())
    return list(db.execute(q).scalars().all())


def summarize_assets(
    db: Session,
    *,
    space_id: str | None = None,
    usage: str | None = None,
) -> dict[str, object]:
    q = select(MediaAsset).order_by(MediaAsset.created_at.desc())
    if space_id is not None:
        q = q.where(MediaAsset.space_id == space_id)
    if usage:
        q = q.where(MediaAsset.usage == _sanitize_usage(usage))

    rows = list(db.execute(q).scalars().all())
    folder_counts: Counter[str] = Counter()
    tag_counts: Counter[str] = Counter()
    expired_assets = 0

    for asset in rows:
        meta = db.get(MediaAssetMeta, asset.id)
        if is_expired(asset, meta):
            expired_assets += 1
        if meta and meta.folder_path:
            folder_counts[meta.folder_path] += 1
        for tag in _parse_tags_json(meta.tags_json if meta else None):
            tag_counts[tag] += 1

    folders = [{"value": folder, "count": count} for folder, count in folder_counts.most_common(24)]
    tags = [{"value": tag, "count": count} for tag, count in tag_counts.most_common(36)]
    return {
        "total_assets": len(rows),
        "expired_assets": expired_assets,
        "folders": folders,
        "tags": tags,
    }


def apply_bulk_meta_patch(
    db: Session,
    *,
    assets: list[MediaAsset],
    patch: dict[str, Any],
) -> list[MediaAsset]:
    updated: list[MediaAsset] = []
    for asset in assets:
        apply_meta_patch(db, asset, patch)
        updated.append(asset)
    return updated


def cleanup_expired_assets(
    db: Session,
    *,
    space_id: str | None = None,
    usage: str | None = None,
) -> int:
    q = select(MediaAsset).order_by(MediaAsset.created_at.asc(), MediaAsset.id.asc())
    if space_id is not None:
        q = q.where(MediaAsset.space_id == space_id)
    if usage:
        q = q.where(MediaAsset.usage == _sanitize_usage(usage))
    rows = list(db.execute(q).scalars().all())

    deleted_count = 0
    for asset in rows:
        meta = db.get(MediaAssetMeta, asset.id)
        if not is_expired(asset, meta):
            continue
        delete_asset_file(asset)
        db.execute(delete(MediaAttachment).where(MediaAttachment.asset_id == asset.id))
        db.execute(delete(MediaUsage).where(MediaUsage.asset_id == asset.id))
        if meta is not None:
            db.delete(meta)
        db.delete(asset)
        deleted_count += 1

    if deleted_count:
        db.commit()
    return deleted_count
