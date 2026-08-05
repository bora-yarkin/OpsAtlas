# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for organization administration, branding, and audit behavior."""

import json
import re
import uuid
from collections import defaultdict
from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from sqlalchemy import and_, delete, func, or_, select
from sqlalchemy.orm import Session

from app.core.db import Base
from app.core.deps import bad_request, forbidden, not_found
from app.core.auth.policy import generate_onboarding_token, hash_onboarding_token
from app.core.auth.policy import validate_password_policy
from app.core.auth.security import hash_password
from app.modules.auth.deps import resolve_user_auth_role
from app.modules.auth.models import User, UserNotificationPreference, UserNotificationPreferenceAudit
from app.modules.localization import service as localization_service
from app.modules.media.models import MediaAsset
from app.modules.spaces import service as spaces_service
from app.modules.spaces.models import Space

from .models import (
    BrandingDraft,
    BrandingRevision,
    BrandingSettings,
    CustomRole,
    OrganizationAuditEvent,
    OrganizationItem,
    OrganizationItemLink,
    OrganizationUnit,
)

BUILTIN_ROLE_ORDER = ("viewer", "member", "moderator", "admin")
BUILTIN_ROLE_LABELS = {
    "viewer": "Viewer",
    "member": "Member",
    "moderator": "Moderator",
    "admin": "Admin",
}
ALLOWED_GLOBAL_ROLES = set(BUILTIN_ROLE_ORDER)
ALLOWED_EFFECTIVE_LEVELS = set(BUILTIN_ROLE_ORDER)
ROLE_KEY_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{1,99}$")
UNIT_TYPE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{1,49}$")
_MEDIA_FILE_URL_PATTERN = re.compile(r"^/media/([^/?#]+)/file/?$")
_TRANSLATION_META_KEY_SANITIZE_RE = re.compile(r"[^a-z0-9_.-]+")
_USER_PROVISIONING_ROLE_HINTS = (
    "admin",
    "manager",
    "hr",
    "people",
    "it",
    "security",
)
_AUTH_ROLE_RANK = {"viewer": 0, "member": 1, "moderator": 2, "admin": 3}
_SPACE_ROLE_RANK = {"viewer": 0, "member": 1, "moderator": 2, "admin": 3}
_SUPPORTED_ITEM_LINK_PAIRS = {
    ("department", "space"),
    ("department", "department"),
    ("department", "user"),
    ("user", "user"),
    ("role", "user"),
}
_BRANDING_DEFAULT_APP_TITLE = "OpsAtlas"
_BRANDING_DEFAULT_SHORT_NAME = "OpsAtlas"
_BRANDING_DEFAULT_DESCRIPTION = (
    "OpsAtlas is a self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work."
)
_BRANDING_DEFAULT_THEME_HEX = "#0F67E8"
_BRANDING_DEFAULT_INSTALL_BACKGROUND_HEX = "#0A0D12"
_BRANDING_SOURCE_PUBLISH = "publish"
_BRANDING_SOURCE_ROLLBACK = "rollback"
_BRANDING_SOURCE_SEED = "seed"
_BRANDING_SNAPSHOT_FIELDS = (
    "company_name",
    "application_title",
    "application_short_name",
    "web_description",
    "apple_web_app_title",
    "logo_url",
    "light_logo_url",
    "dark_logo_url",
    "favicon_url",
    "login_background_url",
    "light_seed_hex",
    "dark_accent_hex",
    "dark_bg_hex",
    "browser_theme_hex",
    "install_background_hex",
)


def _normalize_role_key(raw: str) -> str:
    key = raw.strip().lower()
    if not ROLE_KEY_PATTERN.match(key):
        raise bad_request("role_key must be 2-100 chars and contain only lowercase letters, numbers, '-' or '_'")
    if key in ALLOWED_EFFECTIVE_LEVELS:
        raise bad_request("Built-in role keys cannot be recreated")
    return key


def _normalize_slug(raw: str, *, field_name: str = "slug") -> str:
    value = raw.strip().lower()
    if not ROLE_KEY_PATTERN.match(value):
        raise bad_request(f"{field_name} must be 2-100 chars and contain only lowercase letters, numbers, '-' or '_'")
    return value


def _normalize_builtin_role(raw: str | None) -> str:
    normalized = (raw or "").strip().lower()
    if normalized in ALLOWED_GLOBAL_ROLES:
        return normalized
    return "member"


def _pending_organization_item(
    db: Session,
    *,
    item_id: str,
) -> OrganizationItem | None:
    for pending in db.new:
        if not isinstance(pending, OrganizationItem):
            continue
        if pending.id == item_id:
            return pending
    return None


def _upsert_organization_item(
    db: Session,
    *,
    item_id: str,
    kind: str,
    name: str,
    entity_id: str | None,
    slug: str | None,
    active: bool,
    meta_json: str | None,
    created_at: datetime | None = None,
) -> OrganizationItem:
    row = _pending_organization_item(db, item_id=item_id)
    if row is None:
        row = db.get(OrganizationItem, item_id)
    if row is None:
        row = OrganizationItem(
            id=item_id,
            kind=kind,
            entity_id=entity_id,
            slug=slug,
            name=name,
            active=active,
            meta_json=meta_json,
        )
        if created_at is not None:
            row.created_at = created_at
        db.add(row)
        return row

    row.kind = kind
    row.entity_id = entity_id
    row.slug = slug
    row.name = name
    row.active = active
    row.meta_json = meta_json
    return row


def ensure_builtin_role_items(db: Session) -> None:
    for role_key in BUILTIN_ROLE_ORDER:
        _upsert_organization_item(
            db,
            item_id=role_key,
            kind="role",
            entity_id=None,
            slug=role_key,
            name=BUILTIN_ROLE_LABELS[role_key],
            active=True,
            meta_json=None,
        )


def sync_user_organization_item(db: Session, user: User) -> OrganizationItem:
    return _upsert_organization_item(
        db,
        item_id=user.id,
        kind="user",
        entity_id=user.id,
        slug=user.email,
        name=user.name,
        active=bool(getattr(user, "is_active", True)),
        meta_json=user.meta_json,
        created_at=user.created_at,
    )


def sync_space_organization_item(db: Session, space: Space) -> OrganizationItem:
    return _upsert_organization_item(
        db,
        item_id=space.id,
        kind="space",
        entity_id=space.id,
        slug=space.slug,
        name=space.name,
        active=True,
        meta_json=space.meta_json,
        created_at=space.created_at,
    )


def sync_custom_role_organization_item(
    db: Session,
    role: CustomRole,
) -> OrganizationItem:
    return _upsert_organization_item(
        db,
        item_id=role.role_key,
        kind="role",
        entity_id=role.id,
        slug=role.role_key,
        name=role.name,
        active=role.active,
        meta_json=role.meta_json,
        created_at=role.created_at,
    )


def sync_organization_unit_item(
    db: Session,
    org_unit: OrganizationUnit,
) -> OrganizationItem:
    return _upsert_organization_item(
        db,
        item_id=org_unit.id,
        kind="department",
        entity_id=org_unit.id,
        slug=org_unit.slug,
        name=org_unit.name,
        active=org_unit.active,
        meta_json=org_unit.meta_json,
        created_at=org_unit.created_at,
    )


def delete_organization_item(db: Session, item_id: str) -> None:
    row = db.get(OrganizationItem, item_id)
    if row is not None:
        db.delete(row)


def _require_organization_item_row(db: Session, item_id: str) -> OrganizationItem:
    row = db.get(OrganizationItem, item_id)
    if row is None:
        raise not_found("Organization item not found")
    return row


def sync_user_builtin_role_binding(
    db: Session,
    user: User,
    *,
    role_key: str | None = None,
) -> None:
    ensure_builtin_role_items(db)
    normalized_role = _normalize_builtin_role(role_key or user.global_role)
    user.global_role = normalized_role

    current_links = list(
        db.execute(
            select(OrganizationItemLink).where(
                OrganizationItemLink.parent_kind == "role",
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.child_id == user.id,
                OrganizationItemLink.parent_id.in_(sorted(ALLOWED_GLOBAL_ROLES)),
            )
        )
        .scalars()
        .all()
    )

    for link in current_links:
        if link.parent_id != normalized_role:
            db.delete(link)

    retained = next(
        (link for link in current_links if link.parent_id == normalized_role),
        None,
    )
    if retained is not None:
        retained.grant_role = normalized_role
        retained.inherit_to_descendants = False
        retained.active = True
        return

    db.add(
        OrganizationItemLink(
            id=str(uuid.uuid4()),
            parent_kind="role",
            parent_id=normalized_role,
            child_kind="user",
            child_id=user.id,
            grant_role=normalized_role,
            inherit_to_descendants=False,
            active=True,
        )
    )


def _ensure_department_parent_link(
    db: Session,
    *,
    parent_id: str,
    child_id: str,
) -> None:
    existing = db.scalar(
        select(OrganizationItemLink).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.parent_id == parent_id,
            OrganizationItemLink.child_kind == "department",
            OrganizationItemLink.child_id == child_id,
        )
    )
    if existing is not None:
        existing.grant_role = "member"
        existing.inherit_to_descendants = True
        existing.active = True
        return

    db.add(
        OrganizationItemLink(
            id=str(uuid.uuid4()),
            parent_kind="department",
            parent_id=parent_id,
            child_kind="department",
            child_id=child_id,
            grant_role="member",
            inherit_to_descendants=True,
            active=True,
        )
    )


def _sync_org_unit_primary_parent_link(
    db: Session,
    *,
    org_unit_id: str,
    previous_parent_id: str | None,
    next_parent_id: str | None,
) -> None:
    normalized_previous = _clean_optional_text(previous_parent_id)
    normalized_next = _clean_optional_text(next_parent_id)

    if normalized_previous is not None and normalized_previous != normalized_next:
        previous_link = db.scalar(
            select(OrganizationItemLink).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.parent_id == normalized_previous,
                OrganizationItemLink.child_kind == "department",
                OrganizationItemLink.child_id == org_unit_id,
            )
        )
        if previous_link is not None:
            db.delete(previous_link)

    if normalized_next is None or normalized_next == org_unit_id:
        return

    _ensure_department_parent_link(
        db,
        parent_id=normalized_next,
        child_id=org_unit_id,
    )


def _active_department_parent_ids_by_child(db: Session) -> dict[str, list[str]]:
    mapped: dict[str, set[str]] = {}
    rows = db.execute(
        select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.child_kind == "department",
            OrganizationItemLink.active.is_(True),
        )
    ).all()
    for parent_id, child_id in rows:
        if not isinstance(parent_id, str) or not parent_id:
            continue
        if not isinstance(child_id, str) or not child_id:
            continue
        mapped.setdefault(child_id, set()).add(parent_id)
    return {child_id: sorted(parent_ids) for child_id, parent_ids in mapped.items() if parent_ids}


def _active_department_child_ids_by_parent(db: Session) -> dict[str, list[str]]:
    mapped: dict[str, set[str]] = {}
    rows = db.execute(
        select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.child_kind == "department",
            OrganizationItemLink.active.is_(True),
        )
    ).all()
    for parent_id, child_id in rows:
        if not isinstance(parent_id, str) or not parent_id:
            continue
        if not isinstance(child_id, str) or not child_id:
            continue
        mapped.setdefault(parent_id, set()).add(child_id)
    return {parent_id: sorted(child_ids) for parent_id, child_ids in mapped.items() if child_ids}


def _primary_org_unit_parent_id(db: Session, org_unit_id: str) -> str | None:
    parent_ids = _active_department_parent_ids_by_child(db).get(org_unit_id, [])
    return parent_ids[0] if parent_ids else None


def list_organization_items(db: Session) -> list[OrganizationItem]:
    q = select(OrganizationItem).order_by(
        OrganizationItem.kind.asc(),
        OrganizationItem.name.asc(),
        OrganizationItem.id.asc(),
    )
    return list(db.execute(q).scalars().all())


def sync_organization_items(db: Session) -> None:
    ensure_builtin_role_items(db)

    for user in db.execute(select(User).order_by(User.created_at.asc())).scalars().all():
        sync_user_organization_item(db, user)
        sync_user_builtin_role_binding(db, user)

    for space in db.execute(select(Space).order_by(Space.created_at.asc())).scalars().all():
        sync_space_organization_item(db, space)

    for org_unit in db.execute(select(OrganizationUnit).order_by(OrganizationUnit.created_at.asc())).scalars().all():
        sync_organization_unit_item(db, org_unit)

    for role in db.execute(select(CustomRole).order_by(CustomRole.created_at.asc())).scalars().all():
        sync_custom_role_organization_item(db, role)

    db.commit()


def _normalize_unit_type(raw: str) -> str:
    value = raw.strip().lower()
    if not UNIT_TYPE_PATTERN.match(value):
        raise bad_request("unit_type must be 2-50 chars and contain only lowercase letters, numbers, '-' or '_'")
    return value


