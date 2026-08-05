# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for task planning, assignment, and execution APIs."""

from collections.abc import Mapping

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.core.deps import get_db
from app.core.deps import not_found
from app.modules.analytics import service as analytics_service
from app.modules.analytics.schemas import TrackEventIn
from app.modules.auth.models import User
from app.modules.auth.deps import get_current_user, resolve_user_auth_role, user_auth_role
from app.modules.localization import service as localization_service
from app.modules.sop import service as sop_service
from app.modules.spaces import service as spaces_service

from . import service
from .models import Task, TaskComment
from .schemas import TaskCommentCreateIn, TaskCommentOut, TaskCreateIn, TaskOut, TaskUpdateIn

router = APIRouter(prefix="/tasks", tags=["tasks"])


def _ensure_assignee_in_space(db: Session, space_id: str, assignee_user_id: str | None) -> None:
    if not assignee_user_id:
        return
    assignee = db.get(User, assignee_user_id)
    if assignee and resolve_user_auth_role(db, assignee) in {"admin", "moderator"}:
        return
    if spaces_service.get_space_role(db, space_id, assignee_user_id) is None:
        raise not_found("Assignee must be a member of the selected space")


def _can_edit_task(db: Session, task: Task, user: User) -> bool:
    if task.assignee_user_id == user.id:
        return True
    if user_auth_role(user) in {"admin", "moderator"}:
        return True
    try:
        spaces_service.require_space_role(db, task.space_id, user.id, {"admin", "moderator", "member"})
    except HTTPException:
        return False
    return True


