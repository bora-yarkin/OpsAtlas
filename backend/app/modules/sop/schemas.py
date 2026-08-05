# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for SOP authoring, review, and run workflows."""

from datetime import datetime

from pydantic import BaseModel, Field


class SopOut(BaseModel):
    id: str
    space_id: str
    folder_id: str | None = None
    folder_path: str | None = None
    title: str
    slug: str
    status: str
    overview_md: str
    created_at: datetime | None = None
    updated_at: datetime | None = None
    review_due_at: datetime | None = None
    last_reviewed_at: datetime | None = None
    reviewer_user_id: str | None = None
    reviewer_name: str | None = None
    requires_approval: bool = False
    approved_at: datetime | None = None
    approved_by: str | None = None
    pending_approval: bool = False
    pending_approval_stage_order: int | None = None
    archived_at: datetime | None = None
    archived_by: str | None = None
    last_run_at: datetime | None = None
    linked_task_count: int = 0


class SopCreateIn(BaseModel):
    space_id: str
    folder_id: str | None = None
    title: str
    slug: str
    overview_md: str = ""
    review_due_at: datetime | None = None
    reviewer_user_id: str | None = None
    requires_approval: bool = False


class SopUpdateIn(BaseModel):
    title: str
    slug: str
    overview_md: str
    folder_id: str | None = None
    review_due_at: datetime | None = None
    reviewer_user_id: str | None = None
    requires_approval: bool = False


class SopMetaUpdateIn(BaseModel):
    review_due_at: datetime | None = None
    reviewer_user_id: str | None = None
    requires_approval: bool | None = None


class SopStepOut(BaseModel):
    id: str
    sop_id: str
    step_order: int
    title: str
    body_md: str
    requires_evidence: bool = False
    evidence_min_files: int = 0
    evidence_allowed_extensions: list[str] = Field(default_factory=list)
    follow_up_severity: int = 3
    follow_up_owner_user_id: str | None = None
    follow_up_owner_name: str | None = None
    follow_up_title_template: str = ""


class SopStepIn(BaseModel):
    step_order: int
    title: str
    body_md: str = ""
    requires_evidence: bool = False
    evidence_min_files: int = 0
    evidence_allowed_extensions: list[str] = Field(default_factory=list)
    follow_up_severity: int = 3
    follow_up_owner_user_id: str | None = None
    follow_up_title_template: str = ""


class SopApprovalStageIn(BaseModel):
    stage_order: int
    approver_user_id: str
    label: str = ""
    delegate_approver_user_id: str | None = None
    delegate_start_at: datetime | None = None
    delegate_end_at: datetime | None = None


class SopApprovalStageOut(BaseModel):
    id: str
    sop_id: str
    stage_order: int
    approver_user_id: str
    approver_name: str | None = None
    label: str = ""
    delegate_approver_user_id: str | None = None
    delegate_approver_name: str | None = None
    delegate_start_at: datetime | None = None
    delegate_end_at: datetime | None = None
    effective_approver_user_id: str | None = None
    effective_approver_name: str | None = None
    delegate_active: bool = False
    approved_at: datetime | None = None
    approved_by: str | None = None
    approved_by_name: str | None = None


class SopApprovalDecisionOut(BaseModel):
    id: str
    sop_id: str
    stage_id: str
    approved_by: str
    approved_by_name: str | None = None
    approved_at: datetime
    decision_type: str = "approve"
    note_md: str = ""


class SopApprovalDecisionIn(BaseModel):
    decision_type: str = Field(default="approve", min_length=3, max_length=30)
    note_md: str = ""


class SopRunScheduleIn(BaseModel):
    cadence_days: int = 7
    next_due_at: datetime | None = None
    operator_user_id: str | None = None
    enabled: bool = True
    reminder_channels: list[str] = Field(default_factory=lambda: ["in_app"])


class SopReminderDispatchOut(BaseModel):
    id: str
    channel: str
    recipient_user_id: str | None = None
    recipient_name: str | None = None
    created_at: datetime
    delivered_at: datetime | None = None
    payload_json: str = "{}"


class SopRunScheduleOut(BaseModel):
    id: str
    sop_id: str
    cadence_days: int
    next_due_at: datetime | None = None
    operator_user_id: str | None = None
    operator_name: str | None = None
    enabled: bool = True
    last_started_at: datetime | None = None
    reminder_channels: list[str] = Field(default_factory=list)
    last_reminder_sent_at: datetime | None = None
    overdue: bool = False
    recent_dispatches: list[SopReminderDispatchOut] = Field(default_factory=list)


class SopRunStepOut(BaseModel):
    id: str
    run_id: str
    step_id: str | None = None
    step_order: int
    title: str
    evidence_required: bool = False
    completed: bool = False
    completed_at: datetime | None = None
    completed_by: str | None = None
    evidence_note: str = ""
    evidence_min_files: int = 0
    evidence_allowed_extensions: list[str] = Field(default_factory=list)
    follow_up_incident_id: str | None = None
    follow_up_task_id: str | None = None


class SopRunStartIn(BaseModel):
    assignee_user_id: str | None = None
    forward_manager_user_id: str | None = None


class SopRunAssignmentOptionOut(BaseModel):
    user_id: str
    name: str
    email: str
    role: str
    report_count: int = 0
    is_manager: bool = False


class SopRunAssignmentOptionsOut(BaseModel):
    allow_self_assign: bool = True
    direct_assignees: list[SopRunAssignmentOptionOut] = Field(default_factory=list)
    forward_managers: list[SopRunAssignmentOptionOut] = Field(default_factory=list)


class SopRunOut(BaseModel):
    id: str
    sop_id: str
    status: str
    started_by: str
    started_at: datetime
    completed_at: datetime | None = None
    steps: list[SopRunStepOut] = Field(default_factory=list)


class SopRunStepUpdateIn(BaseModel):
    completed: bool | None = None
    evidence_note: str | None = None


class SopRunAuditOut(BaseModel):
    run_id: str
    title: str
    text: str
    html: str


class SopRunStartOut(BaseModel):
    run: SopRunOut
    task_id: str | None = None
    assigned_user_id: str | None = None
    assignment_mode: str = "self"


class SopDetailOut(SopOut):
    steps: list[SopStepOut]
    runs: list[SopRunOut] = Field(default_factory=list)
    approval_stages: list[SopApprovalStageOut] = Field(default_factory=list)
    sign_off_history: list[SopApprovalDecisionOut] = Field(default_factory=list)
    run_schedules: list[SopRunScheduleOut] = Field(default_factory=list)
