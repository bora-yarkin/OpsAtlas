# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for organization administration, branding, and global settings."""

from datetime import datetime
from collections.abc import Sequence
import json
from urllib.parse import quote

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.core.deps import get_db
from app.core.deps import forbidden
from app.modules.auth.deps import (
    get_current_user,
    require_mfa_for_sensitive_action,
    require_role,
    resolve_user_auth_role,
)
from app.modules.auth.schemas import SessionPolicyOut, SessionPolicyUpdateIn
from app.modules.auth import service as auth_service
from app.modules.auth.models import User
from app.modules.localization import service as localization_service
from .models import OrganizationItem, OrganizationItemLink
from .schemas import (
    AdminSpaceCreateIn,
    AdminSpaceDeleteOut,
    BrandingAdminStateOut,
    BrandingHistoryEntryOut,
    AdminSpaceOut,
    AdminSpaceUpdateIn,
    BrandingOut,
    BrandingUpdateIn,
    CustomRoleCreateIn,
    CustomRoleOut,
    OrganizationAuditEventOut,
    OrganizationItemOut,
    OrganizationGraphIntegrityOut,
    OrganizationGraphImportIn,
    OrganizationGraphImportOut,
    OrganizationGraphPackageOut,
    OrganizationItemLinkBulkResultOut,
    OrganizationItemLinkMutationPlanIn,
    OrganizationRoleImpactSimulationIn,
    OrganizationRoleImpactSimulationOut,
    OrganizationWhyAccessOut,
    CustomRoleUpdateIn,
    OrganizationItemLinkCreateIn,
    OrganizationRoleBindingOut,
    OrganizationItemLinkOut,
    OrganizationUnitCreateIn,
    OrganizationUnitOut,
    OrganizationUnitUpdateIn,
    UserCreateIn,
    UserOnboardingTokenOut,
    UserOut,
    UserUpdateIn,
)
from . import service


def _string_or_none(value: object | None) -> str | None:
    return value if isinstance(value, str) else None


def _datetime_or_none(value: object | None) -> datetime | None:
    return value if isinstance(value, datetime) else None


def _meta_from_json(value: object | None) -> dict[str, object] | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        decoded = json.loads(value)
    except Exception:
        return None
    return decoded if isinstance(decoded, dict) else None


def _name_for_user_id(db: Session, user_id: str | None) -> str | None:
    if not user_id:
        return None
    row = db.get(User, user_id)
    if row is None:
        return None
    name = (row.name or "").strip()
    if name:
        return name
    email = (row.email or "").strip()
    return email or None


def _onboarding_url_for_token(token: str) -> str:
    return f"/login?invite_token={quote(token, safe='')}"


def _to_branding_out(payload: dict[str, object | None]) -> BrandingOut:
    return BrandingOut(
        company_name=_string_or_none(payload.get("company_name")),
        application_title=_string_or_none(payload.get("application_title")),
        application_short_name=_string_or_none(payload.get("application_short_name")),
        web_description=_string_or_none(payload.get("web_description")),
        apple_web_app_title=_string_or_none(payload.get("apple_web_app_title")),
        logo_url=_string_or_none(payload.get("logo_url")),
        light_logo_url=_string_or_none(payload.get("light_logo_url")),
        dark_logo_url=_string_or_none(payload.get("dark_logo_url")),
        favicon_url=_string_or_none(payload.get("favicon_url")),
        login_background_url=_string_or_none(payload.get("login_background_url")),
        light_seed_hex=_string_or_none(payload.get("light_seed_hex")),
        dark_accent_hex=_string_or_none(payload.get("dark_accent_hex")),
        dark_bg_hex=_string_or_none(payload.get("dark_bg_hex")),
        browser_theme_hex=_string_or_none(payload.get("browser_theme_hex")),
        install_background_hex=_string_or_none(payload.get("install_background_hex")),
        resolved_app_title=_string_or_none(payload.get("resolved_app_title")) or "OpsAtlas",
        resolved_application_short_name=_string_or_none(payload.get("resolved_application_short_name")) or "OpsAtlas",
        resolved_web_description=_string_or_none(payload.get("resolved_web_description"))
        or "OpsAtlas is a self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work.",
        resolved_apple_web_app_title=_string_or_none(payload.get("resolved_apple_web_app_title")) or "OpsAtlas",
        resolved_theme_color_hex=_string_or_none(payload.get("resolved_theme_color_hex")) or "#0F67E8",
        resolved_install_background_hex=_string_or_none(payload.get("resolved_install_background_hex")) or "#0A0D12",
        updated_at=_datetime_or_none(payload.get("updated_at")),
    )


