# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for tasks, assignees, and related task state."""

from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Task(Base):
    __tablename__ = "tasks"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(240), nullable=False)
    description: Mapped[str | None] = mapped_column(String(4000), nullable=True)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="todo")
    priority: Mapped[str] = mapped_column(String(32), nullable=False, default="medium")
    assignee_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    source_kind: Mapped[str | None] = mapped_column(String(40), nullable=True, index=True)
    source_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    source_step_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    checklist_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class TaskComment(Base):
    __tablename__ = "task_comments"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    task_id: Mapped[str] = mapped_column(String(36), ForeignKey("tasks.id"), index=True, nullable=False)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    author_user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class TaskExecutionProfile(Base):
    __tablename__ = "task_execution_profiles"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    source_kind: Mapped[str] = mapped_column(String(40), index=True, nullable=False, default="sop")
    source_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    source_step_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    title: Mapped[str] = mapped_column(String(240), nullable=False)
    cadence_days: Mapped[int] = mapped_column(Integer, nullable=False, default=7)
    next_due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    operator_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    last_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reminder_channels_csv: Mapped[str] = mapped_column(Text, nullable=False, default="in_app")
    last_reminder_sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class TaskReminderDispatch(Base):
    __tablename__ = "task_reminder_dispatches"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    profile_id: Mapped[str | None] = mapped_column(
        String(36),
        ForeignKey("task_execution_profiles.id"),
        index=True,
        nullable=True,
    )
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    source_kind: Mapped[str] = mapped_column(String(40), index=True, nullable=False)
    source_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    source_step_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    recipient_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    channel: Mapped[str] = mapped_column(String(30), nullable=False)
    payload_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
