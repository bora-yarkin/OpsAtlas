# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for SOP lifecycle, approval, scheduling, and run execution."""

from __future__ import annotations

import csv
import html
import io
import uuid
from collections.abc import Mapping, Sequence
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.deps import bad_request, not_found
from app.core.rich_html import sanitize_rich_html
from app.modules.auth.deps import resolve_user_auth_role
from app.modules.auth.models import User
from app.modules.kb import repo as kb_repo
from app.modules.localization import service as localization_service
from app.modules.media import service as media_service
from app.modules.spaces import service as spaces_service
from app.modules.tasks import service as tasks_service

from .models import (
    Sop,
    SopApprovalDecision,
    SopApprovalStage,
    SopMeta,
    SopReminderDispatch,
    SopRun,
    SopRunFollowUp,
    SopRunSchedule,
    SopRunStep,
    SopStep,
    SopStepEvidenceRule,
    SopStepMeta,
)
from .schemas import (
    SopApprovalDecisionOut,
    SopApprovalStageOut,
    SopDetailOut,
    SopOut,
    SopRunAuditOut,
    SopReminderDispatchOut,
    SopRunOut,
    SopRunScheduleOut,
    SopRunStepOut,
    SopStepOut,
)

MIN_SCHEDULE_DAYS = 1
MAX_SCHEDULE_DAYS = 90
VALID_APPROVAL_DECISIONS = {"approve", "reject", "change_request"}
VALID_REMINDER_CHANNELS = {"in_app", "email", "webhook"}
REMINDER_RETRY_INTERVAL = timedelta(hours=6)


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _coerce_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _normalize_cadence_days(value: int | None) -> int:
    if value is None:
        return 7
    return max(MIN_SCHEDULE_DAYS, min(MAX_SCHEDULE_DAYS, int(value)))


def _normalize_min_files(value: int | None) -> int:
    if value is None:
        return 0
    return max(0, min(10, int(value)))


def _normalize_severity(value: int | None) -> int:
    if value is None:
        return 3
    return max(1, min(4, int(value)))


def _priority_from_severity(value: int | None) -> str:
    normalized = _normalize_severity(value)
    return {
        1: "critical",
        2: "high",
        3: "medium",
        4: "low",
    }.get(normalized, "medium")


def _normalize_follow_up_title(value: str | None) -> str:
    return (value or "").strip()[:240]


