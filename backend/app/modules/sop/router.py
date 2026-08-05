# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for standard operating procedures and run execution APIs."""

from collections.abc import Mapping
from typing import TypeVar, cast

from fastapi import APIRouter, Depends, Response
from sqlalchemy.orm import Session

from app.core.deps import get_db
from app.core.deps import not_found
from app.modules.auth.models import User
from app.modules.auth.deps import get_current_user
from app.modules.localization import service as localization_service
from app.modules.spaces import service as spaces_service
from app.modules.tasks import service as tasks_service

from . import service
from .schemas import (
    SopApprovalDecisionIn,
    SopApprovalStageIn,
    SopCreateIn,
    SopDetailOut,
    SopMetaUpdateIn,
    SopOut,
    SopRunAuditOut,
    SopRunAssignmentOptionOut,
    SopRunAssignmentOptionsOut,
    SopRunStartIn,
    SopRunStartOut,
    SopRunScheduleIn,
    SopRunScheduleOut,
    SopRunOut,
    SopRunStepOut,
    SopRunStepUpdateIn,
    SopStepIn,
    SopUpdateIn,
)

router = APIRouter(prefix="/sop", tags=["sop"])


_SopOutT = TypeVar("_SopOutT", SopOut, SopDetailOut)


def _localize_sop_out(
    row: _SopOutT,
    fields: Mapping[str, str] | None,
) -> _SopOutT:
    if not fields:
        return row
    updates: dict[str, str] = {}
    title = fields.get("title")
    if title is not None and title.strip():
        updates["title"] = title
    overview = fields.get("overview")
    if overview is not None and overview.strip():
        updates["overview_md"] = overview
    if not updates:
        return row
    return cast(_SopOutT, row.model_copy(update=updates))


def _localize_sop_detail_out(
    row: SopDetailOut,
    *,
    sop_fields: Mapping[str, str] | None,
    step_fields_by_id: Mapping[str, Mapping[str, str]] | None,
) -> SopDetailOut:
    localized = _localize_sop_out(row, sop_fields)
    if not step_fields_by_id:
        return localized

    steps_changed = False
    localized_steps = []
    for step in localized.steps:
        fields = step_fields_by_id.get(step.id)
        if not fields:
            localized_steps.append(step)
            continue
        step_updates: dict[str, str] = {}
        title = fields.get("title")
        if title is not None and title.strip():
            step_updates["title"] = title
        body = fields.get("body")
        if body is not None and body.strip():
            step_updates["body_md"] = body
        if step_updates:
            steps_changed = True
            localized_steps.append(step.model_copy(update=step_updates))
        else:
            localized_steps.append(step)

    runs_changed = False
    localized_runs = []
    for run in localized.runs:
        run_steps_changed = False
        localized_run_steps = []
        for run_step in run.steps:
            step_id = run_step.step_id
            if step_id is None:
                localized_run_steps.append(run_step)
                continue
            fields = step_fields_by_id.get(step_id)
            if not fields:
                localized_run_steps.append(run_step)
                continue
            title = fields.get("title")
            if title is not None and title.strip():
                run_steps_changed = True
                localized_run_steps.append(run_step.model_copy(update={"title": title}))
            else:
                localized_run_steps.append(run_step)
        if run_steps_changed:
            runs_changed = True
            localized_runs.append(run.model_copy(update={"steps": localized_run_steps}))
        else:
            localized_runs.append(run)

    detail_updates: dict[str, object] = {}
    if steps_changed:
        detail_updates["steps"] = localized_steps
    if runs_changed:
        detail_updates["runs"] = localized_runs
    return localized.model_copy(update=detail_updates) if detail_updates else localized


def _localize_run_out(
    row: SopRunOut,
    *,
    step_fields_by_id: Mapping[str, Mapping[str, str]] | None,
) -> SopRunOut:
    if not step_fields_by_id:
        return row
    changed = False
    localized_steps = []
    for run_step in row.steps:
        step_id = run_step.step_id
        if step_id is None:
            localized_steps.append(run_step)
            continue
        fields = step_fields_by_id.get(step_id)
        if not fields:
            localized_steps.append(run_step)
            continue
        title = fields.get("title")
        if title is not None and title.strip():
            changed = True
            localized_steps.append(run_step.model_copy(update={"title": title}))
        else:
            localized_steps.append(run_step)
    return row.model_copy(update={"steps": localized_steps}) if changed else row


