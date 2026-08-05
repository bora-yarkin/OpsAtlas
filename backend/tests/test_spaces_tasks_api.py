# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.modules.admin import service as admin_service
from app.modules.admin.models import OrganizationItemLink, OrganizationUnit
from app.modules.incidents.models import Incident, IncidentProfile
from app.modules.kb import service as kb_service
from app.modules.sop import service as sop_service
from app.modules.sop.models import Sop
from app.modules.spaces import service as spaces_service
from app.modules.tasks import service as tasks_service
from app.modules.tasks.models import Task, TaskExecutionProfile, TaskReminderDispatch


def _create_unit(
    db: Session,
    *,
    name: str,
    slug: str,
    unit_type: str = "team",
) -> OrganizationUnit:
    unit = OrganizationUnit(
        id=str(uuid.uuid4()),
        name=name,
        slug=slug,
        unit_type=unit_type,
        active=True,
        meta_json=None,
    )
    db.add(unit)
    admin_service.sync_organization_unit_item(db, unit)
    db.flush()
    return unit


def _link(
    db: Session,
    *,
    parent_kind: str,
    parent_id: str,
    child_kind: str,
    child_id: str,
    grant_role: str,
    inherit_to_descendants: bool = True,
) -> None:
    admin_service.create_organization_item_link(
        db,
        parent_kind=parent_kind,
        parent_id=parent_id,
        child_kind=child_kind,
        child_id=child_id,
        grant_role=grant_role,
        inherit_to_descendants=inherit_to_descendants,
        active=True,
        commit=False,
    )


def _seed_workspace_graph(
    db: Session,
    user_factory,
) -> dict[str, object]:
    admin = user_factory(
        email="spaces-admin@example.com",
        name="Space Admin",
        password="Admin!Pass123",
    )
    member = user_factory(
        email="spaces-member@example.com",
        name="Space Member",
        password="Member!Pass123",
        role="member",
    )
    viewer = user_factory(
        email="spaces-viewer@example.com",
        name="Space Viewer",
        password="Viewer!Pass123",
        role="member",
    )
    outsider = user_factory(
        email="spaces-outsider@example.com",
        name="Space Outsider",
        password="Outsider!Pass123",
        role="member",
    )

    parent_department = _create_unit(
        db,
        name="Operations",
        slug="ops-root",
        unit_type="division",
    )
    child_department = _create_unit(
        db,
        name="Incident Response",
        slug="incident-response",
    )
    viewer_department = _create_unit(
        db,
        name="Read Only",
        slug="read-only",
    )

    space = spaces_service.create_space(
        db,
        "Europe Operations",
        "europe-ops",
        admin.id,
        region_code="eu-west",
        meta_json='{"tier":"prod","owner":"ops"}',
    )

    _link(
        db,
        parent_kind="department",
        parent_id=parent_department.id,
        child_kind="department",
        child_id=child_department.id,
        grant_role="member",
    )
    _link(
        db,
        parent_kind="department",
        parent_id=child_department.id,
        child_kind="user",
        child_id=member.id,
        grant_role="member",
    )
    _link(
        db,
        parent_kind="department",
        parent_id=parent_department.id,
        child_kind="space",
        child_id=space.id,
        grant_role="member",
    )
    _link(
        db,
        parent_kind="department",
        parent_id=viewer_department.id,
        child_kind="user",
        child_id=viewer.id,
        grant_role="member",
    )
    _link(
        db,
        parent_kind="department",
        parent_id=viewer_department.id,
        child_kind="space",
        child_id=space.id,
        grant_role="viewer",
    )
    db.commit()

    return {
        "admin": admin,
        "member": member,
        "viewer": viewer,
        "outsider": outsider,
        "space_id": space.id,
    }