def _to_branding_history_out(db: Session, payload: dict[str, object]) -> BrandingHistoryEntryOut:
    snapshot = payload.get("snapshot")
    snapshot_payload = snapshot if isinstance(snapshot, dict) else {}
    published_by_user_id = _string_or_none(payload.get("published_by_user_id"))
    return BrandingHistoryEntryOut(
        id=str(payload.get("id") or ""),
        revision_number=int(payload.get("revision_number") or 0),
        source_kind=_string_or_none(payload.get("source_kind")) or "publish",
        source_revision_id=_string_or_none(payload.get("source_revision_id")),
        summary=_string_or_none(payload.get("summary")),
        published_by_user_id=published_by_user_id,
        published_by_name=_name_for_user_id(db, published_by_user_id),
        published_at=_datetime_or_none(payload.get("published_at")),
        snapshot=_to_branding_out(snapshot_payload),
    )


def _to_branding_admin_state_out(db: Session, payload: dict[str, object]) -> BrandingAdminStateOut:
    published = payload.get("published")
    draft = payload.get("draft")
    raw_history = payload.get("history")
    history_rows = raw_history if isinstance(raw_history, list) else []
    return BrandingAdminStateOut(
        published=_to_branding_out(published if isinstance(published, dict) else {}),
        draft=_to_branding_out(draft if isinstance(draft, dict) else {}),
        history=[
            _to_branding_history_out(db, row)
            for row in history_rows
            if isinstance(row, dict)
        ],
        has_unpublished_changes=bool(payload.get("has_unpublished_changes")),
    )