def _as_out(task: Task, *, localized_fields: Mapping[str, str] | None = None) -> TaskOut:
    fields = localized_fields or {}
    return TaskOut(
        id=task.id,
        space_id=task.space_id,
        title=fields.get("title", task.title),
        description=fields.get("description", task.description),
        status=task.status,
        priority=task.priority,
        assignee_user_id=task.assignee_user_id,
        created_by=task.created_by,
        source_kind=task.source_kind,
        source_id=task.source_id,
        source_step_id=task.source_step_id,
        checklist=service.task_checklist_items(task),
        due_at=task.due_at,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


def _comment_out(
    comment: TaskComment,
    *,
    author_name: str | None,
    localized_fields: Mapping[str, str] | None = None,
) -> TaskCommentOut:
    fields = localized_fields or {}
    return TaskCommentOut(
        id=comment.id,
        task_id=comment.task_id,
        space_id=comment.space_id,
        author_user_id=comment.author_user_id,
        author_name=author_name,
        body=fields.get("body", comment.body),
        created_at=comment.created_at,
        updated_at=comment.updated_at,
    )


def _can_delete_comment(db: Session, task: Task, comment: TaskComment, user: User) -> bool:
    if comment.author_user_id == user.id or task.assignee_user_id == user.id:
        return True
    if user_auth_role(user) in {"admin", "moderator"}:
        return True
    try:
        spaces_service.require_space_role(db, task.space_id, user.id, {"admin", "moderator"})
    except HTTPException:
        return False
    return True


def _track_task_search(
    db: Session,
    *,
    user_id: str,
    query: str,
    result_count: int,
    surface: str,
    space_id: str | None,
) -> None:
    normalized = query.strip()
    if not normalized:
        return
    path = "/tasks" if space_id is None else f"/tasks?spaceId={space_id}"
    analytics_service.track(
        db,
        user_id,
        TrackEventIn(
            session_id="tasks-search",
            event_type="search_query_issued",
            space_id=space_id,
            entity_type="task",
            path=path,
            meta={"surface": surface, "query": normalized},
        ),
    )
    analytics_service.track(
        db,
        user_id,
        TrackEventIn(
            session_id="tasks-search",
            event_type="search_results_shown" if result_count > 0 else "search_no_result",
            space_id=space_id,
            entity_type="task",
            path=path,
            meta={"surface": surface, "query": normalized, "results": result_count},
        ),
    )


@router.get("/my", response_model=list[TaskOut])
def my_tasks(
    q: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    rows = service.list_my_tasks(db, user.id, search_query=q)
    localized_by_task_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="task",
        content_ids=[row.id for row in rows],
        field_keys=["title", "description"],
        user_id=user.id,
    )
    visible: list[TaskOut] = []
    for t in rows:
        if t.assignee_user_id == user.id:
            visible.append(_as_out(t, localized_fields=localized_by_task_id.get(t.id, {})))
            continue
        try:
            spaces_service.require_space_role(db, t.space_id, user.id, {"admin", "moderator", "member", "viewer"})
        except HTTPException:
            continue
        visible.append(_as_out(t, localized_fields=localized_by_task_id.get(t.id, {})))
    _track_task_search(
        db,
        user_id=user.id,
        query=q or "",
        result_count=len(visible),
        surface="tasks_my",
        space_id=None,
    )
    return visible


@router.get("/spaces/{space_id}", response_model=list[TaskOut])
def list_tasks(
    space_id: str,
    q: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_space_tasks(db, space_id, search_query=q)
    localized_by_task_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="task",
        content_ids=[row.id for row in rows],
        field_keys=["title", "description"],
        user_id=user.id,
    )
    out = [_as_out(task, localized_fields=localized_by_task_id.get(task.id, {})) for task in rows]
    _track_task_search(
        db,
        user_id=user.id,
        query=q or "",
        result_count=len(out),
        surface="tasks_space",
        space_id=space_id,
    )
    return out


@router.post("", response_model=TaskOut)
def create_task(payload: TaskCreateIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    spaces_service.require_space_role(db, payload.space_id, user.id, {"admin", "moderator", "member"})
    _ensure_assignee_in_space(db, payload.space_id, payload.assignee_user_id)
    t = service.create_task(
        db,
        space_id=payload.space_id,
        title=payload.title,
        description=payload.description,
        status=payload.status,
        priority=payload.priority,
        assignee_user_id=payload.assignee_user_id,
        created_by=user.id,
        source_kind=payload.source_kind,
        source_id=payload.source_id,
        source_step_id=payload.source_step_id,
        checklist=[item.model_dump() for item in payload.checklist],
        due_at=payload.due_at,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="task",
        content_id=t.id,
        field_keys=["title", "description"],
        user_id=user.id,
    )
    return _as_out(t, localized_fields=localized)


@router.put("/{task_id}", response_model=TaskOut)
def update_task(task_id: str, payload: TaskUpdateIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    t0 = service.get_task(db, task_id)
    if not t0:
        raise not_found("Task not found")
    if not _can_edit_task(db, t0, user):
        raise HTTPException(status_code=403, detail="Insufficient role to edit this task")
    if "assignee_user_id" in payload.model_fields_set:
        _ensure_assignee_in_space(db, t0.space_id, payload.assignee_user_id)
    t = service.update_task(
        db,
        task_id,
        actor_user_id=user.id,
        title=payload.title,
        description=payload.description,
        status=payload.status,
        priority=payload.priority,
        assignee_user_id=payload.assignee_user_id,
        apply_assignee_user_id="assignee_user_id" in payload.model_fields_set,
        source_kind=payload.source_kind,
        source_id=payload.source_id,
        source_step_id=payload.source_step_id,
        apply_source_link=bool(
            {"source_kind", "source_id", "source_step_id"}.intersection(payload.model_fields_set)
        ),
        checklist=None
        if payload.checklist is None
        else [item.model_dump() for item in payload.checklist],
        apply_checklist="checklist" in payload.model_fields_set,
        due_at=payload.due_at,
        apply_due_at="due_at" in payload.model_fields_set,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="task",
        content_id=t.id,
        field_keys=["title", "description"],
        user_id=user.id,
    )
    return _as_out(t, localized_fields=localized)


@router.get("/sop/{sop_id}", response_model=list[TaskOut])
def list_sop_linked_tasks(
    sop_id: str,
    source_step_id: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    sop = sop_service.get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_tasks_for_sop_source(db, sop_id=sop_id, source_step_id=source_step_id)
    localized_by_task_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="task",
        content_ids=[row.id for row in rows],
        field_keys=["title", "description"],
        user_id=user.id,
    )
    return [_as_out(task, localized_fields=localized_by_task_id.get(task.id, {})) for task in rows]


@router.get("/{task_id}/comments", response_model=list[TaskCommentOut])
def list_comments(task_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    task = service.get_task(db, task_id)
    if not task:
        raise not_found("Task not found")
    spaces_service.require_space_role(db, task.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_task_comments(db, task_id)
    localized_by_comment_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="task_comment",
        content_ids=[comment.id for comment, _ in rows],
        field_keys=["body"],
        user_id=user.id,
    )
    return [
        _comment_out(
            comment,
            author_name=author.name if author else None,
            localized_fields=localized_by_comment_id.get(comment.id, {}),
        )
        for comment, author in rows
    ]


@router.post("/{task_id}/comments", response_model=TaskCommentOut)
def create_comment(
    task_id: str,
    payload: TaskCommentCreateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    task = service.get_task(db, task_id)
    if not task:
        raise not_found("Task not found")
    spaces_service.require_space_role(db, task.space_id, user.id, {"admin", "moderator", "member"})
    comment = service.create_task_comment(
        db,
        task=task,
        author_user_id=user.id,
        body=payload.body,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="task_comment",
        content_id=comment.id,
        field_keys=["body"],
        user_id=user.id,
    )
    return _comment_out(comment, author_name=user.name, localized_fields=localized)


@router.delete("/{task_id}/comments/{comment_id}")
def delete_comment(comment_id: str, task_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    task = service.get_task(db, task_id)
    if not task:
        raise not_found("Task not found")
    comment = service.get_task_comment(db, comment_id)
    if not comment or comment.task_id != task.id:
        raise not_found("Task comment not found")
    if not _can_delete_comment(db, task, comment, user):
        raise HTTPException(status_code=403, detail="Insufficient role to delete this comment")
    service.delete_task_comment(db, comment)
    return {"ok": True}
