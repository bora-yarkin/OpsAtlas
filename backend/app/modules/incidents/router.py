# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for incident reporting, tracking, and postmortem workflows."""

from collections.abc import Mapping
from typing import TypeVar, cast

from fastapi import APIRouter, Depends, Response
from sqlalchemy.orm import Session

from app.core.deps import get_db
from app.core.deps import bad_request, not_found
from app.modules.auth.models import User
from app.modules.auth.deps import get_current_user
from app.modules.localization import service as localization_service
from app.modules.spaces import service as spaces_service

from . import service
from .schemas import (
    IncidentActionItemIn,
    IncidentActionItemOut,
    IncidentActionReminderOut,
    IncidentCreateIn,
    IncidentDetailOut,
    IncidentImpactServiceIn,
    IncidentImpactServiceOut,
    IncidentLinkIn,
    IncidentLinkOut,
    IncidentMetaUpdateIn,
    IncidentOut,
    IncidentProfileUpdateIn,
    IncidentReportOut,
    IncidentSpaceAnalyticsOut,
    IncidentStatusUpdateIn,
    IncidentStatusUpdateOut,
    IncidentTemplateIn,
    IncidentTemplateOut,
    IncidentUpdateIn,
    TimelineCreateIn,
    TimelineOut,
    TimelineUpdateIn,
)

router = APIRouter(prefix="/incidents", tags=["incidents"])


_IncidentOutT = TypeVar("_IncidentOutT", IncidentOut, IncidentDetailOut)


def _localize_incident_out(
    row: _IncidentOutT,
    fields: Mapping[str, str] | None,
) -> _IncidentOutT:
    if not fields:
        return row
    updates: dict[str, str] = {}
    title = fields.get("title")
    if title is not None and title.strip():
        updates["title"] = title
    summary = fields.get("summary")
    if summary is not None and summary.strip():
        updates["summary_md"] = summary
    if not updates:
        return row
    return cast(_IncidentOutT, row.model_copy(update=updates))


def _localize_incident_detail_out(
    row: IncidentDetailOut,
    *,
    incident_fields: Mapping[str, str] | None,
    timeline_fields_by_id: Mapping[str, Mapping[str, str]] | None,
    action_item_fields_by_id: Mapping[str, Mapping[str, str]] | None,
) -> IncidentDetailOut:
    localized = _localize_incident_out(row, incident_fields)
    updates: dict[str, object] = {}

    if incident_fields:
        postmortem = incident_fields.get("postmortem")
        if postmortem is not None and postmortem.strip():
            updates["postmortem_md"] = postmortem

    if timeline_fields_by_id:
        timeline_changed = False
        localized_timeline = []
        for timeline_entry in localized.timeline:
            fields = timeline_fields_by_id.get(timeline_entry.id)
            if not fields:
                localized_timeline.append(timeline_entry)
                continue
            entry = fields.get("entry")
            if entry is not None and entry.strip():
                timeline_changed = True
                localized_timeline.append(
                    timeline_entry.model_copy(update={"entry_md": entry})
                )
            else:
                localized_timeline.append(timeline_entry)
        if timeline_changed:
            updates["timeline"] = localized_timeline

    if action_item_fields_by_id:
        action_items_changed = False
        localized_action_items = []
        for action_item in localized.action_items:
            fields = action_item_fields_by_id.get(action_item.id)
            if not fields:
                localized_action_items.append(action_item)
                continue
            action_updates: dict[str, str] = {}
            title = fields.get("title")
            if title is not None and title.strip():
                action_updates["title"] = title
            notes = fields.get("notes")
            if notes is not None and notes.strip():
                action_updates["notes_md"] = notes
            if action_updates:
                action_items_changed = True
                localized_action_items.append(action_item.model_copy(update=action_updates))
            else:
                localized_action_items.append(action_item)
        if action_items_changed:
            updates["action_items"] = localized_action_items

    return localized.model_copy(update=updates) if updates else localized