def test_spaces_api_lists_counts_search_and_memberships(
    client,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    graph = _seed_workspace_graph(db_session, user_factory)
    admin = graph["admin"]
    member = graph["member"]
    viewer = graph["viewer"]
    outsider = graph["outsider"]
    space_id = str(graph["space_id"])

    tasks_service.create_task(
        db_session,
        space_id=space_id,
        title="Investigate latency spike",
        description="Confirm whether this is regional.",
        status="todo",
        priority="high",
        assignee_user_id=member.id,
        created_by=admin.id,
        source_kind=None,
        source_id=None,
        source_step_id=None,
        due_at=None,
    )
    tasks_service.create_task(
        db_session,
        space_id=space_id,
        title="Archive resolved alert",
        description=None,
        status="done",
        priority="low",
        assignee_user_id=member.id,
        created_by=admin.id,
        source_kind=None,
        source_id=None,
        source_step_id=None,
        due_at=None,
    )

    open_incident = Incident(
        id=str(uuid.uuid4()),
        space_id=space_id,
        title="Payments degraded",
        status="open",
        severity=2,
        summary_md="Checkout latency increased.",
        created_by=admin.id,
    )
    resolved_incident = Incident(
        id=str(uuid.uuid4()),
        space_id=space_id,
        title="Search recovered",
        status="resolved",
        severity=3,
        summary_md="Recovered before paging.",
        created_by=admin.id,
    )
    archived_incident = Incident(
        id=str(uuid.uuid4()),
        space_id=space_id,
        title="Old archived issue",
        status="open",
        severity=4,
        summary_md="Should not count once archived.",
        created_by=admin.id,
    )
    db_session.add_all([open_incident, resolved_incident, archived_incident])
    db_session.add(
        IncidentProfile(
            incident_id=archived_incident.id,
            archived=True,
        )
    )
    db_session.commit()

    member_headers = auth_headers_factory(member)
    admin_headers = auth_headers_factory(admin)
    outsider_headers = auth_headers_factory(outsider)

    response = client.get("/spaces", params={"q": "region:eu-west"}, headers=member_headers)
    assert response.status_code == 200, response.text
    payload = response.json()
    assert len(payload) == 1
    assert payload[0] == {
        **payload[0],
        "id": space_id,
        "name": "Europe Operations",
        "slug": "europe-ops",
        "region_code": "eu-west",
        "meta": {"tier": "prod", "owner": "ops"},
        "member_count": 3,
        "active_incident_count": 1,
        "open_task_count": 1,
    }

    no_result_response = client.get("/spaces", params={"q": "region:us-east"}, headers=member_headers)
    assert no_result_response.status_code == 200
    assert no_result_response.json() == []

    members_forbidden = client.get(f"/spaces/{space_id}/members", headers=member_headers)
    assert members_forbidden.status_code == 403

    member_details = client.get(f"/spaces/{space_id}/members/detailed", headers=member_headers)
    assert member_details.status_code == 200
    detail_payload = member_details.json()
    assert {(row["email"], row["role"]) for row in detail_payload} == {
        (admin.email, "admin"),
        (member.email, "member"),
        (viewer.email, "viewer"),
    }

    admin_members = client.get(f"/spaces/{space_id}/members", headers=admin_headers)
    assert admin_members.status_code == 200
    assert {(row["user_id"], row["role"]) for row in admin_members.json()} == {
        (admin.id, "admin"),
        (member.id, "member"),
        (viewer.id, "viewer"),
    }

    outsider_spaces = client.get("/spaces", headers=outsider_headers)
    assert outsider_spaces.status_code == 200
    assert outsider_spaces.json() == []


def test_member_space_visibility_is_scoped_to_region_and_own_department(
    client,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    admin = user_factory(
        email="scoped-access-admin@example.com",
        name="Scoped Access Admin",
        password="Admin!Pass123",
    )
    member = user_factory(
        email="scoped-access-member@example.com",
        name="Scoped Access Member",
        password="Member!Pass123",
        role="member",
    )

    region = _create_unit(
        db_session,
        name="Europe",
        slug=f"europe-{uuid.uuid4().hex[:6]}",
        unit_type="region",
    )
    first_department = _create_unit(
        db_session,
        name="Customer Support",
        slug=f"customer-support-{uuid.uuid4().hex[:6]}",
        unit_type="department",
    )
    second_department = _create_unit(
        db_session,
        name="Billing Operations",
        slug=f"billing-operations-{uuid.uuid4().hex[:6]}",
        unit_type="department",
    )

    region_space = spaces_service.create_space(
        db_session,
        "Europe Leadership",
        f"europe-leadership-{uuid.uuid4().hex[:6]}",
        admin.id,
        region_code="eu-west",
        meta_json=None,
    )
    first_department_space = spaces_service.create_space(
        db_session,
        "Support Queue",
        f"support-queue-{uuid.uuid4().hex[:6]}",
        admin.id,
        region_code="eu-west",
        meta_json=None,
    )
    second_department_space = spaces_service.create_space(
        db_session,
        "Billing Escalations",
        f"billing-escalations-{uuid.uuid4().hex[:6]}",
        admin.id,
        region_code="eu-west",
        meta_json=None,
    )

    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="department",
        child_id=first_department.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="department",
        child_id=second_department.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="space",
        child_id=region_space.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=first_department.id,
        child_kind="space",
        child_id=first_department_space.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=second_department.id,
        child_kind="space",
        child_id=second_department_space.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=second_department.id,
        child_kind="user",
        child_id=member.id,
        grant_role="member",
    )
    db_session.commit()

    member_headers = auth_headers_factory(member)
    initial_response = client.get("/spaces", headers=member_headers)
    assert initial_response.status_code == 200
    assert {row["name"] for row in initial_response.json()} == {
        "Europe Leadership",
        "Billing Escalations",
    }
    assert spaces_service.get_space_role(db_session, region_space.id, member.id) == "member"
    assert (
        spaces_service.get_space_role(
            db_session,
            second_department_space.id,
            member.id,
        )
        == "member"
    )
    assert (
        spaces_service.get_space_role(
            db_session,
            first_department_space.id,
            member.id,
        )
        is None
    )

    admin_service.create_organization_item_link(
        db_session,
        parent_kind="department",
        parent_id=first_department.id,
        child_kind="user",
        child_id=member.id,
        grant_role="member",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )
    db_session.commit()

    active_parent_ids = {
        parent_id
        for parent_id, in db_session.execute(
            select(OrganizationItemLink.parent_id).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.child_kind == "user",
                OrganizationItemLink.child_id == member.id,
                OrganizationItemLink.active.is_(True),
            )
        ).all()
        if isinstance(parent_id, str) and parent_id
    }
    assert active_parent_ids == {first_department.id}

    reassigned_response = client.get("/spaces", headers=member_headers)
    assert reassigned_response.status_code == 200
    assert {row["name"] for row in reassigned_response.json()} == {
        "Europe Leadership",
        "Support Queue",
    }
    assert (
        spaces_service.get_space_role(
            db_session,
            first_department_space.id,
            member.id,
        )
        == "member"
    )
    assert (
        spaces_service.get_space_role(
            db_session,
            second_department_space.id,
            member.id,
        )
        is None
    )


