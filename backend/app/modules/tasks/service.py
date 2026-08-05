# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for task creation, filtering, and status transitions."""

import json
import uuid
from collections.abc import Mapping, Sequence
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import case, delete, func, select
from sqlalchemy.orm import Session

from app.core.deps import bad_request, not_found
from app.core.search.ast import parse_search_query_ast
from app.core.search.translation import SearchFieldCapability, compile_search_translation
from app.modules.analytics.models import Event
from app.modules.auth.models import User
from app.modules.incidents.models import Incident, IncidentActionItem
from app.modules.localization import service as localization_service
from app.modules.sop.models import Sop, SopRun, SopStep
from app.modules.spaces import service as spaces_service

from .models import Task, TaskComment, TaskExecutionProfile, TaskReminderDispatch

ALLOWED_STATUSES = {"todo", "in_progress", "blocked", "done"}
ALLOWED_PRIORITIES = {"low", "medium", "high", "critical"}
ALLOWED_SOURCE_KINDS = {
    "sop",
    "sop_run",
    "sop_step",
    "incident",
    "incident_action_item",
    "manual",
}

MIN_CADENCE_DAYS = 1
MAX_CADENCE_DAYS = 90
VALID_REMINDER_CHANNELS = {"in_app", "email", "webhook"}
REMINDER_RETRY_INTERVAL = timedelta(hours=6)
MAX_TASK_CHECKLIST_ITEMS = 40
MAX_TASK_CHECKLIST_LABEL_LENGTH = 240


def _task_search_capabilities() -> tuple[SearchFieldCapability, ...]:
    return (
        SearchFieldCapability(
            name="status",
            aliases=("state",),
            value_type="enum",
            predicate_builder=lambda value: func.lower(Task.status) == value,
            score_builder=lambda value: case((func.lower(Task.status) == value, 2.4), else_=0.0),
        ),
        SearchFieldCapability(
            name="priority",
            aliases=("prio",),
            value_type="enum",
            predicate_builder=lambda value: func.lower(Task.priority) == value,
            score_builder=lambda value: case((func.lower(Task.priority) == value, 2.0), else_=0.0),
        ),
        SearchFieldCapability(
            name="source",
            aliases=("source_kind", "linked_to"),
            value_type="text",
            predicate_builder=lambda value: func.lower(
                func.coalesce(Task.source_kind, "")
            ).contains(value, autoescape=True),
            score_builder=lambda value: case(
                (func.lower(func.coalesce(Task.source_kind, "")) == value, 2.2),
                else_=0.0,
            ),
        ),
        SearchFieldCapability(
            name="space",
            aliases=("space_id", "spaceid"),
            value_type="text",
            predicate_builder=lambda value: func.lower(Task.space_id).contains(
                value,
                autoescape=True,
            ),
            score_builder=lambda value: case((func.lower(Task.space_id) == value, 1.6), else_=0.0),
        ),
        SearchFieldCapability(
            name="assignee",
            aliases=("assignee_id", "user"),
            value_type="text",
            predicate_builder=lambda value: func.lower(
                func.coalesce(Task.assignee_user_id, "")
            ).contains(value, autoescape=True),
            score_builder=lambda value: case(
                (func.lower(func.coalesce(Task.assignee_user_id, "")) == value, 1.6),
                else_=0.0,
            ),
        ),
    )


def _normalize_status(status: str) -> str:
    normalized = status.strip().lower()
    if normalized not in ALLOWED_STATUSES:
        raise bad_request("Invalid task status")
    return normalized


def _normalize_priority(priority: str) -> str:
    normalized = priority.strip().lower()
    if normalized not in ALLOWED_PRIORITIES:
        raise bad_request("Invalid task priority")
    return normalized


def _normalize_desc(description: str | None) -> str | None:
    if description is None:
        return None
    trimmed = description.strip()
    return trimmed or None


def _deserialize_checklist(raw: str | None) -> list[dict[str, Any]]:
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []

    out: list[dict[str, Any]] = []
    for item in decoded:
        if not isinstance(item, Mapping):
            continue
        label = str(item.get("label") or "").strip()
        if not label:
            continue
        item_id = str(item.get("id") or "").strip() or str(uuid.uuid4())
        out.append(
            {
                "id": item_id[:64],
                "label": label[:MAX_TASK_CHECKLIST_LABEL_LENGTH],
                "completed": bool(item.get("completed")),
            }
        )
    return out[:MAX_TASK_CHECKLIST_ITEMS]