def _normalize_approval_decision(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_APPROVAL_DECISIONS:
        raise bad_request("Invalid approval decision")
    return normalized


def _normalize_extensions(raw: Sequence[str] | None) -> list[str]:
    if raw is None:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        clean = item.strip().lower().lstrip(".")
        if not clean:
            continue
        clean = "".join(ch for ch in clean if ch.isalnum())
        if not clean or clean in seen:
            continue
        seen.add(clean)
        out.append(clean[:10])
    return out


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


def _extensions_csv(values: Sequence[str]) -> str:
    return ",".join(_normalize_extensions(values))


def _extensions_from_csv(raw: str | None) -> list[str]:
    if not raw:
        return []
    return _normalize_extensions(raw.split(","))


def _is_archived(meta: SopMeta | None) -> bool:
    return meta is not None and meta.archived_at is not None


def _active_delegate_user_id(
    stage: SopApprovalStage, *, now: datetime | None = None
) -> str | None:
    delegate_id = (stage.delegate_approver_user_id or "").strip() or None
    if delegate_id is None:
        return None
    current = now or _now_utc()
    start_at = _coerce_utc(stage.delegate_start_at)
    end_at = _coerce_utc(stage.delegate_end_at)
    if start_at is not None and current < start_at:
        return None
    if end_at is not None and current > end_at:
        return None
    return delegate_id


def _validate_space_user(
    db: Session, *, space_id: str, user_id: str | None, label: str
) -> str | None:
    normalized = (user_id or "").strip() or None
    if normalized is None:
        return None
    role_key = spaces_service.get_space_role(db, space_id, normalized)
    if role_key is None:
        raise bad_request(f"{label} must be a member of this space")
    return normalized


def _validate_reviewer(
    db: Session, *, space_id: str, reviewer_user_id: str | None
) -> str | None:
    return _validate_space_user(
        db, space_id=space_id, user_id=reviewer_user_id, label="Reviewer"
    )


def _validate_operator(
    db: Session, *, space_id: str, operator_user_id: str | None
) -> str | None:
    return _validate_space_user(
        db, space_id=space_id, user_id=operator_user_id, label="Operator"
    )


def _validate_folder(
    db: Session, *, space_id: str, folder_id: str | None
) -> str | None:
    normalized = (folder_id or "").strip() or None
    if normalized is None:
        return None
    folder = kb_repo.get_folder(db, normalized)
    if folder is None or folder.space_id != space_id:
        raise bad_request("Folder must exist in this space")
    return folder.id


def _folder_path(db: Session, folder_id: str | None) -> str | None:
    normalized = (folder_id or "").strip() or None
    if normalized is None:
        return None
    folder = kb_repo.get_folder(db, normalized)
    return folder.path if folder else None


def list_sops(
    db: Session,
    space_id: str,
    published_only: bool,
    *,
    include_archived: bool = False,
) -> list[Sop]:
    q = select(Sop).where(Sop.space_id == space_id)
    if published_only:
        q = q.where(Sop.status == "published")
    rows = list(db.execute(q.order_by(Sop.updated_at.desc())).scalars().all())
    if include_archived:
        return rows
    return [row for row in rows if not _is_archived(db.get(SopMeta, row.id))]


def get_by_slug(db: Session, space_id: str, slug: str) -> Sop | None:
    sop = db.scalar(select(Sop).where(Sop.space_id == space_id, Sop.slug == slug))
    if sop is None:
        return None
    if _is_archived(db.get(SopMeta, sop.id)):
        return None
    return sop


def get(db: Session, sop_id: str) -> Sop | None:
    return db.get(Sop, sop_id)


def list_steps(db: Session, sop_id: str) -> list[SopStep]:
    q = (
        select(SopStep)
        .where(SopStep.sop_id == sop_id)
        .order_by(SopStep.step_order.asc())
    )
    return list(db.execute(q).scalars().all())


def _ensure_meta(db: Session, sop_id: str) -> SopMeta:
    meta = db.get(SopMeta, sop_id)
    if meta:
        return meta
    meta = SopMeta(
        sop_id=sop_id,
        review_due_at=None,
        last_reviewed_at=None,
        reviewer_user_id=None,
        requires_approval=False,
        approved_at=None,
        approved_by=None,
        archived_at=None,
        archived_by=None,
    )
    db.add(meta)
    db.flush()
    return meta


def _ensure_step_meta(db: Session, step_id: str) -> SopStepMeta:
    meta = db.get(SopStepMeta, step_id)
    if meta:
        return meta
    meta = SopStepMeta(step_id=step_id, requires_evidence=False)
    db.add(meta)
    db.flush()
    return meta


def _ensure_evidence_rule(db: Session, step_id: str) -> SopStepEvidenceRule:
    rule = db.get(SopStepEvidenceRule, step_id)
    if rule:
        return rule
    rule = SopStepEvidenceRule(
        step_id=step_id,
        min_file_count=0,
        allowed_extensions_csv="",
        follow_up_severity=3,
        follow_up_owner_user_id=None,
        follow_up_title_template="",
    )
    db.add(rule)
    db.flush()
    return rule


def _get_step_meta_map(db: Session, step_ids: list[str]) -> dict[str, SopStepMeta]:
    if not step_ids:
        return {}
    rows = (
        db.execute(select(SopStepMeta).where(SopStepMeta.step_id.in_(step_ids)))
        .scalars()
        .all()
    )
    return {row.step_id: row for row in rows}


def _get_step_rule_map(
    db: Session, step_ids: list[str]
) -> dict[str, SopStepEvidenceRule]:
    if not step_ids:
        return {}
    rows = (
        db.execute(
            select(SopStepEvidenceRule).where(SopStepEvidenceRule.step_id.in_(step_ids))
        )
        .scalars()
        .all()
    )
    return {row.step_id: row for row in rows}


def list_runs(db: Session, sop_id: str) -> list[SopRun]:
    return list(
        db.execute(
            select(SopRun)
            .where(SopRun.sop_id == sop_id)
            .order_by(SopRun.started_at.desc())
        )
        .scalars()
        .all()
    )


def list_run_steps(db: Session, run_id: str) -> list[SopRunStep]:
    return list(
        db.execute(
            select(SopRunStep)
            .where(SopRunStep.run_id == run_id)
            .order_by(SopRunStep.step_order.asc(), SopRunStep.id.asc())
        )
        .scalars()
        .all()
    )


def get_run(db: Session, run_id: str) -> SopRun | None:
    return db.get(SopRun, run_id)


def get_active_run(db: Session, sop_id: str) -> SopRun | None:
    return db.scalar(
        select(SopRun)
        .where(SopRun.sop_id == sop_id, SopRun.status == "in_progress")
        .order_by(SopRun.started_at.desc())
    )


def list_approval_stages(db: Session, sop_id: str) -> list[SopApprovalStage]:
    return list(
        db.execute(
            select(SopApprovalStage)
            .where(SopApprovalStage.sop_id == sop_id)
            .order_by(SopApprovalStage.stage_order.asc())
        )
        .scalars()
        .all()
    )


def list_sign_off_history(db: Session, sop_id: str) -> list[SopApprovalDecision]:
    return list(
        db.execute(
            select(SopApprovalDecision)
            .where(SopApprovalDecision.sop_id == sop_id)
            .order_by(SopApprovalDecision.approved_at.asc())
        )
        .scalars()
        .all()
    )


def list_run_schedules(db: Session, sop_id: str) -> list[SopRunScheduleOut]:
    rows = tasks_service.list_sop_execution_schedule_views(db, sop_id=sop_id)
    return [SopRunScheduleOut(**row) for row in rows]


def get_due_run_schedules(db: Session, *, space_id: str) -> list[SopRunScheduleOut]:
    rows = tasks_service.list_due_sop_execution_schedule_views(db, space_id=space_id)
    out: list[SopRunScheduleOut] = []
    for row in rows:
        sop_id = str(row.get("sop_id") or "")
        if not sop_id:
            continue
        if _is_archived(_ensure_meta(db, sop_id)):
            continue
        out.append(SopRunScheduleOut(**row))
    return out


def _user_names(db: Session, user_ids: set[str]) -> dict[str, str]:
    ids = {user_id for user_id in user_ids if user_id}
    if not ids:
        return {}
    users = db.execute(select(User).where(User.id.in_(ids))).scalars().all()
    return {user.id: user.name for user in users}


def _decision_map(db: Session, sop_id: str) -> dict[str, SopApprovalDecision]:
    decisions = list_sign_off_history(db, sop_id)
    out: dict[str, SopApprovalDecision] = {}
    for decision in decisions:
        out[decision.stage_id] = decision
    return out


def _pending_stage(
    stages: Sequence[SopApprovalStage],
    decision_by_stage: dict[str, SopApprovalDecision],
) -> SopApprovalStage | None:
    for stage in stages:
        decision = decision_by_stage.get(stage.id)
        if decision is None or decision.decision_type != "approve":
            return stage
    return None


def _to_out(db: Session, sop: Sop) -> SopOut:
    meta = _ensure_meta(db, sop.id)
    reviewer_name = None
    if meta.reviewer_user_id:
        reviewer = db.get(User, meta.reviewer_user_id)
        reviewer_name = reviewer.name if reviewer else None
    stages = list_approval_stages(db, sop.id)
    decisions = _decision_map(db, sop.id)
    pending_stage = _pending_stage(stages, decisions)
    runs = list_runs(db, sop.id)
    linked_tasks = tasks_service.list_tasks_for_sop_source(db, sop_id=sop.id)
    return SopOut(
        id=sop.id,
        space_id=sop.space_id,
        folder_id=sop.folder_id,
        folder_path=_folder_path(db, sop.folder_id),
        title=sop.title,
        slug=sop.slug,
        status=sop.status,
        overview_md=sop.overview_md,
        created_at=sop.created_at,
        updated_at=sop.updated_at,
        review_due_at=meta.review_due_at,
        last_reviewed_at=meta.last_reviewed_at,
        reviewer_user_id=meta.reviewer_user_id,
        reviewer_name=reviewer_name,
        requires_approval=meta.requires_approval,
        approved_at=meta.approved_at,
        approved_by=meta.approved_by,
        pending_approval=meta.requires_approval and meta.approved_at is None,
        pending_approval_stage_order=pending_stage.stage_order
        if pending_stage
        else None,
        archived_at=meta.archived_at,
        archived_by=meta.archived_by,
        last_run_at=runs[0].started_at if runs else None,
        linked_task_count=len(linked_tasks),
    )


def _stage_to_out(
    stage: SopApprovalStage,
    *,
    decision: SopApprovalDecision | None,
    user_names: dict[str, str],
) -> SopApprovalStageOut:
    effective_approver_user_id = (
        _active_delegate_user_id(stage) or stage.approver_user_id
    )
    return SopApprovalStageOut(
        id=stage.id,
        sop_id=stage.sop_id,
        stage_order=stage.stage_order,
        approver_user_id=stage.approver_user_id,
        approver_name=user_names.get(stage.approver_user_id),
        label=stage.label,
        delegate_approver_user_id=stage.delegate_approver_user_id,
        delegate_approver_name=user_names.get(stage.delegate_approver_user_id or ""),
        delegate_start_at=stage.delegate_start_at,
        delegate_end_at=stage.delegate_end_at,
        effective_approver_user_id=effective_approver_user_id,
        effective_approver_name=user_names.get(effective_approver_user_id or ""),
        delegate_active=effective_approver_user_id != stage.approver_user_id,
        approved_at=decision.approved_at if decision else None,
        approved_by=decision.approved_by if decision else None,
        approved_by_name=user_names.get(decision.approved_by) if decision else None,
    )


def _decision_to_out(
    decision: SopApprovalDecision, *, user_names: dict[str, str]
) -> SopApprovalDecisionOut:
    return SopApprovalDecisionOut(
        id=decision.id,
        sop_id=decision.sop_id,
        stage_id=decision.stage_id,
        approved_by=decision.approved_by,
        approved_by_name=user_names.get(decision.approved_by),
        approved_at=decision.approved_at,
        decision_type=decision.decision_type,
        note_md=decision.note_md,
    )


def _dispatch_to_out(
    dispatch: SopReminderDispatch, *, user_names: dict[str, str]
) -> SopReminderDispatchOut:
    return SopReminderDispatchOut(
        id=dispatch.id,
        channel=dispatch.channel,
        recipient_user_id=dispatch.recipient_user_id,
        recipient_name=user_names.get(dispatch.recipient_user_id or ""),
        created_at=dispatch.created_at,
        delivered_at=dispatch.delivered_at,
        payload_json=dispatch.payload_json,
    )


def _schedule_to_out(
    schedule: SopRunSchedule,
    *,
    user_names: dict[str, str],
    recent_dispatches: Sequence[SopReminderDispatch] = (),
) -> SopRunScheduleOut:
    next_due_at = _coerce_utc(schedule.next_due_at)
    now = _now_utc()
    return SopRunScheduleOut(
        id=schedule.id,
        sop_id=schedule.sop_id,
        cadence_days=schedule.cadence_days,
        next_due_at=next_due_at,
        operator_user_id=schedule.operator_user_id,
        operator_name=user_names.get(schedule.operator_user_id or ""),
        enabled=schedule.enabled,
        last_started_at=schedule.last_started_at,
        reminder_channels=_channels_from_csv(schedule.reminder_channels_csv),
        last_reminder_sent_at=schedule.last_reminder_sent_at,
        overdue=bool(schedule.enabled and next_due_at and next_due_at <= now),
        recent_dispatches=[
            _dispatch_to_out(row, user_names=user_names) for row in recent_dispatches
        ],
    )


def _follow_up_map(
    db: Session, run_step_ids: Sequence[str]
) -> dict[str, SopRunFollowUp]:
    ids = [run_step_id for run_step_id in run_step_ids if run_step_id]
    if not ids:
        return {}
    rows = (
        db.execute(select(SopRunFollowUp).where(SopRunFollowUp.run_step_id.in_(ids)))
        .scalars()
        .all()
    )
    return {row.run_step_id: row for row in rows}


def _follow_up_task_map(
    db: Session,
    *,
    sop_id: str,
    source_step_ids: Sequence[str],
) -> dict[str, str]:
    ids = {(source_step_id or "").strip() for source_step_id in source_step_ids}
    ids.discard("")
    if not ids:
        return {}

    rows = tasks_service.list_tasks_for_sop_source(db, sop_id=sop_id)
    out: dict[str, str] = {}
    for row in rows:
        if row.source_kind != "sop_step":
            continue
        source_step_id = (row.source_step_id or "").strip()
        if not source_step_id or source_step_id not in ids or source_step_id in out:
            continue
        out[source_step_id] = row.id
    return out


def _run_step_to_out(
    step: SopRunStep,
    *,
    follow_up: SopRunFollowUp | None,
    follow_up_task_id: str | None,
) -> SopRunStepOut:
    return SopRunStepOut(
        id=step.id,
        run_id=step.run_id,
        step_id=step.step_id,
        step_order=step.step_order,
        title=step.title,
        evidence_required=step.evidence_required,
        completed=step.completed,
        completed_at=step.completed_at,
        completed_by=step.completed_by,
        evidence_note=step.evidence_note,
        evidence_min_files=_normalize_min_files(step.evidence_min_files),
        evidence_allowed_extensions=_extensions_from_csv(
            step.evidence_allowed_extensions_csv
        ),
        follow_up_incident_id=follow_up.incident_id if follow_up else None,
        follow_up_task_id=follow_up_task_id,
    )


def _run_to_out(db: Session, run: SopRun) -> SopRunOut:
    steps = list_run_steps(db, run.id)
    follow_up_map = _follow_up_map(db, [step.id for step in steps])
    follow_up_task_map = _follow_up_task_map(
        db,
        sop_id=run.sop_id,
        source_step_ids=[step.step_id for step in steps if step.step_id],
    )
    return SopRunOut(
        id=run.id,
        sop_id=run.sop_id,
        status=run.status,
        started_by=run.started_by,
        started_at=run.started_at,
        completed_at=run.completed_at,
        steps=[
            _run_step_to_out(
                step,
                follow_up=follow_up_map.get(step.id),
                follow_up_task_id=follow_up_task_map.get((step.step_id or "").strip()),
            )
            for step in steps
        ],
    )


def get_detail(db: Session, sop_id: str) -> SopDetailOut:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    step_rows = list_steps(db, sop_id)
    step_meta_map = _get_step_meta_map(db, [step.id for step in step_rows])
    step_rule_map = _get_step_rule_map(db, [step.id for step in step_rows])
    runs = list_runs(db, sop_id)
    base = _to_out(db, sop)
    stages = list_approval_stages(db, sop.id)
    decisions = list_sign_off_history(db, sop.id)
    schedules = list_run_schedules(db, sop.id)
    user_ids = {
        *[stage.approver_user_id for stage in stages],
        *[
            stage.delegate_approver_user_id
            for stage in stages
            if stage.delegate_approver_user_id
        ],
        *[decision.approved_by for decision in decisions],
        *[run.started_by for run in runs],
    }
    for rule in step_rule_map.values():
        if rule.follow_up_owner_user_id:
            user_ids.add(rule.follow_up_owner_user_id)
    user_names = _user_names(db, user_ids)
    decision_by_stage = {decision.stage_id: decision for decision in decisions}
    step_out_rows: list[SopStepOut] = []
    for step in step_rows:
        step_meta = step_meta_map.get(step.id)
        step_rule = step_rule_map.get(step.id)
        follow_up_owner_user_id = (
            step_rule.follow_up_owner_user_id if step_rule else None
        )
        step_out_rows.append(
            SopStepOut(
                id=step.id,
                sop_id=step.sop_id,
                step_order=step.step_order,
                title=step.title,
                body_md=step.body_md,
                requires_evidence=step_meta.requires_evidence if step_meta else False,
                evidence_min_files=step_rule.min_file_count if step_rule else 0,
                evidence_allowed_extensions=_extensions_from_csv(
                    step_rule.allowed_extensions_csv if step_rule else ""
                ),
                follow_up_severity=_normalize_severity(
                    step_rule.follow_up_severity if step_rule else 3
                ),
                follow_up_owner_user_id=follow_up_owner_user_id,
                follow_up_owner_name=user_names.get(follow_up_owner_user_id or ""),
                follow_up_title_template=step_rule.follow_up_title_template
                if step_rule
                else "",
            )
        )
    return SopDetailOut(
        **base.model_dump(),
        steps=step_out_rows,
        runs=[_run_to_out(db, run) for run in runs],
        approval_stages=[
            _stage_to_out(
                stage, decision=decision_by_stage.get(stage.id), user_names=user_names
            )
            for stage in stages
        ],
        sign_off_history=[
            _decision_to_out(decision, user_names=user_names) for decision in decisions
        ],
        run_schedules=schedules,
    )


def create_sop(
    db: Session,
    user_id: str,
    space_id: str,
    title: str,
    slug: str,
    overview_md: str,
    *,
    folder_id: str | None = None,
    review_due_at: datetime | None = None,
    reviewer_user_id: str | None = None,
    requires_approval: bool = False,
) -> Sop:
    if get_by_slug(db, space_id, slug):
        raise bad_request("SOP slug already exists in this space")
    sanitized_overview = sanitize_rich_html(overview_md)
    sop = Sop(
        id=str(uuid.uuid4()),
        space_id=space_id,
        folder_id=_validate_folder(db, space_id=space_id, folder_id=folder_id),
        title=title,
        slug=slug,
        status="draft",
        overview_md=sanitized_overview,
        created_by=user_id,
        updated_by=user_id,
    )
    db.add(sop)
    db.flush()
    meta = _ensure_meta(db, sop.id)
    meta.review_due_at = _coerce_utc(review_due_at)
    meta.reviewer_user_id = _validate_reviewer(
        db, space_id=space_id, reviewer_user_id=reviewer_user_id
    )
    meta.requires_approval = requires_approval
    meta.approved_at = None
    meta.approved_by = None
    meta.archived_at = None
    meta.archived_by = None
    media_service.sync_usage_refs(
        db,
        entity_type="sop",
        entity_id=sop.id,
        field_name="overview",
        content=sanitized_overview,
        space_id=space_id,
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="sop",
        content_id=sop.id,
        fields={
            "title": title,
            "overview": sanitized_overview,
        },
        actor_user_id=user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(sop)
    return sop


def update_sop(
    db: Session,
    user_id: str,
    sop_id: str,
    title: str,
    slug: str,
    overview_md: str,
    *,
    folder_id: str | None = None,
    review_due_at: datetime | None = None,
    reviewer_user_id: str | None = None,
    requires_approval: bool = False,
) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop.id)
    if _is_archived(meta):
        raise bad_request("Restore this SOP before editing it")
    if slug != sop.slug and get_by_slug(db, sop.space_id, slug):
        raise bad_request("SOP slug already exists in this space")
    sanitized_overview = sanitize_rich_html(overview_md)
    sop.title = title
    sop.slug = slug
    sop.folder_id = _validate_folder(db, space_id=sop.space_id, folder_id=folder_id)
    sop.overview_md = sanitized_overview
    sop.updated_by = user_id
    meta.review_due_at = _coerce_utc(review_due_at)
    meta.reviewer_user_id = _validate_reviewer(
        db, space_id=sop.space_id, reviewer_user_id=reviewer_user_id
    )
    if meta.requires_approval != requires_approval:
        meta.requires_approval = requires_approval
        meta.approved_at = None
        meta.approved_by = None
    if meta.requires_approval:
        meta.approved_at = None
        meta.approved_by = None
    media_service.sync_usage_refs(
        db,
        entity_type="sop",
        entity_id=sop.id,
        field_name="overview",
        content=sanitized_overview,
        space_id=sop.space_id,
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="sop",
        content_id=sop.id,
        fields={
            "title": title,
            "overview": sanitized_overview,
        },
        actor_user_id=user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(sop)
    return sop


def update_meta(
    db: Session,
    *,
    user_id: str,
    sop_id: str,
    review_due_at: datetime | None = None,
    reviewer_user_id: str | None = None,
    requires_approval: bool | None = None,
) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop.id)
    if _is_archived(meta):
        raise bad_request("Restore this SOP before editing it")
    meta.review_due_at = _coerce_utc(review_due_at)
    meta.reviewer_user_id = _validate_reviewer(
        db, space_id=sop.space_id, reviewer_user_id=reviewer_user_id
    )
    if requires_approval is not None and meta.requires_approval != requires_approval:
        meta.requires_approval = requires_approval
        meta.approved_at = None
        meta.approved_by = None
    meta.last_reviewed_at = _now_utc()
    sop.updated_by = user_id
    db.commit()
    db.refresh(sop)
    return sop


def replace_steps(db: Session, sop_id: str, steps: Sequence[Mapping[str, Any]]) -> None:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    if _is_archived(_ensure_meta(db, sop.id)):
        raise bad_request("Restore this SOP before editing it")
    old_step_ids = list(
        db.execute(select(SopStep.id).where(SopStep.sop_id == sop_id)).scalars().all()
    )
    for old_step_id in old_step_ids:
        media_service.clear_usage_refs(
            db, entity_type="sop_step", entity_id=old_step_id
        )

    step_ids_for_sop = select(SopStep.id).where(SopStep.sop_id == sop_id)
    db.execute(delete(SopStepMeta).where(SopStepMeta.step_id.in_(step_ids_for_sop)))
    db.execute(
        delete(SopStepEvidenceRule).where(
            SopStepEvidenceRule.step_id.in_(step_ids_for_sop)
        )
    )
    db.execute(delete(SopStep).where(SopStep.sop_id == sop_id))
    for st in steps:
        step_body = sanitize_rich_html(str(st.get("body_md", "")))
        step = SopStep(
            id=str(uuid.uuid4()),
            sop_id=sop_id,
            step_order=int(st["step_order"]),
            title=str(st["title"]),
            body_md=step_body,
        )
        db.add(step)
        db.flush()
        step_meta = _ensure_step_meta(db, step.id)
        step_meta.requires_evidence = bool(st.get("requires_evidence"))
        rule = _ensure_evidence_rule(db, step.id)
        rule.min_file_count = _normalize_min_files(
            int(st.get("evidence_min_files", 0) or 0)
        )
        raw_exts = st.get("evidence_allowed_extensions", [])
        ext_values = raw_exts if isinstance(raw_exts, list) else []
        rule.allowed_extensions_csv = _extensions_csv(
            [str(value) for value in ext_values]
        )
        rule.follow_up_severity = _normalize_severity(
            int(st.get("follow_up_severity", 3) or 3)
        )
        rule.follow_up_owner_user_id = _validate_space_user(
            db,
            space_id=sop.space_id,
            user_id=(st.get("follow_up_owner_user_id") or None),
            label="Follow-up owner",
        )
        rule.follow_up_title_template = str(
            st.get("follow_up_title_template", "") or ""
        ).strip()[:240]
        step_meta.requires_evidence = (
            step_meta.requires_evidence
            or rule.min_file_count > 0
            or bool(rule.allowed_extensions_csv)
        )
        media_service.sync_usage_refs(
            db,
            entity_type="sop_step",
            entity_id=step.id,
            field_name="body",
            content=step.body_md,
            space_id=sop.space_id,
        )
        localization_service.try_queue_content_translations(
            db,
            content_kind="sop_step",
            content_id=step.id,
            fields={
                "title": step.title,
                "body": step.body_md,
            },
            actor_user_id=None,
            triggered_by="auto_write",
        )
    meta = _ensure_meta(db, sop.id)
    if meta.requires_approval:
        meta.approved_at = None
        meta.approved_by = None
    db.commit()


def replace_approval_stages(
    db: Session, *, sop_id: str, stages: Sequence[Mapping[str, Any]]
) -> None:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop_id)
    if _is_archived(meta):
        raise bad_request("Restore this SOP before editing it")
    existing_decisions = list_sign_off_history(db, sop_id)
    for row in existing_decisions:
        db.delete(row)
    db.execute(delete(SopApprovalStage).where(SopApprovalStage.sop_id == sop_id))
    for stage in stages:
        approver_user_id = _validate_space_user(
            db,
            space_id=sop.space_id,
            user_id=str(stage.get("approver_user_id", "")),
            label="Approver",
        )
        if approver_user_id is None:
            raise bad_request("Approval stages require an approver")
        label = (
            str(stage.get("label", "")).strip()
            or f"Stage {int(stage.get('stage_order', 0) or 0)}"
        )
        delegate_approver_user_id = _validate_space_user(
            db,
            space_id=sop.space_id,
            user_id=(stage.get("delegate_approver_user_id") or None),
            label="Delegate approver",
        )
        delegate_start_at = (
            _coerce_utc(stage.get("delegate_start_at"))
            if isinstance(stage.get("delegate_start_at"), datetime)
            else None
        )
        delegate_end_at = (
            _coerce_utc(stage.get("delegate_end_at"))
            if isinstance(stage.get("delegate_end_at"), datetime)
            else None
        )
        if (
            delegate_start_at
            and delegate_end_at
            and delegate_end_at < delegate_start_at
        ):
            raise bad_request("Delegate coverage end must be after start")
        db.add(
            SopApprovalStage(
                id=str(uuid.uuid4()),
                sop_id=sop_id,
                stage_order=int(stage.get("stage_order", 0) or 0),
                approver_user_id=approver_user_id,
                label=label[:120],
                delegate_approver_user_id=delegate_approver_user_id,
                delegate_start_at=delegate_start_at,
                delegate_end_at=delegate_end_at,
            )
        )
    meta.requires_approval = bool(stages) or meta.requires_approval
    meta.approved_at = None
    meta.approved_by = None
    db.commit()