def test_reassigning_department_to_new_parent_replaces_previous_parent(
    db_session: Session,
) -> None:
    first_region = _create_unit(
        db_session,
        name="First Region",
        slug=f"first-region-{uuid.uuid4().hex[:6]}",
        unit_type="region",
    )
    second_region = _create_unit(
        db_session,
        name="Second Region",
        slug=f"second-region-{uuid.uuid4().hex[:6]}",
        unit_type="region",
    )
    department = _create_unit(
        db_session,
        name="Platform Engineering",
        slug=f"platform-engineering-{uuid.uuid4().hex[:6]}",
        unit_type="department",
    )

    _link(
        db_session,
        parent_kind="department",
        parent_id=first_region.id,
        child_kind="department",
        child_id=department.id,
        grant_role="member",
    )
    db_session.commit()

    admin_service.create_organization_item_link(
        db_session,
        parent_kind="department",
        parent_id=second_region.id,
        child_kind="department",
        child_id=department.id,
        grant_role="member",
        inherit_to_descendants=True,
        active=True,
        commit=False,
    )
    db_session.commit()

    active_parent_ids = {
        parent_id
        for parent_id, in db_session.execute(
            select(OrganizationItemLink.parent_id).where(
                OrganizationItemLink.parent_kind == "department",
                OrganizationItemLink.child_kind == "department",
                OrganizationItemLink.child_id == department.id,
                OrganizationItemLink.active.is_(True),
            )
        ).all()
        if isinstance(parent_id, str) and parent_id
    }
    assert active_parent_ids == {second_region.id}