def task_checklist_items(task: Task) -> list[dict[str, Any]]:
    return _deserialize_checklist(task.checklist_json)


def _normalize_checklist(
    checklist: Sequence[Mapping[str, Any]] | None,
) -> list[dict[str, Any]]:
    if checklist is None:
        return []
    if len(checklist) > MAX_TASK_CHECKLIST_ITEMS:
        raise bad_request(
            f"Task checklist cannot contain more than {MAX_TASK_CHECKLIST_ITEMS} items"
        )

    out: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for raw_item in checklist:
        label = str(raw_item.get("label") or "").strip()
        if not label:
            raise bad_request("Checklist item label is required")
        item_id = str(raw_item.get("id") or "").strip() or str(uuid.uuid4())
        if item_id in seen_ids:
            item_id = str(uuid.uuid4())
        seen_ids.add(item_id)
        out.append(
            {
                "id": item_id[:64],
                "label": label[:MAX_TASK_CHECKLIST_LABEL_LENGTH],
                "completed": bool(raw_item.get("completed")),
            }
        )
    return out


def _serialize_checklist(checklist: Sequence[Mapping[str, Any]] | None) -> str:
    return json.dumps(
        _normalize_checklist(checklist),
        separators=(",", ":"),
    )


def _ensure_assignee(db: Session, assignee_user_id: str | None) -> None:
    if assignee_user_id is None:
        return
    if not db.get(User, assignee_user_id):
        raise not_found("Assignee user not found")


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _coerce_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _normalize_source_fields(
    source_kind: str | None,
    source_id: str | None,
    source_step_id: str | None,
) -> tuple[str | None, str | None, str | None]:
    normalized_kind = (source_kind or "").strip().lower() or None
    normalized_id = (source_id or "").strip() or None
    normalized_step_id = (source_step_id or "").strip() or None

    if normalized_kind is None:
        if normalized_id is not None or normalized_step_id is not None:
            raise bad_request("Task source_kind is required when source identifiers are provided")
        return None, None, None

    if normalized_kind not in ALLOWED_SOURCE_KINDS:
        raise bad_request("Invalid task source kind")

    if normalized_kind == "manual":
        if normalized_id is not None or normalized_step_id is not None:
            raise bad_request("Manual tasks cannot declare source identifiers")
        return normalized_kind, None, None

    if normalized_id is None:
        raise bad_request("Task source_id is required when source_kind is provided")

    if normalized_kind == "sop_step" and normalized_step_id is None:
        raise bad_request("Task source_step_id is required when source_kind is sop_step")

    if normalized_kind == "incident_action_item" and normalized_step_id is None:
        raise bad_request("Task source_step_id is required when source_kind is incident_action_item")

    if normalized_step_id is not None and normalized_kind not in {
        "sop",
        "sop_run",
        "sop_step",
        "incident",
        "incident_action_item",
    }:
        raise bad_request(
            "Task source_step_id is only supported for SOP and incident-linked tasks"
        )

    return normalized_kind, normalized_id, normalized_step_id


def _validate_task_source(
    db: Session,
    *,
    space_id: str,
    source_kind: str | None,
    source_id: str | None,
    source_step_id: str | None,
) -> None:
    if source_kind is None:
        return
    if source_kind not in {"sop", "sop_step", "incident", "incident_action_item"}:
        return
    if source_id is None:
        raise bad_request("Task source_id is required")

    if source_kind in {"sop", "sop_run", "sop_step"}:
        sop = db.get(Sop, source_id)
        if not sop or sop.space_id != space_id:
            raise not_found("Linked SOP not found in this space")

        if source_kind == "sop_run":
            if source_step_id is None:
                return
            run = db.get(SopRun, source_step_id)
            if not run or run.sop_id != sop.id:
                raise not_found("Linked SOP run not found")
            return

        if source_step_id is None:
            return
        step = db.get(SopStep, source_step_id)
        if not step or step.sop_id != sop.id:
            raise not_found("Linked SOP step not found")
        return

    incident = db.get(Incident, source_id)
    if not incident or incident.space_id != space_id:
        raise not_found("Linked incident not found in this space")

    if source_step_id is None:
        return

    action_item = db.get(IncidentActionItem, source_step_id)
    if not action_item or action_item.incident_id != incident.id:
        raise not_found("Linked incident action item not found")