def _to_org_unit_out(
    row,
    *,
    parent_id: str | None = None,
) -> OrganizationUnitOut:
    return OrganizationUnitOut(
        id=row.id,
        name=row.name,
        slug=row.slug,
        unit_type=row.unit_type,
        parent_id=parent_id,
        active=row.active,
        meta=_meta_from_json(getattr(row, "meta_json", None)),
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


def _to_org_item_out(
    row: OrganizationItem,
    *,
    name: str | None = None,
    details: dict[str, object] | None = None,
) -> OrganizationItemOut:
    return OrganizationItemOut(
        id=row.id,
        kind=row.kind,
        entity_id=row.entity_id,
        slug=row.slug,
        name=(name or "").strip() or row.name,
        active=row.active,
        meta=_meta_from_json(row.meta_json),
        details=details,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


def _to_org_item_link_out(
    link,
    *,
    parent_name: str | None,
    child_name: str | None,
) -> OrganizationItemLinkOut:
    return OrganizationItemLinkOut(
        id=link.id,
        parent_kind=link.parent_kind,
        parent_id=link.parent_id,
        parent_name=parent_name,
        child_kind=link.child_kind,
        child_id=link.child_id,
        child_name=child_name,
        grant_role=link.grant_role,
        inherit_to_descendants=link.inherit_to_descendants,
        active=link.active,
        created_at=link.created_at,
        updated_at=link.updated_at,
    )


def _to_org_audit_event_out(
    row,
    *,
    actor_name: str | None,
) -> OrganizationAuditEventOut:
    return OrganizationAuditEventOut(
        id=row.id,
        scope_kind=row.scope_kind,
        action=row.action,
        item_kind=row.item_kind,
        item_id=row.item_id,
        link_parent_kind=row.link_parent_kind,
        link_parent_id=row.link_parent_id,
        link_child_kind=row.link_child_kind,
        link_child_id=row.link_child_id,
        actor_user_id=row.actor_user_id,
        actor_name=actor_name,
        summary=row.summary,
        before=_meta_from_json(row.before_json),
        after=_meta_from_json(row.after_json),
        created_at=row.created_at,
    )


def _item_name_for_kind(db: Session, *, kind: str, item_id: str) -> str | None:
    row = db.get(OrganizationItem, item_id)
    if row is None:
        return None
    return row.name if row.kind == kind else None


def _department_parent_ids_by_child(
    links: Sequence[OrganizationItemLink],
) -> dict[str, list[str]]:
    mapped: dict[str, set[str]] = {}
    for link in links:
        parent_kind = str(getattr(link, "parent_kind", "") or "").strip().lower()
        child_kind = str(getattr(link, "child_kind", "") or "").strip().lower()
        parent_id = str(getattr(link, "parent_id", "") or "").strip()
        child_id = str(getattr(link, "child_id", "") or "").strip()
        if parent_kind != "department" or child_kind != "department" or not parent_id or not child_id:
            continue
        mapped.setdefault(child_id, set()).add(parent_id)
    return {child_id: sorted(parent_ids) for child_id, parent_ids in mapped.items() if parent_ids}


def _primary_department_parent_id(
    *,
    row,
    parent_ids_by_child: dict[str, list[str]],
) -> str | None:
    parent_ids = parent_ids_by_child.get(row.id, [])
    if parent_ids:
        return parent_ids[0]
    return None


def _org_unit_out_from_links(db: Session, row) -> OrganizationUnitOut:
    parent_ids_by_child = _department_parent_ids_by_child(service.list_organization_item_links(db))
    return _to_org_unit_out(
        row,
        parent_id=_primary_department_parent_id(
            row=row,
            parent_ids_by_child=parent_ids_by_child,
        ),
    )


def _build_org_item_details_map(
    db: Session,
    *,
    item_links: Sequence[OrganizationItemLink],
) -> dict[str, dict[str, object]]:
    details_by_item_id: dict[str, dict[str, object]] = {}
    parent_ids_by_child = _department_parent_ids_by_child(item_links)
    user_name_by_id: dict[str, str] = {}

    user_rows = service.list_users(db)
    for user, _, _, _ in user_rows:
        user_name_by_id[user.id] = user.name or user.email

    for user, prefs, change_count, last_change_at in user_rows:
        invited_by_id = (getattr(user, "invited_by_user_id", None) or "").strip()
        details_by_item_id[user.id] = {
            "email": user.email,
            "global_role": resolve_user_auth_role(db, user),
            "is_active": bool(getattr(user, "is_active", True)),
            "must_change_password": bool(getattr(user, "must_change_password", False)),
            "invited_at": getattr(user, "invited_at", None),
            "invite_expires_at": getattr(user, "invite_expires_at", None),
            "invited_by_user_id": invited_by_id or None,
            "invited_by_name": user_name_by_id.get(invited_by_id) if invited_by_id else None,
            "notification_prefs_synced": prefs is not None,
            "notification_prefs_updated_at": None if prefs is None else prefs.updated_at,
            "notification_prefs_change_count": int(change_count or 0),
            "notification_prefs_last_change_at": last_change_at,
        }

    for space, member_count in service.list_spaces(db):
        details_by_item_id[space.id] = {
            "region_code": space.region_code,
            "member_count": member_count,
            "owner_user_id": getattr(space, "owner_user_id", None),
            "owner_name": user_name_by_id.get((getattr(space, "owner_user_id", None) or "").strip()),
        }

    for row in service.list_organization_units(db):
        parent_ids = parent_ids_by_child.get(row.id, [])
        details_by_item_id[row.id] = {
            "unit_type": row.unit_type,
            "parent_id": _primary_department_parent_id(
                row=row,
                parent_ids_by_child=parent_ids_by_child,
            ),
            "parent_ids": parent_ids,
        }

    for role_key in service.BUILTIN_ROLE_ORDER:
        details_by_item_id[role_key] = {
            "role_key": role_key,
            "description": None,
            "effective_level": role_key,
            "built_in": True,
        }

    for role in service.list_custom_roles(db):
        details_by_item_id[role.role_key] = {
            "role_key": role.role_key,
            "description": role.description,
            "effective_level": role.effective_level,
            "built_in": False,
        }

    return details_by_item_id


def _build_item_name_maps(
    db: Session,
    *,
    links: Sequence[OrganizationItemLink],
    user_id: str | None = None,
) -> tuple[dict[str, str], dict[str, str], dict[str, str], dict[str, str]]:
    item_ids: set[str] = set()

    for link in links:
        parent_kind = str(getattr(link, "parent_kind", "") or "").strip().lower()
        parent_id = str(getattr(link, "parent_id", "") or "").strip()
        child_kind = str(getattr(link, "child_kind", "") or "").strip().lower()
        child_id = str(getattr(link, "child_id", "") or "").strip()

        if parent_kind in {"department", "space", "user", "role"} and parent_id:
            item_ids.add(parent_id)
        if child_kind in {"department", "space", "user", "role"} and child_id:
            item_ids.add(child_id)

    rows = db.execute(select(OrganizationItem).where(OrganizationItem.id.in_(sorted(item_ids)))).scalars().all() if item_ids else []

    localized_name_by_kind_and_id: dict[str, dict[str, str]] = {}
    if user_id is not None and rows:
        ids_by_kind: dict[str, list[str]] = {}
        for row in rows:
            normalized_kind = (row.kind or "").strip().lower()
            if normalized_kind not in {"department", "space", "user", "role"}:
                continue
            ids_by_kind.setdefault(normalized_kind, []).append(row.id)

        for kind, ids in ids_by_kind.items():
            localized_fields = localization_service.localized_fields_for_contents(
                db,
                content_kind=f"org_{kind}",
                content_ids=ids,
                field_keys=["name"],
                user_id=user_id,
            )
            localized_name_by_kind_and_id[kind] = {item_id: name for item_id, fields in localized_fields.items() for name in [str(fields.get("name", "")).strip()] if name}

    department_names = {row.id: localized_name_by_kind_and_id.get("department", {}).get(row.id, row.name) for row in rows if row.kind == "department"}
    space_names = {row.id: localized_name_by_kind_and_id.get("space", {}).get(row.id, row.name) for row in rows if row.kind == "space"}
    user_names = {row.id: localized_name_by_kind_and_id.get("user", {}).get(row.id, row.name) for row in rows if row.kind == "user"}
    role_names = {row.id: localized_name_by_kind_and_id.get("role", {}).get(row.id, row.name) for row in rows if row.kind == "role"}

    return department_names, space_names, user_names, role_names


def _item_name_from_maps(
    *,
    kind: str,
    item_id: str,
    department_names: dict[str, str],
    space_names: dict[str, str],
    user_names: dict[str, str],
    role_names: dict[str, str],
) -> str | None:
    if kind == "department":
        return department_names.get(item_id)
    if kind == "space":
        return space_names.get(item_id)
    if kind == "user":
        return user_names.get(item_id)
    if kind == "role":
        return role_names.get(item_id)
    return None


def _require_user_provisioning_actor(
    db: Session = Depends(get_db),
    actor: User = Depends(get_current_user),
) -> User:
    service.ensure_user_provisioning_access(db, actor)
    return require_mfa_for_sensitive_action(user=actor, db=db)


def _require_admin_sensitive_actor(
    db: Session = Depends(get_db),
    actor: User = Depends(require_role("admin")),
) -> User:
    return require_mfa_for_sensitive_action(user=actor, db=db)


router = APIRouter(prefix="/admin", tags=["admin"])


@router.post("/users", response_model=UserOut)
def create_user(
    payload: UserCreateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_user_provisioning_actor),
):
    actor_role = resolve_user_auth_role(db, actor)
    requested_role = (payload.global_role or "member").strip().lower()
    if actor_role != "admin" and requested_role in {"admin", "moderator"}:
        raise forbidden("Only admins can assign elevated global roles")
    u = service.create_user(
        db,
        email=payload.email,
        name=payload.name,
        password=payload.password,
        global_role=payload.global_role,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    return UserOut(
        id=u.id,
        email=u.email,
        name=u.name,
        global_role=resolve_user_auth_role(db, u),
        is_active=bool(getattr(u, "is_active", True)),
        must_change_password=bool(getattr(u, "must_change_password", False)),
        invited_at=getattr(u, "invited_at", None),
        invite_expires_at=getattr(u, "invite_expires_at", None),
        meta=_meta_from_json(u.meta_json),
    )


@router.put("/users/{user_id}", response_model=UserOut)
def update_user(
    user_id: str,
    payload: UserUpdateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_user_provisioning_actor),
):
    actor_role = resolve_user_auth_role(db, actor)
    if payload.global_role is not None:
        requested_role = payload.global_role.strip().lower()
        if actor_role != "admin" and requested_role in {"admin", "moderator"}:
            raise forbidden("Only admins can assign elevated global roles")
    u = service.update_user(
        db,
        user_id,
        email=payload.email,
        name=payload.name,
        password=payload.password,
        global_role=payload.global_role,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    return UserOut(
        id=u.id,
        email=u.email,
        name=u.name,
        global_role=resolve_user_auth_role(db, u),
        is_active=bool(getattr(u, "is_active", True)),
        must_change_password=bool(getattr(u, "must_change_password", False)),
        invited_at=getattr(u, "invited_at", None),
        invite_expires_at=getattr(u, "invite_expires_at", None),
        meta=_meta_from_json(u.meta_json),
    )


@router.post("/users/{user_id}/invite", response_model=UserOnboardingTokenOut)
def invite_user(
    user_id: str,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_user_provisioning_actor),
):
    user, onboarding_token, expires_at = service.invite_user(
        db,
        user_id=user_id,
        actor_user_id=actor.id,
    )
    return UserOnboardingTokenOut(
        user_id=user.id,
        email=user.email,
        onboarding_token=onboarding_token,
        onboarding_url=_onboarding_url_for_token(onboarding_token),
        expires_at=expires_at,
    )


@router.post("/users/{user_id}/password-reset", response_model=UserOnboardingTokenOut)
def reset_user_password(
    user_id: str,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_user_provisioning_actor),
):
    user, onboarding_token, expires_at = service.reset_user_password(
        db,
        user_id=user_id,
        actor_user_id=actor.id,
    )
    return UserOnboardingTokenOut(
        user_id=user.id,
        email=user.email,
        onboarding_token=onboarding_token,
        onboarding_url=_onboarding_url_for_token(onboarding_token),
        expires_at=expires_at,
    )


