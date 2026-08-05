# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for space and membership APIs."""

from pydantic import BaseModel

class SpaceOut(BaseModel):
    id: str
    name: str
    slug: str
    region_code: str | None = None
    meta: dict[str, object] | None = None
    member_count: int = 0
    active_incident_count: int = 0
    open_task_count: int = 0

class SpaceCreateIn(BaseModel):
    name: str
    slug: str
    region_code: str | None = None
    meta: dict[str, object] | None = None

class SpaceMemberOut(BaseModel):
    user_id: str
    role: str


class SpaceMemberDetailOut(BaseModel):
    user_id: str
    role: str
    name: str
    email: str
    report_count: int = 0
    is_manager: bool = False