def create_task(
    db: Session,
    *,
    space_id: str,
    title: str,
    description: str | None,
    status: str,
    priority: str,
    assignee_user_id: str | None,
    created_by: str,
    source_kind: str | None,
    source_id: str | None,
    source_step_id: str | None,
    checklist: Sequence[Mapping[str, Any]] | None = None,
    due_at: datetime | None = None,
) -> Task:
    _ensure_assignee(db, assignee_user_id)
    normalized_source_kind, normalized_source_id, normalized_source_step_id = _normalize_source_fields(
        source_kind,
        source_id,
        source_step_id,
    )
    _validate_task_source(
        db,
        space_id=space_id,
        source_kind=normalized_source_kind,
        source_id=normalized_source_id,
        source_step_id=normalized_source_step_id,
    )
    task = Task(
        id=str(uuid.uuid4()),
        space_id=space_id,
        title=title.strip(),
        description=_normalize_desc(description),
        status=_normalize_status(status),
        priority=_normalize_priority(priority),
        assignee_user_id=assignee_user_id,
        created_by=created_by,
        source_kind=normalized_source_kind,
        source_id=normalized_source_id,
        source_step_id=normalized_source_step_id,
        checklist_json=_serialize_checklist(checklist),
        due_at=due_at,
    )
    if not task.title:
        raise bad_request("Task title is required")
    db.add(task)
    db.add(
        Event(
            id=str(uuid.uuid4()),
            user_id=created_by,
            session_id=f"task-create-{task.id}",
            event_type="task_created",
            space_id=space_id,
            entity_type="task",
            entity_id=task.id,
            path=f"/tasks?spaceId={space_id}",
            meta_json=json.dumps(
                {
                    "status": task.status,
                    "priority": task.priority,
                    "assignee_user_id": task.assignee_user_id,
                    "source_kind": task.source_kind,
                    "source_id": task.source_id,
                    "source_step_id": task.source_step_id,
                }
            ),
        )
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="task",
        content_id=task.id,
        fields={
            "title": task.title,
            "description": task.description,
        },
        actor_user_id=created_by,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(task)
    return task


def list_space_tasks(
    db: Session,
    space_id: str,
    *,
    search_query: str | None = None,
) -> list[Task]:
    q = select(Task).where(Task.space_id == space_id)
    if search_query and search_query.strip():
        parsed = parse_search_query_ast(search_query.strip())
        translation = compile_search_translation(
            parsed,
            capabilities=_task_search_capabilities(),
            text_columns=(
                Task.id,
                Task.title,
                Task.description,
                Task.status,
                Task.priority,
                Task.space_id,
                Task.assignee_user_id,
            ),
            updated_at_column=Task.updated_at,
        )
        q = q.where(translation.where_clause).order_by(
            translation.ranking_clause.desc(),
            Task.updated_at.desc(),
            Task.created_at.desc(),
        )
    else:
        q = q.order_by(Task.updated_at.desc(), Task.created_at.desc())
    return list(db.execute(q).scalars().all())


def list_my_tasks(
    db: Session,
    user_id: str,
    *,
    search_query: str | None = None,
) -> list[Task]:
    q = select(Task).where(Task.assignee_user_id == user_id)
    if search_query and search_query.strip():
        parsed = parse_search_query_ast(search_query.strip())
        translation = compile_search_translation(
            parsed,
            capabilities=_task_search_capabilities(),
            text_columns=(
                Task.id,
                Task.title,
                Task.description,
                Task.status,
                Task.priority,
                Task.space_id,
                Task.assignee_user_id,
            ),
            updated_at_column=Task.updated_at,
        )
        q = q.where(translation.where_clause).order_by(
            translation.ranking_clause.desc(),
            Task.updated_at.desc(),
            Task.created_at.desc(),
        )
    else:
        q = q.order_by(Task.updated_at.desc(), Task.created_at.desc())
    return list(db.execute(q).scalars().all())


def get_task(db: Session, task_id: str) -> Task | None:
    return db.get(Task, task_id)


def get_task_by_source(
    db: Session,
    *,
    source_kind: str,
    source_id: str,
    source_step_id: str | None,
) -> Task | None:
    q = select(Task).where(
        Task.source_kind == source_kind,
        Task.source_id == source_id,
    )
    if source_step_id is None:
        q = q.where(Task.source_step_id.is_(None))
    else:
        q = q.where(Task.source_step_id == source_step_id)
    return db.execute(
        q.order_by(Task.updated_at.desc(), Task.created_at.desc())
    ).scalars().first()


def list_tasks_for_incident_source(
    db: Session,
    *,
    incident_id: str,
    source_step_id: str | None = None,
) -> list[Task]:
    q = select(Task).where(
        Task.source_id == incident_id,
        Task.source_kind.in_(("incident", "incident_action_item")),
    )
    if source_step_id is not None:
        q = q.where(Task.source_step_id == source_step_id)
    return list(
        db.execute(
            q.order_by(Task.updated_at.desc(), Task.created_at.desc())
        ).scalars().all()
    )


def list_task_comments(db: Session, task_id: str) -> list[tuple[TaskComment, User | None]]:
    q = select(TaskComment, User).outerjoin(User, User.id == TaskComment.author_user_id).where(TaskComment.task_id == task_id).order_by(TaskComment.created_at.asc(), TaskComment.id.asc())
    return [(comment, author) for comment, author in db.execute(q).all()]


def create_task_comment(
    db: Session,
    *,
    task: Task,
    author_user_id: str,
    body: str,
) -> TaskComment:
    normalized_body = body.strip()
    if not normalized_body:
        raise bad_request("Comment body is required")
    comment = TaskComment(
        id=str(uuid.uuid4()),
        task_id=task.id,
        space_id=task.space_id,
        author_user_id=author_user_id,
        body=normalized_body,
    )
    db.add(comment)
    db.add(
        Event(
            id=str(uuid.uuid4()),
            user_id=author_user_id,
            session_id=f"task-comment-{comment.id}",
            event_type="task_updated",
            space_id=task.space_id,
            entity_type="task_comment",
            entity_id=comment.id,
            path=f"/tasks?spaceId={task.space_id}",
            meta_json=json.dumps(
                {
                    "task_id": task.id,
                    "comment": True,
                }
            ),
        )
    )
    db.commit()
    db.refresh(comment)
    return comment


def get_task_comment(db: Session, comment_id: str) -> TaskComment | None:
    return db.get(TaskComment, comment_id)


def delete_task_comment(db: Session, comment: TaskComment) -> None:
    db.delete(comment)
    db.commit()


def update_task(
    db: Session,
    task_id: str,
    *,
    actor_user_id: str | None = None,
    title: str | None = None,
    description: str | None = None,
    status: str | None = None,
    priority: str | None = None,
    assignee_user_id: str | None = None,
    apply_assignee_user_id: bool = False,
    source_kind: str | None = None,
    source_id: str | None = None,
    source_step_id: str | None = None,
    apply_source_link: bool = False,
    checklist: Sequence[Mapping[str, Any]] | None = None,
    apply_checklist: bool = False,
    due_at: datetime | None = None,
    apply_due_at: bool = False,
) -> Task:
    task = db.get(Task, task_id)
    if not task:
        raise not_found("Task not found")

    prev_status = task.status
    prev_priority = task.priority
    prev_assignee = task.assignee_user_id
    prev_source_kind = task.source_kind
    prev_source_id = task.source_id
    prev_source_step_id = task.source_step_id
    if title is not None:
        next_title = title.strip()
        if not next_title:
            raise bad_request("Task title is required")
        task.title = next_title
    if description is not None:
        task.description = _normalize_desc(description)
    if status is not None:
        task.status = _normalize_status(status)
    if priority is not None:
        task.priority = _normalize_priority(priority)
    if apply_assignee_user_id:
        # Empty string is treated as null to simplify form submissions.
        next_assignee = assignee_user_id.strip() if assignee_user_id else ""
        task.assignee_user_id = next_assignee or None
        _ensure_assignee(db, task.assignee_user_id)
    if apply_source_link:
        normalized_source_kind, normalized_source_id, normalized_source_step_id = _normalize_source_fields(
            source_kind,
            source_id,
            source_step_id,
        )
        _validate_task_source(
            db,
            space_id=task.space_id,
            source_kind=normalized_source_kind,
            source_id=normalized_source_id,
            source_step_id=normalized_source_step_id,
        )
        task.source_kind = normalized_source_kind
        task.source_id = normalized_source_id
        task.source_step_id = normalized_source_step_id
    if apply_checklist:
        task.checklist_json = _serialize_checklist(checklist)
    if apply_due_at:
        task.due_at = due_at

    db.add(
        Event(
            id=str(uuid.uuid4()),
            user_id=actor_user_id,
            session_id=f"task-update-{task.id}",
            event_type="task_updated",
            space_id=task.space_id,
            entity_type="task",
            entity_id=task.id,
            path=f"/tasks?spaceId={task.space_id}",
            meta_json=json.dumps(
                {
                    "status": task.status,
                    "priority": task.priority,
                    "assignee_user_id": task.assignee_user_id,
                    "prev_status": prev_status,
                    "prev_priority": prev_priority,
                    "prev_assignee_user_id": prev_assignee,
                    "source_kind": task.source_kind,
                    "source_id": task.source_id,
                    "source_step_id": task.source_step_id,
                    "prev_source_kind": prev_source_kind,
                    "prev_source_id": prev_source_id,
                    "prev_source_step_id": prev_source_step_id,
                }
            ),
        )
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="task",
        content_id=task.id,
        fields={
            "title": task.title,
            "description": task.description,
        },
        actor_user_id=actor_user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(task)
    return task


def list_tasks_for_sop_source(
    db: Session,
    *,
    sop_id: str,
    source_step_id: str | None = None,
) -> list[Task]:
    q = select(Task).where(
        Task.source_id == sop_id,
        Task.source_kind.in_(("sop", "sop_run", "sop_step")),
    )
    if source_step_id is not None:
        q = q.where(Task.source_step_id == source_step_id)
    return list(
        db.execute(
            q.order_by(Task.updated_at.desc(), Task.created_at.desc())
        ).scalars().all()
    )


def _normalize_profile_title(value: str | None) -> str:
    normalized = (value or "").strip()
    if not normalized:
        return "Scheduled SOP execution"
    return normalized[:240]


def _normalize_cadence_days(value: int | None) -> int:
    if value is None:
        return 7
    return max(MIN_CADENCE_DAYS, min(MAX_CADENCE_DAYS, int(value)))


def _normalize_reminder_channels(raw: Sequence[str] | None) -> list[str]:
    if raw is None:
        return ["in_app"]
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        clean = str(item).strip().lower()
        if clean not in VALID_REMINDER_CHANNELS or clean in seen:
            continue
        seen.add(clean)
        out.append(clean)
    return out or ["in_app"]


def _channels_csv(values: Sequence[str]) -> str:
    return ",".join(_normalize_reminder_channels(values))


def _channels_from_csv(raw: str | None) -> list[str]:
    if not raw:
        return ["in_app"]
    return _normalize_reminder_channels(raw.split(","))


def _user_names(db: Session, user_ids: set[str]) -> dict[str, str]:
    ids = {user_id for user_id in user_ids if user_id}
    if not ids:
        return {}
    users = db.execute(select(User).where(User.id.in_(ids))).scalars().all()
    return {user.id: user.name for user in users}


def _profile_schedule_view(
    profile: TaskExecutionProfile,
    *,
    user_names: Mapping[str, str],
    recent_dispatches: Sequence[TaskReminderDispatch],
) -> dict[str, Any]:
    next_due_at = _coerce_utc(profile.next_due_at)
    now = _now_utc()
    return {
        "id": profile.id,
        "sop_id": profile.source_id,
        "cadence_days": profile.cadence_days,
        "next_due_at": next_due_at,
        "operator_user_id": profile.operator_user_id,
        "operator_name": user_names.get(profile.operator_user_id or ""),
        "enabled": profile.enabled,
        "last_started_at": profile.last_started_at,
        "reminder_channels": _channels_from_csv(profile.reminder_channels_csv),
        "last_reminder_sent_at": profile.last_reminder_sent_at,
        "overdue": bool(profile.enabled and next_due_at and next_due_at <= now),
        "recent_dispatches": [
            {
                "id": dispatch.id,
                "channel": dispatch.channel,
                "recipient_user_id": dispatch.recipient_user_id,
                "recipient_name": user_names.get(dispatch.recipient_user_id or ""),
                "created_at": dispatch.created_at,
                "delivered_at": dispatch.delivered_at,
                "payload_json": dispatch.payload_json,
            }
            for dispatch in recent_dispatches
        ],
    }


def list_sop_execution_schedule_views(db: Session, *, sop_id: str) -> list[dict[str, Any]]:
    profiles = list(
        db.execute(
            select(TaskExecutionProfile)
            .where(
                TaskExecutionProfile.source_kind == "sop",
                TaskExecutionProfile.source_id == sop_id,
                TaskExecutionProfile.source_step_id.is_(None),
            )
            .order_by(
                TaskExecutionProfile.next_due_at.asc().nulls_last(),
                TaskExecutionProfile.id.asc(),
            )
        )
        .scalars()
        .all()
    )
    if not profiles:
        return []

    profile_ids = [profile.id for profile in profiles]
    dispatch_rows = list(
        db.execute(
            select(TaskReminderDispatch)
            .where(TaskReminderDispatch.profile_id.in_(profile_ids))
            .order_by(TaskReminderDispatch.created_at.desc())
            .limit(200)
        )
        .scalars()
        .all()
    )
    dispatches_by_profile: dict[str, list[TaskReminderDispatch]] = {}
    for dispatch in dispatch_rows:
        if dispatch.profile_id is None:
            continue
        bucket = dispatches_by_profile.setdefault(dispatch.profile_id, [])
        if len(bucket) < 5:
            bucket.append(dispatch)

    user_ids = {profile.operator_user_id for profile in profiles if profile.operator_user_id}
    user_ids.update(
        dispatch.recipient_user_id
        for dispatch in dispatch_rows
        if dispatch.recipient_user_id
    )
    user_names = _user_names(db, set(user_ids))

    return [
        _profile_schedule_view(
            profile,
            user_names=user_names,
            recent_dispatches=dispatches_by_profile.get(profile.id, []),
        )
        for profile in profiles
    ]


def list_due_sop_execution_schedule_views(db: Session, *, space_id: str) -> list[dict[str, Any]]:
    now = _now_utc()
    profiles = list(
        db.execute(
            select(TaskExecutionProfile)
            .where(
                TaskExecutionProfile.space_id == space_id,
                TaskExecutionProfile.source_kind == "sop",
                TaskExecutionProfile.source_step_id.is_(None),
                TaskExecutionProfile.enabled.is_(True),
                TaskExecutionProfile.next_due_at.is_not(None),
                TaskExecutionProfile.next_due_at <= now,
            )
            .order_by(TaskExecutionProfile.next_due_at.asc())
        )
        .scalars()
        .all()
    )
    if not profiles:
        return []

    user_names = _user_names(
        db,
        {profile.operator_user_id for profile in profiles if profile.operator_user_id},
    )
    return [
        _profile_schedule_view(
            profile,
            user_names=user_names,
            recent_dispatches=(),
        )
        for profile in profiles
    ]


def replace_sop_execution_profiles(
    db: Session,
    *,
    sop_id: str,
    space_id: str,
    sop_title: str,
    actor_user_id: str,
    schedules: Sequence[Mapping[str, Any]],
) -> None:
    profile_ids = list(
        db.execute(
            select(TaskExecutionProfile.id).where(
                TaskExecutionProfile.source_kind == "sop",
                TaskExecutionProfile.source_id == sop_id,
                TaskExecutionProfile.source_step_id.is_(None),
            )
        )
        .scalars()
        .all()
    )
    if profile_ids:
        db.execute(
            delete(TaskReminderDispatch).where(
                TaskReminderDispatch.profile_id.in_(profile_ids)
            )
        )
    db.execute(
        delete(TaskExecutionProfile).where(
            TaskExecutionProfile.source_kind == "sop",
            TaskExecutionProfile.source_id == sop_id,
            TaskExecutionProfile.source_step_id.is_(None),
        )
    )

    profile_title = _normalize_profile_title(f"Run SOP: {sop_title}")
    for row in schedules:
        enabled = bool(row.get("enabled", True))
        try:
            cadence_days = _normalize_cadence_days(int(row.get("cadence_days", 7) or 7))
        except (TypeError, ValueError) as exc:
            raise bad_request("Invalid schedule cadence") from exc

        raw_next_due = row.get("next_due_at")
        next_due_at = _coerce_utc(raw_next_due) if isinstance(raw_next_due, datetime) else None

        operator_user_id = (str(row.get("operator_user_id") or "").strip() or None)
        if operator_user_id is not None and spaces_service.get_space_role(db, space_id, operator_user_id) is None:
            raise bad_request("Operator must be a member of this space")

        raw_channels = row.get("reminder_channels")
        reminder_channels = _normalize_reminder_channels(
            raw_channels if isinstance(raw_channels, list) else None
        )
        if next_due_at is None and enabled:
            next_due_at = _now_utc() + timedelta(days=cadence_days)

        db.add(
            TaskExecutionProfile(
                id=str(uuid.uuid4()),
                space_id=space_id,
                source_kind="sop",
                source_id=sop_id,
                source_step_id=None,
                title=profile_title,
                cadence_days=cadence_days,
                next_due_at=next_due_at,
                operator_user_id=operator_user_id,
                enabled=enabled,
                last_started_at=None,
                reminder_channels_csv=_channels_csv(reminder_channels),
                last_reminder_sent_at=None,
                created_by=actor_user_id,
            )
        )
    db.commit()


def mark_sop_execution_started(
    db: Session,
    *,
    sop_id: str,
    started_at: datetime | None = None,
) -> None:
    now = _coerce_utc(started_at) or _now_utc()
    profiles = list(
        db.execute(
            select(TaskExecutionProfile).where(
                TaskExecutionProfile.source_kind == "sop",
                TaskExecutionProfile.source_id == sop_id,
                TaskExecutionProfile.source_step_id.is_(None),
            )
        )
        .scalars()
        .all()
    )
    if not profiles:
        return
    for profile in profiles:
        if not profile.enabled:
            continue
        profile.last_started_at = now
        profile.next_due_at = now + timedelta(days=_normalize_cadence_days(profile.cadence_days))
    db.commit()


def clear_sop_execution_profiles(db: Session, *, sop_id: str) -> None:
    profile_ids = list(
        db.execute(
            select(TaskExecutionProfile.id).where(
                TaskExecutionProfile.source_kind == "sop",
                TaskExecutionProfile.source_id == sop_id,
                TaskExecutionProfile.source_step_id.is_(None),
            )
        )
        .scalars()
        .all()
    )
    if profile_ids:
        db.execute(
            delete(TaskReminderDispatch).where(
                TaskReminderDispatch.profile_id.in_(profile_ids)
            )
        )
    db.execute(
        delete(TaskExecutionProfile).where(
            TaskExecutionProfile.source_kind == "sop",
            TaskExecutionProfile.source_id == sop_id,
            TaskExecutionProfile.source_step_id.is_(None),
        )
    )


def process_due_sop_execution_reminders(db: Session) -> int:
    now = _now_utc()
    profiles = list(
        db.execute(
            select(TaskExecutionProfile)
            .where(
                TaskExecutionProfile.source_kind == "sop",
                TaskExecutionProfile.source_step_id.is_(None),
                TaskExecutionProfile.enabled.is_(True),
                TaskExecutionProfile.next_due_at.is_not(None),
                TaskExecutionProfile.next_due_at <= now,
            )
            .order_by(TaskExecutionProfile.next_due_at.asc())
        )
        .scalars()
        .all()
    )

    created = 0
    for profile in profiles:
        last_sent = _coerce_utc(profile.last_reminder_sent_at)
        if last_sent is not None and now - last_sent < REMINDER_RETRY_INTERVAL:
            continue
        payload = json.dumps(
            {
                "profile_id": profile.id,
                "source_kind": profile.source_kind,
                "source_id": profile.source_id,
                "source_step_id": profile.source_step_id,
                "title": profile.title,
                "next_due_at": profile.next_due_at.isoformat() if profile.next_due_at else None,
                "operator_user_id": profile.operator_user_id,
            },
            separators=(",", ":"),
        )
        for channel in _channels_from_csv(profile.reminder_channels_csv):
            db.add(
                TaskReminderDispatch(
                    id=str(uuid.uuid4()),
                    profile_id=profile.id,
                    space_id=profile.space_id,
                    source_kind=profile.source_kind,
                    source_id=profile.source_id,
                    source_step_id=profile.source_step_id,
                    recipient_user_id=profile.operator_user_id,
                    channel=channel,
                    payload_json=payload,
                    delivered_at=now,
                )
            )
            created += 1
        profile.last_reminder_sent_at = now
    if created:
        db.commit()
    return created
