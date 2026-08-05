# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for backup snapshot creation, browsing, and export operations."""

from fastapi import APIRouter, Depends
from app.modules.auth.deps import require_mfa_for_sensitive_action, require_role
from app.modules.auth.models import User
from .service import backup_service

router = APIRouter(prefix="/admin/backups", tags=["backups"])


@router.get("/snapshots")
def snapshots(_user: User = Depends(require_role("admin", "moderator"))):
    return backup_service.list_snapshots()


@router.post("/snapshots")
def create_snapshot(
    mode: str = "full",
    _user: User = Depends(require_role("admin")),
    _mfa_user: User = Depends(require_mfa_for_sensitive_action),
):
    return backup_service.create_snapshot(mode=mode)


@router.get("/snapshots/{snapshot_id}/tree")
def tree(snapshot_id: str, path: str = "/", _user: User = Depends(require_role("admin", "moderator"))):
    return backup_service.tree(snapshot_id=snapshot_id, path=path)


@router.get("/snapshots/{snapshot_id}/node")
def node(snapshot_id: str, path: str, _user: User = Depends(require_role("admin", "moderator"))):
    return backup_service.node(snapshot_id=snapshot_id, path=path)
