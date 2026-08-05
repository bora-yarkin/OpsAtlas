# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for task management APIs."""

from datetime import datetime

from pydantic import BaseModel, Field


class TaskChecklistItemOut(BaseModel):
    id: str
    label: str
    completed: bool = False


class TaskChecklistItemIn(BaseModel):
    id: str | None = Field(default=None, max_length=64)
    label: str = Field(min_length=1, max_length=240)
    completed: bool = False


class TaskOut(BaseModel):
    id: str
    space_id: str
    title: str
    description: str | None = None
    status: str
    priority: str
    assignee_user_id: str | None = None
    created_by: str
    source_kind: str | None = None
    source_id: str | None = None
    source_step_id: str | None = None
    checklist: list[TaskChecklistItemOut] = Field(default_factory=list)
    due_at: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class TaskCreateIn(BaseModel):
    space_id: str
    title: str = Field(min_length=1, max_length=240)
    description: str | None = Field(default=None, max_length=4000)
    status: str = Field(default="todo", min_length=1, max_length=32)
    priority: str = Field(default="medium", min_length=1, max_length=32)
    assignee_user_id: str | None = None
    source_kind: str | None = Field(default=None, min_length=1, max_length=40)
    source_id: str | None = None
    source_step_id: str | None = None
    checklist: list[TaskChecklistItemIn] = Field(default_factory=list, max_length=40)
    due_at: datetime | None = None


class TaskUpdateIn(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=240)
    description: str | None = Field(default=None, max_length=4000)
    status: str | None = Field(default=None, min_length=1, max_length=32)
    priority: str | None = Field(default=None, min_length=1, max_length=32)
    assignee_user_id: str | None = None
    source_kind: str | None = Field(default=None, min_length=1, max_length=40)
    source_id: str | None = None
    source_step_id: str | None = None
    checklist: list[TaskChecklistItemIn] | None = Field(default=None, max_length=40)
    due_at: datetime | None = None


class TaskCommentOut(BaseModel):
    id: str
    task_id: str
    space_id: str
    author_user_id: str
    author_name: str | None = None
    body: str
    created_at: datetime | None = None
    updated_at: datetime | None = None


class TaskCommentCreateIn(BaseModel):
    body: str = Field(min_length=1, max_length=8000)
