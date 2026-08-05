# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from app.core.db import Base, SessionLocal, engine, init_db
from app.modules.analytics import service as analytics_service
from app.modules.analytics.models import Event
from app.modules.auth.models import User
from app.modules.kb.models import Doc
from app.modules.spaces.models import Space
from app.modules.tasks.models import Task


@pytest.fixture(autouse=True)
def reset_db() -> None:
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


def _seed_user_and_space() -> tuple[str, str]:
    with SessionLocal() as db:
        user = User(
            id=str(uuid.uuid4()),
            email="analytics@example.com",
            name="Analytics Admin",
            password_hash="test-hash",
            global_role="admin",
            is_active=True,
            must_change_password=False,
        )
        space = Space(
            id=str(uuid.uuid4()),
            name="Ops Space",
            slug=f"ops-space-{uuid.uuid4().hex[:8]}",
            owner_user_id=user.id,
            region_code="eu-central",
            meta_json=None,
        )
        db.add(user)
        db.add(space)
        db.commit()
        return user.id, space.id


def test_top_entities_counts_real_view_and_open_signals() -> None:
    user_id, space_id = _seed_user_and_space()
    doc_id = str(uuid.uuid4())
    task_id = str(uuid.uuid4())

    with SessionLocal() as db:
        db.add(
            Doc(
                id=doc_id,
                space_id=space_id,
                folder_id=None,
                title="Runbook",
                slug=f"runbook-{uuid.uuid4().hex[:8]}",
                status="published",
                content_md="<p>Runbook</p>",
                created_by=user_id,
                updated_by=user_id,
            )
        )
        db.add(
            Task(
                id=task_id,
                space_id=space_id,
                title="Restore service",
                description="",
                status="todo",
                priority="high",
                assignee_user_id=user_id,
                created_by=user_id,
                source_kind=None,
                source_id=None,
                source_step_id=None,
                due_at=None,
            )
        )
        db.add_all(
            [
                Event(
                    id=str(uuid.uuid4()),
                    ts=datetime.now(timezone.utc) - timedelta(hours=2),
                    user_id=user_id,
                    session_id="app-session-1",
                    event_type="view",
                    space_id=space_id,
                    entity_type="doc",
                    entity_id=doc_id,
                    path=f"/spaces/{space_id}?docId={doc_id}",
                    meta_json=json.dumps({"producer": "client"}),
                ),
                Event(
                    id=str(uuid.uuid4()),
                    ts=datetime.now(timezone.utc) - timedelta(hours=1),
                    user_id=user_id,
                    session_id="app-session-1",
                    event_type="view",
                    space_id=space_id,
                    entity_type="doc",
                    entity_id=doc_id,
                    path=f"/spaces/{space_id}?docId={doc_id}",
                    meta_json=json.dumps({"producer": "client"}),
                ),
                Event(
                    id=str(uuid.uuid4()),
                    ts=datetime.now(timezone.utc) - timedelta(minutes=30),
                    user_id=user_id,
                    session_id="app-session-1",
                    event_type="open",
                    space_id=space_id,
                    entity_type="task",
                    entity_id=task_id,
                    path=f"/tasks?spaceId={space_id}&search={task_id}",
                    meta_json=json.dumps({"producer": "client"}),
                ),
            ]
        )
        db.commit()

        doc_rows = analytics_service.top_entities(db, space_id, "doc", days=30)
        task_rows = analytics_service.top_entities(db, space_id, "task", days=30)

    assert doc_rows == [
        {
            "entity_id": doc_id,
            "views": 2,
            "title": "Runbook",
            "slug": doc_rows[0]["slug"],
            "path": f"/spaces/{space_id}?docId={doc_id}",
        }
    ]
    assert task_rows == [
        {
            "entity_id": task_id,
            "views": 1,
            "title": "Restore service",
            "slug": None,
            "path": f"/tasks?spaceId={space_id}&search={task_id}",
        }
    ]


