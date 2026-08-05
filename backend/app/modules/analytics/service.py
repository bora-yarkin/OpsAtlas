# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for analytics aggregation, feed shaping, and reporting metrics."""

import csv
import json
import re
import uuid
from datetime import datetime, timedelta, timezone
from io import StringIO
from typing import Any, cast
from urllib.parse import quote

from sqlalchemy import func as sa_func, select
from sqlalchemy.orm import Session

from app.core.deps import bad_request
from app.modules.auth.deps import user_auth_role
from app.modules.auth.models import User
from app.modules.incidents.models import Incident
from app.modules.incidents.models import IncidentActionItem, IncidentStatusUpdate
from app.modules.kb.models import Doc, DocComment
from app.modules.spaces.models import Space
from app.modules.spaces import service as spaces_service
from app.modules.sop.models import Sop
from app.modules.tasks.models import Task, TaskComment

from .models import Event
from .schemas import TrackEventIn

TOP_ENTITY_EVENT_TYPES = frozenset({"view", "open"})
SEARCH_QUALITY_EVENT_TYPES = frozenset(
    {
        "search_query_issued",
        "search_results_shown",
        "search_no_result",
        "search_suggestion_accepted",
    }
)
CLIENT_TRACKED_EVENT_TYPES = frozenset(TOP_ENTITY_EVENT_TYPES | SEARCH_QUALITY_EVENT_TYPES)
DEFAULT_ANALYTICS_WINDOW_DAYS = 30
MAX_ANALYTICS_WINDOW_DAYS = 365
_VALID_TREND_GRANULARITIES = frozenset({"day", "week"})
_ADMIN_SURFACE_DEFAULT_PATHS = {
    "organization": "/organization",
    "organization_media": "/organization/media",
    "organization_backups": "/organization/backups",
    "analytics": "/analytics",
}


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _coerce_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _resolve_window(
    *,
    start_at: datetime | None,
    end_at: datetime | None,
    days: int | None,
) -> tuple[datetime, datetime]:
    now = _now_utc()
    normalized_end = _coerce_utc(end_at) or now
    requested_days = DEFAULT_ANALYTICS_WINDOW_DAYS if days is None else int(days)
    bounded_days = max(1, min(requested_days, MAX_ANALYTICS_WINDOW_DAYS))
    normalized_start = _coerce_utc(start_at) or (normalized_end - timedelta(days=bounded_days))
    if normalized_start > normalized_end:
        raise bad_request("Analytics start_at must be before end_at")
    return normalized_start, normalized_end


def _normalize_event_types(event_types: list[str] | tuple[str, ...] | None) -> tuple[str, ...]:
    if not event_types:
        return ()
    normalized: list[str] = []
    seen: set[str] = set()
    for raw in event_types:
        value = raw.strip().lower()
        if not value or value in seen:
            continue
        seen.add(value)
        normalized.append(value)
    return tuple(normalized)


