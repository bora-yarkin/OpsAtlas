# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for media upload, listing, and asset lifecycle operations."""

import json

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile
from fastapi.responses import FileResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import InvalidTokenError
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.deps import get_db
from app.core.deps import bad_request, forbidden, not_found
from app.core.auth.security import decode_token
from app.modules.auth.models import User
from app.modules.auth.deps import get_current_user, hydrate_user_auth_context, user_is_admin
from app.modules.spaces import service as spaces_service

from .models import MediaAsset
from .schemas import (
    MediaAssetOut,
    MediaAttachmentIn,
    MediaBulkMetaUpdateIn,
    MediaMetaUpdateIn,
    MediaPageOut,
    MediaSignedUrlOut,
    MediaSummaryOut,
    MediaUploadPolicyOut,
    MediaUsageOut,
)
from .service import (
    ACCESS_PUBLIC,
    apply_meta_patch,
    apply_bulk_meta_patch,
    attach_asset_to_entity,
    can_read_asset,
    cleanup_expired_assets,
    create_asset,
    create_signed_media_token,
    detach_asset_from_entity,
    file_path_for,
    get_asset,
    get_asset_meta,
    get_upload_policy,
    is_inline_safe_media,
    is_expired,
    list_asset_usage,
    list_assets,
    list_assets_page,
    summarize_assets,
    list_entity_attachments,
    media_expires_at,
    read_access_mode,
    require_manage_asset,
    require_read_asset,
    resolve_entity_space_id,
    validate_signed_media_token,
)

router = APIRouter(prefix="/media", tags=["media"])
_optional_bearer = HTTPBearer(auto_error=False)


def _asset_url(request: Request, asset_id: str, *, token: str | None = None) -> str:
    url = f"{request.base_url}media/{asset_id}/file"
    if token:
        return f"{url}?token={token}"
    return url


def _parse_tags(tags_raw: str | None) -> list[str] | None:
    if tags_raw is None:
        return None
    stripped = tags_raw.strip()
    if not stripped:
        return []
    if stripped.startswith("["):
        try:
            decoded = json.loads(stripped)
            if isinstance(decoded, list):
                return [str(v) for v in decoded]
        except json.JSONDecodeError:
            pass
    return [part.strip() for part in stripped.split(",") if part.strip()]


def _meta_tags(meta_json: str | None) -> list[str]:
    if not meta_json:
        return []
    try:
        value = json.loads(meta_json)
    except json.JSONDecodeError:
        return []
    if not isinstance(value, list):
        return []
    return [str(v) for v in value if isinstance(v, str)]


def _as_int(value: object | None, *, default: int = 0) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        stripped = value.strip()
        if stripped:
            try:
                return int(stripped)
            except ValueError:
                return default
    return default


def _as_bool(value: object | None, *, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default


def _page_items(value: object | None) -> list[MediaAsset]:
    if not isinstance(value, list):
        return []
    out: list[MediaAsset] = []
    for item in value:
        if isinstance(item, MediaAsset):
            out.append(item)
    return out


def _to_out(request: Request, db: Session, asset: MediaAsset) -> MediaAssetOut:
    meta = get_asset_meta(db, asset.id)
    access_mode = read_access_mode(asset, meta)
    url = _asset_url(request, asset.id)
    if access_mode != ACCESS_PUBLIC:
        token, _ = create_signed_media_token(asset.id, ttl_seconds=settings.media_token_ttl_seconds)
        url = _asset_url(request, asset.id, token=token)
    return MediaAssetOut(
        id=asset.id,
        owner_user_id=asset.owner_user_id,
        space_id=asset.space_id,
        usage=asset.usage,
        original_filename=asset.original_filename,
        content_type=asset.content_type,
        size_bytes=asset.size_bytes,
        access_mode=access_mode,
        folder_path=meta.folder_path if meta else None,
        tags=_meta_tags(meta.tags_json if meta else None),
        retention_days=meta.retention_days if meta else None,
        expires_at=media_expires_at(asset, meta),
        url=url,
        created_at=asset.created_at,
    )


def _optional_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_optional_bearer),
    db: Session = Depends(get_db),
) -> User | None:
    if not creds:
        return None
    try:
        payload = decode_token(creds.credentials)
    except InvalidTokenError:
        return None
    sub = payload.get("sub")
    if not isinstance(sub, str) or not sub:
        return None
    return hydrate_user_auth_context(db, db.get(User, sub))