def test_manager_reports_inherit_space_access_from_department_linked_manager(
    client,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    admin = user_factory(
        email="manager-access-admin@example.com",
        name="Manager Access Admin",
        password="Admin!Pass123",
    )
    manager = user_factory(
        email="manager-access-manager@example.com",
        name="Department Manager",
        password="Manager!Pass123",
        role="member",
    )
    report = user_factory(
        email="manager-access-report@example.com",
        name="Managed Report",
        password="Report!Pass123",
        role="member",
    )

    region = _create_unit(
        db_session,
        name="North Region",
        slug=f"north-region-{uuid.uuid4().hex[:6]}",
        unit_type="region",
    )
    department = _create_unit(
        db_session,
        name="Fulfillment",
        slug=f"fulfillment-{uuid.uuid4().hex[:6]}",
        unit_type="department",
    )
    region_space = spaces_service.create_space(
        db_session,
        "Regional Command",
        f"regional-command-{uuid.uuid4().hex[:6]}",
        admin.id,
        region_code="eu-west",
        meta_json=None,
    )
    department_space = spaces_service.create_space(
        db_session,
        "Fulfillment Desk",
        f"fulfillment-desk-{uuid.uuid4().hex[:6]}",
        admin.id,
        region_code="eu-west",
        meta_json=None,
    )

    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="department",
        child_id=department.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="space",
        child_id=region_space.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=department.id,
        child_kind="space",
        child_id=department_space.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=department.id,
        child_kind="user",
        child_id=manager.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="user",
        parent_id=manager.id,
        child_kind="user",
        child_id=report.id,
        grant_role="member",
    )
    db_session.commit()

    report_headers = auth_headers_factory(report)
    response = client.get("/spaces", headers=report_headers)
    assert response.status_code == 200
    assert {row["name"] for row in response.json()} == {
        "Regional Command",
        "Fulfillment Desk",
    }
    assert spaces_service.get_space_role(db_session, region_space.id, report.id) == "member"
    assert (
        spaces_service.get_space_role(
            db_session,
            department_space.id,
            report.id,
        )
        == "member"
    )


def test_effective_space_member_can_open_kb_versions_with_viewer_global_role(
    client,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    admin = user_factory(
        email="kb-access-admin@example.com",
        name="KB Access Admin",
        password="Admin!Pass123",
    )
    manager = user_factory(
        email="kb-access-manager@example.com",
        name="KB Manager",
        password="Manager!Pass123",
        role="member",
    )
    report = user_factory(
        email="kb-access-report@example.com",
        name="KB Report",
        password="Report!Pass123",
        role="viewer",
    )

    region = _create_unit(
        db_session,
        name="KB Region",
        slug=f"kb-region-{uuid.uuid4().hex[:6]}",
        unit_type="region",
    )
    department = _create_unit(
        db_session,
        name="KB Department",
        slug=f"kb-department-{uuid.uuid4().hex[:6]}",
        unit_type="department",
    )
    kb_space = spaces_service.create_space(
        db_session,
        "KB Workspace",
        f"kb-workspace-{uuid.uuid4().hex[:6]}",
        admin.id,
        region_code="eu-west",
        meta_json=None,
    )

    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="department",
        child_id=department.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=region.id,
        child_kind="space",
        child_id=kb_space.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=department.id,
        child_kind="user",
        child_id=manager.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="user",
        parent_id=manager.id,
        child_kind="user",
        child_id=report.id,
        grant_role="member",
    )
    db_session.commit()

    doc = kb_service.create_doc(
        db_session,
        user_id=admin.id,
        space_id=kb_space.id,
        folder_id=None,
        title="Shift Handoff",
        slug=f"shift-handoff-{uuid.uuid4().hex[:6]}",
        content_md="<p>Verify the queues before handoff.</p>",
    )
    kb_service.publish_doc(db_session, doc.id)

    report_headers = auth_headers_factory(report)

    detail_response = client.get(f"/kb/docs/{doc.id}/detail", headers=report_headers)
    assert detail_response.status_code == 200, detail_response.text

    versions_response = client.get(
        f"/kb/docs/{doc.id}/versions",
        headers=report_headers,
    )
    assert versions_response.status_code == 200, versions_response.text
    assert len(versions_response.json()) >= 1

    comments_response = client.get(
        f"/kb/docs/{doc.id}/comments",
        headers=report_headers,
    )
    assert comments_response.status_code == 200, comments_response.text

    diff_response = client.get(f"/kb/docs/{doc.id}/diff", headers=report_headers)
    assert diff_response.status_code == 200, diff_response.text


