# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for space discovery, permissions, and membership workflows."""
from dataclasses import dataclass
import uuid
from sqlalchemy.orm import Session
from sqlalchemy import select
from app.core.deps import bad_request, forbidden
from app.modules.auth.models import User
from app.modules.auth.deps import resolve_user_auth_role
from .models import Space

BUILTIN_SPACE_ROLES = ("viewer", "member", "moderator", "admin")
_SPACE_ROLE_RANK = {role: i for i, role in enumerate(BUILTIN_SPACE_ROLES)}


@dataclass(slots=True)
class SpaceMembership:
    space_id: str
    user_id: str
    role: str

def create_space(
    db: Session,
    name: str,
    slug: str,
    creator_user_id: str,
    *,
    region_code: str | None = None,
    meta_json: str | None = None,
) -> Space:
    exists = db.scalar(select(Space).where(Space.slug == slug))
    if exists:
        raise bad_request("Space slug already exists")
    s = Space(
        id=str(uuid.uuid4()),
        name=name,
        slug=slug,
        owner_user_id=creator_user_id,
        region_code=region_code,
        meta_json=meta_json,
    )
    db.add(s)
    from app.modules.admin import service as admin_service

    admin_service.sync_space_organization_item(db, s)
    db.commit()
    db.refresh(s)
    return s


def _resolve_effective_space_role(db: Session, role_key: str) -> str | None:
    normalized = role_key.strip().lower()
    if normalized in _SPACE_ROLE_RANK:
        return normalized
    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import CustomRole

    custom = db.scalar(select(CustomRole).where(CustomRole.role_key == normalized, CustomRole.active.is_(True)))
    if not custom:
        return None
    return custom.effective_level


def _resolve_effective_space_roles(
    db: Session,
    role_keys: set[str],
) -> dict[str, str]:
    normalized = {role.strip().lower() for role in role_keys if role and role.strip()}
    if not normalized:
        return {}

    resolved: dict[str, str] = {
        role_key: role_key for role_key in normalized if role_key in _SPACE_ROLE_RANK
    }
    unresolved = sorted(normalized - resolved.keys())
    if not unresolved:
        return resolved

    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import CustomRole

    rows = db.execute(
        select(CustomRole.role_key, CustomRole.effective_level).where(
            CustomRole.role_key.in_(unresolved),
            CustomRole.active.is_(True),
        )
    ).all()
    for role_key, effective_level in rows:
        if not isinstance(role_key, str) or not isinstance(effective_level, str):
            continue
        rk = role_key.strip().lower()
        el = effective_level.strip().lower()
        if rk and el in _SPACE_ROLE_RANK:
            resolved[rk] = el
    return resolved


def resolve_effective_space_role(db: Session, role_key: str) -> str | None:
    return _resolve_effective_space_role(db, role_key)


def _load_user_department_links_map(
    db: Session,
    user_ids: list[str] | None = None,
) -> dict[str, set[str]]:
    if user_ids is not None and not user_ids:
        return {}

    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import OrganizationItemLink

    mapped: dict[str, set[str]] = {user_id: set() for user_id in user_ids or []}
    query = select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
        OrganizationItemLink.parent_kind == "department",
        OrganizationItemLink.child_kind == "user",
        OrganizationItemLink.active.is_(True),
    )
    if user_ids is not None:
        query = query.where(OrganizationItemLink.child_id.in_(user_ids))
    rows = db.execute(query).all()
    for department_id, user_id in rows:
        if not isinstance(user_id, str) or not isinstance(department_id, str):
            continue
        if department_id:
            mapped.setdefault(user_id, set()).add(department_id)
    return mapped


def _load_user_manager_parent_map(
    db: Session,
    user_ids: list[str] | None = None,
) -> dict[str, set[str]]:
    if user_ids is not None and not user_ids:
        return {}

    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import OrganizationItemLink

    mapped: dict[str, set[str]] = {user_id: set() for user_id in user_ids or []}
    query = select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
        OrganizationItemLink.parent_kind == "user",
        OrganizationItemLink.child_kind == "user",
        OrganizationItemLink.active.is_(True),
    )
    if user_ids is not None:
        query = query.where(OrganizationItemLink.child_id.in_(user_ids))
    rows = db.execute(query).all()
    for manager_user_id, report_user_id in rows:
        if not isinstance(manager_user_id, str) or not manager_user_id:
            continue
        if not isinstance(report_user_id, str) or not report_user_id:
            continue
        mapped.setdefault(report_user_id, set()).add(manager_user_id)
    return mapped