def _load_localized_incident_detail(
    db: Session,
    *,
    user_id: str,
    detail: IncidentDetailOut,
) -> IncidentDetailOut:
    incident_fields = localization_service.localized_fields_for_content(
        db,
        content_kind="incident",
        content_id=detail.id,
        field_keys=["title", "summary", "postmortem"],
        user_id=user_id,
    )
    timeline_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="incident_timeline",
        content_ids=[row.id for row in detail.timeline],
        field_keys=["entry"],
        user_id=user_id,
    )
    action_item_fields_by_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="incident_action_item",
        content_ids=[row.id for row in detail.action_items],
        field_keys=["title", "notes"],
        user_id=user_id,
    )
    return _localize_incident_detail_out(
        detail,
        incident_fields=incident_fields,
        timeline_fields_by_id=timeline_fields_by_id,
        action_item_fields_by_id=action_item_fields_by_id,
    )


@router.get("/spaces/{space_id}", response_model=list[IncidentOut])
def list_incidents(
    space_id: str,
    include_archived: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """List incidents in a space with localized titles and summaries."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_incidents(db, space_id, include_archived=include_archived)
    localized_by_incident_id = localization_service.localized_fields_for_contents(
        db,
        content_kind="incident",
        content_ids=[row.id for row in rows],
        field_keys=["title", "summary"],
        user_id=user.id,
    )
    return [
        _localize_incident_out(
            service.to_out(db, row),
            localized_by_incident_id.get(row.id, {}),
        )
        for row in rows
    ]


@router.get("/spaces/{space_id}/analytics", response_model=IncidentSpaceAnalyticsOut)
def incident_space_analytics(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return space-level incident metrics used by dashboards and review screens."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.get_space_analytics(db, space_id)


@router.get("/spaces/{space_id}/templates", response_model=list[IncidentTemplateOut])
def list_incident_templates(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """List incident templates available for the target space."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_templates(db, space_id=space_id, include_inactive=True)
    return [service._template_to_out(row) for row in rows]


@router.post("/spaces/{space_id}/templates", response_model=IncidentTemplateOut)
def create_incident_template(
    space_id: str,
    payload: IncidentTemplateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a reusable incident template for summary, postmortem, and defaults."""
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    row = service.create_template(
        db,
        user_id=user.id,
        space_id=space_id,
        name=payload.name,
        incident_type=payload.incident_type,
        severity=payload.severity,
        title_template=payload.title_template,
        summary_template_md=payload.summary_template_md,
        postmortem_template_md=payload.postmortem_template_md,
        default_impacts=payload.default_impacts,
        active=payload.active,
    )
    return service._template_to_out(row)


@router.put("/templates/{template_id}", response_model=IncidentTemplateOut)
def update_incident_template(
    template_id: str,
    payload: IncidentTemplateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update a space-scoped incident template used during incident creation."""
    current = service.get_template(db, template_id)
    if not current:
        raise not_found("Incident template not found")
    if not current.space_id:
        raise bad_request("Global templates are read-only")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    row = service.update_template(
        db,
        template_id=template_id,
        name=payload.name,
        incident_type=payload.incident_type,
        severity=payload.severity,
        title_template=payload.title_template,
        summary_template_md=payload.summary_template_md,
        postmortem_template_md=payload.postmortem_template_md,
        default_impacts=payload.default_impacts,
        active=payload.active,
    )
    return service._template_to_out(row)


@router.delete("/templates/{template_id}")
def delete_incident_template(
    template_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    current = service.get_template(db, template_id)
    if not current:
        raise not_found("Incident template not found")
    if not current.space_id:
        raise bad_request("Global templates are read-only")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    service.delete_template(db, template_id)
    return {"ok": True}


@router.post("", response_model=IncidentOut)
def create_incident(payload: IncidentCreateIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Create a new incident record, optionally seeded from a template."""
    spaces_service.require_space_role(db, payload.space_id, user.id, {"admin", "moderator", "member"})
    incident = service.create(
        db,
        user.id,
        payload.space_id,
        payload.title,
        payload.severity,
        payload.summary_md,
        payload.postmortem_md,
        payload.incident_type,
        payload.template_id,
        folder_id=payload.folder_id,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="incident",
        content_id=incident.id,
        field_keys=["title", "summary"],
        user_id=user.id,
    )
    return _localize_incident_out(service.to_out(db, incident), localized)


@router.get("/{incident_id}", response_model=IncidentDetailOut)
def get_incident(incident_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return the full incident detail payload used by the incident workspace."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    detail = service.get_detail(db, incident_id)
    return _load_localized_incident_detail(db, user_id=user.id, detail=detail)


@router.put("/{incident_id}", response_model=IncidentOut)
def update_incident(
    incident_id: str,
    payload: IncidentUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update core incident state such as status, severity, title, and summary."""
    current = service.get(db, incident_id)
    if not current:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    incident = service.update(
        db,
        user.id,
        incident_id,
        payload.title,
        payload.status,
        payload.severity,
        payload.folder_id,
        payload.incident_type,
        payload.summary_md,
        payload.transition_note,
    )
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="incident",
        content_id=incident.id,
        field_keys=["title", "summary"],
        user_id=user.id,
    )
    return _localize_incident_out(service.to_out(db, incident), localized)


@router.put("/{incident_id}/meta", response_model=IncidentDetailOut)
def update_incident_meta(
    incident_id: str,
    payload: IncidentMetaUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update postmortem-oriented incident metadata without rewriting other sections."""
    current = service.get(db, incident_id)
    if not current:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    service.update_meta(db, incident_id, payload.postmortem_md)
    detail = service.get_detail(db, incident_id)
    return _load_localized_incident_detail(db, user_id=user.id, detail=detail)


@router.put("/{incident_id}/profile", response_model=IncidentDetailOut)
def update_incident_profile(
    incident_id: str,
    payload: IncidentProfileUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Update structured profile fields that describe the incident beyond the timeline."""
    current = service.get(db, incident_id)
    if not current:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    service.update_profile(
        db,
        incident_id,
        incident_type=payload.incident_type,
        on_call_user_id=payload.on_call_user_id,
        escalation_policy=payload.escalation_policy,
        escalation_status=payload.escalation_status,
        escalation_notes=payload.escalation_notes,
        blast_radius_summary=payload.blast_radius_summary,
        public_status_enabled=payload.public_status_enabled,
        private_status_enabled=payload.private_status_enabled,
    )
    detail = service.get_detail(db, incident_id)
    return _load_localized_incident_detail(db, user_id=user.id, detail=detail)


@router.post("/{incident_id}/archive", response_model=IncidentOut)
def archive_incident(incident_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, incident_id)
    if not current:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    incident = service.archive_incident(db, user_id=user.id, incident_id=incident_id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="incident",
        content_id=incident.id,
        field_keys=["title", "summary"],
        user_id=user.id,
    )
    return _localize_incident_out(service.to_out(db, incident), localized)


@router.post("/{incident_id}/restore", response_model=IncidentOut)
def restore_incident(incident_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, incident_id)
    if not current:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator", "member"})
    incident = service.restore_incident(db, user_id=user.id, incident_id=incident_id)
    localized = localization_service.localized_fields_for_content(
        db,
        content_kind="incident",
        content_id=incident.id,
        field_keys=["title", "summary"],
        user_id=user.id,
    )
    return _localize_incident_out(service.to_out(db, incident), localized)


@router.delete("/{incident_id}")
def delete_incident(incident_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    current = service.get(db, incident_id)
    if not current:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, current.space_id, user.id, {"admin", "moderator"})
    service.delete_incident(db, incident_id)
    return {"ok": True}


@router.post("/{incident_id}/timeline", response_model=TimelineOut)
def add_timeline(
    incident_id: str,
    payload: TimelineCreateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Append a new timeline event to the incident chronology."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    row = service.add_timeline(
        db,
        user.id,
        incident_id,
        payload.entry_md,
        category=payload.category,
        pinned=payload.pinned,
    )
    detail = _load_localized_incident_detail(
        db,
        user_id=user.id,
        detail=service.get_detail(db, incident_id),
    )
    match = next((item for item in detail.timeline if item.id == row.id), None)
    if not match:
        raise not_found("Timeline entry not found")
    return match


@router.put("/{incident_id}/timeline/{timeline_id}", response_model=TimelineOut)
def update_timeline(
    incident_id: str,
    timeline_id: str,
    payload: TimelineUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    timeline = service.get_timeline_entry(db, timeline_id)
    if not timeline or timeline.incident_id != incident_id:
        raise not_found("Timeline entry not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    service.update_timeline(
        db,
        timeline_id,
        entry_md=payload.entry_md,
        category=payload.category,
        pinned=payload.pinned,
    )
    detail = _load_localized_incident_detail(
        db,
        user_id=user.id,
        detail=service.get_detail(db, incident_id),
    )
    match = next((item for item in detail.timeline if item.id == timeline_id), None)
    if not match:
        raise not_found("Timeline entry not found")
    return match


@router.delete("/{incident_id}/timeline/{timeline_id}")
def delete_timeline(
    incident_id: str,
    timeline_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    timeline = service.get_timeline_entry(db, timeline_id)
    if not timeline or timeline.incident_id != incident_id:
        raise not_found("Timeline entry not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    service.delete_timeline(db, timeline_id)
    return {"ok": True}


@router.post("/{incident_id}/action-items", response_model=IncidentActionItemOut)
def create_action_item(
    incident_id: str,
    payload: IncidentActionItemIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a follow-up action item owned by the incident workflow."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    item = service.create_action_item(
        db,
        user.id,
        incident_id,
        title=payload.title,
        owner_user_id=payload.owner_user_id,
        due_at=payload.due_at,
        status=payload.status,
        notes_md=payload.notes_md,
    )
    detail = _load_localized_incident_detail(
        db,
        user_id=user.id,
        detail=service.get_detail(db, incident_id),
    )
    match = next((row for row in detail.action_items if row.id == item.id), None)
    if not match:
        raise not_found("Action item not found")
    return match


@router.put("/{incident_id}/action-items/{action_item_id}", response_model=IncidentActionItemOut)
def update_action_item(
    incident_id: str,
    action_item_id: str,
    payload: IncidentActionItemIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    action_item = service.get_action_item(db, action_item_id)
    if not action_item or action_item.incident_id != incident_id:
        raise not_found("Action item not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    service.update_action_item(
        db,
        action_item_id,
        title=payload.title,
        owner_user_id=payload.owner_user_id,
        due_at=payload.due_at,
        status=payload.status,
        notes_md=payload.notes_md,
    )
    detail = _load_localized_incident_detail(
        db,
        user_id=user.id,
        detail=service.get_detail(db, incident_id),
    )
    match = next((row for row in detail.action_items if row.id == action_item_id), None)
    if not match:
        raise not_found("Action item not found")
    return match


@router.post("/{incident_id}/action-items/{action_item_id}/task")
def create_action_item_task(
    incident_id: str,
    action_item_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Materialize an incident action item as a standalone task record."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    action_item = service.get_action_item(db, action_item_id)
    if not action_item or action_item.incident_id != incident_id:
        raise not_found("Action item not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    task_id, created = service.create_task_for_action_item(
        db,
        user_id=user.id,
        incident_id=incident_id,
        action_item_id=action_item_id,
    )
    return {"task_id": task_id, "created": created}


@router.delete("/{incident_id}/action-items/{action_item_id}")
def delete_action_item(
    incident_id: str,
    action_item_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    action_item = service.get_action_item(db, action_item_id)
    if not action_item or action_item.incident_id != incident_id:
        raise not_found("Action item not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    service.delete_action_item(db, action_item_id)
    return {"ok": True}


@router.get("/{incident_id}/impacts", response_model=list[IncidentImpactServiceOut])
def list_incident_impacts(
    incident_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """List impacted services or surfaces associated with an incident."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_impacted_services(db, incident_id)
    return [service._impact_to_out(row) for row in rows]


@router.post("/{incident_id}/impacts", response_model=IncidentImpactServiceOut)
def create_incident_impact(
    incident_id: str,
    payload: IncidentImpactServiceIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Add an impacted service entry to the incident profile."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    row = service.create_impacted_service(
        db,
        user.id,
        incident_id,
        service_name=payload.service_name,
        impact_level=payload.impact_level,
        blast_radius=payload.blast_radius,
        customer_facing=payload.customer_facing,
        notes_md=payload.notes_md,
    )
    return service._impact_to_out(row)


@router.put("/{incident_id}/impacts/{impact_id}", response_model=IncidentImpactServiceOut)
def update_incident_impact(
    incident_id: str,
    impact_id: str,
    payload: IncidentImpactServiceIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    row = service.get_impact_service(db, impact_id)
    if not row or row.incident_id != incident_id:
        raise not_found("Impacted service not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    updated = service.update_impacted_service(
        db,
        impact_id,
        service_name=payload.service_name,
        impact_level=payload.impact_level,
        blast_radius=payload.blast_radius,
        customer_facing=payload.customer_facing,
        notes_md=payload.notes_md,
    )
    return service._impact_to_out(updated)


@router.delete("/{incident_id}/impacts/{impact_id}")
def delete_incident_impact(
    incident_id: str,
    impact_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    row = service.get_impact_service(db, impact_id)
    if not row or row.incident_id != incident_id:
        raise not_found("Impacted service not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    service.delete_impacted_service(db, impact_id)
    return {"ok": True}


@router.get("/{incident_id}/status-updates", response_model=list[IncidentStatusUpdateOut])
def list_incident_status_updates(
    incident_id: str,
    stream_type: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """List the externally or internally visible status updates for an incident."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_status_updates(db, incident_id, stream_type=stream_type)
    user_names = service._user_name_map(db, {row.created_by for row in rows})
    return [service._status_update_to_out(row, user_names=user_names) for row in rows]


@router.post("/{incident_id}/status-updates", response_model=IncidentStatusUpdateOut)
def create_incident_status_update(
    incident_id: str,
    payload: IncidentStatusUpdateIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Create a new status update and preserve it in incident history."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    row = service.add_status_update(
        db,
        user.id,
        incident_id,
        stream_type=payload.stream_type,
        status=payload.status,
        message_md=payload.message_md,
    )
    user_names = service._user_name_map(db, {row.created_by})
    return service._status_update_to_out(row, user_names=user_names)


@router.get("/{incident_id}/reminders", response_model=list[IncidentActionReminderOut])
def list_incident_reminders(
    incident_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Return reminder records tied to unresolved incident action items."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    rows = service.list_action_reminders(db, incident_id)
    user_names = service._user_name_map(db, {row.owner_user_id for row in rows if row.owner_user_id})
    return [service._reminder_to_out(row, user_names=user_names) for row in rows]


@router.post("/{incident_id}/links", response_model=IncidentLinkOut)
def create_incident_link(
    incident_id: str,
    payload: IncidentLinkIn,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    link = service.create_link(
        db,
        user.id,
        incident_id,
        target_type=payload.target_type,
        target_id=payload.target_id,
        label=payload.label,
    )
    detail = _load_localized_incident_detail(
        db,
        user_id=user.id,
        detail=service.get_detail(db, incident_id),
    )
    match = next((row for row in detail.links if row.id == link.id), None)
    if not match:
        raise not_found("Incident link not found")
    return match


@router.delete("/{incident_id}/links/{link_id}")
def delete_incident_link(
    incident_id: str,
    link_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    link = service.get_link(db, link_id)
    if not link or link.incident_id != incident_id:
        raise not_found("Incident link not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member"})
    service.delete_link(db, link_id)
    return {"ok": True}


@router.get("/{incident_id}/report", response_model=IncidentReportOut)
def get_incident_report(incident_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Return the structured incident report payload used for reporting and export."""
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    return service.export_incident_report(db, incident_id=incident_id)


@router.get("/{incident_id}/report.csv")
def export_incident_report_csv(
    incident_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    payload = service.export_incident_report_csv(db, incident_id=incident_id)
    return Response(
        content=payload,
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="incident-{incident_id}-report.csv"'
        },
    )


@router.get("/{incident_id}/report.pdf")
def export_incident_report_pdf(
    incident_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    payload = service.export_incident_report_pdf_bytes(db, incident_id=incident_id)
    return Response(
        content=payload,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="incident-{incident_id}-report.pdf"'},
    )


@router.get("/{incident_id}/postmortem.pdf")
def export_incident_postmortem_pdf(
    incident_id: str,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    incident = service.get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    spaces_service.require_space_role(db, incident.space_id, user.id, {"admin", "moderator", "member", "viewer"})
    payload = service.export_postmortem_pdf_bytes(db, incident_id=incident_id)
    return Response(
        content=payload,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="incident-{incident_id}-postmortem.pdf"'},
    )