def replace_run_schedules(
    db: Session,
    *,
    sop_id: str,
    actor_user_id: str,
    schedules: Sequence[Mapping[str, Any]],
) -> None:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    if _is_archived(_ensure_meta(db, sop_id)):
        raise bad_request("Restore this SOP before editing it")

    normalized_schedules: list[dict[str, Any]] = []
    for row in schedules:
        normalized_row = dict(row)
        normalized_row["operator_user_id"] = _validate_operator(
            db,
            space_id=sop.space_id,
            operator_user_id=(row.get("operator_user_id") or None),
        )
        normalized_schedules.append(normalized_row)

    tasks_service.replace_sop_execution_profiles(
        db,
        sop_id=sop.id,
        space_id=sop.space_id,
        sop_title=sop.title,
        actor_user_id=actor_user_id,
        schedules=normalized_schedules,
    )

    # Remove legacy SOP-owned schedules once the task-owned profile mirror is written.
    db.execute(delete(SopReminderDispatch).where(SopReminderDispatch.sop_id == sop_id))
    db.execute(delete(SopRunSchedule).where(SopRunSchedule.sop_id == sop_id))
    db.commit()


def record_approval_decision(
    db: Session,
    user_id: str,
    sop_id: str,
    *,
    decision_type: str,
    note_md: str = "",
) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop.id)
    if _is_archived(meta):
        raise bad_request("Restore this SOP before approving it")
    if not meta.requires_approval:
        raise bad_request("This SOP does not require approval")
    normalized_decision = _normalize_approval_decision(decision_type)
    stages = list_approval_stages(db, sop.id)
    sanitized_note = sanitize_rich_html(note_md)
    if stages:
        decisions = _decision_map(db, sop.id)
        pending = _pending_stage(stages, decisions)
        if pending is None:
            if normalized_decision == "approve":
                meta.approved_at = meta.approved_at or _now_utc()
                meta.approved_by = meta.approved_by or user_id
                db.commit()
                db.refresh(sop)
                return sop
            raise bad_request("All approval stages are already signed off")
        allowed_user_ids = {pending.approver_user_id}
        delegate_user_id = _active_delegate_user_id(pending)
        if delegate_user_id:
            allowed_user_ids.add(delegate_user_id)
        if user_id not in allowed_user_ids:
            raise bad_request("You are not assigned to the current approval stage")
        db.add(
            SopApprovalDecision(
                id=str(uuid.uuid4()),
                sop_id=sop.id,
                stage_id=pending.id,
                approved_by=user_id,
                decision_type=normalized_decision,
                note_md=sanitized_note,
            )
        )
        db.flush()
        if (
            normalized_decision == "approve"
            and _pending_stage(stages, _decision_map(db, sop.id)) is None
        ):
            meta.approved_at = _now_utc()
            meta.approved_by = user_id
        else:
            meta.approved_at = None
            meta.approved_by = None
            sop.status = "draft"
    else:
        if normalized_decision != "approve":
            raise bad_request(
                "Configure approval stages before rejecting or requesting changes"
            )
        meta.approved_at = _now_utc()
        meta.approved_by = user_id
    meta.last_reviewed_at = _now_utc()
    db.commit()
    db.refresh(sop)
    return sop


