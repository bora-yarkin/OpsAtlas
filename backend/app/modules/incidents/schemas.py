# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Pydantic payloads for incident management APIs."""

from datetime import datetime

from pydantic import BaseModel


class IncidentOut(BaseModel):
    id: str
    space_id: str
    folder_id: str | None = None
    folder_path: str | None = None
    title: str
    status: str
    severity: int
    summary_md: str
    created_by: str
    created_at: datetime
    open_action_items: int = 0
    linked_entities: int = 0
    linked_task_count: int = 0
    pinned_timeline_events: int = 0
    archived: bool = False
    incident_type: str = "service"
    on_call_user_id: str | None = None
    on_call_user_name: str | None = None
    escalation_policy: str = "standard"
    escalation_status: str = "normal"
    blast_radius_summary: str = ""


class IncidentCreateIn(BaseModel):
    space_id: str
    folder_id: str | None = None
    title: str = ""
    severity: int | None = 3
    incident_type: str = "service"
    template_id: str | None = None
    summary_md: str = ""
    postmortem_md: str = ""


class IncidentUpdateIn(BaseModel):
    title: str
    status: str
    severity: int
    folder_id: str | None = None
    incident_type: str | None = None
    summary_md: str
    transition_note: str = ""


class IncidentProfileUpdateIn(BaseModel):
    incident_type: str | None = None
    on_call_user_id: str | None = None
    escalation_policy: str | None = None
    escalation_status: str | None = None
    escalation_notes: str | None = None
    blast_radius_summary: str | None = None
    public_status_enabled: bool | None = None
    private_status_enabled: bool | None = None


class IncidentMetaUpdateIn(BaseModel):
    postmortem_md: str


class TimelineOut(BaseModel):
    id: str
    incident_id: str
    ts: datetime
    entry_md: str
    created_by: str
    created_by_name: str | None = None
    category: str = "update"
    pinned: bool = False


class TimelineCreateIn(BaseModel):
    entry_md: str
    category: str = "update"
    pinned: bool = False


class TimelineUpdateIn(BaseModel):
    entry_md: str | None = None
    category: str | None = None
    pinned: bool | None = None


class IncidentImpactServiceOut(BaseModel):
    id: str
    incident_id: str
    service_name: str
    impact_level: str
    blast_radius: str
    customer_facing: bool
    notes_md: str
    created_by: str
    created_at: datetime
    updated_at: datetime | None = None


class IncidentImpactServiceIn(BaseModel):
    service_name: str
    impact_level: str = "degraded"
    blast_radius: str = "single-service"
    customer_facing: bool = True
    notes_md: str = ""


class IncidentStatusUpdateOut(BaseModel):
    id: str
    incident_id: str
    stream_type: str
    status: str
    message_md: str
    created_by: str
    created_by_name: str | None = None
    created_at: datetime


class IncidentStatusUpdateIn(BaseModel):
    stream_type: str = "private"
    status: str = "update"
    message_md: str


class IncidentTemplateOut(BaseModel):
    id: str
    space_id: str | None = None
    name: str
    incident_type: str
    severity: int
    title_template: str
    summary_template_md: str
    postmortem_template_md: str
    default_impacts: list[IncidentImpactServiceIn] = []
    active: bool
    created_by: str
    created_at: datetime
    updated_at: datetime | None = None


class IncidentTemplateIn(BaseModel):
    name: str
    incident_type: str = "service"
    severity: int = 3
    title_template: str = ""
    summary_template_md: str = ""
    postmortem_template_md: str = ""
    default_impacts: list[IncidentImpactServiceIn] = []
    active: bool = True


class IncidentActionReminderOut(BaseModel):
    id: str
    incident_id: str
    action_item_id: str
    owner_user_id: str | None = None
    owner_name: str | None = None
    reminder_key: str
    channel: str
    due_at_snapshot: datetime | None = None
    created_at: datetime


class IncidentReportOut(BaseModel):
    title: str
    text: str


class IncidentActionItemOut(BaseModel):
    id: str
    incident_id: str
    title: str
    owner_user_id: str | None = None
    owner_name: str | None = None
    due_at: datetime | None = None
    status: str
    notes_md: str
    created_by: str
    created_at: datetime
    completed_at: datetime | None = None
    linked_task_id: str | None = None


class IncidentActionItemIn(BaseModel):
    title: str
    owner_user_id: str | None = None
    due_at: datetime | None = None
    status: str = "open"
    notes_md: str = ""


class IncidentLinkOut(BaseModel):
    id: str
    incident_id: str
    target_type: str
    target_id: str
    title: str
    slug: str | None = None
    label: str = ""
    created_by: str
    created_at: datetime


class IncidentLinkIn(BaseModel):
    target_type: str
    target_id: str
    label: str = ""


class IncidentStatusTransitionOut(BaseModel):
    id: str
    incident_id: str
    from_status: str | None = None
    to_status: str
    note_md: str
    changed_by: str
    changed_by_name: str | None = None
    changed_at: datetime


class IncidentAnalyticsOut(BaseModel):
    mttr_minutes: int | None = None
    transition_count: int = 0
    open_action_items: int = 0
    linked_entities: int = 0
    pinned_timeline_events: int = 0


class IncidentSpaceAnalyticsOut(BaseModel):
    total_incidents: int
    open_incidents: int
    monitoring_incidents: int
    resolved_incidents: int
    avg_mttr_minutes: int | None = None
    severity_1: int = 0
    severity_2: int = 0
    severity_3: int = 0
    severity_4: int = 0


class IncidentDetailOut(IncidentOut):
    postmortem_md: str
    timeline: list[TimelineOut]
    action_items: list[IncidentActionItemOut]
    links: list[IncidentLinkOut]
    status_history: list[IncidentStatusTransitionOut]
    status_updates: list[IncidentStatusUpdateOut]
    impacted_services: list[IncidentImpactServiceOut]
    reminders: list[IncidentActionReminderOut]
    template_id: str | None = None
    template_name: str | None = None
    escalation_notes: str = ""
    public_status_enabled: bool = True
    private_status_enabled: bool = True
    analytics: IncidentAnalyticsOut