def _nearest_manager_unit_links_for_user(
    user_id: str,
    *,
    direct_units_by_user: dict[str, set[str]],
    manager_parents_by_user: dict[str, set[str]],
) -> set[str]:
    next_layer = set(manager_parents_by_user.get(user_id, set()))
    if not next_layer:
        return set()

    seen_user_ids = {user_id}
    while next_layer:
        layer_units: set[str] = set()
        following_layer: set[str] = set()
        for manager_user_id in next_layer:
            if manager_user_id in seen_user_ids:
                continue
            seen_user_ids.add(manager_user_id)
            direct_units = direct_units_by_user.get(manager_user_id, set())
            if direct_units:
                layer_units.update(direct_units)
            else:
                following_layer.update(
                    manager_parents_by_user.get(manager_user_id, set())
                )
        if layer_units:
            return layer_units
        next_layer = following_layer
    return set()


def _load_effective_user_department_links_map(
    db: Session,
    user_ids: list[str],
) -> dict[str, set[str]]:
    if not user_ids:
        return {}

    direct_units_by_user = _load_user_department_links_map(db)
    manager_parents_by_user = _load_user_manager_parent_map(db)
    effective_units_by_user: dict[str, set[str]] = {}

    for user_id in user_ids:
        direct_units = direct_units_by_user.get(user_id, set())
        if direct_units:
            effective_units_by_user[user_id] = set(direct_units)
            continue
        effective_units_by_user[user_id] = _nearest_manager_unit_links_for_user(
            user_id,
            direct_units_by_user=direct_units_by_user,
            manager_parents_by_user=manager_parents_by_user,
        )

    return effective_units_by_user


def _load_department_parent_map(db: Session) -> dict[str, set[str]]:
    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import OrganizationItemLink

    rows = db.execute(
        select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.child_kind == "department",
            OrganizationItemLink.active.is_(True),
        )
    ).all()
    mapped: dict[str, set[str]] = {}
    for parent_id, child_id in rows:
        if not isinstance(parent_id, str) or not parent_id:
            continue
        if not isinstance(child_id, str) or not child_id:
            continue
        mapped.setdefault(child_id, set()).add(parent_id)
    return mapped


def _ancestor_chain_for_department(
    department_id: str,
    parents_by_child: dict[str, set[str]],
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
            _ancestor_chain_for_department(
                parent_id,
                parents_by_child,
                cache,
                visiting,
            )
        )
    visiting.remove(department_id)

    cache[department_id] = chain
    return chain


def _list_space_item_links(
    db: Session,
    *,
    space_id: str | None = None,
    parent_ids: set[str] | None = None,
) -> list[object]:
    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import OrganizationItemLink

    q = select(OrganizationItemLink).where(
        OrganizationItemLink.parent_kind == "department",
        OrganizationItemLink.child_kind == "space",
        OrganizationItemLink.active.is_(True),
    )
    if space_id is not None:
        q = q.where(OrganizationItemLink.child_id == space_id)
    if parent_ids is not None:
        if not parent_ids:
            return []
        q = q.where(OrganizationItemLink.parent_id.in_(sorted(parent_ids)))
    return list(db.execute(q).scalars().all())


def _best_link_role_for_units(
    *,
    direct_units: set[str],
    ancestor_units: set[str],
    links: list[object],
    effective_role_by_key: dict[str, str],
) -> str | None:
    best_role: str | None = None
    best_rank = -1
    for link in links:
        if not _link_matches_units(
            link, direct_units=direct_units, ancestor_units=ancestor_units
        ):
            continue

        grant_role_raw = getattr(link, "grant_role", None)
        if not isinstance(grant_role_raw, str):
            continue
        grant_role = grant_role_raw.strip().lower()
        if not grant_role:
            continue
        effective = effective_role_by_key.get(grant_role)
        if effective is None:
            continue
        rank = _SPACE_ROLE_RANK.get(effective, -1)
        if rank > best_rank:
            best_rank = rank
            best_role = grant_role
    return best_role


def _link_matches_units(
    link: object,
    *,
    direct_units: set[str],
    ancestor_units: set[str],
) -> bool:
    link_unit_id = getattr(link, "parent_id", None)
    if not isinstance(link_unit_id, str) or not link_unit_id:
        return False
    if link_unit_id in direct_units:
        return True
    return bool(getattr(link, "inherit_to_descendants", False)) and (
        link_unit_id in ancestor_units
    )