def approve(db: Session, user_id: str, sop_id: str, *, note_md: str = "") -> Sop:
    return record_approval_decision(
        db, user_id, sop_id, decision_type="approve", note_md=note_md
    )


def publish(db: Session, sop_id: str) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop.id)
    if _is_archived(meta):
        raise bad_request("Restore this SOP before publishing it")
    stages = list_approval_stages(db, sop.id)
    if meta.requires_approval:
        if stages and _pending_stage(stages, _decision_map(db, sop.id)) is not None:
            raise bad_request("All approval stages must be signed off before publish")
        if not stages and meta.approved_at is None:
            raise bad_request("SOP requires approval before it can be published")
    sop.status = "published"
    db.commit()
    db.refresh(sop)
    return sop


def unpublish(db: Session, sop_id: str) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    if _is_archived(_ensure_meta(db, sop.id)):
        raise bad_request("Restore this SOP before changing publish state")
    sop.status = "draft"
    db.commit()
    db.refresh(sop)
    return sop


def archive(db: Session, *, user_id: str, sop_id: str) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop.id)
    meta.archived_at = _now_utc()
    meta.archived_by = user_id
    meta.approved_at = None
    meta.approved_by = None
    sop.status = "draft"
    db.commit()
    db.refresh(sop)
    return sop