@router.get("/spaces/{space_id}/sops", response_model=list[SopOut])
def list_sops(
    space_id: str,
    published_only: bool = True,
    include_archived: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """List SOPs visible in a space, optionally including drafts or archived items."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_sops(db, space_id, published_only, include_archived=include_archived)
    localized_by_sop_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="sop",
        content_ids=[row.id for row in rows],
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return [
        _localize_sop_out(service._to_out(db, row), localized_by_sop_id.get(row.id, {}))
        for row in rows
    ]


@router.get("/spaces/{space_id}/sops/{slug}", response_model=SopDetailOut)
def get_sop(
    space_id: str,
    slug: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    sop = service.get_by_slug(db, space_id, slug)
    if not sop:
        raise not_found("SOP not found")
    if sop.status != "published":
        spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    detail = service.get_detail(db, sop.id)
    sop_fields = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=detail.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    step_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="sop_step",
        content_ids=[step.id for step in detail.steps],
        field_keys=["title", "body"],
        user_id=user.id,
    )
    return _localize_sop_detail_out(
        detail,
        sop_fields=sop_fields,
        step_fields_by_id=step_fields_by_id,
    )


@router.get("/sops/{sop_id}/detail", response_model=SopDetailOut)
def get_sop_detail(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return the full SOP detail payload used by editor and run-launch screens."""
    sop = service.get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    detail = service.get_detail(db, sop_id)
    if detail.status != "published":
        spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member"})
    sop_fields = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=detail.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    step_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="sop_step",
        content_ids=[step.id for step in detail.steps],
        field_keys=["title", "body"],
        user_id=user.id,
    )
    return _localize_sop_detail_out(
        detail,
        sop_fields=sop_fields,
        step_fields_by_id=step_fields_by_id,
    )


