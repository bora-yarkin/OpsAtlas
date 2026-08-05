# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import uuid
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.auth.security import create_access_token
from app.core.db import Base, SessionLocal, engine, init_db
from app.main import app
from app.modules.admin import service as admin_service
from app.modules.admin.models import (
    CustomRole,
    OrganizationItemLink,
    OrganizationUnit,
)
from app.modules.auth.models import User
from app.modules.spaces.models import Space


@pytest.fixture(autouse=True)
def reset_db() -> None:
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app, base_url="http://localhost") as test_client:
        yield test_client


def _insert_user(*, db, email: str, name: str, role: str) -> User:
    user = User(
        id=str(uuid.uuid4()),
        email=email,
        name=name,
        password_hash="test-hash",
        global_role=role,
        is_active=True,
        must_change_password=False,
    )
    db.add(user)
    db.flush()
    admin_service.sync_user_organization_item(db, user)
    admin_service.sync_user_builtin_role_binding(db, user, role_key=role)
    return user


def _seed_org_graph(db) -> dict[str, str]:
    admin = _insert_user(db=db, email="admin@example.com", name="Admin", role="admin")
    member = _insert_user(db=db, email="member@example.com", name="Member", role="member")

    custom_role = CustomRole(
        id=str(uuid.uuid4()),
        role_key="ops_admin",
        name="Ops Admin",
        description="",
        effective_level="admin",
        active=True,
        meta_json=None,
    )
    db.add(custom_role)
    admin_service.sync_custom_role_organization_item(db, custom_role)

    department = OrganizationUnit(
        id=str(uuid.uuid4()),
        name="Operations",
        slug="operations",
        unit_type="team",
        active=True,
        meta_json=None,
    )
    db.add(department)
    admin_service.sync_organization_unit_item(db, department)

    space = Space(
        id=str(uuid.uuid4()),
        name="Ops Space",
        slug="ops-space",
        owner_user_id=admin.id,
        region_code="eu-central",
        meta_json=None,
    )
    db.add(space)
    admin_service.sync_space_organization_item(db, space)

    db.flush()

    admin_service.create_organization_item_link(
        db,
        parent_kind="department",
        parent_id=department.id,
        child_kind="user",
        child_id=member.id,
        grant_role="member",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )
    admin_service.create_organization_item_link(
        db,
        parent_kind="department",
        parent_id=department.id,
        child_kind="space",
        child_id=space.id,
        grant_role="member",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )

    db.commit()

    return {
        "admin_id": admin.id,
        "member_id": member.id,
        "department_id": department.id,
        "space_id": space.id,
    }


def _seed_inherited_access_graph(db) -> dict[str, str]:
    admin = _insert_user(db=db, email="admin2@example.com", name="Admin", role="admin")
    user = _insert_user(db=db, email="member2@example.com", name="Member", role="member")

    parent_department = OrganizationUnit(
        id=str(uuid.uuid4()),
        name="Operations",
        slug="ops-root",
        unit_type="division",
        active=True,
        meta_json=None,
    )
    child_department = OrganizationUnit(
        id=str(uuid.uuid4()),
        name="Field Team",
        slug="field-team",
        unit_type="team",
        active=True,
        meta_json=None,
    )
    db.add(parent_department)
    db.add(child_department)
    admin_service.sync_organization_unit_item(db, parent_department)
    admin_service.sync_organization_unit_item(db, child_department)

    space = Space(
        id=str(uuid.uuid4()),
        name="Incident Space",
        slug="incident-space",
        owner_user_id=admin.id,
        region_code="eu-west",
        meta_json=None,
    )
    db.add(space)
    admin_service.sync_space_organization_item(db, space)
    db.flush()

    admin_service.create_organization_item_link(
        db,
        parent_kind="department",
        parent_id=parent_department.id,
        child_kind="department",
        child_id=child_department.id,
        grant_role="member",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )
    admin_service.create_organization_item_link(
        db,
        parent_kind="department",
        parent_id=child_department.id,
        child_kind="user",
        child_id=user.id,
        grant_role="member",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )
    admin_service.create_organization_item_link(
        db,
        parent_kind="department",
        parent_id=parent_department.id,
        child_kind="space",
        child_id=space.id,
        grant_role="moderator",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )
    db.commit()

    return {
        "admin_id": admin.id,
        "user_id": user.id,
        "parent_department_id": parent_department.id,
        "child_department_id": child_department.id,
        "space_id": space.id,
    }


def _headers_for_admin(user_id: str) -> dict[str, str]:
    token = create_access_token(sub=user_id, role="admin", mfa_verified=True)
    return {"Authorization": f"Bearer {token}"}