def restore(db: Session, *, user_id: str, sop_id: str) -> Sop:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    meta = _ensure_meta(db, sop.id)
    meta.archived_at = None
    meta.archived_by = None
    meta.last_reviewed_at = _now_utc()
    sop.updated_by = user_id
    db.commit()
    db.refresh(sop)
    return sop


def delete_sop(db: Session, *, sop_id: str) -> None:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    steps = list_steps(db, sop_id)
    runs = list_runs(db, sop_id)
    for step in steps:
        media_service.clear_usage_refs(db, entity_type="sop_step", entity_id=step.id)
        step_meta = db.get(SopStepMeta, step.id)
        if step_meta is not None:
            db.delete(step_meta)
        step_rule = db.get(SopStepEvidenceRule, step.id)
        if step_rule is not None:
            db.delete(step_rule)
        db.delete(step)
    for run in runs:
        for run_step in list_run_steps(db, run.id):
            media_service.clear_usage_refs(
                db, entity_type="sop_run_step", entity_id=run_step.id
            )
            follow_up = db.scalar(
                select(SopRunFollowUp).where(SopRunFollowUp.run_step_id == run_step.id)
            )
            if follow_up is not None:
                db.delete(follow_up)
            db.delete(run_step)
        db.delete(run)
    for stage in list_approval_stages(db, sop_id):
        db.delete(stage)
    for decision in list_sign_off_history(db, sop_id):
        db.delete(decision)

    # Remove task-owned execution profiles tied to this SOP.
    tasks_service.clear_sop_execution_profiles(db, sop_id=sop_id)

    # Remove any remaining legacy SOP-owned schedule/reminder rows.
    db.execute(delete(SopReminderDispatch).where(SopReminderDispatch.sop_id == sop_id))
    db.execute(delete(SopRunSchedule).where(SopRunSchedule.sop_id == sop_id))

    meta = db.get(SopMeta, sop_id)
    if meta is not None:
        db.delete(meta)
    media_service.clear_usage_refs(db, entity_type="sop", entity_id=sop_id)
    db.delete(sop)
    db.commit()