def _item_link_space_role_for_user(db: Session, space_id: str, user: User | None) -> str | None:
    if not user:
        return None

    user_units = _load_effective_user_department_links_map(db, [user.id]).get(
        user.id,
        set(),
    )
    if not user_units:
        return None

    parents_by_child = _load_department_parent_map(db)
    ancestor_cache: dict[str, set[str]] = {}
    ancestor_units: set[str] = set()
    for unit_id in user_units:
        ancestor_units.update(
            _ancestor_chain_for_department(unit_id, parents_by_child, ancestor_cache)
        )

    links = _list_space_item_links(db, space_id=space_id)
    if not links:
        return None

    role_keys = {
        getattr(link, "grant_role", "").strip().lower()
        for link in links
        if isinstance(getattr(link, "grant_role", None), str)
    }
    effective_role_by_key = _resolve_effective_space_roles(db, role_keys)
    return _best_link_role_for_units(
        direct_units=user_units,
        ancestor_units=ancestor_units,
        links=links,
        effective_role_by_key=effective_role_by_key,
    )


def list_spaces_for_user(db: Session, user_id: str) -> list[Space]:
    user = db.get(User, user_id)
    if user and resolve_user_auth_role(db, user) in {"admin", "moderator"}:
        return list(db.execute(select(Space).order_by(Space.created_at.desc())).scalars().all())
    if not user:
        return []

    user_units = _load_effective_user_department_links_map(db, [user.id]).get(
        user.id,
        set(),
    )
    if not user_units:
        return []

    parents_by_child = _load_department_parent_map(db)
    ancestor_cache: dict[str, set[str]] = {}
    ancestor_units: set[str] = set()
    for unit_id in user_units:
        ancestor_units.update(
            _ancestor_chain_for_department(unit_id, parents_by_child, ancestor_cache)
        )
    if not ancestor_units:
        return []

    links = _list_space_item_links(db, parent_ids=ancestor_units)
    if not links:
        return []

    role_keys = {
        getattr(link, "grant_role", "").strip().lower()
        for link in links
        if isinstance(getattr(link, "grant_role", None), str)
    }
    effective_role_by_key = _resolve_effective_space_roles(db, role_keys)

    best_rank_by_space: dict[str, int] = {}
    for link in links:
        space_id = getattr(link, "child_id", None)
        if not isinstance(space_id, str) or not space_id:
            continue
        if not _link_matches_units(
            link, direct_units=user_units, ancestor_units=ancestor_units
        ):
            continue
        grant_role_raw = getattr(link, "grant_role", None)
        if not isinstance(grant_role_raw, str):
            continue
        role = grant_role_raw.strip().lower()
        if not role:
            continue
        effective = effective_role_by_key.get(role)
        if effective is None:
            continue
        rank = _SPACE_ROLE_RANK.get(effective, -1)
        if rank > best_rank_by_space.get(space_id, -1):
            best_rank_by_space[space_id] = rank

    if not best_rank_by_space:
        return []

    return list(
        db.execute(
            select(Space)
            .where(Space.id.in_(sorted(best_rank_by_space.keys())))
            .order_by(Space.created_at.desc())
        ).scalars().all()
    )


def is_valid_assignable_space_role(db: Session, role_key: str) -> bool:
    return _resolve_effective_space_role(db, role_key) is not None

def get_space_role(db: Session, space_id: str, user_id: str) -> str | None:
    user = db.get(User, user_id)
    if user:
        system_role = resolve_user_auth_role(db, user)
        if system_role in {"admin", "moderator"}:
            return system_role
    item_link_role = _item_link_space_role_for_user(db, space_id, user)
    if item_link_role is not None:
        return item_link_role
    return None

def require_space_role(db: Session, space_id: str, user_id: str, allowed: set[str]) -> None:
    user = db.get(User, user_id)
    if user:
        system_role = resolve_user_auth_role(db, user)
        # Global admins can operate across all spaces/content. Global moderators can do the same
        # except for strict space-admin operations.
        if system_role == "admin":
            return
        if system_role == "moderator" and not (allowed and allowed == {"admin"}):
            return
    role_key = get_space_role(db, space_id, user_id)
    if role_key is None:
        raise forbidden("No access to this space")
    effective_role = _resolve_effective_space_role(db, role_key)
    if effective_role is None:
        raise forbidden("Space role is invalid or disabled")
    if allowed and effective_role not in allowed:
        raise forbidden("Insufficient space role")