@router.post("/users/{user_id}/activate", response_model=UserOut)
def activate_user(
    user_id: str,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_user_provisioning_actor),
):
    user = service.set_user_active_state(
        db,
        user_id=user_id,
        active=True,
        actor_user_id=actor.id,
    )
    return UserOut(
        id=user.id,
        email=user.email,
        name=user.name,
        global_role=resolve_user_auth_role(db, user),
        is_active=bool(getattr(user, "is_active", True)),
        must_change_password=bool(getattr(user, "must_change_password", False)),
        invited_at=getattr(user, "invited_at", None),
        invite_expires_at=getattr(user, "invite_expires_at", None),
        meta=_meta_from_json(user.meta_json),
    )


@router.post("/users/{user_id}/deactivate", response_model=UserOut)
def deactivate_user(
    user_id: str,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_user_provisioning_actor),
):
    user = service.set_user_active_state(
        db,
        user_id=user_id,
        active=False,
        actor_user_id=actor.id,
    )
    return UserOut(
        id=user.id,
        email=user.email,
        name=user.name,
        global_role=resolve_user_auth_role(db, user),
        is_active=bool(getattr(user, "is_active", True)),
        must_change_password=bool(getattr(user, "must_change_password", False)),
        invited_at=getattr(user, "invited_at", None),
        invite_expires_at=getattr(user, "invite_expires_at", None),
        meta=_meta_from_json(user.meta_json),
    )