def _validate_run_step_evidence(db: Session, step: SopRunStep) -> None:
    attachments = media_service.list_entity_attachments(
        db,
        entity_type="sop_run_step",
        entity_id=step.id,
    )
    if step.evidence_required and not step.evidence_note.strip():
        raise bad_request("This step requires evidence notes before completion")
    if step.evidence_min_files > 0 and len(attachments) < step.evidence_min_files:
        raise bad_request(
            f"This step requires at least {step.evidence_min_files} evidence attachment(s) before completion"
        )
    allowed_exts = set(_extensions_from_csv(step.evidence_allowed_extensions_csv))
    if allowed_exts and attachments:
        for asset in attachments:
            ext = Path(asset.original_filename).suffix.lower().lstrip(".")
            if ext and ext not in allowed_exts:
                raise bad_request(
                    f"Attachment '{asset.original_filename}' does not match allowed file types: {', '.join(sorted(allowed_exts))}"
                )


def _space_member_option_rows(
    db: Session,
    *,
    space_id: str,
    memberships: Sequence[spaces_service.SpaceMembership],
    report_count_by_user_id: Mapping[str, int],
    user_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    if not memberships:
        return []

    requested_ids = user_ids or {membership.user_id for membership in memberships}
    users_by_id = {
        user.id: user
        for user in db.execute(
            select(User).where(User.id.in_(sorted(requested_ids)))
        ).scalars().all()
    }
    rows: list[dict[str, Any]] = []
    for membership in memberships:
        if membership.user_id not in requested_ids:
            continue
        user = users_by_id.get(membership.user_id)
        if user is None:
            continue
        report_count = int(report_count_by_user_id.get(membership.user_id, 0) or 0)
        rows.append(
            {
                "user_id": membership.user_id,
                "role": membership.role,
                "name": user.name,
                "email": user.email,
                "report_count": report_count,
                "is_manager": report_count > 0,
                "space_id": space_id,
            }
        )
    rows.sort(
        key=lambda row: (
            str(row["name"] or row["email"] or row["user_id"]).strip().lower(),
            str(row["email"] or "").strip().lower(),
        )
    )
    return rows


def _run_assignment_can_delegate(db: Session, *, space_id: str, user_id: str) -> bool:
    actor = db.get(User, user_id)
    if actor is None:
        return False
    if resolve_user_auth_role(db, actor) in {"admin", "moderator"}:
        return True
    role_key = spaces_service.get_space_role(db, space_id, user_id)
    if role_key is None:
        return False
    effective_role = spaces_service.resolve_effective_space_role(db, role_key)
    return effective_role in {"admin", "moderator"}


def list_run_assignment_options(
    db: Session,
    *,
    sop_id: str,
    user_id: str,
) -> dict[str, Any]:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")

    memberships = spaces_service.list_members(db, sop.space_id)
    memberships_by_user_id = {
        membership.user_id: membership
        for membership in memberships
    }
    if user_id not in memberships_by_user_id and db.get(User, user_id) is None:
        raise not_found("User not found")

    report_count_by_user_id = spaces_service.member_report_counts(db, sop.space_id)
    direct_report_memberships = spaces_service.list_direct_reports(
        db,
        space_id=sop.space_id,
        manager_user_id=user_id,
    )
    can_assign_any_member = _run_assignment_can_delegate(
        db,
        space_id=sop.space_id,
        user_id=user_id,
    )

    if can_assign_any_member:
        direct_assignee_memberships = [
            membership
            for membership in memberships
            if membership.user_id != user_id and membership.role != "viewer"
        ]
    else:
        direct_assignee_memberships = [
            membership
            for membership in direct_report_memberships
            if membership.user_id != user_id and membership.role != "viewer"
        ]

    forward_manager_ids = {
        membership.user_id
        for membership in memberships
        if membership.user_id != user_id
        and membership.role != "viewer"
        and int(report_count_by_user_id.get(membership.user_id, 0) or 0) > 0
    }

    return {
        "allow_self_assign": True,
        "direct_assignees": _space_member_option_rows(
            db,
            space_id=sop.space_id,
            memberships=direct_assignee_memberships,
            report_count_by_user_id=report_count_by_user_id,
        ),
        "forward_managers": _space_member_option_rows(
            db,
            space_id=sop.space_id,
            memberships=memberships,
            report_count_by_user_id=report_count_by_user_id,
            user_ids=forward_manager_ids,
        ),
    }


def _resolve_run_assignment(
    db: Session,
    *,
    sop: Sop,
    user_id: str,
    assignee_user_id: str | None,
    forward_manager_user_id: str | None,
) -> tuple[str, str]:
    options = list_run_assignment_options(db, sop_id=sop.id, user_id=user_id)
    direct_assignee_ids = {
        str(row["user_id"]).strip()
        for row in options["direct_assignees"]
    }
    forward_manager_ids = {
        str(row["user_id"]).strip()
        for row in options["forward_managers"]
    }

    normalized_forward_manager_id = (forward_manager_user_id or "").strip()
    if normalized_forward_manager_id:
        if normalized_forward_manager_id not in forward_manager_ids:
            raise bad_request("Selected manager cannot receive this SOP run")
        return normalized_forward_manager_id, "forward"

    normalized_assignee_user_id = (assignee_user_id or "").strip()
    if not normalized_assignee_user_id or normalized_assignee_user_id == user_id:
        return user_id, "self"
    if normalized_assignee_user_id not in direct_assignee_ids:
        raise bad_request("Selected assignee cannot receive this SOP run")
    return normalized_assignee_user_id, "delegate"


def _sop_run_task_payload(
    *,
    sop: Sop,
    run: SopRun,
    assignment_mode: str,
) -> tuple[str, str]:
    if assignment_mode == "forward":
        title = f"Assign SOP run: {sop.title}"
        description = (
            f"A SOP run is waiting for team assignment.\n\n"
            f"Run ID: {run.id}\n"
            f"SOP: {sop.title}\n\n"
            f"Reassign this task to the operator who should execute the run, then "
            f"open the linked SOP run from tasks to continue."
        )
        return title[:240], description

    title = f"Run SOP: {sop.title}"
    description = (
        f"A SOP run has started and is now tracked as task work.\n\n"
        f"Run ID: {run.id}\n"
        f"SOP: {sop.title}\n\n"
        f"Open the linked SOP run from the task source to continue execution."
    )
    return title[:240], description


def ensure_run_task(
    db: Session,
    *,
    sop: Sop,
    run: SopRun,
    actor_user_id: str,
    assignee_user_id: str,
    assignment_mode: str,
):
    title, description = _sop_run_task_payload(
        sop=sop,
        run=run,
        assignment_mode=assignment_mode,
    )
    existing = tasks_service.get_task_by_source(
        db,
        source_kind="sop_run",
        source_id=sop.id,
        source_step_id=run.id,
    )
    if existing is None:
        return tasks_service.create_task(
            db,
            space_id=sop.space_id,
            title=title,
            description=description,
            status="todo",
            priority="high" if assignment_mode == "forward" else "medium",
            assignee_user_id=assignee_user_id,
            created_by=actor_user_id,
            source_kind="sop_run",
            source_id=sop.id,
            source_step_id=run.id,
            due_at=None,
        )

    next_status = existing.status
    if next_status == "done":
        next_status = "todo"
    return tasks_service.update_task(
        db,
        existing.id,
        actor_user_id=actor_user_id,
        title=title,
        description=description,
        status=next_status,
        priority="high" if assignment_mode == "forward" else "medium",
        assignee_user_id=assignee_user_id,
        apply_assignee_user_id=True,
        source_kind="sop_run",
        source_id=sop.id,
        source_step_id=run.id,
        apply_source_link=True,
        due_at=existing.due_at,
        apply_due_at=False,
    )


def start_run_with_task(
    db: Session,
    *,
    user_id: str,
    sop_id: str,
    assignee_user_id: str | None = None,
    forward_manager_user_id: str | None = None,
):
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    assigned_user_id, assignment_mode = _resolve_run_assignment(
        db,
        sop=sop,
        user_id=user_id,
        assignee_user_id=assignee_user_id,
        forward_manager_user_id=forward_manager_user_id,
    )
    run = start_run(db, user_id=user_id, sop_id=sop_id)
    task = ensure_run_task(
        db,
        sop=sop,
        run=run,
        actor_user_id=user_id,
        assignee_user_id=assigned_user_id,
        assignment_mode=assignment_mode,
    )
    return run, task, assigned_user_id, assignment_mode


def start_run(db: Session, *, user_id: str, sop_id: str) -> SopRun:
    sop = get(db, sop_id)
    if not sop:
        raise not_found("SOP not found")
    if _is_archived(_ensure_meta(db, sop.id)):
        raise bad_request("Restore this SOP before starting a run")
    if sop.status != "published":
        raise bad_request("Only published SOPs can be run")
    active = get_active_run(db, sop_id)
    if active:
        return active
    run = SopRun(
        id=str(uuid.uuid4()), sop_id=sop_id, status="in_progress", started_by=user_id
    )
    db.add(run)
    db.flush()
    step_rows = list_steps(db, sop_id)
    step_meta_map = _get_step_meta_map(db, [step.id for step in step_rows])
    step_rule_map = _get_step_rule_map(db, [step.id for step in step_rows])
    for step in step_rows:
        rule = step_rule_map.get(step.id)
        step_meta = step_meta_map.get(step.id)
        db.add(
            SopRunStep(
                id=str(uuid.uuid4()),
                run_id=run.id,
                step_id=step.id,
                step_order=step.step_order,
                title=step.title,
                evidence_required=step_meta.requires_evidence if step_meta else False,
                completed=False,
                completed_at=None,
                completed_by=None,
                evidence_note="",
                evidence_min_files=rule.min_file_count if rule else 0,
                evidence_allowed_extensions_csv=rule.allowed_extensions_csv
                if rule
                else "",
            )
        )
    db.commit()
    tasks_service.mark_sop_execution_started(db, sop_id=sop_id, started_at=_now_utc())
    db.refresh(run)
    return run


def update_run_step(
    db: Session,
    *,
    user_id: str,
    run_id: str,
    run_step_id: str,
    completed: bool | None = None,
    evidence_note: str | None = None,
) -> SopRunStep:
    run = get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    if run.status != "in_progress":
        raise bad_request("Run is already completed")
    step = db.get(SopRunStep, run_step_id)
    if not step or step.run_id != run_id:
        raise not_found("Run step not found")
    if evidence_note is not None:
        step.evidence_note = evidence_note.strip()
    if completed is not None:
        if completed:
            _validate_run_step_evidence(db, step)
            step.completed = True
            step.completed_at = _now_utc()
            step.completed_by = user_id
        else:
            step.completed = False
            step.completed_at = None
            step.completed_by = None
    db.commit()
    db.refresh(step)
    return step


def complete_run(db: Session, *, run_id: str) -> SopRun:
    run = get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    if run.status != "in_progress":
        return run
    steps = list_run_steps(db, run_id)
    for step in steps:
        if not step.completed:
            raise bad_request(
                "All SOP steps must be completed before finishing this run"
            )
        _validate_run_step_evidence(db, step)
    run.status = "completed"
    run.completed_at = _now_utc()
    meta = _ensure_meta(db, run.sop_id)
    meta.last_reviewed_at = run.completed_at
    db.commit()
    run_task = tasks_service.get_task_by_source(
        db,
        source_kind="sop_run",
        source_id=run.sop_id,
        source_step_id=run.id,
    )
    if run_task is not None and run_task.status != "done":
        tasks_service.update_task(
            db,
            run_task.id,
            actor_user_id=run.started_by,
            status="done",
        )
    db.refresh(run)
    return run


def export_run_audit(db: Session, *, run_id: str) -> SopRunAuditOut:
    run = get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    steps = list_run_steps(db, run_id)
    follow_ups = _follow_up_map(db, [step.id for step in steps])
    follow_up_tasks = _follow_up_task_map(
        db,
        sop_id=sop.id,
        source_step_ids=[step.step_id for step in steps if step.step_id],
    )
    lines = [
        f"SOP Run Audit: {sop.title}",
        f"Run ID: {run.id}",
        f"Status: {run.status}",
        f"Started: {run.started_at.isoformat()}",
        f"Completed: {run.completed_at.isoformat() if run.completed_at else 'in progress'}",
        "",
    ]
    html_rows: list[str] = []
    for step in steps:
        follow_up = follow_ups.get(step.id)
        follow_up_task_id = follow_up_tasks.get((step.step_id or "").strip())
        lines.extend(
            [
                f"{step.step_order}. {step.title}",
                f"   Completed: {'yes' if step.completed else 'no'}",
                f"   Evidence note: {step.evidence_note or 'n/a'}",
                f"   Evidence files required: {step.evidence_min_files}",
                f"   Allowed file types: {', '.join(_extensions_from_csv(step.evidence_allowed_extensions_csv)) or 'any'}",
                f"   Follow-up incident: {follow_up.incident_id if follow_up else 'none'}",
                f"   Follow-up task: {follow_up_task_id or 'none'}",
                "",
            ]
        )
        html_rows.append(
            "<tr>"
            f"<td>{step.step_order}</td>"
            f"<td>{html.escape(step.title)}</td>"
            f"<td>{'Yes' if step.completed else 'No'}</td>"
            f"<td>{html.escape(step.evidence_note or '')}</td>"
            f"<td>{html.escape(follow_up.incident_id if follow_up else '')}</td>"
            f"<td>{html.escape(follow_up_task_id or '')}</td>"
            "</tr>"
        )
    html_body = (
        f"<h1>SOP Run Audit: {html.escape(sop.title)}</h1>"
        f"<p>Run ID: {html.escape(run.id)}<br>Status: {html.escape(run.status)}</p>"
        "<table border='1' cellspacing='0' cellpadding='6'>"
        "<thead><tr><th>#</th><th>Step</th><th>Completed</th><th>Evidence Note</th><th>Follow-up Incident</th><th>Follow-up Task</th></tr></thead>"
        f"<tbody>{''.join(html_rows)}</tbody></table>"
    )
    return SopRunAuditOut(
        run_id=run.id,
        title=sop.title,
        text="\n".join(lines).strip(),
        html=html_body,
    )


def export_run_audit_csv(db: Session, *, run_id: str) -> str:
    run = get_run(db, run_id)
    if not run:
        raise not_found("Run not found")
    sop = get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    steps = list_run_steps(db, run_id)
    follow_ups = _follow_up_map(db, [step.id for step in steps])
    follow_up_tasks = _follow_up_task_map(
        db,
        sop_id=sop.id,
        source_step_ids=[step.step_id for step in steps if step.step_id],
    )

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["sop_title", sop.title])
    writer.writerow(["run_id", run.id])
    writer.writerow(["status", run.status])
    writer.writerow(["started_at", run.started_at.isoformat()])
    writer.writerow(
        ["completed_at", run.completed_at.isoformat() if run.completed_at else ""]
    )
    writer.writerow([])
    writer.writerow(
        [
            "step_order",
            "title",
            "completed",
            "completed_at",
            "completed_by",
            "evidence_required",
            "evidence_note",
            "evidence_min_files",
            "evidence_allowed_extensions",
            "follow_up_incident_id",
            "follow_up_task_id",
        ]
    )
    for step in steps:
        follow_up = follow_ups.get(step.id)
        follow_up_task_id = follow_up_tasks.get((step.step_id or "").strip())
        writer.writerow(
            [
                step.step_order,
                step.title,
                "yes" if step.completed else "no",
                step.completed_at.isoformat() if step.completed_at else "",
                step.completed_by or "",
                "yes" if step.evidence_required else "no",
                step.evidence_note,
                step.evidence_min_files,
                ",".join(_extensions_from_csv(step.evidence_allowed_extensions_csv)),
                follow_up.incident_id if follow_up else "",
                follow_up_task_id or "",
            ]
        )
    return output.getvalue()