def _clean_optional_text(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    return cleaned or None


def _decode_meta_json(value: str | None) -> dict[str, object] | None:
    if not value:
        return None
    try:
        decoded = json.loads(value)
    except Exception:
        return None
    return decoded if isinstance(decoded, dict) else None


def _encode_meta_json(value: dict[str, object] | None) -> str | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise bad_request("meta must be an object")
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _json_if_changed(
    *,
    before: dict[str, object] | None,
    after: dict[str, object] | None,
) -> tuple[str | None, str | None]:
    if before == after:
        return None, None
    before_json = json.dumps(before, ensure_ascii=False, separators=(",", ":")) if before is not None else None
    after_json = json.dumps(after, ensure_ascii=False, separators=(",", ":")) if after is not None else None
    return before_json, after_json


def _translation_meta_fields(meta: dict[str, object] | None) -> dict[str, str]:
    if not meta:
        return {}
    fields: dict[str, str] = {}
    for raw_key, raw_value in meta.items():
        if not isinstance(raw_value, str):
            continue
        value = raw_value.strip()
        if not value:
            continue
        base_key = str(raw_key).strip().lower()
        if not base_key:
            continue
        normalized_key = _TRANSLATION_META_KEY_SANITIZE_RE.sub("_", base_key).strip("_")
        if not normalized_key:
            continue
        fields[f"meta.{normalized_key[:96]}"] = value
    return fields


def _queue_organization_item_translations(
    db: Session,
    *,
    item_kind: str,
    item_id: str,
    name: str,
    meta: dict[str, object] | None,
    actor_user_id: str | None,
) -> None:
    fields: dict[str, str] = {"name": name}
    fields.update(_translation_meta_fields(meta))
    localization_service.try_queue_content_translations(
        db,
        content_kind=f"org_{item_kind}",
        content_id=item_id,
        fields=fields,
        actor_user_id=actor_user_id,
        triggered_by="auto_write",
    )


def _append_org_audit_event(
    db: Session,
    *,
    scope_kind: str,
    action: str,
    actor_user_id: str | None = None,
    item_kind: str | None = None,
    item_id: str | None = None,
    link_parent_kind: str | None = None,
    link_parent_id: str | None = None,
    link_child_kind: str | None = None,
    link_child_id: str | None = None,
    summary: str | None = None,
    before_json: str | None = None,
    after_json: str | None = None,
) -> None:
    db.add(
        OrganizationAuditEvent(
            id=str(uuid.uuid4()),
            scope_kind=scope_kind,
            action=action,
            item_kind=item_kind,
            item_id=item_id,
            link_parent_kind=link_parent_kind,
            link_parent_id=link_parent_id,
            link_child_kind=link_child_kind,
            link_child_id=link_child_id,
            actor_user_id=actor_user_id,
            summary=summary,
            before_json=before_json,
            after_json=after_json,
        )
    )


def _json_from_payload(payload: Mapping[str, object] | None) -> str | None:
    if payload is None:
        return None
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def append_user_lifecycle_audit_event(
    db: Session,
    *,
    action: str,
    user_id: str,
    actor_user_id: str | None = None,
    summary: str | None = None,
    before: Mapping[str, object] | None = None,
    after: Mapping[str, object] | None = None,
) -> None:
    _append_org_audit_event(
        db,
        scope_kind="user_lifecycle",
        action=action,
        actor_user_id=actor_user_id,
        item_kind="user",
        item_id=user_id,
        summary=summary,
        before_json=_json_from_payload(before),
        after_json=_json_from_payload(after),
    )


def _pending_onboarding_password_seed() -> str:
    return f"onboarding-pending-{uuid.uuid4().hex}-{uuid.uuid4().hex}"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def user_has_provisioning_access(db: Session, actor: User) -> bool:
    role = resolve_user_auth_role(db, actor)
    if role in {"admin", "moderator"}:
        return True

    linked_role_keys = {
        role_key.strip().lower()
        for role_key, in db.execute(
            select(OrganizationItemLink.parent_id).where(
                OrganizationItemLink.parent_kind == "role",
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.child_id == actor.id,
                OrganizationItemLink.active.is_(True),
            )
        ).all()
        if isinstance(role_key, str) and role_key.strip()
    }
    for role_key in linked_role_keys:
        if any(hint in role_key for hint in _USER_PROVISIONING_ROLE_HINTS):
            return True

    manages_reports_count = int(
        db.scalar(
            select(func.count(OrganizationItemLink.id)).where(
                OrganizationItemLink.parent_kind == "user",
                OrganizationItemLink.parent_id == actor.id,
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.active.is_(True),
            )
        )
        or 0
    )
    return manages_reports_count > 0


def ensure_user_provisioning_access(db: Session, actor: User) -> None:
    if user_has_provisioning_access(db, actor):
        return
    raise forbidden("User provisioning requires admin, HR/IT, or manager access")


def _normalize_hex(value: str | None) -> str | None:
    if value is None:
        return None
    raw = value.strip()
    if raw == "":
        return None
    if not raw.startswith("#"):
        raw = f"#{raw}"
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", raw):
        raise bad_request("Color values must be in hex format like #1D9BF0")
    return raw.upper()


def _safe_hex(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    if not raw.startswith("#"):
        raw = f"#{raw}"
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", raw):
        return None
    return raw.upper()


def _normalize_optional_text(value: str | None) -> str | None:
    if value is None:
        return None
    raw = value.strip()
    return raw or None


def _normalize_url(value: str | None) -> str | None:
    if value is None:
        return None
    raw = value.strip()
    if raw == "":
        return None
    if not (raw.startswith("http://") or raw.startswith("https://") or raw.startswith("/")):
        raise bad_request("URL values must start with https://, http://, or /")
    return raw


def _normalize_branding_asset_url(db: Session, value: str | None) -> str | None:
    normalized = _normalize_url(value)
    if normalized is None:
        return None

    split = urlsplit(normalized)
    match = _MEDIA_FILE_URL_PATTERN.fullmatch(split.path)
    if match is None:
        return normalized

    asset_id = match.group(1).strip()
    if not asset_id:
        return normalized

    asset = db.get(MediaAsset, asset_id)
    if asset is None:
        return normalized

    query = {key: item for key, item in parse_qsl(split.query, keep_blank_values=True) if key.lower() != "token"}
    if asset.original_filename:
        query["filename"] = asset.original_filename

    rebuilt_query = urlencode(query)
    return urlunsplit((split.scheme, split.netloc, split.path, rebuilt_query, split.fragment))


def _branding_empty_snapshot() -> dict[str, object | None]:
    return {key: None for key in _BRANDING_SNAPSHOT_FIELDS}


def _branding_snapshot_from_settings(row: BrandingSettings | None) -> dict[str, object | None]:
    snapshot = _branding_empty_snapshot()
    if row is None:
        return snapshot
    for key in _BRANDING_SNAPSHOT_FIELDS:
        snapshot[key] = getattr(row, key, None)
    return snapshot


def _branding_snapshot_from_json(raw: str | None) -> dict[str, object | None]:
    snapshot = _branding_empty_snapshot()
    if not isinstance(raw, str) or not raw.strip():
        return snapshot
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return snapshot
    if not isinstance(decoded, dict):
        return snapshot
    for key in _BRANDING_SNAPSHOT_FIELDS:
        value = decoded.get(key)
        snapshot[key] = value if isinstance(value, str) else None
    return snapshot


def _branding_snapshot_json(snapshot: Mapping[str, object | None]) -> str:
    return json.dumps(
        {
            key: (value if isinstance(value, str) and value.strip() else None)
            for key in _BRANDING_SNAPSHOT_FIELDS
            for value in [snapshot.get(key)]
        },
        separators=(",", ":"),
        ensure_ascii=False,
    )


def _branding_snapshot_equal(
    left: Mapping[str, object | None],
    right: Mapping[str, object | None],
) -> bool:
    for key in _BRANDING_SNAPSHOT_FIELDS:
        left_value = left.get(key)
        right_value = right.get(key)
        if isinstance(left_value, str):
            left_value = left_value.strip() or None
        if isinstance(right_value, str):
            right_value = right_value.strip() or None
        if left_value != right_value:
            return False
    return True


def _branding_has_content(snapshot: Mapping[str, object | None]) -> bool:
    return any(
        isinstance(snapshot.get(key), str) and snapshot.get(key, "").strip()
        for key in _BRANDING_SNAPSHOT_FIELDS
    )


def _resolved_branding_asset_url(db: Session, value: object | None) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return _normalize_branding_asset_url(db, value)
    except Exception:
        return value.strip() or None


def _resolved_branding_title(snapshot: Mapping[str, object | None]) -> str:
    return (
        _normalize_optional_text(snapshot.get("application_title") if isinstance(snapshot.get("application_title"), str) else None)
        or _normalize_optional_text(snapshot.get("company_name") if isinstance(snapshot.get("company_name"), str) else None)
        or _BRANDING_DEFAULT_APP_TITLE
    )


def _resolved_branding_short_name(snapshot: Mapping[str, object | None]) -> str:
    explicit = _normalize_optional_text(
        snapshot.get("application_short_name") if isinstance(snapshot.get("application_short_name"), str) else None
    )
    value = explicit or _resolved_branding_title(snapshot) or _BRANDING_DEFAULT_SHORT_NAME
    return value[:32].rstrip() or _BRANDING_DEFAULT_SHORT_NAME


def _resolved_branding_description(snapshot: Mapping[str, object | None]) -> str:
    return (
        _normalize_optional_text(snapshot.get("web_description") if isinstance(snapshot.get("web_description"), str) else None)
        or _BRANDING_DEFAULT_DESCRIPTION
    )


def _resolved_apple_web_app_title(snapshot: Mapping[str, object | None]) -> str:
    return (
        _normalize_optional_text(
            snapshot.get("apple_web_app_title") if isinstance(snapshot.get("apple_web_app_title"), str) else None
        )
        or _resolved_branding_short_name(snapshot)
    )


def _resolved_theme_color_hex(snapshot: Mapping[str, object | None]) -> str:
    return (
        _safe_hex(snapshot.get("browser_theme_hex"))
        or _safe_hex(snapshot.get("light_seed_hex"))
        or _BRANDING_DEFAULT_THEME_HEX
    )


def _resolved_install_background_hex(snapshot: Mapping[str, object | None]) -> str:
    return (
        _safe_hex(snapshot.get("install_background_hex"))
        or _safe_hex(snapshot.get("dark_bg_hex"))
        or _BRANDING_DEFAULT_INSTALL_BACKGROUND_HEX
    )


def _resolved_branding_snapshot(
    db: Session,
    snapshot: Mapping[str, object | None],
    *,
    updated_at: datetime | None,
) -> dict[str, object | None]:
    company_name = _normalize_optional_text(
        snapshot.get("company_name") if isinstance(snapshot.get("company_name"), str) else None
    )
    application_title = _normalize_optional_text(
        snapshot.get("application_title") if isinstance(snapshot.get("application_title"), str) else None
    )
    application_short_name = _normalize_optional_text(
        snapshot.get("application_short_name") if isinstance(snapshot.get("application_short_name"), str) else None
    )
    web_description = _normalize_optional_text(
        snapshot.get("web_description") if isinstance(snapshot.get("web_description"), str) else None
    )
    apple_web_app_title = _normalize_optional_text(
        snapshot.get("apple_web_app_title") if isinstance(snapshot.get("apple_web_app_title"), str) else None
    )

    return {
        "company_name": company_name,
        "application_title": application_title,
        "application_short_name": application_short_name,
        "web_description": web_description,
        "apple_web_app_title": apple_web_app_title,
        "logo_url": _resolved_branding_asset_url(db, snapshot.get("logo_url")),
        "light_logo_url": _resolved_branding_asset_url(db, snapshot.get("light_logo_url")),
        "dark_logo_url": _resolved_branding_asset_url(db, snapshot.get("dark_logo_url")),
        "favicon_url": _resolved_branding_asset_url(db, snapshot.get("favicon_url")),
        "login_background_url": _resolved_branding_asset_url(db, snapshot.get("login_background_url")),
        "light_seed_hex": _safe_hex(snapshot.get("light_seed_hex")),
        "dark_accent_hex": _safe_hex(snapshot.get("dark_accent_hex")),
        "dark_bg_hex": _safe_hex(snapshot.get("dark_bg_hex")),
        "browser_theme_hex": _safe_hex(snapshot.get("browser_theme_hex")),
        "install_background_hex": _safe_hex(snapshot.get("install_background_hex")),
        "resolved_app_title": _resolved_branding_title(snapshot),
        "resolved_application_short_name": _resolved_branding_short_name(snapshot),
        "resolved_web_description": _resolved_branding_description(snapshot),
        "resolved_apple_web_app_title": _resolved_apple_web_app_title(snapshot),
        "resolved_theme_color_hex": _resolved_theme_color_hex(snapshot),
        "resolved_install_background_hex": _resolved_install_background_hex(snapshot),
        "updated_at": updated_at,
    }


def _branding_summary(snapshot: Mapping[str, object | None], *, source_kind: str) -> str:
    title = _resolved_branding_title(snapshot)
    return {
        _BRANDING_SOURCE_ROLLBACK: f"Rollback to {title}",
        _BRANDING_SOURCE_SEED: f"Seeded live branding for {title}",
    }.get(source_kind, f"Published branding for {title}")


def get_branding_draft(db: Session) -> BrandingDraft | None:
    return db.get(BrandingDraft, 1)


def get_or_create_branding_draft(db: Session) -> BrandingDraft:
    row = db.get(BrandingDraft, 1)
    if row is not None:
        return row
    row = BrandingDraft(
        id=1,
        snapshot_json=_branding_snapshot_json(_branding_snapshot_from_settings(get_branding(db))),
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def _apply_branding_snapshot_to_settings(row: BrandingSettings, snapshot: Mapping[str, object | None]) -> None:
    for key in _BRANDING_SNAPSHOT_FIELDS:
        setattr(row, key, snapshot.get(key) if isinstance(snapshot.get(key), str) else None)


def _next_branding_revision_number(db: Session) -> int:
    current = db.scalar(select(func.max(BrandingRevision.revision_number))) or 0
    return int(current) + 1


def _create_branding_revision(
    db: Session,
    *,
    snapshot: Mapping[str, object | None],
    source_kind: str,
    published_by_user_id: str | None,
    source_revision_id: str | None = None,
    published_at: datetime | None = None,
) -> BrandingRevision:
    row = BrandingRevision(
        id=str(uuid.uuid4()),
        revision_number=_next_branding_revision_number(db),
        source_kind=source_kind,
        source_revision_id=source_revision_id,
        summary=_branding_summary(snapshot, source_kind=source_kind),
        snapshot_json=_branding_snapshot_json(snapshot),
        published_by_user_id=published_by_user_id,
        published_at=published_at or datetime.now(timezone.utc),
    )
    db.add(row)
    db.flush()
    return row


def _ensure_branding_history_seed(db: Session) -> None:
    if (db.scalar(select(func.count(BrandingRevision.id))) or 0) > 0:
        return
    published = get_branding(db)
    if published is None:
        return
    snapshot = _branding_snapshot_from_settings(published)
    if not _branding_has_content(snapshot):
        return
    _create_branding_revision(
        db,
        snapshot=snapshot,
        source_kind=_BRANDING_SOURCE_SEED,
        published_by_user_id=None,
        published_at=published.updated_at,
    )
    db.commit()


def list_branding_revisions(db: Session) -> list[BrandingRevision]:
    return list(
        db.execute(
            select(BrandingRevision).order_by(BrandingRevision.revision_number.desc())
        ).scalars().all()
    )


def _role_exists(db: Session, role_key: str) -> bool:
    normalized = role_key.strip().lower()
    if normalized in ALLOWED_EFFECTIVE_LEVELS:
        return True
    role = db.scalar(
        select(CustomRole).where(
            CustomRole.role_key == normalized,
            CustomRole.active.is_(True),
        )
    )
    return role is not None


def list_users(db: Session) -> list[tuple[User, UserNotificationPreference | None, int, datetime | None]]:
    audit_summary = (
        select(
            UserNotificationPreferenceAudit.user_id.label("user_id"),
            func.count(UserNotificationPreferenceAudit.id).label("change_count"),
            func.max(UserNotificationPreferenceAudit.changed_at).label("last_change_at"),
        )
        .group_by(UserNotificationPreferenceAudit.user_id)
        .subquery()
    )
    q = (
        select(
            User,
            UserNotificationPreference,
            audit_summary.c.change_count,
            audit_summary.c.last_change_at,
        )
        .outerjoin(UserNotificationPreference, UserNotificationPreference.user_id == User.id)
        .outerjoin(audit_summary, audit_summary.c.user_id == User.id)
        .order_by(User.created_at.desc())
    )
    return [(user, prefs, int(change_count or 0), last_change_at) for user, prefs, change_count, last_change_at in db.execute(q).all()]


def create_user(
    db: Session,
    *,
    email: str,
    name: str,
    password: str,
    global_role: str = "member",
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> User:
    next_email = email.strip().lower()
    next_name = name.strip()
    next_password = password.strip()
    next_role = global_role.strip().lower()

    if not next_name:
        raise bad_request("Name is required")
    validate_password_policy(next_password, email=next_email, name=next_name)
    if next_role not in ALLOWED_GLOBAL_ROLES:
        raise bad_request("Invalid global role")

    existing = db.scalar(select(User).where(User.email == next_email))
    if existing:
        raise bad_request("Email already registered")

    user = User(
        id=str(uuid.uuid4()),
        email=next_email,
        name=next_name,
        password_hash=hash_password(next_password),
        global_role=next_role,
        is_active=True,
        must_change_password=False,
        meta_json=_encode_meta_json(meta),
    )
    db.add(user)
    sync_user_organization_item(db, user)
    sync_user_builtin_role_binding(db, user, role_key=next_role)
    append_user_lifecycle_audit_event(
        db,
        action="user_create",
        user_id=user.id,
        actor_user_id=actor_user_id,
        summary="User account created",
        before=None,
        after={
            "email": user.email,
            "global_role": user.global_role,
            "is_active": bool(getattr(user, "is_active", True)),
            "must_change_password": bool(getattr(user, "must_change_password", False)),
        },
    )
    if meta is not None:
        _append_org_audit_event(
            db,
            scope_kind="item",
            action="meta_create",
            actor_user_id=actor_user_id,
            item_kind="user",
            item_id=user.id,
            summary="User created with metadata",
            before_json=None,
            after_json=_encode_meta_json(meta),
        )
    _queue_organization_item_translations(
        db,
        item_kind="user",
        item_id=user.id,
        name=user.name,
        meta=_decode_meta_json(user.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(user)
    return user


def update_user(
    db: Session,
    user_id: str,
    *,
    email: str | None = None,
    name: str | None = None,
    password: str | None = None,
    global_role: str | None = None,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> User:
    user = db.get(User, user_id)
    if not user:
        raise not_found("User not found")
    before_meta = _decode_meta_json(user.meta_json)

    effective_email = user.email
    effective_name = user.name

    if email is not None:
        next_email = email.strip().lower()
        existing = db.scalar(select(User).where(User.email == next_email))
        if existing and existing.id != user.id:
            raise bad_request("Email already registered")
        user.email = next_email
        effective_email = next_email

    if name is not None:
        next_name = name.strip()
        if not next_name:
            raise bad_request("Name is required")
        user.name = next_name
        effective_name = next_name

    if password is not None:
        next_password = password.strip()
        validate_password_policy(next_password, email=effective_email, name=effective_name)
        user.password_hash = hash_password(next_password)
        user.must_change_password = False
        user.invite_expires_at = None
        user.invite_token_hash = None
        user.invite_token_issued_at = None

    if global_role is not None:
        next_role = global_role.strip().lower()
        if next_role not in ALLOWED_GLOBAL_ROLES:
            raise bad_request("Invalid global role")
        user.global_role = next_role

    if meta is not None:
        user.meta_json = _encode_meta_json(meta)

    sync_user_organization_item(db, user)
    sync_user_builtin_role_binding(db, user)
    if meta is not None:
        before_json, after_json = _json_if_changed(
            before=before_meta,
            after=_decode_meta_json(user.meta_json),
        )
        if before_json is not None or after_json is not None:
            _append_org_audit_event(
                db,
                scope_kind="item",
                action="meta_update",
                actor_user_id=actor_user_id,
                item_kind="user",
                item_id=user.id,
                summary="User metadata updated",
                before_json=before_json,
                after_json=after_json,
            )
    _queue_organization_item_translations(
        db,
        item_kind="user",
        item_id=user.id,
        name=user.name,
        meta=_decode_meta_json(user.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(user)
    return user


def set_user_active_state(
    db: Session,
    *,
    user_id: str,
    active: bool,
    actor_user_id: str | None = None,
) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise not_found("User not found")
    before = {
        "is_active": bool(getattr(user, "is_active", True)),
    }
    user.is_active = bool(active)
    if not bool(active):
        user.must_change_password = False
        user.invite_expires_at = None
        user.invite_token_hash = None
        user.invite_token_issued_at = None
        from app.modules.auth import service as auth_service

        auth_service.revoke_user_sessions(
            db,
            user_id=user.id,
            reason="admin_deactivate",
            commit=False,
        )
    sync_user_organization_item(db, user)
    after = {
        "is_active": bool(getattr(user, "is_active", True)),
    }
    if before != after:
        append_user_lifecycle_audit_event(
            db,
            action="activate" if active else "deactivate",
            user_id=user.id,
            actor_user_id=actor_user_id,
            summary="User account activated" if active else "User account deactivated",
            before=before,
            after=after,
        )
    db.commit()
    db.refresh(user)
    return user


def _issue_user_onboarding_token(
    db: Session,
    *,
    user_id: str,
    actor_user_id: str | None,
    action: str,
    summary: str,
    validity_hours: int = 72,
) -> tuple[User, str, datetime]:
    user = db.get(User, user_id)
    if user is None:
        raise not_found("User not found")
    safe_validity = max(1, min(int(validity_hours), 24 * 14))
    onboarding_token = generate_onboarding_token()
    onboarding_token_hash = hash_onboarding_token(onboarding_token)
    if not onboarding_token_hash:
        raise bad_request("Failed to generate onboarding token")
    now = _utc_now()
    expires_at = now + timedelta(hours=safe_validity)
    previous_invite_expires_at = getattr(user, "invite_expires_at", None)
    previous_token_present = bool((getattr(user, "invite_token_hash", None) or "").strip())
    before = {
        "is_active": bool(getattr(user, "is_active", True)),
        "must_change_password": bool(getattr(user, "must_change_password", False)),
        "invite_expires_at": (previous_invite_expires_at.isoformat() if isinstance(previous_invite_expires_at, datetime) else None),
        "invite_token_present": previous_token_present,
    }

    user.password_hash = hash_password(_pending_onboarding_password_seed())
    user.is_active = True
    user.must_change_password = True
    user.invited_at = now
    user.invite_expires_at = expires_at
    user.invite_token_hash = onboarding_token_hash
    user.invite_token_issued_at = now
    user.invited_by_user_id = actor_user_id
    sync_user_organization_item(db, user)

    from app.modules.auth import service as auth_service

    auth_service.revoke_user_sessions(
        db,
        user_id=user.id,
        reason=action,
        commit=False,
    )

    append_user_lifecycle_audit_event(
        db,
        action=action,
        user_id=user.id,
        actor_user_id=actor_user_id,
        summary=summary,
        before=before,
        after={
            "is_active": True,
            "must_change_password": True,
            "invite_expires_at": expires_at.isoformat(),
            "invite_token_present": True,
        },
    )
    db.commit()
    db.refresh(user)
    return user, onboarding_token, expires_at


def invite_user(
    db: Session,
    *,
    user_id: str,
    actor_user_id: str | None = None,
) -> tuple[User, str, datetime]:
    return _issue_user_onboarding_token(
        db,
        user_id=user_id,
        actor_user_id=actor_user_id,
        action="invite",
        summary="User invite issued",
    )


def reset_user_password(
    db: Session,
    *,
    user_id: str,
    actor_user_id: str | None = None,
) -> tuple[User, str, datetime]:
    return _issue_user_onboarding_token(
        db,
        user_id=user_id,
        actor_user_id=actor_user_id,
        action="password_reset",
        summary="Password reset onboarding token issued",
    )


def list_spaces(db: Session) -> list[tuple[Space, int]]:
    q = (
        select(Space, func.count(OrganizationItemLink.id).label("link_count"))
        .outerjoin(
            OrganizationItemLink,
            and_(
                OrganizationItemLink.child_kind == "space",
                OrganizationItemLink.child_id == Space.id,
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.active.is_(True),
            ),
        )
        .group_by(Space.id)
        .order_by(Space.created_at.desc())
    )
    return [(space, int(link_count or 0)) for space, link_count in db.execute(q).all()]


def count_space_item_links(db: Session, space_id: str) -> int:
    return int(
        db.scalar(
            select(func.count(OrganizationItemLink.id)).where(
                OrganizationItemLink.child_kind == "space",
                OrganizationItemLink.child_id == space_id,
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.active.is_(True),
            )
        )
        or 0
    )


def create_space(
    db: Session,
    name: str,
    slug: str,
    owner_user_id: str,
    *,
    region_code: str | None = None,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> Space:
    owner = db.get(User, owner_user_id)
    if not owner:
        raise not_found("Owner user not found")
    space = spaces_service.create_space(
        db,
        name,
        slug,
        owner_user_id,
        region_code=_clean_optional_text(region_code),
        meta_json=_encode_meta_json(meta),
    )
    space.owner_user_id = owner_user_id
    sync_space_organization_item(db, space)
    if meta is not None:
        _append_org_audit_event(
            db,
            scope_kind="item",
            action="meta_create",
            actor_user_id=actor_user_id,
            item_kind="space",
            item_id=space.id,
            summary="Space created with metadata",
            before_json=None,
            after_json=_encode_meta_json(meta),
        )
    _queue_organization_item_translations(
        db,
        item_kind="space",
        item_id=space.id,
        name=space.name,
        meta=_decode_meta_json(space.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(space)
    return space


def update_space(
    db: Session,
    space_id: str,
    *,
    name: str | None = None,
    slug: str | None = None,
    owner_user_id: str | None = None,
    owner_user_id_provided: bool = False,
    region_code: str | None = None,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> Space:
    space = _require_space(db, space_id)
    before_meta = _decode_meta_json(space.meta_json)
    previous_owner_user_id = _clean_optional_text(space.owner_user_id)

    if name is not None:
        next_name = name.strip()
        if not next_name:
            raise bad_request("Space name is required")
        space.name = next_name

    if slug is not None:
        next_slug = _normalize_slug(slug, field_name="slug")
        existing = db.scalar(select(Space).where(Space.slug == next_slug, Space.id != space_id))
        if existing:
            raise bad_request("Space slug already exists")
        space.slug = next_slug

    if owner_user_id_provided:
        normalized_owner_user_id = _clean_optional_text(owner_user_id)
        if normalized_owner_user_id is not None:
            owner = db.get(User, normalized_owner_user_id)
            if owner is None:
                raise not_found("Owner user not found")
        space.owner_user_id = normalized_owner_user_id

    if region_code is not None:
        space.region_code = _clean_optional_text(region_code)

    if meta is not None:
        space.meta_json = _encode_meta_json(meta)

    sync_space_organization_item(db, space)
    if owner_user_id_provided and previous_owner_user_id != _clean_optional_text(space.owner_user_id):
        _append_org_audit_event(
            db,
            scope_kind="item",
            action="owner_update",
            actor_user_id=actor_user_id,
            item_kind="space",
            item_id=space.id,
            summary="Space owner updated",
            before_json=json.dumps(
                {"owner_user_id": previous_owner_user_id},
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            after_json=json.dumps(
                {"owner_user_id": _clean_optional_text(space.owner_user_id)},
                ensure_ascii=False,
                separators=(",", ":"),
            ),
        )
    if meta is not None:
        before_json, after_json = _json_if_changed(
            before=before_meta,
            after=_decode_meta_json(space.meta_json),
        )
        if before_json is not None or after_json is not None:
            _append_org_audit_event(
                db,
                scope_kind="item",
                action="meta_update",
                actor_user_id=actor_user_id,
                item_kind="space",
                item_id=space.id,
                summary="Space metadata updated",
                before_json=before_json,
                after_json=after_json,
            )
    _queue_organization_item_translations(
        db,
        item_kind="space",
        item_id=space.id,
        name=space.name,
        meta=_decode_meta_json(space.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(space)
    return space


def _list_space_dependency_counts(db: Session, space_id: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for table in Base.metadata.sorted_tables:
        if table.name == "spaces":
            continue
        if "space_id" not in table.c:
            continue
        count_value = db.scalar(select(func.count()).select_from(table).where(table.c.space_id == space_id))
        count = int(count_value or 0)
        if count > 0:
            counts[table.name] = count
    item_links_table = Base.metadata.tables.get("organization_item_links")
    if item_links_table is not None and "child_kind" in item_links_table.c and "child_id" in item_links_table.c:
        link_count = int(
            db.scalar(
                select(func.count())
                .select_from(item_links_table)
                .where(
                    item_links_table.c.child_kind == "space",
                    item_links_table.c.child_id == space_id,
                )
            )
            or 0
        )
        if link_count > 0:
            counts[item_links_table.name] = link_count
    return counts


def delete_space(db: Session, space_id: str) -> None:
    space = _require_space(db, space_id)
    dependency_counts = _list_space_dependency_counts(db, space_id)

    auto_cleanup_tables = {"organization_item_links"}
    blocking = {table_name: count for table_name, count in dependency_counts.items() if table_name not in auto_cleanup_tables}
    if blocking:
        summary = ", ".join(f"{table_name}={blocking[table_name]}" for table_name in sorted(blocking.keys()))
        raise bad_request(f"Cannot delete space while linked data exists ({summary})")

    for table in Base.metadata.sorted_tables:
        if table.name not in auto_cleanup_tables:
            continue
        if table.name == "organization_item_links":
            if "child_kind" not in table.c or "child_id" not in table.c:
                continue
            db.execute(
                delete(table).where(
                    table.c.child_kind == "space",
                    table.c.child_id == space_id,
                )
            )
            continue
        if "space_id" not in table.c:
            continue
        db.execute(delete(table).where(table.c.space_id == space_id))

    delete_organization_item(db, space_id)
    db.delete(space)
    db.commit()


def _require_space(db: Session, space_id: str) -> Space:
    space = db.get(Space, space_id)
    if not space:
        raise not_found("Space not found")
    return space


def list_custom_roles(db: Session) -> list[CustomRole]:
    q = select(CustomRole).order_by(CustomRole.active.desc(), CustomRole.name.asc(), CustomRole.role_key.asc())
    return list(db.execute(q).scalars().all())


def create_custom_role(
    db: Session,
    *,
    role_key: str,
    name: str,
    description: str | None,
    effective_level: str,
    active: bool,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> CustomRole:
    key = _normalize_role_key(role_key)
    level = effective_level.strip().lower()
    if level not in ALLOWED_EFFECTIVE_LEVELS:
        raise bad_request("Invalid effective level")
    if db.scalar(select(CustomRole).where(CustomRole.role_key == key)):
        raise bad_request("Custom role key already exists")

    role = CustomRole(
        id=str(uuid.uuid4()),
        role_key=key,
        name=name.strip(),
        description=description.strip() if isinstance(description, str) and description.strip() else None,
        effective_level=level,
        active=active,
        meta_json=_encode_meta_json(meta),
    )
    if not role.name:
        raise bad_request("Role name is required")
    db.add(role)
    sync_custom_role_organization_item(db, role)
    if meta is not None:
        _append_org_audit_event(
            db,
            scope_kind="item",
            action="meta_create",
            actor_user_id=actor_user_id,
            item_kind="role",
            item_id=role.role_key,
            summary="Role created with metadata",
            before_json=None,
            after_json=_encode_meta_json(meta),
        )
    _queue_organization_item_translations(
        db,
        item_kind="role",
        item_id=role.role_key,
        name=role.name,
        meta=_decode_meta_json(role.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(role)
    return role


def update_custom_role(
    db: Session,
    role_key: str,
    *,
    name: str | None = None,
    description: str | None = None,
    effective_level: str | None = None,
    active: bool | None = None,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> CustomRole:
    key = role_key.strip().lower()
    role = db.scalar(select(CustomRole).where(CustomRole.role_key == key))
    if not role:
        raise not_found("Custom role not found")
    before_meta = _decode_meta_json(role.meta_json)
    if name is not None:
        next_name = name.strip()
        if not next_name:
            raise bad_request("Role name is required")
        role.name = next_name
    if description is not None:
        role.description = description.strip() if description.strip() else None
    if effective_level is not None:
        level = effective_level.strip().lower()
        if level not in ALLOWED_EFFECTIVE_LEVELS:
            raise bad_request("Invalid effective level")
        role.effective_level = level
    if active is not None:
        role.active = active
    if meta is not None:
        role.meta_json = _encode_meta_json(meta)
    sync_custom_role_organization_item(db, role)
    if meta is not None:
        before_json, after_json = _json_if_changed(
            before=before_meta,
            after=_decode_meta_json(role.meta_json),
        )
        if before_json is not None or after_json is not None:
            _append_org_audit_event(
                db,
                scope_kind="item",
                action="meta_update",
                actor_user_id=actor_user_id,
                item_kind="role",
                item_id=role.role_key,
                summary="Role metadata updated",
                before_json=before_json,
                after_json=after_json,
            )
    _queue_organization_item_translations(
        db,
        item_kind="role",
        item_id=role.role_key,
        name=role.name,
        meta=_decode_meta_json(role.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(role)
    return role


def delete_custom_role(db: Session, role_key: str) -> None:
    key = role_key.strip().lower()
    role = db.scalar(select(CustomRole).where(CustomRole.role_key == key))
    if not role:
        raise not_found("Custom role not found")
    assigned_item_links = int(
        db.scalar(
            select(func.count(OrganizationItemLink.id)).where(
                or_(
                    OrganizationItemLink.grant_role == role.role_key,
                    and_(
                        OrganizationItemLink.parent_kind == "role",
                        OrganizationItemLink.parent_id == role.role_key,
                    ),
                    and_(
                        OrganizationItemLink.child_kind == "role",
                        OrganizationItemLink.child_id == role.role_key,
                    ),
                )
            )
        )
        or 0
    )
    if assigned_item_links > 0:
        raise bad_request("Cannot delete a custom role while it is assigned")
    delete_organization_item(db, role.role_key)
    db.delete(role)
    db.commit()


def get_branding(db: Session) -> BrandingSettings | None:
    return db.get(BrandingSettings, 1)


def get_or_create_branding(db: Session) -> BrandingSettings:
    row = db.get(BrandingSettings, 1)
    if row:
        return row
    row = BrandingSettings(id=1)
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def update_branding(
    db: Session,
    *,
    company_name: str | None,
    application_title: str | None,
    application_short_name: str | None,
    web_description: str | None,
    apple_web_app_title: str | None,
    logo_url: str | None,
    light_logo_url: str | None,
    dark_logo_url: str | None,
    favicon_url: str | None,
    login_background_url: str | None,
    light_seed_hex: str | None,
    dark_accent_hex: str | None,
    dark_bg_hex: str | None,
    browser_theme_hex: str | None,
    install_background_hex: str | None,
) -> BrandingDraft:
    row = get_or_create_branding_draft(db)
    snapshot = {
        "company_name": _normalize_optional_text(company_name),
        "application_title": _normalize_optional_text(application_title),
        "application_short_name": _normalize_optional_text(application_short_name),
        "web_description": _normalize_optional_text(web_description),
        "apple_web_app_title": _normalize_optional_text(apple_web_app_title),
        "logo_url": _normalize_branding_asset_url(db, logo_url),
        "light_logo_url": _normalize_branding_asset_url(db, light_logo_url),
        "dark_logo_url": _normalize_branding_asset_url(db, dark_logo_url),
        "favicon_url": _normalize_branding_asset_url(db, favicon_url),
        "login_background_url": _normalize_branding_asset_url(db, login_background_url),
        "light_seed_hex": _normalize_hex(light_seed_hex),
        "dark_accent_hex": _normalize_hex(dark_accent_hex),
        "dark_bg_hex": _normalize_hex(dark_bg_hex),
        "browser_theme_hex": _normalize_hex(browser_theme_hex),
        "install_background_hex": _normalize_hex(install_background_hex),
    }
    row.snapshot_json = _branding_snapshot_json(snapshot)
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def discard_branding_draft(db: Session) -> BrandingDraft:
    draft = get_or_create_branding_draft(db)
    draft.snapshot_json = _branding_snapshot_json(_branding_snapshot_from_settings(get_branding(db)))
    db.add(draft)
    db.commit()
    db.refresh(draft)
    return draft


def publish_branding_draft(db: Session, *, actor_user_id: str | None) -> BrandingSettings:
    _ensure_branding_history_seed(db)
    draft = get_or_create_branding_draft(db)
    draft_snapshot = _branding_snapshot_from_json(draft.snapshot_json)
    live = get_or_create_branding(db)
    live_snapshot = _branding_snapshot_from_settings(live)
    if _branding_snapshot_equal(draft_snapshot, live_snapshot):
        return live
    _apply_branding_snapshot_to_settings(live, draft_snapshot)
    db.add(live)
    db.flush()
    _create_branding_revision(
        db,
        snapshot=draft_snapshot,
        source_kind=_BRANDING_SOURCE_PUBLISH,
        published_by_user_id=actor_user_id,
        published_at=live.updated_at,
    )
    draft.snapshot_json = _branding_snapshot_json(draft_snapshot)
    db.add(draft)
    db.commit()
    db.refresh(live)
    return live


def rollback_branding_revision(
    db: Session,
    *,
    revision_id: str,
    actor_user_id: str | None,
) -> BrandingSettings:
    _ensure_branding_history_seed(db)
    revision = db.get(BrandingRevision, revision_id)
    if revision is None:
        raise not_found("Branding revision not found")
    snapshot = _branding_snapshot_from_json(revision.snapshot_json)
    live = get_or_create_branding(db)
    _apply_branding_snapshot_to_settings(live, snapshot)
    db.add(live)
    draft = get_or_create_branding_draft(db)
    draft.snapshot_json = _branding_snapshot_json(snapshot)
    db.add(draft)
    db.flush()
    _create_branding_revision(
        db,
        snapshot=snapshot,
        source_kind=_BRANDING_SOURCE_ROLLBACK,
        published_by_user_id=actor_user_id,
        source_revision_id=revision.id,
        published_at=live.updated_at,
    )
    db.commit()
    db.refresh(live)
    return live


def get_branding_admin_state(db: Session) -> dict[str, object]:
    _ensure_branding_history_seed(db)
    published = get_branding(db)
    draft = get_or_create_branding_draft(db)
    published_snapshot = _branding_snapshot_from_settings(published)
    draft_snapshot = _branding_snapshot_from_json(draft.snapshot_json)
    history_rows = list_branding_revisions(db)
    history = []
    for row in history_rows:
        history.append(
            {
                "id": row.id,
                "revision_number": row.revision_number,
                "source_kind": row.source_kind,
                "source_revision_id": row.source_revision_id,
                "summary": row.summary,
                "published_by_user_id": row.published_by_user_id,
                "published_at": row.published_at,
                "snapshot": _resolved_branding_snapshot(
                    db,
                    _branding_snapshot_from_json(row.snapshot_json),
                    updated_at=row.published_at,
                ),
            }
        )
    return {
        "published": _resolved_branding_snapshot(
            db,
            published_snapshot,
            updated_at=published.updated_at if published is not None else None,
        ),
        "draft": _resolved_branding_snapshot(
            db,
            draft_snapshot,
            updated_at=draft.updated_at,
        ),
        "history": history,
        "has_unpublished_changes": not _branding_snapshot_equal(
            published_snapshot,
            draft_snapshot,
        ),
    }


def get_effective_branding(db: Session) -> dict[str, object | None]:
    base = get_branding(db)
    return _resolved_branding_snapshot(
        db,
        _branding_snapshot_from_settings(base),
        updated_at=base.updated_at if base is not None else None,
    )


def get_branding_manifest(db: Session) -> dict[str, object]:
    payload = get_effective_branding(db)
    return {
        "name": payload.get("resolved_app_title") if isinstance(payload.get("resolved_app_title"), str) else _BRANDING_DEFAULT_APP_TITLE,
        "short_name": payload.get("resolved_application_short_name") if isinstance(payload.get("resolved_application_short_name"), str) else _BRANDING_DEFAULT_SHORT_NAME,
        "start_url": ".",
        "display": "standalone",
        "background_color": payload.get("resolved_install_background_hex") if isinstance(payload.get("resolved_install_background_hex"), str) else _BRANDING_DEFAULT_INSTALL_BACKGROUND_HEX,
        "theme_color": payload.get("resolved_theme_color_hex") if isinstance(payload.get("resolved_theme_color_hex"), str) else _BRANDING_DEFAULT_THEME_HEX,
        "description": payload.get("resolved_web_description") if isinstance(payload.get("resolved_web_description"), str) else _BRANDING_DEFAULT_DESCRIPTION,
        "orientation": "portrait-primary",
        "prefer_related_applications": False,
        "icons": [
            {
                "src": "icons/Icon-192.png",
                "sizes": "192x192",
                "type": "image/png",
            },
            {
                "src": "icons/Icon-512.png",
                "sizes": "512x512",
                "type": "image/png",
            },
            {
                "src": "icons/Icon-maskable-192.png",
                "sizes": "192x192",
                "type": "image/png",
                "purpose": "maskable",
            },
            {
                "src": "icons/Icon-maskable-512.png",
                "sizes": "512x512",
                "type": "image/png",
                "purpose": "maskable",
            },
        ],
    }


def _require_org_unit(db: Session, org_unit_id: str) -> OrganizationUnit:
    row = db.get(OrganizationUnit, org_unit_id)
    if not row:
        raise not_found("Organization unit not found")
    return row


def list_organization_units(db: Session) -> list[OrganizationUnit]:
    q = select(OrganizationUnit).order_by(OrganizationUnit.unit_type.asc(), OrganizationUnit.name.asc())
    return list(db.execute(q).scalars().all())


def create_organization_unit(
    db: Session,
    *,
    name: str,
    slug: str,
    unit_type: str,
    parent_id: str | None,
    active: bool,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> OrganizationUnit:
    normalized_slug = _normalize_slug(slug)
    if db.scalar(select(OrganizationUnit).where(OrganizationUnit.slug == normalized_slug)):
        raise bad_request("Organization unit slug already exists")
    if parent_id:
        _require_org_unit(db, parent_id)
    row = OrganizationUnit(
        id=str(uuid.uuid4()),
        name=name.strip(),
        slug=normalized_slug,
        unit_type=_normalize_unit_type(unit_type),
        active=active,
        meta_json=_encode_meta_json(meta),
    )
    if not row.name:
        raise bad_request("Organization unit name is required")
    db.add(row)
    sync_organization_unit_item(db, row)
    _sync_org_unit_primary_parent_link(
        db,
        org_unit_id=row.id,
        previous_parent_id=None,
        next_parent_id=parent_id,
    )
    if meta is not None:
        _append_org_audit_event(
            db,
            scope_kind="item",
            action="meta_create",
            actor_user_id=actor_user_id,
            item_kind="department",
            item_id=row.id,
            summary="Department created with metadata",
            before_json=None,
            after_json=_encode_meta_json(meta),
        )
    _queue_organization_item_translations(
        db,
        item_kind="department",
        item_id=row.id,
        name=row.name,
        meta=_decode_meta_json(row.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(row)
    return row


def _org_descendant_ids(db: Session, org_unit_id: str | None) -> set[str]:
    if not org_unit_id:
        return set()
    seen: set[str] = set()
    stack = [org_unit_id]
    child_ids_by_parent = _active_department_child_ids_by_parent(db)
    while stack:
        current_id = stack.pop()
        for child_id in child_ids_by_parent.get(current_id, []):
            if child_id in seen:
                continue
            seen.add(child_id)
            stack.append(child_id)
    return seen


def update_organization_unit(
    db: Session,
    org_unit_id: str,
    *,
    name: str | None = None,
    slug: str | None = None,
    unit_type: str | None = None,
    parent_id: str | None = None,
    parent_id_provided: bool = False,
    active: bool | None = None,
    meta: dict[str, object] | None = None,
    actor_user_id: str | None = None,
) -> OrganizationUnit:
    row = _require_org_unit(db, org_unit_id)
    previous_parent_id = _primary_org_unit_parent_id(db, row.id)
    before_meta = _decode_meta_json(row.meta_json)
    if name is not None:
        next_name = name.strip()
        if not next_name:
            raise bad_request("Organization unit name is required")
        row.name = next_name
    if slug is not None:
        normalized_slug = _normalize_slug(slug)
        existing = db.scalar(select(OrganizationUnit).where(OrganizationUnit.slug == normalized_slug, OrganizationUnit.id != row.id))
        if existing:
            raise bad_request("Organization unit slug already exists")
        row.slug = normalized_slug
    if unit_type is not None:
        row.unit_type = _normalize_unit_type(unit_type)
    normalized_parent_id = _clean_optional_text(parent_id)
    if parent_id_provided:
        if normalized_parent_id == row.id:
            raise bad_request("An organization unit cannot be its own parent")
        if normalized_parent_id:
            _require_org_unit(db, normalized_parent_id)
            if normalized_parent_id in _org_descendant_ids(db, row.id):
                raise bad_request("Parent would create a hierarchy cycle")
    if active is not None:
        row.active = active
    if meta is not None:
        row.meta_json = _encode_meta_json(meta)
    sync_organization_unit_item(db, row)
    if parent_id_provided:
        _sync_org_unit_primary_parent_link(
            db,
            org_unit_id=row.id,
            previous_parent_id=previous_parent_id,
            next_parent_id=normalized_parent_id,
        )
    if meta is not None:
        before_json, after_json = _json_if_changed(
            before=before_meta,
            after=_decode_meta_json(row.meta_json),
        )
        if before_json is not None or after_json is not None:
            _append_org_audit_event(
                db,
                scope_kind="item",
                action="meta_update",
                actor_user_id=actor_user_id,
                item_kind="department",
                item_id=row.id,
                summary="Department metadata updated",
                before_json=before_json,
                after_json=after_json,
            )
    _queue_organization_item_translations(
        db,
        item_kind="department",
        item_id=row.id,
        name=row.name,
        meta=_decode_meta_json(row.meta_json),
        actor_user_id=actor_user_id,
    )
    db.commit()
    db.refresh(row)
    return row


def delete_organization_unit(db: Session, org_unit_id: str) -> None:
    row = _require_org_unit(db, org_unit_id)

    child_count = int(
        db.scalar(
            select(func.count(OrganizationItemLink.id)).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.parent_id == org_unit_id,
                OrganizationItemLink.child_kind == "department",
                OrganizationItemLink.active.is_(True),
            )
        )
        or 0
    )
    item_link_count = int(
        db.scalar(
            select(func.count(OrganizationItemLink.id)).where(
                OrganizationItemLink.active.is_(True),
                or_(
                    and_(
                        OrganizationItemLink.parent_kind == "department",
                        OrganizationItemLink.parent_id == org_unit_id,
                    ),
                    and_(
                        OrganizationItemLink.child_kind == "department",
                        OrganizationItemLink.child_id == org_unit_id,
                    ),
                ),
            )
        )
        or 0
    )

    blocking_parts: list[str] = []
    if child_count > 0:
        blocking_parts.append(f"children={child_count}")
    if item_link_count > 0:
        blocking_parts.append(f"organization_item_links={item_link_count}")
    if blocking_parts:
        summary = ", ".join(blocking_parts)
        raise bad_request("Cannot delete organization unit while linked data exists " f"({summary})")

    delete_organization_item(db, org_unit_id)
    db.delete(row)
    db.commit()


def list_organization_item_links(db: Session) -> list[OrganizationItemLink]:
    q = (
        select(OrganizationItemLink)
        .where(OrganizationItemLink.active.is_(True))
        .order_by(
            OrganizationItemLink.parent_kind.asc(),
            OrganizationItemLink.parent_id.asc(),
            OrganizationItemLink.child_kind.asc(),
            OrganizationItemLink.child_id.asc(),
            OrganizationItemLink.created_at.asc(),
        )
    )
    return list(db.execute(q).scalars().all())


def _organization_item_link_payload(link: OrganizationItemLink) -> dict[str, object]:
    return {
        "id": link.id,
        "parent_kind": link.parent_kind,
        "parent_id": link.parent_id,
        "child_kind": link.child_kind,
        "child_id": link.child_id,
        "grant_role": link.grant_role,
        "inherit_to_descendants": bool(link.inherit_to_descendants),
        "active": bool(link.active),
    }


def create_organization_item_link(
    db: Session,
    *,
    parent_kind: str,
    parent_id: str,
    child_kind: str,
    child_id: str,
    grant_role: str,
    inherit_to_descendants: bool,
    active: bool,
    actor_user_id: str | None = None,
    commit: bool = True,
) -> OrganizationItemLink:
    normalized_parent_kind = parent_kind.strip().lower()
    normalized_child_kind = child_kind.strip().lower()
    normalized_parent_id = _clean_optional_text(parent_id)
    normalized_child_id = _clean_optional_text(child_id)
    if normalized_parent_id is None or normalized_child_id is None:
        raise bad_request("parent_id and child_id are required")

    if (normalized_parent_kind, normalized_child_kind) not in _SUPPORTED_ITEM_LINK_PAIRS:
        raise bad_request("Unsupported item-link kind pair")

    if normalized_parent_kind == "department":
        _require_org_unit(db, normalized_parent_id)
    elif normalized_parent_kind == "user":
        if not db.get(User, normalized_parent_id):
            raise not_found("Parent user not found")
    elif normalized_parent_kind == "role":
        if not _role_exists(db, normalized_parent_id):
            raise not_found("Parent role not found")

    if normalized_child_kind == "space":
        if not db.get(Space, normalized_child_id):
            raise not_found("Child space not found")
    elif normalized_child_kind == "department":
        _require_org_unit(db, normalized_child_id)
    elif normalized_child_kind == "user":
        if not db.get(User, normalized_child_id):
            raise not_found("Child user not found")

    if normalized_parent_kind == normalized_child_kind and normalized_parent_id == normalized_child_id:
        raise bad_request("Parent and child cannot be the same item")
    if normalized_parent_kind == "department" and normalized_child_kind == "department" and normalized_parent_id in _org_descendant_ids(db, normalized_child_id):
        raise bad_request("Parent would create a hierarchy cycle")

    normalized_grant_role = grant_role.strip().lower()
    if normalized_parent_kind == "department" and normalized_child_kind == "space":
        if not spaces_service.is_valid_assignable_space_role(db, normalized_grant_role):
            raise bad_request("Invalid grant role")
    if normalized_parent_kind == "role" and normalized_child_kind == "user":
        normalized_grant_role = normalized_parent_id

    if normalized_parent_kind == "department" and normalized_child_kind in {
        "department",
        "user",
    }:
        conflicting_links = list(
            db.execute(
                select(OrganizationItemLink).where(
                    OrganizationItemLink.parent_kind == "department",
                    OrganizationItemLink.child_kind == normalized_child_kind,
                    OrganizationItemLink.child_id == normalized_child_id,
                    OrganizationItemLink.active.is_(True),
                    OrganizationItemLink.parent_id != normalized_parent_id,
                )
            )
            .scalars()
            .all()
        )
        for conflicting_link in conflicting_links:
            delete_organization_item_link(
                db,
                conflicting_link.id,
                actor_user_id=actor_user_id,
                commit=False,
            )

    existing = db.scalar(
        select(OrganizationItemLink).where(
            OrganizationItemLink.parent_kind == normalized_parent_kind,
            OrganizationItemLink.parent_id == normalized_parent_id,
            OrganizationItemLink.child_kind == normalized_child_kind,
            OrganizationItemLink.child_id == normalized_child_id,
        )
    )
    if existing is not None:
        before_payload = _organization_item_link_payload(existing)
        existing.grant_role = normalized_grant_role
        existing.inherit_to_descendants = inherit_to_descendants
        existing.active = active
        after_payload = _organization_item_link_payload(existing)
        before_json, after_json = _json_if_changed(
            before=before_payload,
            after=after_payload,
        )
        if before_json is not None or after_json is not None:
            _append_org_audit_event(
                db,
                scope_kind="item_link",
                action="update",
                actor_user_id=actor_user_id,
                link_parent_kind=normalized_parent_kind,
                link_parent_id=normalized_parent_id,
                link_child_kind=normalized_child_kind,
                link_child_id=normalized_child_id,
                summary="Organization item-link updated",
                before_json=before_json,
                after_json=after_json,
            )
        if commit:
            db.commit()
            db.refresh(existing)
        else:
            db.flush()
        return existing

    row = OrganizationItemLink(
        id=str(uuid.uuid4()),
        parent_kind=normalized_parent_kind,
        parent_id=normalized_parent_id,
        child_kind=normalized_child_kind,
        child_id=normalized_child_id,
        grant_role=normalized_grant_role,
        inherit_to_descendants=inherit_to_descendants,
        active=active,
    )
    db.add(row)
    _append_org_audit_event(
        db,
        scope_kind="item_link",
        action="create",
        actor_user_id=actor_user_id,
        link_parent_kind=normalized_parent_kind,
        link_parent_id=normalized_parent_id,
        link_child_kind=normalized_child_kind,
        link_child_id=normalized_child_id,
        summary="Organization item-link created",
        after_json=json.dumps(_organization_item_link_payload(row), ensure_ascii=False, separators=(",", ":")),
    )
    if commit:
        db.commit()
        db.refresh(row)
    else:
        db.flush()
    return row


def delete_organization_item_link(
    db: Session,
    link_id: str,
    *,
    actor_user_id: str | None = None,
    commit: bool = True,
) -> None:
    row = db.get(OrganizationItemLink, link_id)
    if not row:
        raise not_found("Organization item link not found")
    before_payload = _organization_item_link_payload(row)
    _append_org_audit_event(
        db,
        scope_kind="item_link",
        action="delete",
        actor_user_id=actor_user_id,
        link_parent_kind=row.parent_kind,
        link_parent_id=row.parent_id,
        link_child_kind=row.child_kind,
        link_child_id=row.child_id,
        summary="Organization item-link deleted",
        before_json=json.dumps(before_payload, ensure_ascii=False, separators=(",", ":")),
    )
    db.delete(row)
    if commit:
        db.commit()
    else:
        db.flush()


def list_organization_audit_events(
    db: Session,
    *,
    item_kind: str | None = None,
    item_id: str | None = None,
    limit: int = 120,
) -> list[OrganizationAuditEvent]:
    normalized_kind = _clean_optional_text(item_kind)
    if normalized_kind is not None:
        normalized_kind = normalized_kind.lower()
    normalized_item_id = _clean_optional_text(item_id)

    q = select(OrganizationAuditEvent)

    if normalized_kind is not None and normalized_item_id is not None:
        q = q.where(
            or_(
                and_(
                    OrganizationAuditEvent.item_kind == normalized_kind,
                    OrganizationAuditEvent.item_id == normalized_item_id,
                ),
                and_(
                    OrganizationAuditEvent.link_parent_kind == normalized_kind,
                    OrganizationAuditEvent.link_parent_id == normalized_item_id,
                ),
                and_(
                    OrganizationAuditEvent.link_child_kind == normalized_kind,
                    OrganizationAuditEvent.link_child_id == normalized_item_id,
                ),
            )
        )
    elif normalized_kind is not None:
        q = q.where(
            or_(
                OrganizationAuditEvent.item_kind == normalized_kind,
                OrganizationAuditEvent.link_parent_kind == normalized_kind,
                OrganizationAuditEvent.link_child_kind == normalized_kind,
            )
        )
    elif normalized_item_id is not None:
        q = q.where(
            or_(
                OrganizationAuditEvent.item_id == normalized_item_id,
                OrganizationAuditEvent.link_parent_id == normalized_item_id,
                OrganizationAuditEvent.link_child_id == normalized_item_id,
            )
        )

    safe_limit = max(1, min(int(limit or 120), 500))
    q = q.order_by(OrganizationAuditEvent.created_at.desc()).limit(safe_limit)
    return list(db.execute(q).scalars().all())


def _decode_json_object(value: str | None) -> dict[str, object] | None:
    if not value:
        return None
    try:
        decoded = json.loads(value)
    except Exception:
        return None
    return decoded if isinstance(decoded, dict) else None


def explain_user_space_access(
    db: Session,
    *,
    user_id: str,
    space_id: str,
) -> dict[str, object]:
    user = db.get(User, user_id)
    if user is None:
        raise not_found("User not found")
    space = db.get(Space, space_id)
    if space is None:
        raise not_found("Space not found")

    direct_department_ids = {
        department_id.strip()
        for department_id, in db.execute(
            select(OrganizationItemLink.parent_id).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.child_id == user_id,
                OrganizationItemLink.active.is_(True),
            )
        ).all()
        if isinstance(department_id, str) and department_id.strip()
    }

    parents_by_child: dict[str, set[str]] = defaultdict(set)
    for parent_id, child_id in db.execute(
        select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.child_kind == "department",
            OrganizationItemLink.active.is_(True),
        )
    ).all():
        if not isinstance(parent_id, str) or not isinstance(child_id, str):
            continue
        normalized_parent_id = parent_id.strip()
        normalized_child_id = child_id.strip()
        if normalized_parent_id and normalized_child_id:
            parents_by_child[normalized_child_id].add(normalized_parent_id)

    ancestor_cache: dict[str, set[str]] = {}
    ancestor_department_ids: set[str] = set()
    for department_id in direct_department_ids:
        ancestor_department_ids.update(
            _ancestor_chain_for_department_ids(
                department_id,
                parents_by_child=parents_by_child,
                cache=ancestor_cache,
            )
        )

    relevant_department_ids = sorted(
        direct_department_ids.union(ancestor_department_ids)
    )
    department_names: dict[str, str] = {}
    if relevant_department_ids:
        rows = db.execute(
            select(OrganizationUnit.id, OrganizationUnit.name).where(
                OrganizationUnit.id.in_(relevant_department_ids)
            )
        ).all()
        for department_id, name in rows:
            if not isinstance(department_id, str):
                continue
            department_names[department_id] = (
                name.strip() if isinstance(name, str) and name.strip() else department_id
            )

    role_levels = _active_effective_role_levels(db)
    matching_rows: list[tuple[int, dict[str, object]]] = []
    best_rank = -1
    selected_grant_role: str | None = None
    selected_effective_role: str | None = None

    space_links = list(
        db.execute(
            select(OrganizationItemLink).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.child_kind == "space",
                OrganizationItemLink.child_id == space_id,
                OrganizationItemLink.active.is_(True),
            )
        ).scalars().all()
    )
    for link in space_links:
        department_id = (link.parent_id or "").strip()
        if not department_id:
            continue
        source: str | None = None
        if department_id in direct_department_ids:
            source = "direct_department"
        elif bool(link.inherit_to_descendants) and department_id in ancestor_department_ids:
            source = "ancestor_department"
        if source is None:
            continue

        grant_role = (link.grant_role or "").strip().lower()
        if not grant_role:
            continue
        effective_role = role_levels.get(grant_role)
        rank = _SPACE_ROLE_RANK.get(effective_role or "", -1)
        if rank > best_rank:
            best_rank = rank
            selected_grant_role = grant_role
            selected_effective_role = effective_role

        matching_rows.append(
            (
                rank,
                {
                    "link_id": link.id,
                    "department_id": department_id,
                    "department_name": department_names.get(department_id, department_id),
                    "grant_role": grant_role,
                    "effective_role": effective_role,
                    "inherit_to_descendants": bool(link.inherit_to_descendants),
                    "source": source,
                },
            )
        )

    matching_rows.sort(
        key=lambda pair: (
            -pair[0],
            str(pair[1].get("department_name", "")).lower(),
            str(pair[1].get("grant_role", "")).lower(),
        )
    )
    matching_grants = [row for _, row in matching_rows]

    system_role = resolve_user_auth_role(db, user)
    system_role_effective = role_levels.get(system_role, _normalized_auth_role(system_role))

    final_role = selected_grant_role
    final_effective_role = selected_effective_role
    if system_role in {"admin", "moderator"}:
        final_role = system_role
        final_effective_role = system_role

    return {
        "user_id": user.id,
        "user_name": (user.name or "").strip() or (user.email or "").strip() or user.id,
        "space_id": space.id,
        "space_name": (space.name or "").strip() or space.id,
        "system_role": system_role,
        "system_role_effective": system_role_effective,
        "direct_department_ids": sorted(direct_department_ids),
        "ancestor_department_ids": sorted(ancestor_department_ids - direct_department_ids),
        "matching_grants": matching_grants,
        "selected_grant_role": selected_grant_role,
        "selected_effective_role": selected_effective_role,
        "final_role": final_role,
        "final_effective_role": final_effective_role,
        "access_granted": bool(final_role),
    }


def simulate_organization_role_impact(
    db: Session,
    *,
    global_role_changes: list[Mapping[str, object]],
    space_grant_changes: list[Mapping[str, object]],
    space_grant_removals: list[Mapping[str, object]],
) -> dict[str, object]:
    before_rows = _active_link_payload_rows(db)
    after_map: dict[tuple[str, str, str, str], dict[str, object]] = {
        _link_key_from_payload(row): dict(row) for row in before_rows
    }

    simulated_space_grant_changes = 0
    simulated_space_grant_removals = 0

    for removal in space_grant_removals:
        department_id = str(removal.get("department_id", "")).strip()
        space_id = str(removal.get("space_id", "")).strip()
        if not department_id or not space_id:
            raise bad_request("space_grant_removals entries require department_id and space_id")
        _require_org_unit(db, department_id)
        if db.get(Space, space_id) is None:
            raise not_found(f"Space '{space_id}' not found")
        key = _normalized_link_key(
            parent_kind="department",
            parent_id=department_id,
            child_kind="space",
            child_id=space_id,
        )
        if after_map.pop(key, None) is not None:
            simulated_space_grant_removals += 1

    for change in space_grant_changes:
        department_id = str(change.get("department_id", "")).strip()
        space_id = str(change.get("space_id", "")).strip()
        grant_role = str(change.get("grant_role", "member")).strip().lower()
        inherit_to_descendants = bool(change.get("inherit_to_descendants", True))
        active = bool(change.get("active", True))
        if not department_id or not space_id:
            raise bad_request("space_grant_changes entries require department_id and space_id")
        _require_org_unit(db, department_id)
        if db.get(Space, space_id) is None:
            raise not_found(f"Space '{space_id}' not found")
        if not spaces_service.is_valid_assignable_space_role(db, grant_role):
            raise bad_request(f"Invalid grant_role '{grant_role}' for space grant simulation")

        key = _normalized_link_key(
            parent_kind="department",
            parent_id=department_id,
            child_kind="space",
            child_id=space_id,
        )
        if not active:
            if after_map.pop(key, None) is not None:
                simulated_space_grant_removals += 1
            continue

        existing = after_map.get(key)
        candidate = {
            "id": str(existing.get("id", "")) if existing is not None else "",
            "parent_kind": "department",
            "parent_id": department_id,
            "child_kind": "space",
            "child_id": space_id,
            "grant_role": grant_role,
            "inherit_to_descendants": inherit_to_descendants,
            "active": True,
        }
        if existing is None or _link_payload_map([existing])[key] != _link_payload_map([candidate])[key]:
            simulated_space_grant_changes += 1
        after_map[key] = candidate

    before_global_overrides: dict[str, str] = {}
    after_global_overrides: dict[str, str] = {}
    simulated_global_role_changes = 0

    for change in global_role_changes:
        user_id = str(change.get("user_id", "")).strip()
        role_key = str(change.get("role_key", "")).strip().lower()
        if not user_id or not role_key:
            raise bad_request("global_role_changes entries require user_id and role_key")
        if role_key not in ALLOWED_GLOBAL_ROLES:
            raise bad_request("global role simulation supports built-in roles only")

        user = db.get(User, user_id)
        if user is None:
            raise not_found(f"User '{user_id}' not found")

        previous_role = _normalized_auth_role(getattr(user, "global_role", None))
        before_global_overrides[user_id] = previous_role
        after_global_overrides[user_id] = role_key
        if previous_role != role_key:
            simulated_global_role_changes += 1

    access_impact = _access_impact_for_snapshots(
        db,
        before_links=before_rows,
        after_links=list(after_map.values()),
        before_global_role_overrides=before_global_overrides or None,
        after_global_role_overrides=after_global_overrides or None,
    )

    return {
        "ok": True,
        "simulated_global_role_changes": simulated_global_role_changes,
        "simulated_space_grant_changes": simulated_space_grant_changes,
        "simulated_space_grant_removals": simulated_space_grant_removals,
        "access_impact": {
            "affected_user_count": int(access_impact.get("affected_user_count", 0)),
            "affected_space_count": int(access_impact.get("affected_space_count", 0)),
            "changed_membership_count": int(access_impact.get("changed_pair_count", 0)),
            "truncated": bool(access_impact.get("truncated", False)),
            "changes": list(access_impact.get("changes", [])),
        },
    }


def _normalized_link_key(
    *,
    parent_kind: str,
    parent_id: str,
    child_kind: str,
    child_id: str,
) -> tuple[str, str, str, str]:
    return (
        (parent_kind or "").strip().lower(),
        (parent_id or "").strip(),
        (child_kind or "").strip().lower(),
        (child_id or "").strip(),
    )


def _link_key_from_payload(payload: Mapping[str, object]) -> tuple[str, str, str, str]:
    return _normalized_link_key(
        parent_kind=str(payload.get("parent_kind", "")),
        parent_id=str(payload.get("parent_id", "")),
        child_kind=str(payload.get("child_kind", "")),
        child_id=str(payload.get("child_id", "")),
    )


def _active_link_payload_rows(db: Session) -> list[dict[str, object]]:
    return [_organization_item_link_payload(link) for link in list_organization_item_links(db)]


def _link_payload_map(rows: list[dict[str, object]]) -> dict[tuple[str, str, str, str], dict[str, object]]:
    mapped: dict[tuple[str, str, str, str], dict[str, object]] = {}
    for row in rows:
        mapped[_link_key_from_payload(row)] = {
            "grant_role": str(row.get("grant_role", "")).strip().lower(),
            "inherit_to_descendants": bool(row.get("inherit_to_descendants", False)),
            "active": bool(row.get("active", False)),
        }
    return mapped


def _summarize_link_diff(
    *,
    before_rows: list[dict[str, object]],
    after_rows: list[dict[str, object]],
) -> tuple[int, int, int]:
    before_map = _link_payload_map(before_rows)
    after_map = _link_payload_map(after_rows)
    created = len([key for key in after_map if key not in before_map])
    deleted = len([key for key in before_map if key not in after_map])
    updated = len(
        [
            key
            for key in set(before_map.keys()).intersection(after_map.keys())
            if before_map[key] != after_map[key]
        ]
    )
    return created, updated, deleted


def _active_effective_role_levels(db: Session) -> dict[str, str]:
    role_levels = {role_key: role_key for role_key in BUILTIN_ROLE_ORDER}
    for role_key, effective_level in db.execute(
        select(CustomRole.role_key, CustomRole.effective_level).where(
            CustomRole.active.is_(True),
        )
    ).all():
        if not isinstance(role_key, str) or not isinstance(effective_level, str):
            continue
        normalized_key = role_key.strip().lower()
        normalized_level = effective_level.strip().lower()
        if normalized_key and normalized_level in _AUTH_ROLE_RANK:
            role_levels[normalized_key] = normalized_level
    return role_levels


def _normalized_auth_role(value: str | None) -> str:
    normalized = (value or "").strip().lower()
    if normalized in _AUTH_ROLE_RANK:
        return normalized
    return "member"


def _resolve_auth_role_snapshot(
    *,
    stored_role: str | None,
    role_keys: set[str],
    effective_levels: Mapping[str, str],
) -> str:
    best_role = _normalized_auth_role(stored_role)
    best_rank = _AUTH_ROLE_RANK.get(best_role, 1)
    for role_key in role_keys:
        normalized_key = role_key.strip().lower()
        if not normalized_key:
            continue
        effective = effective_levels.get(normalized_key)
        if effective is None:
            continue
        rank = _AUTH_ROLE_RANK.get(effective, -1)
        if rank > best_rank:
            best_role = effective
            best_rank = rank
    return best_role


def _ancestor_chain_for_department_ids(
    department_id: str,
    *,
    parents_by_child: Mapping[str, set[str]],
    cache: dict[str, set[str]],
    visiting: set[str] | None = None,
) -> set[str]:
    cached = cache.get(department_id)
    if cached is not None:
        return cached

    if visiting is None:
        visiting = set()
    if department_id in visiting:
        return {department_id}

    visiting.add(department_id)
    chain: set[str] = {department_id}
    for parent_id in parents_by_child.get(department_id, set()):
        chain.update(
            _ancestor_chain_for_department_ids(
                parent_id,
                parents_by_child=parents_by_child,
                cache=cache,
                visiting=visiting,
            )
        )
    visiting.remove(department_id)
    cache[department_id] = chain
    return chain


def _compute_membership_matrix(
    db: Session,
    *,
    links: list[dict[str, object]],
    global_role_overrides: Mapping[str, str] | None = None,
) -> tuple[
    dict[tuple[str, str], str],
    dict[str, str],
    dict[str, str],
]:
    role_overrides = global_role_overrides or {}
    effective_levels = _active_effective_role_levels(db)

    user_rows = list(
        db.execute(
            select(
                User.id,
                User.name,
                User.email,
                User.global_role,
                User.is_active,
            )
        ).all()
    )
    space_rows = list(db.execute(select(Space.id, Space.name)).all())

    user_name_by_id: dict[str, str] = {}
    active_user_ids: set[str] = set()
    for user_id, name, email, _global_role, is_active in user_rows:
        if not isinstance(user_id, str) or not user_id.strip():
            continue
        normalized_id = user_id.strip()
        display_name = ""
        if isinstance(name, str):
            display_name = name.strip()
        if not display_name and isinstance(email, str):
            display_name = email.strip()
        user_name_by_id[normalized_id] = display_name or normalized_id
        if bool(is_active):
            active_user_ids.add(normalized_id)

    space_name_by_id: dict[str, str] = {}
    all_space_ids: list[str] = []
    for space_id, name in space_rows:
        if not isinstance(space_id, str) or not space_id.strip():
            continue
        normalized_id = space_id.strip()
        all_space_ids.append(normalized_id)
        label = name.strip() if isinstance(name, str) and name.strip() else normalized_id
        space_name_by_id[normalized_id] = label

    role_keys_by_user: dict[str, set[str]] = defaultdict(set)
    direct_units_by_user: dict[str, set[str]] = defaultdict(set)
    parents_by_child_unit: dict[str, set[str]] = defaultdict(set)
    department_space_links: list[dict[str, object]] = []

    for row in links:
        if row.get("active") is False:
            continue
        parent_kind, parent_id, child_kind, child_id = _link_key_from_payload(row)
        if not parent_id or not child_id:
            continue
        if (parent_kind, child_kind) == ("role", "user"):
            role_keys_by_user[child_id].add(parent_id)
            continue
        if (parent_kind, child_kind) == ("department", "user"):
            direct_units_by_user[child_id].add(parent_id)
            continue
        if (parent_kind, child_kind) == ("department", "department"):
            parents_by_child_unit[child_id].add(parent_id)
            continue
        if (parent_kind, child_kind) == ("department", "space"):
            department_space_links.append(
                {
                    "parent_id": parent_id,
                    "child_id": child_id,
                    "grant_role": str(row.get("grant_role", "")).strip().lower(),
                    "inherit_to_descendants": bool(row.get("inherit_to_descendants", False)),
                }
            )

    membership_by_user_space: dict[tuple[str, str], str] = {}
    ancestor_cache: dict[str, set[str]] = {}

    for user_id, _name, _email, global_role, _is_active in user_rows:
        if not isinstance(user_id, str):
            continue
        normalized_user_id = user_id.strip()
        if not normalized_user_id or normalized_user_id not in active_user_ids:
            continue

        effective_system_role = _resolve_auth_role_snapshot(
            stored_role=str(role_overrides.get(normalized_user_id, global_role) or ""),
            role_keys=role_keys_by_user.get(normalized_user_id, set()),
            effective_levels=effective_levels,
        )
        if effective_system_role in {"admin", "moderator"}:
            for space_id in all_space_ids:
                membership_by_user_space[(normalized_user_id, space_id)] = effective_system_role
            continue

        direct_units = direct_units_by_user.get(normalized_user_id, set())
        if not direct_units:
            continue

        ancestor_units: set[str] = set()
        for unit_id in direct_units:
            ancestor_units.update(
                _ancestor_chain_for_department_ids(
                    unit_id,
                    parents_by_child=parents_by_child_unit,
                    cache=ancestor_cache,
                )
            )

        best_rank_by_space: dict[str, int] = {}
        best_role_by_space: dict[str, str] = {}
        for link in department_space_links:
            parent_id = str(link.get("parent_id", "")).strip()
            space_id = str(link.get("child_id", "")).strip()
            grant_role = str(link.get("grant_role", "")).strip().lower()
            inherit_to_descendants = bool(link.get("inherit_to_descendants", False))
            if not parent_id or not space_id or not grant_role:
                continue
            if parent_id not in direct_units and not (inherit_to_descendants and parent_id in ancestor_units):
                continue
            effective_role = effective_levels.get(grant_role)
            if effective_role is None:
                continue
            rank = _SPACE_ROLE_RANK.get(effective_role, -1)
            if rank > best_rank_by_space.get(space_id, -1):
                best_rank_by_space[space_id] = rank
                best_role_by_space[space_id] = grant_role

        for space_id, role_key in best_role_by_space.items():
            membership_by_user_space[(normalized_user_id, space_id)] = role_key

    return membership_by_user_space, user_name_by_id, space_name_by_id


def _access_impact_for_snapshots(
    db: Session,
    *,
    before_links: list[dict[str, object]],
    after_links: list[dict[str, object]],
    before_global_role_overrides: Mapping[str, str] | None = None,
    after_global_role_overrides: Mapping[str, str] | None = None,
    max_changes: int = 500,
) -> dict[str, object]:
    before_membership, user_name_by_id, space_name_by_id = _compute_membership_matrix(
        db,
        links=before_links,
        global_role_overrides=before_global_role_overrides,
    )
    after_membership, _, _ = _compute_membership_matrix(
        db,
        links=after_links,
        global_role_overrides=after_global_role_overrides,
    )

    all_keys = sorted(set(before_membership.keys()).union(after_membership.keys()))
    changed_user_ids: set[str] = set()
    changed_space_ids: set[str] = set()
    changes: list[dict[str, object]] = []
    truncated = False
    changed_pair_count = 0

    for user_id, space_id in all_keys:
        before_role = before_membership.get((user_id, space_id))
        after_role = after_membership.get((user_id, space_id))
        if before_role == after_role:
            continue
        changed_pair_count += 1
        changed_user_ids.add(user_id)
        changed_space_ids.add(space_id)
        if len(changes) >= max_changes:
            truncated = True
            continue
        changes.append(
            {
                "user_id": user_id,
                "user_name": user_name_by_id.get(user_id),
                "space_id": space_id,
                "space_name": space_name_by_id.get(space_id),
                "before_role": before_role,
                "after_role": after_role,
            }
        )

    return {
        "affected_user_count": len(changed_user_ids),
        "affected_space_count": len(changed_space_ids),
        "changed_membership_count": changed_pair_count,
        "truncated": truncated,
        "changes": changes,
        "changed_pair_count": changed_pair_count,
    }


def _apply_role_rebind_groups(
    db: Session,
    *,
    rebind_groups: list[Mapping[str, object]],
    actor_user_id: str | None,
) -> tuple[int, dict[str, str]]:
    rebound_count = 0
    previous_global_role_by_user: dict[str, str] = {}

    for group in rebind_groups:
        role_key = str(group.get("role_key", "")).strip().lower()
        if not role_key:
            raise bad_request("role_key is required for rebind operation")
        if not _role_exists(db, role_key):
            raise bad_request(f"Role '{role_key}' was not found or is inactive")

        raw_user_ids = group.get("user_ids")
        if not isinstance(raw_user_ids, list):
            raise bad_request("rebind_roles.user_ids must be an array")
        user_ids = sorted({str(user_id).strip() for user_id in raw_user_ids if str(user_id).strip()})
        if not user_ids:
            continue

        for user_id in user_ids:
            user = db.get(User, user_id)
            if user is None:
                raise not_found(f"User '{user_id}' not found")

            previous_global = _normalized_auth_role(getattr(user, "global_role", None))
            previous_global_role_by_user[user_id] = previous_global

            existing_links = list(
                db.execute(
                    select(OrganizationItemLink).where(
                        OrganizationItemLink.parent_kind == "role",
                        OrganizationItemLink.child_kind == "user",
                        OrganizationItemLink.child_id == user_id,
                        OrganizationItemLink.active.is_(True),
                    )
                ).scalars().all()
            )
            for existing_link in existing_links:
                delete_organization_item_link(
                    db,
                    existing_link.id,
                    actor_user_id=actor_user_id,
                    commit=False,
                )

            create_organization_item_link(
                db,
                parent_kind="role",
                parent_id=role_key,
                child_kind="user",
                child_id=user_id,
                grant_role=role_key,
                inherit_to_descendants=False,
                active=True,
                actor_user_id=actor_user_id,
                commit=False,
            )

            next_global_role = role_key if role_key in ALLOWED_GLOBAL_ROLES else "member"
            user.global_role = next_global_role
            sync_user_organization_item(db, user)
            sync_user_builtin_role_binding(db, user, role_key=next_global_role)

            if previous_global != next_global_role:
                append_user_lifecycle_audit_event(
                    db,
                    action="role_rebind",
                    user_id=user_id,
                    actor_user_id=actor_user_id,
                    summary="User role binding updated",
                    before={"global_role": previous_global},
                    after={"global_role": next_global_role},
                )

            rebound_count += 1

    return rebound_count, previous_global_role_by_user


def bulk_mutate_organization_item_links(
    db: Session,
    *,
    links: list[Mapping[str, object]],
    unlinks: list[Mapping[str, object]],
    rebind_roles: list[Mapping[str, object]],
    dry_run: bool,
    actor_user_id: str | None,
) -> dict[str, object]:
    before_rows = _active_link_payload_rows(db)
    before_global_overrides: dict[str, str] = {}

    try:
        for pair in unlinks:
            parent_kind, parent_id, child_kind, child_id = _link_key_from_payload(pair)
            if not parent_id or not child_id:
                raise bad_request("unlink operations require parent_id and child_id")
            if (parent_kind, child_kind) not in _SUPPORTED_ITEM_LINK_PAIRS:
                raise bad_request("Unsupported item-link kind pair")
            existing = db.scalar(
                select(OrganizationItemLink).where(
                    OrganizationItemLink.parent_kind == parent_kind,
                    OrganizationItemLink.parent_id == parent_id,
                    OrganizationItemLink.child_kind == child_kind,
                    OrganizationItemLink.child_id == child_id,
                    OrganizationItemLink.active.is_(True),
                )
            )
            if existing is None:
                continue
            delete_organization_item_link(
                db,
                existing.id,
                actor_user_id=actor_user_id,
                commit=False,
            )

        for payload in links:
            parent_kind, parent_id, child_kind, child_id = _link_key_from_payload(payload)
            grant_role = str(payload.get("grant_role", "member"))
            inherit_to_descendants = bool(payload.get("inherit_to_descendants", True))
            active = bool(payload.get("active", True))
            create_organization_item_link(
                db,
                parent_kind=parent_kind,
                parent_id=parent_id,
                child_kind=child_kind,
                child_id=child_id,
                grant_role=grant_role,
                inherit_to_descendants=inherit_to_descendants,
                active=active,
                actor_user_id=actor_user_id,
                commit=False,
            )

        rebound_count, previous_global_by_user = _apply_role_rebind_groups(
            db,
            rebind_groups=rebind_roles,
            actor_user_id=actor_user_id,
        )
        before_global_overrides.update(previous_global_by_user)

        after_rows = _active_link_payload_rows(db)
        link_created, link_updated, link_deleted = _summarize_link_diff(
            before_rows=before_rows,
            after_rows=after_rows,
        )
        access_impact = _access_impact_for_snapshots(
            db,
            before_links=before_rows,
            after_links=after_rows,
            before_global_role_overrides=before_global_overrides,
        )

        result = {
            "ok": True,
            "dry_run": bool(dry_run),
            "link_created": link_created,
            "link_updated": link_updated,
            "link_deleted": link_deleted,
            "role_rebound": rebound_count,
            "access_impact": {
                "affected_user_count": int(access_impact.get("affected_user_count", 0)),
                "affected_space_count": int(access_impact.get("affected_space_count", 0)),
                "changed_membership_count": int(access_impact.get("changed_pair_count", 0)),
                "truncated": bool(access_impact.get("truncated", False)),
                "changes": list(access_impact.get("changes", [])),
            },
        }

        if dry_run:
            db.rollback()
            return result

        _append_org_audit_event(
            db,
            scope_kind="graph",
            action="bulk_item_link_mutation",
            actor_user_id=actor_user_id,
            summary=(
                f"Bulk mutation applied: +{link_created} created, "
                f"~{link_updated} updated, -{link_deleted} deleted, "
                f"{rebound_count} role rebind(s)"
            ),
            after_json=_json_from_payload(
                {
                    "link_created": link_created,
                    "link_updated": link_updated,
                    "link_deleted": link_deleted,
                    "role_rebound": rebound_count,
                    "changed_membership_count": int(access_impact.get("changed_pair_count", 0)),
                }
            ),
        )
        db.commit()
        return result
    except Exception:
        db.rollback()
        raise


def _collect_graph_cycles(edges_by_parent: Mapping[str, set[str]]) -> list[list[str]]:
    cycles: list[list[str]] = []
    seen_signatures: set[tuple[str, ...]] = set()
    state: dict[str, int] = {}
    stack: list[str] = []

    def visit(node_id: str) -> None:
        state[node_id] = 1
        stack.append(node_id)
        for child_id in sorted(edges_by_parent.get(node_id, set())):
            child_state = state.get(child_id, 0)
            if child_state == 0:
                visit(child_id)
                continue
            if child_state != 1:
                continue
            if child_id not in stack:
                continue
            start_idx = stack.index(child_id)
            cycle = stack[start_idx:] + [child_id]
            signature = tuple(cycle)
            if signature in seen_signatures:
                continue
            seen_signatures.add(signature)
            cycles.append(cycle)
        stack.pop()
        state[node_id] = 2

    for node_id in sorted(edges_by_parent.keys()):
        if state.get(node_id, 0) == 0:
            visit(node_id)

    return cycles


def _entity_exists_for_kind(db: Session, *, kind: str, item_id: str) -> bool:
    normalized_kind = (kind or "").strip().lower()
    normalized_id = (item_id or "").strip()
    if not normalized_id:
        return False
    if normalized_kind == "user":
        return db.get(User, normalized_id) is not None
    if normalized_kind == "space":
        return db.get(Space, normalized_id) is not None
    if normalized_kind == "department":
        return db.get(OrganizationUnit, normalized_id) is not None
    if normalized_kind == "role":
        return normalized_id in ALLOWED_GLOBAL_ROLES or _role_exists(db, normalized_id)
    return False


def validate_organization_graph_integrity(db: Session) -> dict[str, object]:
    checked_at = _utc_now()
    items = list_organization_items(db)
    links = list_organization_item_links(db)
    item_by_id = {item.id: item for item in items}

    issues: list[dict[str, object]] = []

    for item in items:
        item_id = (item.id or "").strip()
        item_kind = (item.kind or "").strip().lower()
        if item_kind not in {"user", "space", "department", "role"}:
            issues.append(
                {
                    "code": "invalid_item_kind",
                    "severity": "warning",
                    "message": f"Organization item '{item_id}' has unsupported kind '{item_kind}'",
                    "item_id": item_id,
                }
            )
            continue
        if not _entity_exists_for_kind(db, kind=item_kind, item_id=item_id):
            issues.append(
                {
                    "code": "dangling_item",
                    "severity": "error",
                    "message": (
                        f"Organization item '{item_id}' ({item_kind}) has no backing entity"
                    ),
                    "item_id": item_id,
                }
            )

    department_edges: dict[str, set[str]] = defaultdict(set)
    manager_edges: dict[str, set[str]] = defaultdict(set)

    for link in links:
        parent_kind = (link.parent_kind or "").strip().lower()
        parent_id = (link.parent_id or "").strip()
        child_kind = (link.child_kind or "").strip().lower()
        child_id = (link.child_id or "").strip()
        grant_role = (link.grant_role or "").strip().lower()

        if (parent_kind, child_kind) not in _SUPPORTED_ITEM_LINK_PAIRS:
            issues.append(
                {
                    "code": "invalid_link_pair",
                    "severity": "error",
                    "message": (
                        f"Link '{link.id}' uses unsupported pair '{parent_kind} -> {child_kind}'"
                    ),
                    "link_id": link.id,
                    "parent_id": parent_id,
                    "child_id": child_id,
                }
            )

        if parent_kind == child_kind and parent_id == child_id:
            issues.append(
                {
                    "code": "self_link",
                    "severity": "warning",
                    "message": f"Link '{link.id}' is a self-link",
                    "link_id": link.id,
                    "parent_id": parent_id,
                    "child_id": child_id,
                }
            )

        parent_item = item_by_id.get(parent_id)
        child_item = item_by_id.get(child_id)
        if parent_item is None or child_item is None:
            issues.append(
                {
                    "code": "dangling_link_ref",
                    "severity": "error",
                    "message": (
                        f"Link '{link.id}' references missing item(s): "
                        f"parent='{parent_id}', child='{child_id}'"
                    ),
                    "link_id": link.id,
                    "parent_id": parent_id,
                    "child_id": child_id,
                }
            )
        else:
            if not bool(parent_item.active) or not bool(child_item.active):
                issues.append(
                    {
                        "code": "inactive_link_drift",
                        "severity": "warning",
                        "message": (
                            f"Link '{link.id}' is active while one or more endpoint items are inactive"
                        ),
                        "link_id": link.id,
                        "parent_id": parent_id,
                        "child_id": child_id,
                    }
                )

        if (parent_kind, child_kind) == ("department", "space"):
            if not spaces_service.is_valid_assignable_space_role(db, grant_role):
                issues.append(
                    {
                        "code": "invalid_space_grant_role",
                        "severity": "error",
                        "message": (
                            f"Link '{link.id}' has invalid space grant role '{grant_role}'"
                        ),
                        "link_id": link.id,
                        "parent_id": parent_id,
                        "child_id": child_id,
                    }
                )
        if (parent_kind, child_kind) == ("role", "user") and grant_role != parent_id:
            issues.append(
                {
                    "code": "invalid_role_binding_grant",
                    "severity": "warning",
                    "message": (
                        f"Link '{link.id}' grant_role '{grant_role}' does not match role '{parent_id}'"
                    ),
                    "link_id": link.id,
                    "parent_id": parent_id,
                    "child_id": child_id,
                }
            )

        if (parent_kind, child_kind) == ("department", "department") and parent_id and child_id:
            department_edges[parent_id].add(child_id)
        if (parent_kind, child_kind) == ("user", "user") and parent_id and child_id:
            manager_edges[parent_id].add(child_id)

    for cycle in _collect_graph_cycles(department_edges):
        issues.append(
            {
                "code": "department_cycle_risk",
                "severity": "warning",
                "message": f"Department cycle risk detected: {' -> '.join(cycle)}",
                "parent_id": cycle[0],
                "child_id": cycle[-1],
            }
        )
    for cycle in _collect_graph_cycles(manager_edges):
        issues.append(
            {
                "code": "manager_cycle_risk",
                "severity": "warning",
                "message": f"Manager hierarchy cycle risk detected: {' -> '.join(cycle)}",
                "parent_id": cycle[0],
                "child_id": cycle[-1],
            }
        )

    return {
        "ok": len(issues) == 0,
        "checked_at": checked_at,
        "item_count": len(items),
        "link_count": len(links),
        "issue_count": len(issues),
        "issues": issues,
    }


def _organization_item_export_payload(item: OrganizationItem) -> dict[str, object]:
    return {
        "id": item.id,
        "kind": item.kind,
        "entity_id": item.entity_id,
        "slug": item.slug,
        "name": item.name,
        "active": bool(item.active),
        "meta": _decode_meta_json(item.meta_json),
        "created_at": item.created_at,
        "updated_at": item.updated_at,
    }


def _organization_link_export_payload(link: OrganizationItemLink) -> dict[str, object]:
    return {
        "id": link.id,
        "parent_kind": link.parent_kind,
        "parent_id": link.parent_id,
        "child_kind": link.child_kind,
        "child_id": link.child_id,
        "grant_role": link.grant_role,
        "inherit_to_descendants": bool(link.inherit_to_descendants),
        "active": bool(link.active),
        "created_at": link.created_at,
        "updated_at": link.updated_at,
    }


def export_organization_graph_package(
    db: Session,
    *,
    actor_user_id: str | None,
) -> dict[str, object]:
    items = list_organization_items(db)
    links = list_organization_item_links(db)
    role_bindings = [
        {
            "user_id": link.child_id,
            "role_key": link.parent_id,
            "source": "item_link",
        }
        for link in links
        if (link.parent_kind or "").strip().lower() == "role"
        and (link.child_kind or "").strip().lower() == "user"
    ]

    package = {
        "version": "1.0",
        "exported_at": _utc_now(),
        "metadata": {
            "item_count": len(items),
            "link_count": len(links),
            "role_binding_count": len(role_bindings),
        },
        "items": [_organization_item_export_payload(item) for item in items],
        "links": [_organization_link_export_payload(link) for link in links],
        "role_bindings": role_bindings,
    }

    _append_org_audit_event(
        db,
        scope_kind="graph",
        action="graph_export",
        actor_user_id=actor_user_id,
        summary=(
            f"Organization graph exported ({len(items)} items, "
            f"{len(links)} links, {len(role_bindings)} role bindings)"
        ),
        after_json=_json_from_payload(
            {
                "item_count": len(items),
                "link_count": len(links),
                "role_binding_count": len(role_bindings),
            }
        ),
    )
    db.commit()
    return package


def _normalize_graph_item_entry(raw: Mapping[str, object], *, index: int) -> dict[str, object]:
    item_id = str(raw.get("id", "")).strip()
    if not item_id:
        raise bad_request(f"package.items[{index}].id is required")

    kind = str(raw.get("kind", "")).strip().lower()
    if kind not in {"department", "space", "user", "role"}:
        raise bad_request(
            f"package.items[{index}].kind must be one of department|space|user|role"
        )

    name = str(raw.get("name", "")).strip() or item_id
    slug_raw = raw.get("slug")
    slug = str(slug_raw).strip() if isinstance(slug_raw, str) else None

    meta_raw = raw.get("meta")
    if meta_raw is not None and not isinstance(meta_raw, Mapping):
        raise bad_request(f"package.items[{index}].meta must be an object when provided")

    entity_raw = raw.get("entity_id")
    entity_id = str(entity_raw).strip() if isinstance(entity_raw, str) and entity_raw.strip() else None
    if entity_id is None and kind in {"department", "space", "user"}:
        entity_id = item_id

    return {
        "id": item_id,
        "kind": kind,
        "entity_id": entity_id,
        "slug": slug,
        "name": name,
        "active": bool(raw.get("active", True)),
        "meta": dict(meta_raw) if isinstance(meta_raw, Mapping) else None,
    }


def _normalize_graph_link_entry(
    db: Session,
    raw: Mapping[str, object],
    *,
    index: int,
) -> dict[str, object]:
    parent_kind, parent_id, child_kind, child_id = _normalized_link_key(
        parent_kind=str(raw.get("parent_kind", "")),
        parent_id=str(raw.get("parent_id", "")),
        child_kind=str(raw.get("child_kind", "")),
        child_id=str(raw.get("child_id", "")),
    )
    if not parent_id or not child_id:
        raise bad_request(f"package.links[{index}] requires parent_id and child_id")
    if (parent_kind, child_kind) not in _SUPPORTED_ITEM_LINK_PAIRS:
        raise bad_request(
            f"package.links[{index}] has unsupported pair '{parent_kind} -> {child_kind}'"
        )

    grant_role = str(raw.get("grant_role", "member")).strip().lower() or "member"
    if (parent_kind, child_kind) == ("role", "user"):
        grant_role = parent_id
    if (parent_kind, child_kind) == ("department", "space") and not spaces_service.is_valid_assignable_space_role(db, grant_role):
        raise bad_request(
            f"package.links[{index}] has invalid grant_role '{grant_role}' for department->space"
        )

    return {
        "parent_kind": parent_kind,
        "parent_id": parent_id,
        "child_kind": child_kind,
        "child_id": child_id,
        "grant_role": grant_role,
        "inherit_to_descendants": bool(raw.get("inherit_to_descendants", True)),
        "active": bool(raw.get("active", True)),
    }


def _normalize_graph_role_binding_entry(raw: Mapping[str, object], *, index: int) -> dict[str, object]:
    user_id = str(raw.get("user_id", "")).strip()
    role_key = str(raw.get("role_key", "")).strip().lower()
    if not user_id:
        raise bad_request(f"package.role_bindings[{index}].user_id is required")
    if not role_key:
        raise bad_request(f"package.role_bindings[{index}].role_key is required")
    return {
        "user_id": user_id,
        "role_key": role_key,
    }


def import_organization_graph_package(
    db: Session,
    *,
    package: Mapping[str, object],
    dry_run: bool,
    actor_user_id: str | None,
) -> dict[str, object]:
    if not isinstance(package, Mapping):
        raise bad_request("package must be an object")

    raw_items = package.get("items", [])
    raw_links = package.get("links", [])
    raw_role_bindings = package.get("role_bindings", [])

    if not isinstance(raw_items, list):
        raise bad_request("package.items must be an array")
    if not isinstance(raw_links, list):
        raise bad_request("package.links must be an array")
    if not isinstance(raw_role_bindings, list):
        raise bad_request("package.role_bindings must be an array")

    parsed_items: list[dict[str, object]] = []
    seen_item_ids: set[str] = set()
    for index, raw_item in enumerate(raw_items):
        if not isinstance(raw_item, Mapping):
            raise bad_request(f"package.items[{index}] must be an object")
        parsed = _normalize_graph_item_entry(raw_item, index=index)
        item_id = str(parsed["id"])
        if item_id in seen_item_ids:
            raise bad_request(f"package.items contains duplicate id '{item_id}'")
        seen_item_ids.add(item_id)
        parsed_items.append(parsed)

    parsed_links: list[dict[str, object]] = []
    for index, raw_link in enumerate(raw_links):
        if not isinstance(raw_link, Mapping):
            raise bad_request(f"package.links[{index}] must be an object")
        parsed_links.append(_normalize_graph_link_entry(db, raw_link, index=index))

    parsed_role_bindings: list[dict[str, object]] = []
    for index, raw_binding in enumerate(raw_role_bindings):
        if not isinstance(raw_binding, Mapping):
            raise bad_request(f"package.role_bindings[{index}] must be an object")
        parsed_role_bindings.append(
            _normalize_graph_role_binding_entry(raw_binding, index=index)
        )

    warnings: list[str] = []
    for item in parsed_items:
        item_id = str(item["id"])
        item_kind = str(item["kind"])
        if not _entity_exists_for_kind(db, kind=item_kind, item_id=item_id):
            raise bad_request(
                f"package item '{item_id}' ({item_kind}) has no matching entity in this environment"
            )

    for index, link in enumerate(parsed_links):
        parent_kind = str(link["parent_kind"])
        parent_id = str(link["parent_id"])
        child_kind = str(link["child_kind"])
        child_id = str(link["child_id"])
        if not _entity_exists_for_kind(db, kind=parent_kind, item_id=parent_id):
            raise bad_request(
                f"package.links[{index}] parent '{parent_id}' ({parent_kind}) is not present"
            )
        if not _entity_exists_for_kind(db, kind=child_kind, item_id=child_id):
            raise bad_request(
                f"package.links[{index}] child '{child_id}' ({child_kind}) is not present"
            )

    for index, binding in enumerate(parsed_role_bindings):
        user_id = str(binding["user_id"])
        role_key = str(binding["role_key"])
        if db.get(User, user_id) is None:
            raise bad_request(
                f"package.role_bindings[{index}] user '{user_id}' was not found"
            )
        if not _role_exists(db, role_key):
            raise bad_request(
                f"package.role_bindings[{index}] role '{role_key}' was not found or inactive"
            )

    created_items = 0
    updated_items = 0
    upserted_links = 0
    rebound_count = 0

    try:
        for item in parsed_items:
            item_id = str(item["id"])
            existing = db.get(OrganizationItem, item_id)
            if existing is None:
                created_items += 1
            else:
                updated_items += 1
            _upsert_organization_item(
                db,
                item_id=item_id,
                kind=str(item["kind"]),
                name=str(item["name"]),
                entity_id=(str(item["entity_id"]) if item.get("entity_id") is not None else None),
                slug=(str(item["slug"]) if item.get("slug") is not None else None),
                active=bool(item["active"]),
                meta_json=_encode_meta_json(item.get("meta") if isinstance(item.get("meta"), dict) else None),
            )

        for link in parsed_links:
            create_organization_item_link(
                db,
                parent_kind=str(link["parent_kind"]),
                parent_id=str(link["parent_id"]),
                child_kind=str(link["child_kind"]),
                child_id=str(link["child_id"]),
                grant_role=str(link["grant_role"]),
                inherit_to_descendants=bool(link["inherit_to_descendants"]),
                active=bool(link["active"]),
                actor_user_id=actor_user_id,
                commit=False,
            )
            upserted_links += 1

        rebind_groups_by_role: dict[str, set[str]] = defaultdict(set)
        for binding in parsed_role_bindings:
            rebind_groups_by_role[str(binding["role_key"])].add(str(binding["user_id"]))

        rebind_groups = [
            {"role_key": role_key, "user_ids": sorted(user_ids)}
            for role_key, user_ids in sorted(rebind_groups_by_role.items())
            if user_ids
        ]
        if rebind_groups:
            rebound_count, _ = _apply_role_rebind_groups(
                db,
                rebind_groups=rebind_groups,
                actor_user_id=actor_user_id,
            )

        if dry_run:
            db.rollback()
            _append_org_audit_event(
                db,
                scope_kind="graph",
                action="graph_import_dry_run",
                actor_user_id=actor_user_id,
                summary=(
                    f"Graph import dry-run validated ({created_items} create, "
                    f"{updated_items} update, {upserted_links} links, "
                    f"{rebound_count} role rebinds)"
                ),
                after_json=_json_from_payload(
                    {
                        "dry_run": True,
                        "created_items": created_items,
                        "updated_items": updated_items,
                        "upserted_links": upserted_links,
                        "role_rebound": rebound_count,
                    }
                ),
            )
            db.commit()
            return {
                "ok": True,
                "dry_run": True,
                "validated": True,
                "applied": False,
                "created_items": created_items,
                "updated_items": updated_items,
                "upserted_links": upserted_links,
                "role_rebound": rebound_count,
                "errors": [],
                "warnings": warnings,
            }

        _append_org_audit_event(
            db,
            scope_kind="graph",
            action="graph_import",
            actor_user_id=actor_user_id,
            summary=(
                f"Graph import applied ({created_items} create, {updated_items} update, "
                f"{upserted_links} links, {rebound_count} role rebinds)"
            ),
            after_json=_json_from_payload(
                {
                    "dry_run": False,
                    "created_items": created_items,
                    "updated_items": updated_items,
                    "upserted_links": upserted_links,
                    "role_rebound": rebound_count,
                }
            ),
        )
        db.commit()
        return {
            "ok": True,
            "dry_run": False,
            "validated": True,
            "applied": True,
            "created_items": created_items,
            "updated_items": updated_items,
            "upserted_links": upserted_links,
            "role_rebound": rebound_count,
            "errors": [],
            "warnings": warnings,
        }
    except Exception:
        db.rollback()
        raise