@router.post("/upload", response_model=MediaAssetOut)
async def upload_media(
    request: Request,
    file: UploadFile = File(...),
    space_id: str | None = Form(default=None),
    usage: str = Form(default="general"),
    access_mode: str | None = Form(default=None),
    folder_path: str | None = Form(default=None),
    tags: str | None = Form(default=None),
    retention_days: int | None = Form(default=None),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if space_id:
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    data = await file.read()
    asset = create_asset(
        db,
        owner_user_id=user.id,
        space_id=space_id,
        usage=usage,
        original_filename=file.filename or "upload.bin",
        content_type=file.content_type,
        data=data,
        access_mode=access_mode,
        folder_path=folder_path,
        tags=_parse_tags(tags),
        retention_days=retention_days,
    )
    return _to_out(request, db, asset)


@router.get("/policy", response_model=MediaUploadPolicyOut)
def media_upload_policy(user: User = Depends(get_current_user)):
    del user
    return get_upload_policy()


@router.get("", response_model=list[MediaAssetOut])
def media_list(
    request: Request,
    space_id: str | None = None,
    usage: str | None = None,
    folder_path: str | None = None,
    tag: str | None = None,
    limit: int = 30,
    include_expired: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if space_id:
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    elif not user_is_admin(user):
        raise forbidden("Admin role required for global media listing")

    rows = list_assets(
        db,
        space_id=space_id,
        usage=usage,
        folder_path=folder_path,
        tag=tag,
        limit=limit,
        include_expired=include_expired,
    )
    visible = [asset for asset in rows if can_read_asset(db, user, asset)]
    return [_to_out(request, db, row) for row in visible]


@router.get("/page", response_model=MediaPageOut)
def media_list_page(
    request: Request,
    space_id: str | None = None,
    usage: str | None = None,
    folder_path: str | None = None,
    tag: str | None = None,
    limit: int = 50,
    offset: int = 0,
    include_expired: bool = False,
    only_expired: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if space_id:
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    elif not user_is_admin(user):
        raise forbidden("Admin role required for global media listing")

    page = list_assets_page(
        db,
        space_id=space_id,
        usage=usage,
        folder_path=folder_path,
        tag=tag,
        limit=limit,
        offset=offset,
        include_expired=include_expired,
        only_expired=only_expired,
    )
    page_items = _page_items(page.get("items"))
    visible = [asset for asset in page_items if can_read_asset(db, user, asset)]
    return MediaPageOut(
        items=[_to_out(request, db, row) for row in visible],
        total=_as_int(page.get("total")),
        limit=_as_int(page.get("limit"), default=50),
        offset=_as_int(page.get("offset")),
        has_more=_as_bool(page.get("has_more")),
    )


@router.get("/summary", response_model=MediaSummaryOut)
def media_summary(
    space_id: str | None = None,
    usage: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if space_id:
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    elif not user_is_admin(user):
        raise forbidden("Admin role required for global media summary")
    return summarize_assets(db, space_id=space_id, usage=usage)


@router.get("/attachments", response_model=list[MediaAssetOut])
def list_attachments(
    request: Request,
    entity_type: str,
    entity_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    space_id = resolve_entity_space_id(db, entity_type, entity_id)
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = list_entity_attachments(db, entity_type=entity_type, entity_id=entity_id)
    return [_to_out(request, db, row) for row in rows if can_read_asset(db, user, row)]


@router.post("/{asset_id}/attachments", response_model=MediaAssetOut)
def attach_media(
    asset_id: str,
    payload: MediaAttachmentIn,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    asset = get_asset(db, asset_id)
    if not asset:
        raise not_found("Media asset not found")
    if is_expired(asset, get_asset_meta(db, asset.id)):
        raise bad_request("Cannot attach expired media asset")
    space_id = resolve_entity_space_id(db, payload.entity_type, payload.entity_id)
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    if not can_read_asset(db, user, asset):
        raise forbidden("Cannot attach media you cannot access")
    attach_asset_to_entity(
        db,
        asset=asset,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        space_id=space_id,
        attached_by=user.id,
    )
    return _to_out(request, db, asset)


@router.delete("/{asset_id}/attachments")
def detach_media(
    asset_id: str,
    entity_type: str,
    entity_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    asset = get_asset(db, asset_id)
    if not asset:
        raise not_found("Media asset not found")
    space_id = resolve_entity_space_id(db, entity_type, entity_id)
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    detached = detach_asset_from_entity(db, asset_id=asset_id, entity_type=entity_type, entity_id=entity_id)
    return {"ok": detached}


@router.patch("/{asset_id}/meta", response_model=MediaAssetOut)
def patch_media_meta(
    asset_id: str,
    payload: MediaMetaUpdateIn,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    asset = get_asset(db, asset_id)
    if not asset:
        raise not_found("Media asset not found")
    require_manage_asset(db, user, asset)
    patch_data = payload.model_dump(exclude_unset=True)
    apply_meta_patch(db, asset, patch_data)
    return _to_out(request, db, asset)


@router.post("/bulk-meta", response_model=list[MediaAssetOut])
def bulk_patch_media_meta(
    payload: MediaBulkMetaUpdateIn,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    patch_data = payload.model_dump(exclude_unset=True)
    patch_data.pop("asset_ids", None)
    clear_folder = bool(patch_data.pop("clear_folder_path", False))
    clear_tags = bool(patch_data.pop("clear_tags", False))
    clear_retention = bool(patch_data.pop("clear_retention_days", False))

    if clear_folder:
        patch_data["folder_path"] = None
    if clear_tags:
        patch_data["tags"] = []
    if clear_retention:
        patch_data["retention_days"] = None
    if not patch_data:
        raise bad_request("At least one metadata field is required")

    assets: list[MediaAsset] = []
    seen: set[str] = set()
    for asset_id in payload.asset_ids:
        normalized = asset_id.strip()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        asset = get_asset(db, normalized)
        if not asset:
            raise not_found(f"Media asset not found: {normalized}")
        require_manage_asset(db, user, asset)
        assets.append(asset)

    updated = apply_bulk_meta_patch(db, assets=assets, patch=patch_data)
    return [_to_out(request, db, asset) for asset in updated]


@router.post("/cleanup")
def cleanup_media(
    space_id: str | None = None,
    usage: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    if space_id:
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    elif not user_is_admin(user):
        raise forbidden("Admin role required for global media cleanup")
    deleted_count = cleanup_expired_assets(db, space_id=space_id, usage=usage)
    return {"deleted_count": deleted_count}


@router.get("/{asset_id}/usage", response_model=list[MediaUsageOut])
def media_usage(asset_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    asset = get_asset(db, asset_id)
    if not asset:
        raise not_found("Media asset not found")
    require_read_asset(db, user, asset)
    rows = list_asset_usage(db, asset_id)
    visible: list[MediaUsageOut] = []
    for row in rows:
        if row.space_id and not can_read_asset(db, user, asset):
            continue
        visible.append(
            MediaUsageOut(
                asset_id=row.asset_id,
                entity_type=row.entity_type,
                entity_id=row.entity_id,
                field_name=row.field_name,
                space_id=row.space_id,
                updated_at=row.updated_at,
            )
        )
    return visible


@router.get("/{asset_id}/signed-url", response_model=MediaSignedUrlOut)
def get_signed_url(
    request: Request,
    asset_id: str,
    ttl_seconds: int = 900,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    asset = get_asset(db, asset_id)
    if not asset:
        raise not_found("Media asset not found")
    require_read_asset(db, user, asset)
    token, expires_at = create_signed_media_token(asset_id, ttl_seconds=ttl_seconds)
    return MediaSignedUrlOut(url=_asset_url(request, asset_id, token=token), expires_at=expires_at)


@router.get("/{asset_id}/file")
def media_file(
    asset_id: str,
    token: str | None = None,
    db: Session = Depends(get_db),
    user: User | None = Depends(_optional_current_user),
):
    asset = get_asset(db, asset_id)
    if not asset:
        raise not_found("Media asset not found")
    signed_ok = bool(token and validate_signed_media_token(token, asset_id))
    require_read_asset(db, user, asset, signed_ok=signed_ok)
    path = file_path_for(asset)
    if not path.exists():
        raise not_found("Media file not found on disk")
    response = FileResponse(
        path,
        media_type=asset.content_type or "application/octet-stream",
        filename=asset.original_filename,
    )
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Cross-Origin-Resource-Policy", "same-site")
    if not is_inline_safe_media(asset):
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'none'; frame-ancestors 'none'; sandbox",
        )
        response.headers.setdefault("Cache-Control", "no-store")
    return response