def _pdf_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def export_run_audit_pdf_bytes(db: Session, *, run_id: str) -> bytes:
    audit = export_run_audit(db, run_id=run_id)
    lines = audit.text.splitlines() or [audit.title]
    content_lines = ["BT", "/F1 11 Tf", "50 780 Td"]
    first = True
    max_lines = 42
    for raw in lines[:max_lines]:
        safe = _pdf_escape(raw[:120])
        if not first:
            content_lines.append("0 -16 Td")
        content_lines.append(f"({safe}) Tj")
        first = False
    content_lines.append("ET")
    stream = "\n".join(content_lines).encode("latin-1", errors="replace")

    objects = [
        b"1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj",
        b"2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
        b"3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj",
        b"4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj",
        b"5 0 obj << /Length "
        + str(len(stream)).encode("ascii")
        + b" >> stream\n"
        + stream
        + b"\nendstream endobj",
    ]

    pdf = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for obj in objects:
        offsets.append(len(pdf))
        pdf.extend(obj)
        pdf.extend(b"\n")
    xref_offset = len(pdf)
    pdf.extend(f"xref\n0 {len(offsets)}\n".encode("ascii"))
    pdf.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        pdf.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    pdf.extend(
        (
            f"trailer << /Size {len(offsets)} /Root 1 0 R >>\n"
            f"startxref\n{xref_offset}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(pdf)


def process_due_reminders(db: Session) -> int:
    return tasks_service.process_due_sop_execution_reminders(db)


def create_follow_up_incident(
    db: Session,
    *,
    user_id: str,
    run_step_id: str,
    note_md: str = "",
) -> str:
    step = db.get(SopRunStep, run_step_id)
    if not step:
        raise not_found("Run step not found")
    existing = db.scalar(
        select(SopRunFollowUp).where(SopRunFollowUp.run_step_id == run_step_id)
    )
    if existing:
        return existing.incident_id
    run = get_run(db, step.run_id)
    if not run:
        raise not_found("Run not found")
    sop = get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")
    from app.modules.incidents import service as incident_service

    rule = db.get(SopStepEvidenceRule, step.step_id) if step.step_id else None

    sanitized_note = sanitize_rich_html(note_md)
    summary_parts = [
        f"<p>Follow-up created from SOP <strong>{html.escape(sop.title)}</strong>.</p>",
        f"<p>Run step: {step.step_order} • {html.escape(step.title)}</p>",
    ]
    if step.evidence_note.strip():
        summary_parts.append(
            f"<p>Operator note: {html.escape(step.evidence_note.strip())}</p>"
        )
    if sanitized_note:
        summary_parts.append(sanitized_note)
    follow_up_title = _normalize_follow_up_title(
        rule.follow_up_title_template if rule else None
    )
    if follow_up_title:
        try:
            incident_title = follow_up_title.format(
                sop_title=sop.title,
                step_title=step.title,
                step_order=step.step_order,
                run_id=run.id,
            )
        except Exception:
            incident_title = follow_up_title
    else:
        incident_title = f"Follow-up: {sop.title} • Step {step.step_order}"
    incident = incident_service.create(
        db,
        user_id,
        sop.space_id,
        incident_title,
        _normalize_severity(rule.follow_up_severity if rule else 3),
        "".join(summary_parts),
        "",
    )
    incident_service.create_link(
        db,
        user_id,
        incident.id,
        target_type="sop",
        target_id=sop.id,
        label=sop.title,
    )
    if rule and rule.follow_up_owner_user_id:
        incident_service.create_action_item(
            db,
            user_id,
            incident.id,
            title=f"Investigate SOP follow-up for step {step.step_order}",
            owner_user_id=rule.follow_up_owner_user_id,
            due_at=_now_utc() + timedelta(days=3),
            status="open",
            notes_md=step.evidence_note.strip() or sanitized_note,
        )
    follow_up = SopRunFollowUp(
        id=str(uuid.uuid4()),
        run_step_id=run_step_id,
        incident_id=incident.id,
        created_by=user_id,
    )
    db.add(follow_up)
    db.commit()
    return incident.id


def create_follow_up_task(
    db: Session,
    *,
    user_id: str,
    run_step_id: str,
) -> tuple[str, bool]:
    step = db.get(SopRunStep, run_step_id)
    if not step:
        raise not_found("Run step not found")
    if not step.step_id:
        raise bad_request("Run step is missing canonical SOP step linkage")

    run = get_run(db, step.run_id)
    if not run:
        raise not_found("Run not found")
    sop = get(db, run.sop_id)
    if not sop:
        raise not_found("SOP not found")

    existing = tasks_service.get_task_by_source(
        db,
        source_kind="sop_step",
        source_id=sop.id,
        source_step_id=step.step_id,
    )
    if existing:
        return existing.id, False

    rule = db.get(SopStepEvidenceRule, step.step_id)
    follow_up_title = _normalize_follow_up_title(
        rule.follow_up_title_template if rule else None
    )
    if follow_up_title:
        try:
            task_title = follow_up_title.format(
                sop_title=sop.title,
                step_title=step.title,
                step_order=step.step_order,
                run_id=run.id,
            )
        except Exception:
            task_title = follow_up_title
    else:
        task_title = f"Follow-up task: {sop.title} • Step {step.step_order}"

    description_lines = [
        f"SOP: {sop.title}",
        f"Run step: {step.step_order} - {step.title}",
    ]
    evidence_note = step.evidence_note.strip()
    if evidence_note:
        description_lines.append(f"Evidence note: {evidence_note}")
    description = "\n".join(description_lines)

    task = tasks_service.create_task(
        db,
        space_id=sop.space_id,
        title=task_title,
        description=description,
        status="todo",
        priority=_priority_from_severity(rule.follow_up_severity if rule else 3),
        assignee_user_id=rule.follow_up_owner_user_id if rule else None,
        created_by=user_id,
        source_kind="sop_step",
        source_id=sop.id,
        source_step_id=step.step_id,
        due_at=_now_utc() + timedelta(days=3),
    )
    return task.id, True