def test_bulk_role_rebind_mutation_updates_user_role_and_link(client: TestClient) -> None:
    with SessionLocal() as db:
        seeded = _seed_org_graph(db)

    headers = _headers_for_admin(seeded["admin_id"])
    payload = {
        "link": [],
        "unlink": [],
        "rebind_roles": [
            {
                "role_key": "admin",
                "user_ids": [seeded["member_id"]],
            }
        ],
        "dry_run": False,
    }

    preview_response = client.post(
        "/admin/org/item-links/bulk/preview",
        json=payload,
        headers=headers,
    )
    assert preview_response.status_code == 200
    preview = preview_response.json()
    assert preview["dry_run"] is True
    assert preview["role_rebound"] == 1
    assert preview["access_impact"]["changed_membership_count"] >= 1

    mutate_response = client.post(
        "/admin/org/item-links/bulk/mutate",
        json=payload,
        headers=headers,
    )
    assert mutate_response.status_code == 200

    with SessionLocal() as db:
        member = db.get(User, seeded["member_id"])
        assert member is not None
        assert member.global_role == "admin"
        role_link = db.scalar(
            select(OrganizationItemLink).where(
                OrganizationItemLink.parent_kind == "role",
                OrganizationItemLink.parent_id == "admin",
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.child_id == seeded["member_id"],
                OrganizationItemLink.active.is_(True),
            )
        )
        assert role_link is not None


def test_why_access_endpoint_returns_inheritance_chain(client: TestClient) -> None:
    with SessionLocal() as db:
        seeded = _seed_inherited_access_graph(db)

    headers = _headers_for_admin(seeded["admin_id"])
    response = client.get(
        "/admin/org/why-access",
        params={"user_id": seeded["user_id"], "space_id": seeded["space_id"]},
        headers=headers,
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["access_granted"] is True
    assert payload["selected_grant_role"] == "moderator"
    assert payload["selected_effective_role"] == "moderator"
    assert seeded["child_department_id"] in payload["direct_department_ids"]
    assert seeded["parent_department_id"] in payload["ancestor_department_ids"]
    assert any(
        grant.get("source") == "ancestor_department"
        for grant in payload.get("matching_grants", [])
    )


def test_role_impact_simulator_previews_changes(client: TestClient) -> None:
    with SessionLocal() as db:
        seeded = _seed_org_graph(db)

    headers = _headers_for_admin(seeded["admin_id"])
    response = client.post(
        "/admin/org/role-impact/simulate",
        json={
            "global_role_changes": [
                {"user_id": seeded["member_id"], "role_key": "admin"}
            ],
            "space_grant_changes": [
                {
                    "department_id": seeded["department_id"],
                    "space_id": seeded["space_id"],
                    "grant_role": "moderator",
                    "inherit_to_descendants": True,
                    "active": True,
                }
            ],
            "space_grant_removals": [],
        },
        headers=headers,
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["simulated_global_role_changes"] == 1
    assert payload["simulated_space_grant_changes"] == 1
    assert payload["access_impact"]["changed_membership_count"] >= 1


def test_graph_integrity_reports_dangling_links(client: TestClient) -> None:
    with SessionLocal() as db:
        seeded = _seed_org_graph(db)
        db.add(
            OrganizationItemLink(
                id=str(uuid.uuid4()),
                parent_kind="department",
                parent_id=seeded["department_id"],
                child_kind="space",
                child_id="missing-space-id",
                grant_role="member",
                inherit_to_descendants=True,
                active=True,
            )
        )
        db.commit()

    headers = _headers_for_admin(seeded["admin_id"])
    response = client.get("/admin/org/graph/integrity", headers=headers)
    assert response.status_code == 200
    payload = response.json()
    codes = {issue.get("code") for issue in payload.get("issues", [])}
    assert "dangling_link_ref" in codes


def test_graph_export_and_import_dry_run_round_trip(client: TestClient) -> None:
    with SessionLocal() as db:
        seeded = _seed_org_graph(db)

    headers = _headers_for_admin(seeded["admin_id"])

    export_response = client.post("/admin/org/graph/export", headers=headers)
    assert export_response.status_code == 200
    package = export_response.json()
    assert isinstance(package.get("items"), list)
    assert isinstance(package.get("links"), list)

    import_response = client.post(
        "/admin/org/graph/import",
        json={"dry_run": True, "package": package},
        headers=headers,
    )
    assert import_response.status_code == 200
    result = import_response.json()
    assert result["validated"] is True
    assert result["applied"] is False