@router.post("/sops", response_model=SopOut)
def create_sop(
    payload: SopCreateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a new SOP draft with overview, reviewer, and approval metadata."""
    spaces_service.require_space_role(db, payload.space_id, user.id, {"admin", "moderator", "member"})
    sop = service.create_sop(
        db,
        user.id,
        payload.space_id,
        payload.title,
        payload.slug,
        payload.overview_md,
        folder_id=payload.folder_id,
        review_due_at=payload.review_due_at,
        reviewer_user_id=payload.reviewer_user_id,
        requires_approval=payload.requires_approval,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.put("/sops/{sop_id}", response_model=SopOut)
def update_sop(
    sop_id: str,
    payload: SopUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update the main SOP record without touching the underlying step list."""
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    sop = service.update_sop(
        db,
        user.id,
        sop_id,
        payload.title,
        payload.slug,
        payload.overview_md,
        folder_id=payload.folder_id,
        review_due_at=payload.review_due_at,
        reviewer_user_id=payload.reviewer_user_id,
        requires_approval=payload.requires_approval,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.put("/sops/{sop_id}/meta", response_model=SopOut)
def update_sop_meta(
    sop_id: str,
    payload: SopMetaUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update reviewer, review schedule, and approval requirements for an SOP."""
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    sop = service.update_meta(
        db,
        user_id=user.id,
        sop_id=sop_id,
        review_due_at=payload.review_due_at,
        reviewer_user_id=payload.reviewer_user_id,
        requires_approval=payload.requires_approval,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.put("/sops/{sop_id}/steps")
def set_steps(
    sop_id: str,
    steps: list[SopStepIn],
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Replace the full ordered SOP step list in one request."""
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    service.replace_steps(db, sop_id, [step.model_dump() for step in steps])
    return {"ok": True}


@router.post("/sops/{sop_id}/approve", response_model=SopOut)
def approve_sop(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Record an SOP approval and return the refreshed SOP state."""
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    sop = service.approve(db, user.id, sop_id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.post("/sops/{sop_id}/decisions", response_model=SopOut)
def record_sop_decision(
    sop_id: str,
    payload: SopApprovalDecisionIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    sop = service.record_approval_decision(
        db,
        user.id,
        sop_id,
        decision_type=payload.decision_type,
        note_md=payload.note_md,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.put("/sops/{sop_id}/approval-stages")
def set_approval_stages(
    sop_id: str,
    stages: list[SopApprovalStageIn],
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    service.replace_approval_stages(db, sop_id=sop_id, stages=[stage.model_dump() for stage in stages])
    return {"ok": True}


@router.put("/sops/{sop_id}/run-schedules", response_model=list[SopRunScheduleOut])
def set_run_schedules(
    sop_id: str,
    schedules: list[SopRunScheduleIn],
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Persist the recurring schedule definitions that should spawn SOP runs."""
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    service.replace_run_schedules(
        db,
        sop_id=sop_id,
        actor_user_id=user.id,
        schedules=[schedule.model_dump() for schedule in schedules],
    )
    detail = service.get_detail(db, sop_id)
    return detail.run_schedules


@router.post("/sops/{sop_id}/publish")
def publish(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    sop = service.publish(db, sop_id)
    return {"id": sop.id, "status": sop.status}


@router.post("/sops/{sop_id}/unpublish")
def unpublish(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    sop = service.unpublish(db, sop_id)
    return {"id": sop.id, "status": sop.status}


@router.post("/sops/{sop_id}/archive", response_model=SopOut)
def archive_sop(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    sop = service.archive(db, user_id=user.id, sop_id=sop_id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.post("/sops/{sop_id}/restore", response_model=SopOut)
def restore_sop(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    sop = service.restore(db, user_id=user.id, sop_id=sop_id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="sop",
        content_id=sop.id,
        field_keys=["title", "overview"],
        user_id=user.id,
    )
    return _localize_sop_out(service._to_out(db, sop), localized)


@router.delete("/sops/{sop_id}")
def delete_sop(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin"})
    service.delete_sop(db, sop_id=sop_id)
    return {"ok": True}


@router.get("/sops/{sop_id}/runs", response_model=list[SopRunOut])
def list_sop_runs(sop_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    step_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="sop_step",
        content_ids=[step.id for step in service.list_steps(db, sop_id)],
        field_keys=["title"],
        user_id=user.id,
    )
    return [
        _localize_run_out(
            service._run_to_out(db, run),
            step_fields_by_id=step_fields_by_id,
        )
        for run in service.list_runs(db, sop_id)
    ]


@router.get("/spaces/{space_id}/due-runs", response_model=list[SopRunScheduleOut])
def due_sop_runs(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.get_due_run_schedules(db, space_id=space_id)


@router.get("/sops/{sop_id}/run-assignment-options", response_model=SopRunAssignmentOptionsOut)
def sop_run_assignment_options(
    sop_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    options = service.list_run_assignment_options(db, sop_id=sop_id, user_id=user.id)
    return SopRunAssignmentOptionsOut(
        allow_self_assign=bool(options.get("allow_self_assign", True)),
        direct_assignees=[
            SopRunAssignmentOptionOut(**row)
            for row in options.get("direct_assignees", [])
        ],
        forward_managers=[
            SopRunAssignmentOptionOut(**row)
            for row in options.get("forward_managers", [])
        ],
    )


@router.post("/sops/{sop_id}/runs", response_model=SopRunStartOut)
def start_sop_run(
    sop_id: str,
    payload: SopRunStartIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Start a live SOP execution run from the current procedure definition."""
    current = service.get(db, sop_id)
    if not current:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    run, task, assigned_user_id, assignment_mode = service.start_run_with_task(
        db,
        user_id=user.id,
        sop_id=sop_id,
        assignee_user_id=payload.assignee_user_id,
        forward_manager_user_id=payload.forward_manager_user_id,
    )
    step_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="sop_step",
        content_ids=[step.id for step in service.list_steps(db, sop_id)],
        field_keys=["title"],
        user_id=user.id,
    )
    return SopRunStartOut(
        run=_localize_run_out(
            service._run_to_out(db, run),
            step_fields_by_id=step_fields_by_id,
        ),
        task_id=task.id,
        assigned_user_id=assigned_user_id,
        assignment_mode=assignment_mode,
    )


@router.put("/runs/{run_id}/steps/{run_step_id}", response_model=SopRunStepOut)
def update_sop_run_step(
    run_id: str,
    run_step_id: str,
    payload: SopRunStepUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update completion state, evidence, and notes for one SOP run step."""
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    step = service.update_run_step(
        db,
        user_id=user.id,
        run_id=run_id,
        run_step_id=run_step_id,
        completed=payload.completed,
        evidence_note=payload.evidence_note,
    )
    follow_up = service._follow_up_map(db, [step.id]).get(step.id)
    follow_up_task_id: str | None = None
    if step.step_id is not None:
        follow_up_task = tasks_service.get_task_by_source(
            db,
            source_kind="sop_step",
            source_id=sop.id,
            source_step_id=step.step_id,
        )
        follow_up_task_id = follow_up_task.id if follow_up_task else None
    localized_step_fields: Mapping[str, str] | None = None
    if step.step_id is not None:
        localized_step_fields = localization_service.localized_fields_for_content(
            db,
            content_kind="sop_step",
            content_id=step.step_id,
            field_keys=["title"],
            user_id=user.id,
        )
    localized_title = (
        localized_step_fields.get("title")
        if localized_step_fields is not None
        else None
    )
    return SopRunStepOut(
        id=step.id,
        run_id=step.run_id,
        step_id=step.step_id,
        step_order=step.step_order,
        title=localized_title if isinstance(localized_title, str) and localized_title.strip() else step.title,
        evidence_required=step.evidence_required,
        completed=step.completed,
        completed_at=step.completed_at,
        completed_by=step.completed_by,
        evidence_note=step.evidence_note,
        evidence_min_files=step.evidence_min_files,
        evidence_allowed_extensions=service._extensions_from_csv(step.evidence_allowed_extensions_csv),
        follow_up_incident_id=follow_up.incident_id if follow_up else None,
        follow_up_task_id=follow_up_task_id,
    )


@router.post("/runs/{run_id}/complete", response_model=SopRunOut)
def complete_sop_run(run_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Finalize a run after all required steps and validations have been satisfied."""
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    completed = service.complete_run(db, run_id=run_id)
    step_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="sop_step",
        content_ids=[step.id for step in service.list_steps(db, sop.id)],
        field_keys=["title"],
        user_id=user.id,
    )
    return _localize_run_out(
        service._run_to_out(db, completed),
        step_fields_by_id=step_fields_by_id,
    )


@router.get("/runs/{run_id}/audit", response_model=SopRunAuditOut)
def export_sop_run_audit(run_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return the structured audit payload for a completed or in-flight SOP run."""
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.export_run_audit(db, run_id=run_id)


@router.get("/runs/{run_id}/audit.csv")
def export_sop_run_audit_csv(run_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    payload = service.export_run_audit_csv(db, run_id=run_id)
    filename = f"sop-run-{run_id}.csv"
    return Response(
        content=payload,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/runs/{run_id}/audit.pdf")
def export_sop_run_audit_pdf(run_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    payload = service.export_run_audit_pdf_bytes(db, run_id=run_id)
    filename = f"sop-run-{run_id}.pdf"
    return Response(
        content=payload,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.post("/runs/{run_id}/steps/{run_step_id}/follow-up")
def create_follow_up_incident(
    run_id: str,
    run_step_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create an incident directly from a SOP run step that surfaced a problem."""
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member"})
    incident_id = service.create_follow_up_incident(db, user_id=user.id, run_step_id=run_step_id)
    return {"incident_id": incident_id}


@router.post("/runs/{run_id}/steps/{run_step_id}/task")
def create_follow_up_task(
    run_id: str,
    run_step_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a standalone task from a SOP run step for deferred follow-up work."""
    run = service.get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = service.get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    spaces_service.require_space_role(db, sop.space_id, user.id, {"admin", "moderator", "member"})
    task_id, created = service.create_follow_up_task(db, user_id=user.id, run_step_id=run_step_id)
    return {"task_id": task_id, "created": created}