@router.post("/spaces", response_model=AdminSpaceOut)
def create_space(payload: AdminSpaceCreateIn, db: Session = Depends(get_db), user: User = Depends(require_role("admin"))):
    owner_user_id = payload.owner_user_id or user.id
    s = service.create_space(
        db,
        payload.name,
        payload.slug,
        owner_user_id,
        region_code=payload.region_code,
        meta=payload.meta,
        actor_user_id=user.id,
    )
    link_count = service.count_space_item_links(db, s.id)
    localized_fields = localization_service.localized_fields_for_content(
        db,
        content_kind="org_space",
        content_id=s.id,
        field_keys=["name"],
        user_id=user.id,
    )
    localized_name = str(localized_fields.get("name", "")).strip()
    return AdminSpaceOut(
        id=s.id,
        name=localized_name or s.name,
        slug=s.slug,
        owner_user_id=s.owner_user_id,
        owner_name=_name_for_user_id(db, s.owner_user_id),
        region_code=s.region_code,
        meta=_meta_from_json(s.meta_json),
        member_count=link_count,
        created_at=s.created_at,
    )


@router.put("/spaces/{space_id}", response_model=AdminSpaceOut)
def update_space(
    space_id: str,
    payload: AdminSpaceUpdateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(require_role("admin")),
):
    s = service.update_space(
        db,
        space_id,
        name=payload.name,
        slug=payload.slug,
        owner_user_id=payload.owner_user_id,
        owner_user_id_provided="owner_user_id" in payload.model_fields_set,
        region_code=payload.region_code,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    link_count = service.count_space_item_links(db, s.id)
    localized_fields = localization_service.localized_fields_for_content(
        db,
        content_kind="org_space",
        content_id=s.id,
        field_keys=["name"],
        user_id=actor.id,
    )
    localized_name = str(localized_fields.get("name", "")).strip()
    return AdminSpaceOut(
        id=s.id,
        name=localized_name or s.name,
        slug=s.slug,
        owner_user_id=s.owner_user_id,
        owner_name=_name_for_user_id(db, s.owner_user_id),
        region_code=s.region_code,
        meta=_meta_from_json(s.meta_json),
        member_count=link_count,
        created_at=s.created_at,
    )


@router.delete("/spaces/{space_id}", response_model=AdminSpaceDeleteOut)
def delete_space(
    space_id: str,
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    service.delete_space(db, space_id)
    return AdminSpaceDeleteOut(ok=True, deleted_space_id=space_id)


@router.post("/custom-roles", response_model=CustomRoleOut)
def create_custom_role(
    payload: CustomRoleCreateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    r = service.create_custom_role(
        db,
        role_key=payload.role_key,
        name=payload.name,
        description=payload.description,
        effective_level=payload.effective_level,
        active=payload.active,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    return CustomRoleOut(
        id=r.id,
        role_key=r.role_key,
        name=r.name,
        description=r.description,
        effective_level=r.effective_level,
        active=r.active,
        meta=_meta_from_json(r.meta_json),
        created_at=r.created_at,
        updated_at=r.updated_at,
    )


@router.put("/custom-roles/{role_key}", response_model=CustomRoleOut)
def update_custom_role(
    role_key: str,
    payload: CustomRoleUpdateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    r = service.update_custom_role(
        db,
        role_key,
        name=payload.name,
        description=payload.description,
        effective_level=payload.effective_level,
        active=payload.active,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    return CustomRoleOut(
        id=r.id,
        role_key=r.role_key,
        name=r.name,
        description=r.description,
        effective_level=r.effective_level,
        active=r.active,
        meta=_meta_from_json(r.meta_json),
        created_at=r.created_at,
        updated_at=r.updated_at,
    )


@router.delete("/custom-roles/{role_key}")
def delete_custom_role(
    role_key: str,
    db: Session = Depends(get_db),
    _user: User = Depends(_require_admin_sensitive_actor),
):
    service.delete_custom_role(db, role_key)
    return {"ok": True}


@router.get("/org/items", response_model=list[OrganizationItemOut])
def list_org_items(
    db: Session = Depends(get_db),
    user: User = Depends(require_role("admin")),
):
    item_links = service.list_organization_item_links(db)
    details_by_item_id = _build_org_item_details_map(db, item_links=item_links)
    rows = service.list_organization_items(db)
    localized_name_by_id: dict[str, str] = {}
    ids_by_kind: dict[str, list[str]] = {}
    for row in rows:
        normalized_kind = (row.kind or "").strip().lower()
        if normalized_kind not in {"department", "space", "user", "role"}:
            continue
        ids_by_kind.setdefault(normalized_kind, []).append(row.id)

    for kind, ids in ids_by_kind.items():
        localized_fields = localization_service.localized_fields_for_contents(
            db,
            content_kind=f"org_{kind}",
            content_ids=ids,
            field_keys=["name"],
            user_id=user.id,
        )
        for item_id, fields in localized_fields.items():
            localized_name = str(fields.get("name", "")).strip()
            if localized_name:
                localized_name_by_id[item_id] = localized_name

    return [
        _to_org_item_out(
            row,
            name=localized_name_by_id.get(row.id),
            details=details_by_item_id.get(row.id),
        )
        for row in rows
    ]


@router.get("/org/why-access", response_model=OrganizationWhyAccessOut)
def explain_org_access(
    user_id: str = Query(min_length=1),
    space_id: str = Query(min_length=1),
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    return service.explain_user_space_access(
        db,
        user_id=user_id,
        space_id=space_id,
    )


@router.post("/org/role-impact/simulate", response_model=OrganizationRoleImpactSimulationOut)
def simulate_org_role_impact(
    payload: OrganizationRoleImpactSimulationIn,
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    return service.simulate_organization_role_impact(
        db,
        global_role_changes=[entry.model_dump() for entry in payload.global_role_changes],
        space_grant_changes=[entry.model_dump() for entry in payload.space_grant_changes],
        space_grant_removals=[entry.model_dump() for entry in payload.space_grant_removals],
    )


@router.post("/org/units", response_model=OrganizationUnitOut)
def create_org_unit(
    payload: OrganizationUnitCreateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(require_role("admin")),
):
    row = service.create_organization_unit(
        db,
        name=payload.name,
        slug=payload.slug,
        unit_type=payload.unit_type,
        parent_id=payload.parent_id,
        active=payload.active,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    return _org_unit_out_from_links(db, row)


@router.put("/org/units/{org_unit_id}", response_model=OrganizationUnitOut)
def update_org_unit(
    org_unit_id: str,
    payload: OrganizationUnitUpdateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(require_role("admin")),
):
    row = service.update_organization_unit(
        db,
        org_unit_id,
        name=payload.name,
        slug=payload.slug,
        unit_type=payload.unit_type,
        parent_id=payload.parent_id,
        parent_id_provided="parent_id" in payload.model_fields_set,
        active=payload.active,
        meta=payload.meta,
        actor_user_id=actor.id,
    )
    return _org_unit_out_from_links(db, row)


@router.delete("/org/units/{org_unit_id}")
def delete_org_unit(
    org_unit_id: str,
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    service.delete_organization_unit(db, org_unit_id)
    return {"ok": True, "deleted_org_unit_id": org_unit_id}


@router.get("/org/item-links", response_model=list[OrganizationItemLinkOut])
def list_org_item_links(
    db: Session = Depends(get_db),
    user: User = Depends(require_role("admin")),
):
    rows = service.list_organization_item_links(db)
    department_names, space_names, user_names, role_names = _build_item_name_maps(
        db,
        links=rows,
        user_id=user.id,
    )
    return [
        _to_org_item_link_out(
            link,
            parent_name=_item_name_from_maps(
                kind=(link.parent_kind or "").strip().lower(),
                item_id=link.parent_id,
                department_names=department_names,
                space_names=space_names,
                user_names=user_names,
                role_names=role_names,
            ),
            child_name=_item_name_from_maps(
                kind=(link.child_kind or "").strip().lower(),
                item_id=link.child_id,
                department_names=department_names,
                space_names=space_names,
                user_names=user_names,
                role_names=role_names,
            ),
        )
        for link in rows
    ]


@router.post("/org/item-links", response_model=OrganizationItemLinkOut)
def create_org_item_link(
    payload: OrganizationItemLinkCreateIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    link = service.create_organization_item_link(
        db,
        parent_kind=payload.parent_kind,
        parent_id=payload.parent_id,
        child_kind=payload.child_kind,
        child_id=payload.child_id,
        grant_role=payload.grant_role,
        inherit_to_descendants=payload.inherit_to_descendants,
        active=payload.active,
        actor_user_id=actor.id,
    )
    return _to_org_item_link_out(
        link,
        parent_name=_item_name_for_kind(
            db,
            kind=(link.parent_kind or "").strip().lower(),
            item_id=link.parent_id,
        ),
        child_name=_item_name_for_kind(
            db,
            kind=(link.child_kind or "").strip().lower(),
            item_id=link.child_id,
        ),
    )


@router.delete("/org/item-links/{link_id}")
def delete_org_item_link(
    link_id: str,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    service.delete_organization_item_link(db, link_id, actor_user_id=actor.id)
    return {"ok": True, "deleted_link_id": link_id}


@router.post("/org/item-links/bulk/preview", response_model=OrganizationItemLinkBulkResultOut)
def preview_org_item_link_bulk_mutation(
    payload: OrganizationItemLinkMutationPlanIn,
    db: Session = Depends(get_db),
    actor: User = Depends(require_role("admin")),
):
    return service.bulk_mutate_organization_item_links(
        db,
        links=[entry.model_dump() for entry in payload.link],
        unlinks=[entry.model_dump() for entry in payload.unlink],
        rebind_roles=[entry.model_dump() for entry in payload.rebind_roles],
        dry_run=True,
        actor_user_id=actor.id,
    )


@router.post("/org/item-links/bulk/mutate", response_model=OrganizationItemLinkBulkResultOut)
def mutate_org_item_link_bulk(
    payload: OrganizationItemLinkMutationPlanIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    return service.bulk_mutate_organization_item_links(
        db,
        links=[entry.model_dump() for entry in payload.link],
        unlinks=[entry.model_dump() for entry in payload.unlink],
        rebind_roles=[entry.model_dump() for entry in payload.rebind_roles],
        dry_run=bool(payload.dry_run),
        actor_user_id=actor.id,
    )


@router.get("/org/graph/integrity", response_model=OrganizationGraphIntegrityOut)
def get_org_graph_integrity(
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    return service.validate_organization_graph_integrity(db)


@router.post("/org/graph/export", response_model=OrganizationGraphPackageOut)
def export_org_graph(
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    payload = service.export_organization_graph_package(db, actor_user_id=actor.id)
    item_rows = payload.get("items", [])
    link_rows = payload.get("links", [])
    role_binding_rows = payload.get("role_bindings", [])

    if not isinstance(item_rows, list):
        item_rows = []
    if not isinstance(link_rows, list):
        link_rows = []
    if not isinstance(role_binding_rows, list):
        role_binding_rows = []

    return OrganizationGraphPackageOut(
        version=str(payload.get("version", "1.0")),
        exported_at=payload.get("exported_at"),
        metadata=payload.get("metadata") if isinstance(payload.get("metadata"), dict) else None,
        items=[
            OrganizationItemOut(
                id=str(row.get("id", "")),
                kind=str(row.get("kind", "")),
                entity_id=(str(row.get("entity_id")) if row.get("entity_id") is not None else None),
                slug=(str(row.get("slug")) if row.get("slug") is not None else None),
                name=str(row.get("name", "")),
                active=bool(row.get("active", False)),
                meta=row.get("meta") if isinstance(row.get("meta"), dict) else None,
                details=None,
                created_at=row.get("created_at"),
                updated_at=row.get("updated_at"),
            )
            for row in item_rows
            if isinstance(row, dict)
        ],
        links=[
            OrganizationItemLinkOut(
                id=str(row.get("id", "")),
                parent_kind=str(row.get("parent_kind", "")),
                parent_id=str(row.get("parent_id", "")),
                parent_name=None,
                child_kind=str(row.get("child_kind", "")),
                child_id=str(row.get("child_id", "")),
                child_name=None,
                grant_role=str(row.get("grant_role", "")),
                inherit_to_descendants=bool(row.get("inherit_to_descendants", False)),
                active=bool(row.get("active", False)),
                created_at=row.get("created_at"),
                updated_at=row.get("updated_at"),
            )
            for row in link_rows
            if isinstance(row, dict)
        ],
        role_bindings=[
            OrganizationRoleBindingOut(
                user_id=str(row.get("user_id", "")),
                role_key=str(row.get("role_key", "")),
                source=str(row.get("source", "item_link")),
            )
            for row in role_binding_rows
            if isinstance(row, dict)
        ],
    )


@router.post("/org/graph/import", response_model=OrganizationGraphImportOut)
def import_org_graph(
    payload: OrganizationGraphImportIn,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    return service.import_organization_graph_package(
        db,
        package=payload.package,
        dry_run=bool(payload.dry_run),
        actor_user_id=actor.id,
    )


@router.get("/org/audit", response_model=list[OrganizationAuditEventOut])
def list_org_audit_events(
    item_kind: str | None = Query(default=None),
    item_id: str | None = Query(default=None),
    limit: int = Query(default=120, ge=1, le=500),
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    rows = service.list_organization_audit_events(
        db,
        item_kind=item_kind,
        item_id=item_id,
        limit=limit,
    )
    actor_ids = sorted({actor_id for actor_id in (row.actor_user_id for row in rows) if isinstance(actor_id, str) and actor_id.strip()})
    actor_name_by_id: dict[str, str] = {}
    if actor_ids:
        users = db.execute(select(User).where(User.id.in_(actor_ids))).scalars().all()
        actor_name_by_id = {user.id: user.name or user.email for user in users if isinstance(user.id, str) and user.id}
    return [
        _to_org_audit_event_out(
            row,
            actor_name=actor_name_by_id.get((row.actor_user_id or "").strip()),
        )
        for row in rows
    ]


@router.get("/customization", response_model=BrandingAdminStateOut)
def get_customization(db: Session = Depends(get_db), _user: User = Depends(require_role("admin"))):
    return _to_branding_admin_state_out(db, service.get_branding_admin_state(db))


@router.put("/customization", response_model=BrandingAdminStateOut)
def update_customization(
    payload: BrandingUpdateIn,
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    service.update_branding(
        db,
        company_name=payload.company_name,
        application_title=payload.application_title,
        application_short_name=payload.application_short_name,
        web_description=payload.web_description,
        apple_web_app_title=payload.apple_web_app_title,
        logo_url=payload.logo_url,
        light_logo_url=payload.light_logo_url,
        dark_logo_url=payload.dark_logo_url,
        favicon_url=payload.favicon_url,
        login_background_url=payload.login_background_url,
        light_seed_hex=payload.light_seed_hex,
        dark_accent_hex=payload.dark_accent_hex,
        dark_bg_hex=payload.dark_bg_hex,
        browser_theme_hex=payload.browser_theme_hex,
        install_background_hex=payload.install_background_hex,
    )
    return _to_branding_admin_state_out(db, service.get_branding_admin_state(db))


@router.post("/customization/discard-draft", response_model=BrandingAdminStateOut)
def discard_customization_draft(
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    service.discard_branding_draft(db)
    return _to_branding_admin_state_out(db, service.get_branding_admin_state(db))


@router.post("/customization/publish", response_model=BrandingAdminStateOut)
def publish_customization(
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    service.publish_branding_draft(db, actor_user_id=actor.id)
    return _to_branding_admin_state_out(db, service.get_branding_admin_state(db))


@router.post("/customization/rollback/{revision_id}", response_model=BrandingAdminStateOut)
def rollback_customization(
    revision_id: str,
    db: Session = Depends(get_db),
    actor: User = Depends(_require_admin_sensitive_actor),
):
    service.rollback_branding_revision(db, revision_id=revision_id, actor_user_id=actor.id)
    return _to_branding_admin_state_out(db, service.get_branding_admin_state(db))


@router.get("/session-policy", response_model=SessionPolicyOut)
def get_session_policy(
    db: Session = Depends(get_db),
    _user: User = Depends(require_role("admin")),
):
    return auth_service.get_session_policy(db)


@router.patch("/session-policy", response_model=SessionPolicyOut)
def update_session_policy(
    payload: SessionPolicyUpdateIn,
    db: Session = Depends(get_db),
    _user: User = Depends(_require_admin_sensitive_actor),
):
    return auth_service.update_session_policy(
        db,
        allow_remember_device=payload.allow_remember_device,
        apply_allow_remember_device="allow_remember_device" in payload.model_fields_set,
        default_profile=payload.default_profile,
        apply_default_profile="default_profile" in payload.model_fields_set,
        this_browser_days=payload.this_browser_days,
        apply_this_browser_days="this_browser_days" in payload.model_fields_set,
        remember_device_days=payload.remember_device_days,
        apply_remember_device_days="remember_device_days" in payload.model_fields_set,
        warning_minutes=payload.warning_minutes,
        apply_warning_minutes="warning_minutes" in payload.model_fields_set,
    )
