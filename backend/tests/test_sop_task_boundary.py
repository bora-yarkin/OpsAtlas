# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.core.db import Base, SessionLocal, engine, init_db
from app.modules.auth.models import User
from app.modules.incidents import service as incident_service
from app.modules.sop import service as sop_service
from app.modules.sop.models import SopRunSchedule
from app.modules.spaces.models import Space
from app.modules.tasks import service as tasks_service
from app.modules.tasks.models import TaskExecutionProfile


@pytest.fixture(autouse=True)
def reset_db() -> None:
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


def _seed_user_space_sop() -> tuple[str, str, str]:
    with SessionLocal() as db:
        user = User(
            id=str(uuid.uuid4()),
            email="ops-admin@example.com",
            name="Ops Admin",
            password_hash="test-hash",
            global_role="admin",
            is_active=True,
            must_change_password=False,
        )
        space = Space(
            id=str(uuid.uuid4()),
            name="Operations",
            slug=f"operations-{uuid.uuid4().hex[:8]}",
            owner_user_id=user.id,
            region_code="eu-central",
            meta_json=None,
        )
        db.add(user)
        db.add(space)
        db.commit()

        sop = sop_service.create_sop(
            db,
            user_id=user.id,
            space_id=space.id,
            title="Incident SOP",
            slug=f"incident-sop-{uuid.uuid4().hex[:8]}",
            overview_md="<p>Procedure reference</p>",
        )
        return user.id, space.id, sop.id


def test_sop_run_schedules_now_use_task_execution_profiles() -> None:
    user_id, space_id, sop_id = _seed_user_space_sop()

    with SessionLocal() as db:
        next_due = datetime.now(timezone.utc) + timedelta(days=2)
        sop_service.replace_run_schedules(
            db,
            sop_id=sop_id,
            actor_user_id=user_id,
            schedules=[
                {
                    "cadence_days": 7,
                    "next_due_at": next_due,
                    "operator_user_id": None,
                    "enabled": True,
                    "reminder_channels": ["in_app", "email"],
                }
            ],
        )

        profiles = list(
            db.execute(
                select(TaskExecutionProfile).where(
                    TaskExecutionProfile.source_kind == "sop",
                    TaskExecutionProfile.source_id == sop_id,
                )
            )
            .scalars()
            .all()
        )
        assert len(profiles) == 1
        assert profiles[0].space_id == space_id
        assert profiles[0].cadence_days == 7
        assert profiles[0].enabled is True

        # Legacy SOP-owned schedule rows should no longer be active after writes.
        legacy_rows = list(
            db.execute(
                select(SopRunSchedule).where(SopRunSchedule.sop_id == sop_id)
            )
            .scalars()
            .all()
        )
        assert legacy_rows == []

        detail = sop_service.get_detail(db, sop_id)
        assert len(detail.run_schedules) == 1
        assert detail.run_schedules[0].cadence_days == 7
        assert detail.run_schedules[0].sop_id == sop_id


def test_task_source_links_support_sop_and_sop_step() -> None:
    user_id, space_id, sop_id = _seed_user_space_sop()

    with SessionLocal() as db:
        sop_service.replace_steps(
            db,
            sop_id,
            [
                {
                    "step_order": 1,
                    "title": "Confirm trigger",
                    "body_md": "<p>Verify the incident trigger.</p>",
                }
            ],
        )
        step = sop_service.list_steps(db, sop_id)[0]

        task = tasks_service.create_task(
            db,
            space_id=space_id,
            title="Execute SOP step",
            description="Run validation and capture output.",
            status="todo",
            priority="medium",
            assignee_user_id=None,
            created_by=user_id,
            source_kind="sop_step",
            source_id=sop_id,
            source_step_id=step.id,
            due_at=None,
        )
        assert task.source_kind == "sop_step"
        assert task.source_id == sop_id
        assert task.source_step_id == step.id

        cleared = tasks_service.update_task(
            db,
            task.id,
            actor_user_id=user_id,
            source_kind=None,
            source_id=None,
            source_step_id=None,
            apply_source_link=True,
        )
        assert cleared.source_kind is None
        assert cleared.source_id is None
        assert cleared.source_step_id is None


def test_sop_run_step_follow_up_task_creation_is_idempotent() -> None:
    user_id, _space_id, sop_id = _seed_user_space_sop()

    with SessionLocal() as db:
        sop_service.replace_steps(
            db,
            sop_id,
            [
                {
                    "step_order": 1,
                    "title": "Capture rollback evidence",
                    "body_md": "<p>Collect command output and attach logs.</p>",
                    "requires_evidence": True,
                }
            ],
        )
        sop_service.publish(db, sop_id)
        run = sop_service.start_run(db, user_id=user_id, sop_id=sop_id)
        run_step = sop_service.list_run_steps(db, run.id)[0]

        task_id, created = sop_service.create_follow_up_task(
            db,
            user_id=user_id,
            run_step_id=run_step.id,
        )
        assert created is True

        existing_task_id, created_again = sop_service.create_follow_up_task(
            db,
            user_id=user_id,
            run_step_id=run_step.id,
        )
        assert created_again is False
        assert existing_task_id == task_id

        linked_task = tasks_service.get_task(db, task_id)
        assert linked_task is not None
        assert linked_task.source_kind == "sop_step"
        assert linked_task.source_id == sop_id
        assert linked_task.source_step_id == run_step.step_id

        run_out = sop_service._run_to_out(db, run)
        assert run_out.steps[0].follow_up_task_id == task_id


def test_incident_action_item_follow_up_task_creation_is_idempotent() -> None:
    user_id, space_id, _sop_id = _seed_user_space_sop()

    with SessionLocal() as db:
        incident = incident_service.create(
            db,
            user_id=user_id,
            space_id=space_id,
            title="API timeout spike",
            severity=2,
            summary_md="<p>Latency increased across edge nodes.</p>",
        )
        action_item = incident_service.create_action_item(
            db,
            user_id=user_id,
            incident_id=incident.id,
            title="Tune edge retry budget",
            owner_user_id=user_id,
            due_at=None,
            status="open",
            notes_md="<p>Coordinate with platform team.</p>",
        )

        task_id, created = incident_service.create_task_for_action_item(
            db,
            user_id=user_id,
            incident_id=incident.id,
            action_item_id=action_item.id,
        )
        assert created is True

        existing_task_id, created_again = incident_service.create_task_for_action_item(
            db,
            user_id=user_id,
            incident_id=incident.id,
            action_item_id=action_item.id,
        )
        assert created_again is False
        assert existing_task_id == task_id

        linked_task = tasks_service.get_task(db, task_id)
        assert linked_task is not None
        assert linked_task.source_kind == "incident_action_item"
        assert linked_task.source_id == incident.id
        assert linked_task.source_step_id == action_item.id

        detail = incident_service.get_detail(db, incident.id)
        detail_action_item = next(
            row for row in detail.action_items if row.id == action_item.id
        )
        assert detail_action_item.linked_task_id == task_id
