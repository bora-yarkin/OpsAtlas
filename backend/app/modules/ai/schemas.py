# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for AI-assisted backend workflows."""

from pydantic import BaseModel, Field


class AiStatusOut(BaseModel):
    enabled: bool
    provider: str
    rate_limit_per_minute: int
    max_input_chars: int


class AiTextIn(BaseModel):
    text: str = Field(min_length=1)


class AiSummaryOut(BaseModel):
    summary: str
    provider: str


class DocSuggestIn(BaseModel):
    text: str = Field(min_length=1)
    existing_title: str | None = None
    max_tags: int = Field(default=5, ge=1, le=10)


class DocSuggestOut(BaseModel):
    title: str
    summary: str
    tags: list[str]
    provider: str


class IncidentPostmortemDraftIn(BaseModel):
    incident_title: str = Field(min_length=1, max_length=300)
    summary_md: str = ""
    timeline_items: list[str] = Field(default_factory=list)


class IncidentPostmortemDraftOut(BaseModel):
    title: str
    executive_summary: str
    postmortem_md: str
    suggested_action_items: list[str]
    provider: str