def list_members(db: Session, space_id: str) -> list[SpaceMembership]:
    if not db.get(Space, space_id):
        return []

    users = list(
        db.execute(select(User).order_by(User.name.asc(), User.email.asc())).scalars().all()
    )
    if not users:
        return []

    links = _list_space_item_links(db, space_id=space_id)
    role_keys = {
        getattr(link, "grant_role", "").strip().lower()
        for link in links
        if isinstance(getattr(link, "grant_role", None), str)
    }
    effective_role_by_key = _resolve_effective_space_roles(db, role_keys)

    resolved: list[SpaceMembership] = []
    scoped_user_ids: list[str] = []
    for user in users:
        system_role = resolve_user_auth_role(db, user)
        if system_role in {"admin", "moderator"}:
            resolved.append(
                SpaceMembership(space_id=space_id, user_id=user.id, role=system_role)
            )
            continue
        scoped_user_ids.append(user.id)

    if not scoped_user_ids or not links:
        return resolved

    user_units_map = _load_effective_user_department_links_map(db, scoped_user_ids)
    all_scoped_units = {
        unit_id for unit_ids in user_units_map.values() for unit_id in unit_ids
    }
    if not all_scoped_units:
        return resolved

    parents_by_child = _load_department_parent_map(db)
    ancestor_cache: dict[str, set[str]] = {}

    for user in users:
        if user.id not in user_units_map:
            continue
        direct_units = user_units_map[user.id]
        if not direct_units:
            continue
        ancestor_units: set[str] = set()
        for unit_id in direct_units:
            ancestor_units.update(
                _ancestor_chain_for_department(unit_id, parents_by_child, ancestor_cache)
            )
        role = _best_link_role_for_units(
            direct_units=direct_units,
            ancestor_units=ancestor_units,
            links=links,
            effective_role_by_key=effective_role_by_key,
        )
        if role is None:
            continue
        resolved.append(SpaceMembership(space_id=space_id, user_id=user.id, role=role))
    return resolved


def _load_space_manager_edges(
    db: Session,
    *,
    member_user_ids: set[str],
    manager_user_id: str | None = None,
) -> dict[str, set[str]]:
    if not member_user_ids:
        return {}

    # Lazy import avoids creating a module dependency loop at import time.
    from app.modules.admin.models import OrganizationItemLink

    q = select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
        OrganizationItemLink.parent_kind == "user",
        OrganizationItemLink.child_kind == "user",
        OrganizationItemLink.parent_id.in_(sorted(member_user_ids)),
        OrganizationItemLink.child_id.in_(sorted(member_user_ids)),
        OrganizationItemLink.active.is_(True),
    )
    if manager_user_id is not None:
        q = q.where(OrganizationItemLink.parent_id == manager_user_id)

    mapped: dict[str, set[str]] = {}
    for parent_id, child_id in db.execute(q).all():
        if not isinstance(parent_id, str) or not parent_id:
            continue
        if not isinstance(child_id, str) or not child_id:
            continue
        mapped.setdefault(parent_id, set()).add(child_id)
    return mapped


def member_report_counts(db: Session, space_id: str) -> dict[str, int]:
    memberships = list_members(db, space_id)
    member_user_ids = {membership.user_id for membership in memberships}
    edges = _load_space_manager_edges(db, member_user_ids=member_user_ids)
    return {
        user_id: len(children)
        for user_id, children in edges.items()
        if children
    }


def list_direct_reports(
    db: Session,
    *,
    space_id: str,
    manager_user_id: str,
) -> list[SpaceMembership]:
    memberships = list_members(db, space_id)
    membership_by_user_id = {
        membership.user_id: membership
        for membership in memberships
    }
    if manager_user_id not in membership_by_user_id:
        return []

    member_user_ids = set(membership_by_user_id.keys())
    edges = _load_space_manager_edges(
        db,
        member_user_ids=member_user_ids,
        manager_user_id=manager_user_id,
    )
    child_ids = edges.get(manager_user_id, set())
    return [
        membership_by_user_id[user_id]
        for user_id in child_ids
        if user_id in membership_by_user_id
    ]