def _parse_meta_json(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(parsed, dict):
        return {}
    return {str(key): value for key, value in parsed.items()}


def _client_produced(meta: dict[str, Any]) -> bool:
    return str(meta.get("producer", "")).strip().lower() == "client"


def _non_empty_text(value: object | None) -> str | None:
    text = str(value or "").strip()
    return text or None


def _plain_text_excerpt(raw: str | None, *, max_len: int = 180) -> str | None:
    if raw is None:
        return None
    text = raw
    text = re.sub(r"<\s*br\s*/?\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</\s*p\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", text)
    text = (
        text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
    )
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return None
    if len(text) > max_len:
        return f"{text[: max_len - 1].rstrip()}…"
    return text


def _load_by_id_map(db: Session, model: Any, ids: set[str]) -> dict[str, Any]:
    normalized_ids = {value.strip() for value in ids if value and value.strip()}
    if not normalized_ids:
        return {}
    rows = db.execute(select(model).where(model.id.in_(normalized_ids))).scalars().all()
    return {
        str(getattr(row, "id", "")).strip(): row
        for row in rows
        if str(getattr(row, "id", "")).strip()
    }


def _resolved_feed_path(row: Event, meta: dict[str, Any]) -> str | None:
    space_id = _non_empty_text(row.space_id) or _non_empty_text(meta.get("space_id"))
    entity_type = _non_empty_text(row.entity_type)
    entity_id = _non_empty_text(row.entity_id)
    normalized_type = (entity_type or "").lower()

    if normalized_type in {"doc", "document"} and space_id and entity_id:
        return f"/spaces/{space_id}?docId={entity_id}"
    if normalized_type == "sop" and space_id and entity_id:
        return f"/spaces/{space_id}?sopId={entity_id}"
    if normalized_type == "incident" and space_id and entity_id:
        return f"/spaces/{space_id}?incidentId={entity_id}"
    if normalized_type == "incident_action_item" and space_id and entity_id:
        incident_id = _non_empty_text(meta.get("incident_id"))
        if incident_id:
            return f"/spaces/{space_id}?incidentId={incident_id}&actionItemId={entity_id}"
    if normalized_type == "incident_status_update" and space_id:
        incident_id = _non_empty_text(meta.get("incident_id"))
        if incident_id:
            return f"/spaces/{space_id}?incidentId={incident_id}"
    if normalized_type == "task" and entity_id:
        if space_id:
            return f"/tasks?spaceId={space_id}&search={quote(entity_id)}"
        return f"/tasks?search={quote(entity_id)}"
    if normalized_type == "task_comment":
        task_id = _non_empty_text(meta.get("task_id"))
        if task_id:
            if space_id:
                return f"/tasks?spaceId={space_id}&search={quote(task_id)}"
            return f"/tasks?search={quote(task_id)}"
    if normalized_type == "admin_surface" and entity_id:
        return _ADMIN_SURFACE_DEFAULT_PATHS.get(entity_id, row.path)
    return row.path


def enrich_feed_rows(db: Session, rows: list[Event]) -> list[dict[str, Any]]:
    meta_by_event_id: dict[str, dict[str, Any]] = {
        row.id: _parse_meta_json(row.meta_json)
        for row in rows
    }

    user_ids = {
        row.user_id.strip()
        for row in rows
        if isinstance(row.user_id, str) and row.user_id.strip()
    }
    space_ids: set[str] = set()
    doc_ids: set[str] = set()
    sop_ids: set[str] = set()
    incident_ids: set[str] = set()
    task_ids: set[str] = set()
    task_comment_ids: set[str] = set()
    action_item_ids: set[str] = set()
    status_update_ids: set[str] = set()
    doc_comment_ids: set[str] = set()

    for row in rows:
        meta = meta_by_event_id[row.id]
        if space_id := _non_empty_text(row.space_id) or _non_empty_text(meta.get("space_id")):
            space_ids.add(space_id)

        entity_type = (_non_empty_text(row.entity_type) or "").lower()
        entity_id = _non_empty_text(row.entity_id)

        if entity_type in {"doc", "document"} and entity_id:
            doc_ids.add(entity_id)
        elif entity_type == "sop" and entity_id:
            sop_ids.add(entity_id)
        elif entity_type == "incident" and entity_id:
            incident_ids.add(entity_id)
        elif entity_type == "task" and entity_id:
            task_ids.add(entity_id)
        elif entity_type == "task_comment" and entity_id:
            task_comment_ids.add(entity_id)
        elif entity_type == "incident_action_item" and entity_id:
            action_item_ids.add(entity_id)
        elif entity_type == "incident_status_update" and entity_id:
            status_update_ids.add(entity_id)

        for key, bucket in (
            ("doc_id", doc_ids),
            ("sop_id", sop_ids),
            ("incident_id", incident_ids),
            ("task_id", task_ids),
            ("action_item_id", action_item_ids),
            ("comment_id", doc_comment_ids),
        ):
            value = _non_empty_text(meta.get(key))
            if value:
                bucket.add(value)

    actor_name_by_id = {
        row.id: _non_empty_text(row.name) or _non_empty_text(row.email)
        for row in db.execute(select(User).where(User.id.in_(user_ids))).scalars().all()
    } if user_ids else {}
    space_name_by_id = {
        row.id: row.name
        for row in db.execute(select(Space).where(Space.id.in_(space_ids))).scalars().all()
    } if space_ids else {}

    docs_by_id = _load_by_id_map(db, Doc, doc_ids)
    sops_by_id = _load_by_id_map(db, Sop, sop_ids)
    incidents_by_id = _load_by_id_map(db, Incident, incident_ids)
    tasks_by_id = _load_by_id_map(db, Task, task_ids)
    task_comments_by_id = _load_by_id_map(db, TaskComment, task_comment_ids)
    action_items_by_id = _load_by_id_map(db, IncidentActionItem, action_item_ids)
    status_updates_by_id = _load_by_id_map(db, IncidentStatusUpdate, status_update_ids)
    doc_comments_by_id = _load_by_id_map(db, DocComment, doc_comment_ids)

    enriched: list[dict[str, Any]] = []
    for row in rows:
        meta = meta_by_event_id[row.id]
        entity_type = (_non_empty_text(row.entity_type) or "").lower()
        entity_id = _non_empty_text(row.entity_id)
        event_type = (_non_empty_text(row.event_type) or "").lower()

        entity_title = _non_empty_text(meta.get("entity_title"))
        detail_text = _non_empty_text(meta.get("detail_text"))

        if entity_title is None:
            if entity_type in {"doc", "document"} and entity_id and entity_id in docs_by_id:
                entity_title = _non_empty_text(docs_by_id[entity_id].title)
            elif entity_type == "sop" and entity_id and entity_id in sops_by_id:
                entity_title = _non_empty_text(sops_by_id[entity_id].title)
            elif entity_type == "incident" and entity_id and entity_id in incidents_by_id:
                entity_title = _non_empty_text(incidents_by_id[entity_id].title)
            elif entity_type == "task" and entity_id and entity_id in tasks_by_id:
                entity_title = _non_empty_text(tasks_by_id[entity_id].title)
            elif entity_type == "task_comment":
                task_id = _non_empty_text(meta.get("task_id"))
                if task_id and task_id in tasks_by_id:
                    entity_title = _non_empty_text(tasks_by_id[task_id].title)
            elif entity_type == "incident_action_item" and entity_id and entity_id in action_items_by_id:
                entity_title = _non_empty_text(action_items_by_id[entity_id].title)
            elif entity_type == "incident_status_update":
                incident_id = _non_empty_text(meta.get("incident_id"))
                if incident_id and incident_id in incidents_by_id:
                    entity_title = _non_empty_text(incidents_by_id[incident_id].title)
            elif entity_type == "admin_surface" and entity_id:
                entity_title = _humanize_admin_surface(entity_id)

        if detail_text is None:
            if event_type == "incident_status_update" and entity_id and entity_id in status_updates_by_id:
                detail_text = _plain_text_excerpt(status_updates_by_id[entity_id].message_md)
            elif entity_type == "task_comment" and entity_id and entity_id in task_comments_by_id:
                detail_text = _plain_text_excerpt(task_comments_by_id[entity_id].body)
            elif event_type == "doc_comment_mention":
                comment_id = _non_empty_text(meta.get("comment_id"))
                if comment_id and comment_id in doc_comments_by_id:
                    detail_text = _plain_text_excerpt(doc_comments_by_id[comment_id].body_md)
            elif event_type == "incident_action_reminder":
                detail_text = _non_empty_text(meta.get("due_at"))

        if entity_title is None:
            entity_title = _non_empty_text(
                meta.get("title")
                or meta.get("name")
                or meta.get("doc_title")
                or meta.get("sop_title")
                or meta.get("incident_title")
                or meta.get("task_title")
            )
        if detail_text is None:
            detail_text = _non_empty_text(meta.get("message"))

        actor_name = actor_name_by_id.get(_non_empty_text(row.user_id) or "")
        if event_type == "incident_action_reminder":
            actor_name = None

        space_name = space_name_by_id.get(
            _non_empty_text(row.space_id) or _non_empty_text(meta.get("space_id")) or ""
        )

        enriched.append(
            {
                "row": row,
                "meta": meta,
                "actor_name": actor_name,
                "space_name": space_name,
                "entity_title": entity_title,
                "detail_text": detail_text,
                "path": _resolved_feed_path(row, meta),
            }
        )
    return enriched


def _humanize_admin_surface(value: str) -> str:
    token = value.strip()
    if not token:
        return ""
    parts = re.split(r"[_\s-]+", token)
    return " ".join(
        part.upper() if len(part) <= 3 else f"{part[:1].upper()}{part[1:]}"
        for part in parts
        if part
    ).strip()


def _query_events(
    db: Session,
    *,
    space_id: str | None = None,
    entity_type: str | None = None,
    event_types: tuple[str, ...] = (),
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    newest_first: bool = True,
    limit: int | None = None,
) -> list[Event]:
    query = select(Event)
    if space_id:
        query = query.where(Event.space_id == space_id)
    if entity_type:
        query = query.where(Event.entity_type == entity_type)
    if event_types:
        query = query.where(Event.event_type.in_(event_types))
    if start_at is not None:
        query = query.where(Event.ts >= start_at)
    if end_at is not None:
        query = query.where(Event.ts <= end_at)
    query = query.order_by(Event.ts.desc() if newest_first else Event.ts.asc())
    if limit is not None:
        query = query.limit(limit)
    return list(db.execute(query).scalars().all())


def track(db: Session, user_id: str | None, payload: TrackEventIn) -> None:
    event = Event(
        id=str(uuid.uuid4()),
        user_id=user_id,
        session_id=payload.session_id,
        event_type=payload.event_type,
        space_id=payload.space_id,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        path=payload.path,
        meta_json=json.dumps(payload.meta, ensure_ascii=False),
    )
    db.add(event)
    db.commit()


def _top_entity_path(
    *,
    entity_type: str,
    entity_id: str,
    latest_event: Event | None,
    space_id: str | None,
) -> str | None:
    if latest_event is not None and latest_event.path:
        return latest_event.path
    if entity_type == "doc" and space_id:
        return f"/spaces/{space_id}?docId={entity_id}"
    if entity_type == "sop" and space_id:
        return f"/spaces/{space_id}?sopId={entity_id}"
    if entity_type == "incident" and space_id:
        return f"/spaces/{space_id}?incidentId={entity_id}"
    if entity_type == "task" and space_id:
        return f"/tasks?spaceId={space_id}&search={quote(entity_id)}"
    if entity_type == "admin_surface":
        return _ADMIN_SURFACE_DEFAULT_PATHS.get(entity_id)
    return None


def top_entities(
    db: Session,
    space_id: str,
    entity_type: str,
    limit: int = 10,
    *,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    days: int | None = None,
    event_types: tuple[str, ...] | None = None,
) -> list[dict[str, object]]:
    normalized_start, normalized_end = _resolve_window(
        start_at=start_at,
        end_at=end_at,
        days=days,
    )
    effective_event_types = _normalize_event_types(event_types) or tuple(TOP_ENTITY_EVENT_TYPES)
    query = (
        select(Event.entity_id, sa_func.count().label("c"))
        .where(
            Event.space_id == space_id,
            Event.entity_type == entity_type,
            Event.entity_id.is_not(None),
            Event.event_type.in_(effective_event_types),
            Event.ts >= normalized_start,
            Event.ts <= normalized_end,
        )
        .group_by(Event.entity_id)
        .order_by(sa_func.count().desc(), Event.entity_id.asc())
        .limit(max(1, min(limit, 25)))
    )
    results: list[dict[str, object]] = []
    for entity_id, count in db.execute(query).all():
        if entity_id is None:
            continue
        entity_id_str = cast(str, entity_id)
        latest_event = db.execute(
            select(Event)
            .where(
                Event.space_id == space_id,
                Event.entity_type == entity_type,
                Event.entity_id == entity_id_str,
                Event.event_type.in_(effective_event_types),
                Event.ts >= normalized_start,
                Event.ts <= normalized_end,
            )
            .order_by(Event.ts.desc())
            .limit(1)
        ).scalars().first()
        title: str | None = None
        slug: str | None = None
        if entity_type == "doc":
            row = db.get(Doc, entity_id_str)
            if row:
                title = row.title
                slug = row.slug
        elif entity_type == "sop":
            row = db.get(Sop, entity_id_str)
            if row:
                title = row.title
                slug = row.slug
        elif entity_type == "incident":
            row = db.get(Incident, entity_id_str)
            if row:
                title = row.title
        elif entity_type == "task":
            row = db.get(Task, entity_id_str)
            if row:
                title = row.title
        results.append(
            {
                "entity_id": entity_id_str,
                "views": int(count),
                "title": title,
                "slug": slug,
                "path": _top_entity_path(
                    entity_type=entity_type,
                    entity_id=entity_id_str,
                    latest_event=latest_event,
                    space_id=space_id,
                ),
            }
        )
    return results


def list_feed(
    db: Session,
    *,
    user: User,
    space_id: str | None = None,
    limit: int = 25,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    days: int | None = None,
    event_types: tuple[str, ...] = (),
) -> list[Event]:
    cap = max(1, min(limit, 100))
    normalized_start, normalized_end = _resolve_window(
        start_at=start_at,
        end_at=end_at,
        days=days,
    )
    query = select(Event).where(Event.ts >= normalized_start, Event.ts <= normalized_end)
    if event_types:
        query = query.where(Event.event_type.in_(event_types))

    if space_id:
        spaces_service.require_space_role(
            db,
            space_id,
            user.id,
            {"admin", "moderator", "member", "viewer"},
        )
        query = query.where(Event.space_id == space_id)
    elif user_auth_role(user) not in {"admin", "moderator"}:
        spaces = spaces_service.list_spaces_for_user(db, user.id)
        allowed_space_ids = {space.id for space in spaces}
        if allowed_space_ids:
            query = query.where(
                (Event.user_id == user.id) | (Event.space_id.in_(allowed_space_ids))
            )
        else:
            query = query.where(Event.user_id == user.id)

    query = query.order_by(Event.ts.desc()).limit(cap)
    return list(db.execute(query).scalars().all())


def search_quality_summary(
    db: Session,
    *,
    space_id: str,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    days: int | None = None,
    surface: str | None = None,
) -> dict[str, object]:
    normalized_start, normalized_end = _resolve_window(
        start_at=start_at,
        end_at=end_at,
        days=days,
    )
    rows = _query_events(
        db,
        space_id=space_id,
        event_types=tuple(SEARCH_QUALITY_EVENT_TYPES),
        start_at=normalized_start,
        end_at=normalized_end,
        newest_first=False,
    )

    query_count = 0
    queries_with_diagnostics = 0
    suggestion_acceptance_count = 0
    zero_result_sessions: set[str] = set()
    recovered_sessions: set[str] = set()
    refinement_depth_total = 0.0

    for row in rows:
        meta = _parse_meta_json(row.meta_json)
        if not _client_produced(meta):
            continue
        current_surface = str(meta.get("surface", "")).strip().lower()
        if surface and current_surface != surface.strip().lower():
            continue
        search_session_id = str(
            meta.get("search_session_id")
            or f"{row.session_id}:{current_surface}:{row.space_id or ''}"
        )

        if row.event_type == "search_query_issued":
            query_count += 1
            diagnostics_count = meta.get("diagnostics_count")
            if isinstance(diagnostics_count, (int, float)) and int(diagnostics_count) > 0:
                queries_with_diagnostics += 1
            elif meta.get("has_diagnostics") is True:
                queries_with_diagnostics += 1
            refinement_value = meta.get("refinement_depth")
            if isinstance(refinement_value, (int, float)):
                refinement_depth_total += float(refinement_value)
        elif row.event_type == "search_suggestion_accepted":
            suggestion_acceptance_count += 1
        elif row.event_type == "search_no_result":
            zero_result_sessions.add(search_session_id)
        elif (
            row.event_type == "search_results_shown"
            and search_session_id in zero_result_sessions
        ):
            recovered_sessions.add(search_session_id)

    parse_diagnostic_rate = (
        round(queries_with_diagnostics / query_count, 4) if query_count else 0.0
    )
    suggestion_acceptance_rate = (
        round(suggestion_acceptance_count / query_count, 4) if query_count else 0.0
    )
    zero_result_recovery_rate = (
        round(len(recovered_sessions) / len(zero_result_sessions), 4)
        if zero_result_sessions
        else 0.0
    )
    average_refinement_depth = (
        round(refinement_depth_total / query_count, 2) if query_count else 0.0
    )

    return {
        "query_count": query_count,
        "queries_with_diagnostics": queries_with_diagnostics,
        "parse_diagnostic_rate": parse_diagnostic_rate,
        "suggestion_acceptance_count": suggestion_acceptance_count,
        "suggestion_acceptance_rate": suggestion_acceptance_rate,
        "zero_result_session_count": len(zero_result_sessions),
        "recovered_zero_result_session_count": len(recovered_sessions),
        "zero_result_recovery_rate": zero_result_recovery_rate,
        "average_refinement_depth": average_refinement_depth,
    }


def trend_counts(
    db: Session,
    *,
    space_id: str,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    days: int | None = None,
    event_types: tuple[str, ...] = (),
    granularity: str = "day",
) -> list[dict[str, object]]:
    normalized_granularity = granularity.strip().lower()
    if normalized_granularity not in _VALID_TREND_GRANULARITIES:
        raise bad_request("Analytics trend granularity must be day or week")
    normalized_start, normalized_end = _resolve_window(
        start_at=start_at,
        end_at=end_at,
        days=days,
    )
    rows = _query_events(
        db,
        space_id=space_id,
        event_types=event_types,
        start_at=normalized_start,
        end_at=normalized_end,
        newest_first=False,
    )

    grouped: dict[datetime, int] = {}
    for row in rows:
        meta = _parse_meta_json(row.meta_json)
        if event_types and any(event_type in SEARCH_QUALITY_EVENT_TYPES for event_type in event_types):
            if not _client_produced(meta):
                continue
        timestamp = _coerce_utc(row.ts)
        if timestamp is None:
            continue
        if normalized_granularity == "week":
            bucket_day = timestamp - timedelta(days=timestamp.weekday())
        else:
            bucket_day = timestamp
        bucket = datetime(
            bucket_day.year,
            bucket_day.month,
            bucket_day.day,
            tzinfo=timezone.utc,
        )
        grouped[bucket] = grouped.get(bucket, 0) + 1

    trend: list[dict[str, object]] = []
    for bucket in sorted(grouped):
        trend.append(
            {
                "bucket_start": bucket,
                "bucket_label": bucket.strftime("%Y-%m-%d"),
                "count": grouped[bucket],
            }
        )
    return trend


def export_events_payload(
    db: Session,
    *,
    space_id: str,
    format_name: str,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    days: int | None = None,
    event_types: tuple[str, ...] = (),
) -> tuple[str, bytes, str]:
    normalized_format = format_name.strip().lower()
    if normalized_format not in {"json", "csv"}:
        raise bad_request("Analytics export format must be json or csv")
    normalized_start, normalized_end = _resolve_window(
        start_at=start_at,
        end_at=end_at,
        days=days,
    )
    rows = _query_events(
        db,
        space_id=space_id,
        event_types=event_types,
        start_at=normalized_start,
        end_at=normalized_end,
        newest_first=False,
    )
    exported = [
        {
            "id": row.id,
            "ts": _coerce_utc(row.ts).isoformat() if _coerce_utc(row.ts) else None,
            "user_id": row.user_id,
            "session_id": row.session_id,
            "event_type": row.event_type,
            "space_id": row.space_id,
            "entity_type": row.entity_type,
            "entity_id": row.entity_id,
            "path": row.path,
            "meta": _parse_meta_json(row.meta_json),
        }
        for row in rows
    ]
    filename_base = f"analytics-{space_id}-{normalized_start.date()}-{normalized_end.date()}"
    if normalized_format == "json":
        payload = json.dumps(exported, ensure_ascii=False, indent=2).encode("utf-8")
        return f"{filename_base}.json", payload, "application/json"

    buffer = StringIO()
    writer = csv.DictWriter(
        buffer,
        fieldnames=[
            "id",
            "ts",
            "user_id",
            "session_id",
            "event_type",
            "space_id",
            "entity_type",
            "entity_id",
            "path",
            "meta_json",
        ],
    )
    writer.writeheader()
    for row in exported:
        writer.writerow(
            {
                "id": row["id"],
                "ts": row["ts"],
                "user_id": row["user_id"],
                "session_id": row["session_id"],
                "event_type": row["event_type"],
                "space_id": row["space_id"],
                "entity_type": row["entity_type"],
                "entity_id": row["entity_id"],
                "path": row["path"],
                "meta_json": json.dumps(row["meta"], ensure_ascii=False),
            }
        )
    return f"{filename_base}.csv", buffer.getvalue().encode("utf-8"), "text/csv"
