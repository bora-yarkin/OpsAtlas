# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for analytics APIs."""

from pydantic import BaseModel, Field
from datetime import datetime

class TrackEventIn(BaseModel):
    session_id: str
    event_type: str
    space_id: str | None = None
    entity_type: str | None = None
    entity_id: str | None = None
    path: str | None = None
    meta: dict[str, object] = Field(default_factory=dict)

class TopEntityOut(BaseModel):
    entity_type: str
    entity_id: str
    views: int
    title: str | None = None
    slug: str | None = None
    path: str | None = None


class ActivityEventOut(BaseModel):
    id: str
    ts: datetime
    user_id: str | None = None
    actor_name: str | None = None
    event_type: str
    space_id: str | None = None
    space_name: str | None = None
    entity_type: str | None = None
    entity_id: str | None = None
    entity_title: str | None = None
    detail_text: str | None = None
    path: str | None = None
    meta: dict[str, object] = Field(default_factory=dict)


class AnalyticsSearchQualityOut(BaseModel):
    query_count: int
    queries_with_diagnostics: int
    parse_diagnostic_rate: float
    suggestion_acceptance_count: int
    suggestion_acceptance_rate: float
    zero_result_session_count: int
    recovered_zero_result_session_count: int
    zero_result_recovery_rate: float
    average_refinement_depth: float


class AnalyticsTrendPointOut(BaseModel):
    bucket_start: datetime
    bucket_label: str
    count: int
