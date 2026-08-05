# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for SOP definitions, schedules, approvals, and execution runs."""

from datetime import datetime

from sqlalchemy import Boolean, String, DateTime, func, ForeignKey, Text, Integer, Index
from sqlalchemy.orm import Mapped, mapped_column
from app.core.db import Base


class Sop(Base):
    __tablename__ = "sops"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    folder_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("folders.id"), index=True, nullable=True)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    slug: Mapped[str] = mapped_column(String(300), index=True, nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False, default="draft")
    overview_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    updated_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

Index("ix_sops_space_slug", Sop.space_id, Sop.slug, unique=True)

class SopStep(Base):
    __tablename__ = "sop_steps"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), index=True, nullable=False)
    step_order: Mapped[int] = mapped_column(Integer, nullable=False)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    body_md: Mapped[str] = mapped_column(Text, nullable=False, default="")


class SopMeta(Base):
    __tablename__ = "sop_meta"
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), primary_key=True)
    review_due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    last_reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reviewer_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    requires_approval: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    approved_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    archived_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)


class SopStepMeta(Base):
    __tablename__ = "sop_step_meta"
    step_id: Mapped[str] = mapped_column(String(36), ForeignKey("sop_steps.id"), primary_key=True)
    requires_evidence: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class SopRun(Base):
    __tablename__ = "sop_runs"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), index=True, nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False, default="in_progress")
    started_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class SopRunStep(Base):
    __tablename__ = "sop_run_steps"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    run_id: Mapped[str] = mapped_column(String(36), ForeignKey("sop_runs.id"), index=True, nullable=False)
    step_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    step_order: Mapped[int] = mapped_column(Integer, nullable=False)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    evidence_required: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    completed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    completed_by: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    evidence_note: Mapped[str] = mapped_column(Text, nullable=False, default="")
    evidence_min_files: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    evidence_allowed_extensions_csv: Mapped[str] = mapped_column(Text, nullable=False, default="")


class SopStepEvidenceRule(Base):
    __tablename__ = "sop_step_evidence_rules"
    step_id: Mapped[str] = mapped_column(String(36), ForeignKey("sop_steps.id"), primary_key=True)
    min_file_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    allowed_extensions_csv: Mapped[str] = mapped_column(Text, nullable=False, default="")
    follow_up_severity: Mapped[int] = mapped_column(Integer, nullable=False, default=3)
    follow_up_owner_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    follow_up_title_template: Mapped[str] = mapped_column(Text, nullable=False, default="")


class SopApprovalStage(Base):
    __tablename__ = "sop_approval_stages"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), index=True, nullable=False)
    stage_order: Mapped[int] = mapped_column(Integer, nullable=False)
    approver_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    label: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    delegate_approver_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    delegate_start_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    delegate_end_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class SopApprovalDecision(Base):
    __tablename__ = "sop_approval_decisions"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), index=True, nullable=False)
    stage_id: Mapped[str] = mapped_column(String(36), ForeignKey("sop_approval_stages.id"), index=True, nullable=False)
    approved_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    approved_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    decision_type: Mapped[str] = mapped_column(String(30), nullable=False, default="approve")
    note_md: Mapped[str] = mapped_column(Text, nullable=False, default="")


class SopRunSchedule(Base):
    __tablename__ = "sop_run_schedules"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), index=True, nullable=False)
    cadence_days: Mapped[int] = mapped_column(Integer, nullable=False, default=7)
    next_due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    operator_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    last_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reminder_channels_csv: Mapped[str] = mapped_column(Text, nullable=False, default="in_app")
    last_reminder_sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class SopReminderDispatch(Base):
    __tablename__ = "sop_reminder_dispatches"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    sop_id: Mapped[str] = mapped_column(String(36), ForeignKey("sops.id"), index=True, nullable=False)
    schedule_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("sop_run_schedules.id"), index=True, nullable=True)
    recipient_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    channel: Mapped[str] = mapped_column(String(30), nullable=False)
    payload_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class SopRunFollowUp(Base):
    __tablename__ = "sop_run_follow_ups"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    run_step_id: Mapped[str] = mapped_column(String(36), ForeignKey("sop_run_steps.id"), index=True, nullable=False)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), index=True, nullable=False)
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