def test_space_creation_and_task_crud_permissions_and_comments(
    client,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    graph = _seed_workspace_graph(db_session, user_factory)
    admin = graph["admin"]
    member = graph["member"]
    viewer = graph["viewer"]
    outsider = graph["outsider"]
    space_id = str(graph["space_id"])

    member_headers = auth_headers_factory(member)
    viewer_headers = auth_headers_factory(viewer)
    outsider_headers = auth_headers_factory(outsider)
    admin_headers = auth_headers_factory(admin)

    create_space_response = client.post(
        "/spaces",
        json={
            "name": "North America",
            "slug": "na-ops",
            "region_code": "us-east",
            "meta": {"tier": "stage"},
        },
        headers=member_headers,
    )
    assert create_space_response.status_code == 200, create_space_response.text
    assert create_space_response.json() == {
        "id": create_space_response.json()["id"],
        "name": "North America",
        "slug": "na-ops",
        "region_code": "us-east",
        "meta": {"tier": "stage"},
        "member_count": 0,
        "active_incident_count": 0,
        "open_task_count": 0,
    }

    task_create_response = client.post(
        "/tasks",
        json={
            "space_id": space_id,
            "title": "Rotate on-call notes",
            "description": "  Clean up the shift summary before handoff.  ",
            "status": "todo",
            "priority": "high",
            "assignee_user_id": member.id,
            "source_kind": "manual",
            "checklist": [
                {"label": "Review handoff summary", "completed": False},
                {"label": "Confirm the escalation owner", "completed": False},
            ],
        },
        headers=member_headers,
    )
    assert task_create_response.status_code == 200, task_create_response.text
    created_task = task_create_response.json()
    task_id = created_task["id"]
    assert created_task["title"] == "Rotate on-call notes"
    assert created_task["description"] == "Clean up the shift summary before handoff."
    assert created_task["status"] == "todo"
    assert created_task["priority"] == "high"
    assert created_task["assignee_user_id"] == member.id
    assert created_task["source_kind"] == "manual"
    assert [item["label"] for item in created_task["checklist"]] == [
        "Review handoff summary",
        "Confirm the escalation owner",
    ]

    bad_assignee_response = client.post(
        "/tasks",
        json={
            "space_id": space_id,
            "title": "This should fail",
            "assignee_user_id": outsider.id,
        },
        headers=member_headers,
    )
    assert bad_assignee_response.status_code == 404
    assert bad_assignee_response.json()["detail"] == "Assignee must be a member of the selected space"

    viewer_list_response = client.get(f"/tasks/spaces/{space_id}", headers=viewer_headers)
    assert viewer_list_response.status_code == 200
    assert [row["id"] for row in viewer_list_response.json()] == [task_id]

    my_tasks_response = client.get("/tasks/my", params={"q": "priority:high"}, headers=member_headers)
    assert my_tasks_response.status_code == 200
    assert [row["id"] for row in my_tasks_response.json()] == [task_id]

    manual_search_response = client.get(
        "/tasks/my",
        params={"q": "@source:manual"},
        headers=member_headers,
    )
    assert manual_search_response.status_code == 200
    assert [row["id"] for row in manual_search_response.json()] == [task_id]

    outsider_list_response = client.get(f"/tasks/spaces/{space_id}", headers=outsider_headers)
    assert outsider_list_response.status_code == 403

    viewer_comment_forbidden = client.post(
        f"/tasks/{task_id}/comments",
        json={"body": "Readonly users cannot comment."},
        headers=viewer_headers,
    )
    assert viewer_comment_forbidden.status_code == 403

    create_comment_response = client.post(
        f"/tasks/{task_id}/comments",
        json={"body": "  Taking this during the next handoff.  "},
        headers=member_headers,
    )
    assert create_comment_response.status_code == 200
    created_comment = create_comment_response.json()
    comment_id = created_comment["id"]
    assert created_comment["author_name"] == member.name
    assert created_comment["body"] == "Taking this during the next handoff."

    comment_list_response = client.get(f"/tasks/{task_id}/comments", headers=viewer_headers)
    assert comment_list_response.status_code == 200
    assert comment_list_response.json() == [
        {
            **comment_list_response.json()[0],
            "id": comment_id,
            "task_id": task_id,
            "space_id": space_id,
            "author_user_id": member.id,
            "author_name": member.name,
            "body": "Taking this during the next handoff.",
        }
    ]

    viewer_update_forbidden = client.put(
        f"/tasks/{task_id}",
        json={"status": "done"},
        headers=viewer_headers,
    )
    assert viewer_update_forbidden.status_code == 403

    due_at = datetime.now(timezone.utc) + timedelta(days=2)
    member_update_response = client.put(
        f"/tasks/{task_id}",
        json={
            "status": "in_progress",
            "priority": "critical",
            "description": "  Investigating blockers now.  ",
            "checklist": [
                {
                    "id": created_task["checklist"][0]["id"],
                    "label": "Review handoff summary",
                    "completed": True,
                },
                {
                    "id": created_task["checklist"][1]["id"],
                    "label": "Confirm the escalation owner",
                    "completed": False,
                },
            ],
            "due_at": due_at.isoformat(),
        },
        headers=member_headers,
    )
    assert member_update_response.status_code == 200, member_update_response.text
    updated_task = member_update_response.json()
    assert updated_task["status"] == "in_progress"
    assert updated_task["priority"] == "critical"
    assert updated_task["description"] == "Investigating blockers now."
    assert updated_task["due_at"] is not None
    assert [item["completed"] for item in updated_task["checklist"]] == [
        True,
        False,
    ]

    delete_comment_forbidden = client.delete(
        f"/tasks/{task_id}/comments/{comment_id}",
        headers=viewer_headers,
    )
    assert delete_comment_forbidden.status_code == 403

    delete_comment_response = client.delete(
        f"/tasks/{task_id}/comments/{comment_id}",
        headers=admin_headers,
    )
    assert delete_comment_response.status_code == 200
    assert delete_comment_response.json() == {"ok": True}

    empty_comments_response = client.get(f"/tasks/{task_id}/comments", headers=member_headers)
    assert empty_comments_response.status_code == 200
    assert empty_comments_response.json() == []


def test_task_service_sop_linking_and_execution_profiles(
    db_session: Session,
    user_factory,
) -> None:
    graph = _seed_workspace_graph(db_session, user_factory)
    admin = graph["admin"]
    member = graph["member"]
    outsider = graph["outsider"]
    space_id = str(graph["space_id"])

    sop = Sop(
        id=str(uuid.uuid4()),
        space_id=space_id,
        title="Refund Escalation",
        slug="refund-escalation",
        status="published",
        overview_md="Run the refund triage flow.",
        created_by=admin.id,
        updated_by=admin.id,
    )
    db_session.add(sop)
    db_session.commit()

    task = tasks_service.create_task(
        db_session,
        space_id=space_id,
        title="Review disputed charge",
        description="Verify routing and escalation tags.",
        status="todo",
        priority="medium",
        assignee_user_id=member.id,
        created_by=admin.id,
        source_kind="sop",
        source_id=sop.id,
        source_step_id=None,
        due_at=None,
    )
    assert tasks_service.get_task_by_source(
        db_session,
        source_kind="sop",
        source_id=sop.id,
        source_step_id=None,
    ) == task
    assert [row.id for row in tasks_service.list_tasks_for_sop_source(db_session, sop_id=sop.id)] == [task.id]

    with pytest.raises(HTTPException) as invalid_source:
        tasks_service.create_task(
            db_session,
            space_id=space_id,
            title="Invalid source",
            description=None,
            status="todo",
            priority="medium",
            assignee_user_id=None,
            created_by=admin.id,
            source_kind="manual",
            source_id="manual-1",
            source_step_id="step-1",
            due_at=None,
        )
    assert invalid_source.value.status_code == 400

    with pytest.raises(HTTPException) as invalid_sop_step:
        tasks_service.update_task(
            db_session,
            task.id,
            actor_user_id=admin.id,
            source_kind="sop_step",
            source_id=sop.id,
            source_step_id=str(uuid.uuid4()),
            apply_source_link=True,
        )
    assert invalid_sop_step.value.status_code == 404

    with pytest.raises(HTTPException) as invalid_operator:
        tasks_service.replace_sop_execution_profiles(
            db_session,
            sop_id=sop.id,
            space_id=space_id,
            sop_title=sop.title,
            actor_user_id=admin.id,
            schedules=[
                {
                    "enabled": True,
                    "operator_user_id": outsider.id,
                }
            ],
        )
    assert invalid_operator.value.status_code == 400
    assert invalid_operator.value.detail == "Operator must be a member of this space"

    now = datetime.now(timezone.utc)
    overdue_at = now - timedelta(days=1)
    tasks_service.replace_sop_execution_profiles(
        db_session,
        sop_id=sop.id,
        space_id=space_id,
        sop_title=sop.title,
        actor_user_id=admin.id,
        schedules=[
            {
                "cadence_days": 120,
                "next_due_at": overdue_at,
                "operator_user_id": member.id,
                "enabled": True,
                "reminder_channels": ["email", "in_app", "email", "bogus"],
            },
            {
                "cadence_days": 0,
                "enabled": False,
                "reminder_channels": [],
            },
        ],
    )

    schedule_views = tasks_service.list_sop_execution_schedule_views(db_session, sop_id=sop.id)
    assert len(schedule_views) == 2
    active_profile = schedule_views[0]
    disabled_profile = schedule_views[1]
    assert active_profile["operator_name"] == member.name
    assert active_profile["cadence_days"] == 90
    assert active_profile["reminder_channels"] == ["email", "in_app"]
    assert active_profile["overdue"] is True
    assert disabled_profile["cadence_days"] == 7
    assert disabled_profile["enabled"] is False
    assert disabled_profile["reminder_channels"] == ["in_app"]

    due_views = tasks_service.list_due_sop_execution_schedule_views(db_session, space_id=space_id)
    assert len(due_views) == 1
    assert due_views[0]["operator_user_id"] == member.id

    created_dispatches = tasks_service.process_due_sop_execution_reminders(db_session)
    assert created_dispatches == 2
    assert tasks_service.process_due_sop_execution_reminders(db_session) == 0

    schedule_views_after_dispatch = tasks_service.list_sop_execution_schedule_views(db_session, sop_id=sop.id)
    assert len(schedule_views_after_dispatch[0]["recent_dispatches"]) == 2
    assert {row["channel"] for row in schedule_views_after_dispatch[0]["recent_dispatches"]} == {
        "email",
        "in_app",
    }

    tasks_service.mark_sop_execution_started(db_session, sop_id=sop.id, started_at=now)
    refreshed_profiles = db_session.execute(
        select(TaskExecutionProfile).where(TaskExecutionProfile.source_id == sop.id)
    ).scalars().all()
    assert any(profile.last_started_at is not None for profile in refreshed_profiles)
    assert tasks_service.list_due_sop_execution_schedule_views(db_session, space_id=space_id) == []

    tasks_service.clear_sop_execution_profiles(db_session, sop_id=sop.id)
    db_session.commit()
    assert tasks_service.list_sop_execution_schedule_views(db_session, sop_id=sop.id) == []
    assert db_session.execute(select(TaskReminderDispatch)).scalars().all() == []


def test_sop_run_start_creates_trackable_task_and_supports_forwarding(
    client,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    graph = _seed_workspace_graph(db_session, user_factory)
    member = graph["member"]
    space_id = str(graph["space_id"])

    report = user_factory(
        email="spaces-report@example.com",
        name="Direct Report",
        password="Report!Pass123",
        role="member",
    )
    forward_manager = user_factory(
        email="spaces-forward-manager@example.com",
        name="Forward Manager",
        password="Manager!Pass123",
        role="member",
    )
    forward_report = user_factory(
        email="spaces-forward-report@example.com",
        name="Forward Report",
        password="Forward!Pass123",
        role="member",
    )
    operator_unit = _create_unit(
        db_session,
        name="Operator Team",
        slug=f"operator-team-{uuid.uuid4().hex[:6]}",
    )
    forward_unit = _create_unit(
        db_session,
        name="Forward Team",
        slug=f"forward-team-{uuid.uuid4().hex[:6]}",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=operator_unit.id,
        child_kind="space",
        child_id=space_id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=operator_unit.id,
        child_kind="user",
        child_id=report.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=forward_unit.id,
        child_kind="space",
        child_id=space_id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=forward_unit.id,
        child_kind="user",
        child_id=forward_manager.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="department",
        parent_id=forward_unit.id,
        child_kind="user",
        child_id=forward_report.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="user",
        parent_id=member.id,
        child_kind="user",
        child_id=report.id,
        grant_role="member",
    )
    _link(
        db_session,
        parent_kind="user",
        parent_id=forward_manager.id,
        child_kind="user",
        child_id=forward_report.id,
        grant_role="member",
    )
    db_session.commit()

    sop = sop_service.create_sop(
        db_session,
        user_id=member.id,
        space_id=space_id,
        title="Refund escalation",
        slug=f"refund-escalation-{uuid.uuid4().hex[:6]}",
        overview_md="<p>Run refund ops workflow.</p>",
    )
    sop_service.replace_steps(
        db_session,
        sop.id,
        [
            {
                "step_order": 1,
                "title": "Validate queue handoff",
                "body_md": "<p>Check that the next owner accepted the work.</p>",
            }
        ],
    )
    sop_service.publish(db_session, sop.id)

    member_headers = auth_headers_factory(member)
    report_headers = auth_headers_factory(report)

    options_response = client.get(
        f"/sop/sops/{sop.id}/run-assignment-options",
        headers=member_headers,
    )
    assert options_response.status_code == 200
    options_payload = options_response.json()
    assert report.id in {
        row["user_id"] for row in options_payload["direct_assignees"]
    }
    assert forward_manager.id in {
        row["user_id"] for row in options_payload["forward_managers"]
    }

    direct_run_response = client.post(
        f"/sop/sops/{sop.id}/runs",
        json={"assignee_user_id": report.id},
        headers=member_headers,
    )
    assert direct_run_response.status_code == 200
    direct_payload = direct_run_response.json()
    assert direct_payload["assignment_mode"] == "delegate"
    direct_task = db_session.get(Task, direct_payload["task_id"])
    assert direct_task is not None
    assert direct_task.assignee_user_id == report.id
    assert direct_task.source_kind == "sop_run"
    assert direct_task.source_id == sop.id
    assert direct_task.source_step_id == direct_payload["run"]["id"]

    report_task_search = client.get(
        "/tasks/my",
        params={"q": "@source:sop_run"},
        headers=report_headers,
    )
    assert report_task_search.status_code == 200
    assert [row["id"] for row in report_task_search.json()] == [
        direct_payload["task_id"]
    ]

    run_id = str(direct_payload["run"]["id"])
    run_steps = sop_service.list_run_steps(db_session, run_id)
    assert len(run_steps) == 1
    sop_service.update_run_step(
        db_session,
        user_id=member.id,
        run_id=run_id,
        run_step_id=run_steps[0].id,
        completed=True,
    )
    sop_service.complete_run(db_session, run_id=run_id)
    direct_task = db_session.get(Task, direct_payload["task_id"])
    assert direct_task is not None
    assert direct_task.status == "done"

    forward_run_response = client.post(
        f"/sop/sops/{sop.id}/runs",
        json={"forward_manager_user_id": forward_manager.id},
        headers=member_headers,
    )
    assert forward_run_response.status_code == 200
    forward_payload = forward_run_response.json()
    assert forward_payload["assignment_mode"] == "forward"
    forward_task = db_session.get(Task, forward_payload["task_id"])
    assert forward_task is not None
    assert forward_task.assignee_user_id == forward_manager.id
    assert forward_task.source_kind == "sop_run"
    assert forward_task.title.startswith("Assign SOP run:")