def test_search_quality_summary_reports_diagnostics_recovery_and_refinement() -> None:
    user_id, space_id = _seed_user_and_space()
    now = datetime.now(timezone.utc)

    def event(*, ts_offset_minutes: int, event_type: str, meta: dict[str, object]) -> Event:
        return Event(
            id=str(uuid.uuid4()),
            ts=now - timedelta(minutes=ts_offset_minutes),
            user_id=user_id,
            session_id="app-session-analytics",
            event_type=event_type,
            space_id=space_id,
            entity_type="task",
            entity_id=None,
            path=f"/tasks?spaceId={space_id}",
            meta_json=json.dumps(meta),
        )

    with SessionLocal() as db:
        db.add_all(
            [
                event(
                        ts_offset_minutes=6,
                    event_type="search_query_issued",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-1",
                        "query": "latency",
                        "diagnostics_count": 0,
                        "has_diagnostics": False,
                        "refinement_depth": 0,
                    },
                ),
                event(
                        ts_offset_minutes=5,
                    event_type="search_no_result",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-1",
                        "query": "latency",
                    },
                ),
                event(
                        ts_offset_minutes=4,
                    event_type="search_suggestion_accepted",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-1",
                        "query": "latency",
                        "next_query": "latency @status:blocked",
                        "suggestion_token": "@status:blocked",
                    },
                ),
                event(
                        ts_offset_minutes=3,
                    event_type="search_query_issued",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-1",
                        "query": "latency @status:blocked",
                        "diagnostics_count": 1,
                        "has_diagnostics": True,
                        "refinement_depth": 1,
                    },
                ),
                event(
                        ts_offset_minutes=2,
                    event_type="search_results_shown",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-1",
                        "query": "latency @status:blocked",
                        "results": 2,
                    },
                ),
                event(
                        ts_offset_minutes=1,
                    event_type="search_query_issued",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-2",
                        "query": "database",
                        "diagnostics_count": 0,
                        "has_diagnostics": False,
                        "refinement_depth": 0,
                    },
                ),
                event(
                        ts_offset_minutes=0,
                    event_type="search_results_shown",
                    meta={
                        "producer": "client",
                        "surface": "tasks_space",
                        "search_session_id": "search-flow-2",
                        "query": "database",
                        "results": 1,
                    },
                ),
            ]
        )
        db.commit()

        summary = analytics_service.search_quality_summary(
            db,
            space_id=space_id,
            days=30,
        )

    assert summary == {
        "query_count": 3,
        "queries_with_diagnostics": 1,
        "parse_diagnostic_rate": 0.3333,
        "suggestion_acceptance_count": 1,
        "suggestion_acceptance_rate": 0.3333,
        "zero_result_session_count": 1,
        "recovered_zero_result_session_count": 1,
        "zero_result_recovery_rate": 1.0,
        "average_refinement_depth": 0.33,
    }


def test_trends_and_export_respect_filters() -> None:
    user_id, space_id = _seed_user_and_space()
    now = datetime.now(timezone.utc)

    with SessionLocal() as db:
        db.add_all(
            [
                Event(
                    id=str(uuid.uuid4()),
                    ts=now - timedelta(days=2),
                    user_id=user_id,
                    session_id="app-session-1",
                    event_type="view",
                    space_id=space_id,
                    entity_type="doc",
                    entity_id=str(uuid.uuid4()),
                    path=f"/spaces/{space_id}",
                    meta_json=json.dumps({"producer": "client"}),
                ),
                Event(
                    id=str(uuid.uuid4()),
                    ts=now - timedelta(days=1),
                    user_id=user_id,
                    session_id="app-session-1",
                    event_type="view",
                    space_id=space_id,
                    entity_type="doc",
                    entity_id=str(uuid.uuid4()),
                    path=f"/spaces/{space_id}",
                    meta_json=json.dumps({"producer": "client"}),
                ),
                Event(
                    id=str(uuid.uuid4()),
                    ts=now - timedelta(days=1),
                    user_id=user_id,
                    session_id="app-session-1",
                    event_type="open",
                    space_id=space_id,
                    entity_type="task",
                    entity_id=str(uuid.uuid4()),
                    path=f"/tasks?spaceId={space_id}",
                    meta_json=json.dumps({"producer": "client"}),
                ),
            ]
        )
        db.commit()

        trend = analytics_service.trend_counts(
            db,
            space_id=space_id,
            days=30,
            event_types=("view", "open"),
            granularity="day",
        )
        filename, payload, media_type = analytics_service.export_events_payload(
            db,
            space_id=space_id,
            format_name="csv",
            days=30,
            event_types=("view", "open"),
        )

    assert len(trend) == 2
    assert [row["count"] for row in trend] == [1, 2]
    assert filename.endswith(".csv")
    assert media_type == "text/csv"
    exported = payload.decode("utf-8")
    assert "event_type" in exported
    assert "view" in exported
    assert "open" in exported


def test_client_tracked_event_taxonomy_matches_backend_queries() -> None:
    tracker_file = (
        Path(__file__).resolve().parents[2]
        / 'client'
        / 'lib'
        / 'core'
        / 'analytics_tracker.dart'
    )
    source = tracker_file.read_text(encoding='utf-8')
    match = re.search(
        r'trackedAnalyticsEventTypes\s*=\s*<String>\{(?P<body>.*?)\};',
        source,
        re.DOTALL,
    )
    assert match is not None
    client_event_types = set(re.findall(r"'([^']+)'", match.group('body')))

    assert client_event_types == set(analytics_service.CLIENT_TRACKED_EVENT_TYPES)
