# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for incident lifecycle, activity streams, and remediation tracking."""

import csv
import json
import re
import uuid
from collections.abc import Sequence
from datetime import datetime, timezone
from io import StringIO

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.core.deps import bad_request, not_found
from app.core.rich_html import sanitize_rich_html
from app.modules.auth.models import User
from app.modules.analytics.models import Event
from app.modules.kb import repo as kb_repo
from app.modules.kb.models import Doc
from app.modules.localization import service as localization_service
from app.modules.media import service as media_service
from app.modules.sop.models import Sop
from app.modules.tasks import service as tasks_service

from .models import (
    Incident,
    IncidentActionItem,
    IncidentActionReminder,
    IncidentImpactService,
    IncidentLink,
    IncidentMeta,
    IncidentProfile,
    IncidentStatusTransition,
    IncidentStatusUpdate,
    IncidentTemplate,
    IncidentTimeline,
    IncidentTimelineMeta,
)
from .schemas import (
    IncidentActionItemOut,
    IncidentActionReminderOut,
    IncidentAnalyticsOut,
    IncidentDetailOut,
    IncidentImpactServiceIn,
    IncidentImpactServiceOut,
    IncidentLinkOut,
    IncidentOut,
    IncidentReportOut,
    IncidentSpaceAnalyticsOut,
    IncidentStatusUpdateOut,
    IncidentTemplateOut,
    IncidentStatusTransitionOut,
    TimelineOut,
)

POSTMORTEM_TEMPLATE = """<h1>Summary</h1><p>Describe the incident impact and customer-facing symptoms.</p><h2>Impact</h2><ul><li>Who was affected?</li><li>What degraded or failed?</li></ul><h2>Detection</h2><p>How was the incident detected and escalated?</p><h2>Root Cause</h2><p>Document the technical and process root causes.</p><h2>Resolution</h2><p>Explain the mitigation and recovery steps.</p><h2>Follow-up</h2><ul><li>List the permanent fixes.</li><li>Link any SOP or KB updates.</li></ul>"""

VALID_STATUSES = {"open", "monitoring", "resolved"}
VALID_TIMELINE_CATEGORIES = {
    "update",
    "detection",
    "mitigation",
    "communication",
    "resolution",
    "follow_up",
}
VALID_ACTION_STATUSES = {"open", "in_progress", "blocked", "done"}
VALID_LINK_TARGETS = {"doc", "sop"}
VALID_INCIDENT_TYPES = {"service", "security", "infra", "product", "support", "other"}
VALID_ESCALATION_POLICIES = {"standard", "sev1", "sev2", "watch"}
VALID_ESCALATION_STATUSES = {"normal", "escalated", "bridge_open", "handoff"}
VALID_STREAM_TYPES = {"public", "private"}
VALID_IMPACT_LEVELS = {"outage", "degraded", "risk", "informational"}
VALID_BLAST_RADIUS = {"single-service", "multi-service", "regional", "global"}


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _normalize_status(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_STATUSES:
        raise bad_request("Invalid incident status")
    return normalized


def _normalize_timeline_category(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_TIMELINE_CATEGORIES:
        raise bad_request("Invalid timeline category")
    return normalized


def _normalize_action_status(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_ACTION_STATUSES:
        raise bad_request("Invalid action item status")
    return normalized


def _normalize_incident_type(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_INCIDENT_TYPES:
        raise bad_request("Invalid incident type")
    return normalized


def _normalize_escalation_policy(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_ESCALATION_POLICIES:
        raise bad_request("Invalid escalation policy")
    return normalized


def _normalize_escalation_status(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_ESCALATION_STATUSES:
        raise bad_request("Invalid escalation status")
    return normalized


def _normalize_stream_type(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_STREAM_TYPES:
        raise bad_request("Invalid stream type")
    return normalized


def _normalize_impact_level(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_IMPACT_LEVELS:
        raise bad_request("Invalid impact level")
    return normalized


def _normalize_blast_radius(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in VALID_BLAST_RADIUS:
        raise bad_request("Invalid blast radius")
    return normalized


def _ensure_user_exists(db: Session, user_id: str | None) -> str | None:
    if not user_id:
        return None
    user = db.get(User, user_id)
    if not user:
        raise bad_request("Assigned user not found")
    return user.id


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


def _ensure_meta(db: Session, incident_id: str) -> IncidentMeta:
    meta = db.get(IncidentMeta, incident_id)
    if meta:
        return meta
    meta = IncidentMeta(incident_id=incident_id, postmortem_md=POSTMORTEM_TEMPLATE)
    db.add(meta)
    db.flush()
    return meta


def _ensure_timeline_meta(db: Session, timeline_id: str) -> IncidentTimelineMeta:
    meta = db.get(IncidentTimelineMeta, timeline_id)
    if meta:
        return meta
    meta = IncidentTimelineMeta(
        timeline_id=timeline_id, category="update", pinned=False
    )
    db.add(meta)
    db.flush()
    return meta


def _ensure_profile(db: Session, incident_id: str) -> IncidentProfile:
    profile = db.get(IncidentProfile, incident_id)
    if profile:
        return profile
    profile = IncidentProfile(incident_id=incident_id)
    db.add(profile)
    db.flush()
    return profile


def _parse_template_impacts(raw: str | None) -> list[dict[str, object]]:
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    out: list[dict[str, object]] = []
    for item in decoded:
        if not isinstance(item, dict):
            continue
        service_name = str(item.get("service_name", "")).strip()
        if not service_name:
            continue
        out.append(
            {
                "service_name": service_name,
                "impact_level": str(item.get("impact_level", "degraded")),
                "blast_radius": str(item.get("blast_radius", "single-service")),
                "customer_facing": bool(item.get("customer_facing", True)),
                "notes_md": str(item.get("notes_md", "")),
            }
        )
    return out


def _template_impacts_json(items: list[dict[str, object]]) -> str:
    return json.dumps(items, ensure_ascii=False, separators=(",", ":"))


def _normalize_template_impacts(
    values: Sequence[IncidentImpactServiceIn | dict[str, object]],
) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for value in values:
        if isinstance(value, IncidentImpactServiceIn):
            service_name = value.service_name.strip()
            impact_level = value.impact_level
            blast_radius = value.blast_radius
            customer_facing = value.customer_facing
            notes_md = value.notes_md
        else:
            service_name = str(value.get("service_name", "")).strip()
            impact_level = str(value.get("impact_level", "degraded"))
            blast_radius = str(value.get("blast_radius", "single-service"))
            customer_facing = bool(value.get("customer_facing", True))
            notes_md = str(value.get("notes_md", ""))
        if not service_name:
            continue
        out.append(
            {
                "service_name": service_name[:220],
                "impact_level": _normalize_impact_level(impact_level),
                "blast_radius": _normalize_blast_radius(blast_radius),
                "customer_facing": customer_facing,
                "notes_md": notes_md.strip(),
            }
        )
    return out


def _strip_html(raw: str) -> str:
    text = raw
    text = re.sub(r"<\s*br\s*/?\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</\s*p\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", text)
    text = (
        text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
    )
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _safe_iso(value: datetime | None) -> str:
    if value is None:
        return "n/a"
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc).isoformat()
    return value.astimezone(timezone.utc).isoformat()


def _pdf_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _simple_pdf_bytes(lines: list[str]) -> bytes:
    page_lines = lines[:42] or ["Incident Report"]
    content_lines = ["BT", "/F1 11 Tf", "50 780 Td"]
    first = True
    for raw in page_lines:
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


def _user_name_map(db: Session, user_ids: set[str]) -> dict[str, str]:
    ids = {user_id for user_id in user_ids if user_id}
    if not ids:
        return {}
    rows = db.execute(select(User).where(User.id.in_(ids))).scalars().all()
    return {row.id: row.name or row.email for row in rows}


def _link_target_snapshot(
    db: Session, space_id: str, target_type: str, target_id: str
) -> tuple[str, str | None]:
    normalized_type = target_type.strip().lower()
    if normalized_type not in VALID_LINK_TARGETS:
        raise bad_request("Invalid link target type")
    if normalized_type == "doc":
        doc = db.get(Doc, target_id)
        if not doc or doc.space_id != space_id:
            raise bad_request("Doc not found in this space")
        return doc.title, doc.slug
    sop = db.get(Sop, target_id)
    if not sop or sop.space_id != space_id:
        raise bad_request("SOP not found in this space")
    return sop.title, sop.slug


def _record_transition(
    db: Session,
    incident_id: str,
    user_id: str,
    from_status: str | None,
    to_status: str,
    note_md: str = "",
) -> IncidentStatusTransition:
    transition = IncidentStatusTransition(
        id=str(uuid.uuid4()),
        incident_id=incident_id,
        from_status=from_status,
        to_status=to_status,
        note_md=note_md.strip(),
        changed_by=user_id,
    )
    db.add(transition)
    db.flush()
    return transition


def _mttr_minutes(
    incident: Incident, transitions: list[IncidentStatusTransition]
) -> int | None:
    resolved_transition = next(
        (row for row in transitions if row.to_status == "resolved"), None
    )
    if (
        not resolved_transition
        or not incident.created_at
        or not resolved_transition.changed_at
    ):
        return None
    delta = resolved_transition.changed_at - incident.created_at
    return max(0, int(delta.total_seconds() // 60))


def _timeline_to_out(
    timeline: IncidentTimeline,
    *,
    meta_map: dict[str, IncidentTimelineMeta],
    user_names: dict[str, str],
) -> TimelineOut:
    meta = meta_map.get(timeline.id)
    return TimelineOut(
        id=timeline.id,
        incident_id=timeline.incident_id,
        ts=timeline.ts,
        entry_md=timeline.entry_md,
        created_by=timeline.created_by,
        created_by_name=user_names.get(timeline.created_by),
        category=meta.category if meta else "update",
        pinned=meta.pinned if meta else False,
    )


def _action_item_to_out(
    action_item: IncidentActionItem,
    *,
    user_names: dict[str, str],
    linked_task_id: str | None,
) -> IncidentActionItemOut:
    return IncidentActionItemOut(
        id=action_item.id,
        incident_id=action_item.incident_id,
        title=action_item.title,
        owner_user_id=action_item.owner_user_id,
        owner_name=user_names.get(action_item.owner_user_id or ""),
        due_at=action_item.due_at,
        status=action_item.status,
        notes_md=action_item.notes_md,
        created_by=action_item.created_by,
        created_at=action_item.created_at,
        completed_at=action_item.completed_at,
        linked_task_id=linked_task_id,
    )


def _action_item_task_map(
    db: Session,
    *,
    incident_id: str,
    action_item_ids: Sequence[str],
) -> dict[str, str]:
    ids = {(action_item_id or "").strip() for action_item_id in action_item_ids}
    ids.discard("")
    if not ids:
        return {}

    rows = tasks_service.list_tasks_for_incident_source(db, incident_id=incident_id)
    out: dict[str, str] = {}
    for row in rows:
        if row.source_kind != "incident_action_item":
            continue
        action_item_id = (row.source_step_id or "").strip()
        if not action_item_id or action_item_id not in ids or action_item_id in out:
            continue
        out[action_item_id] = row.id
    return out


def _link_to_out(
    db: Session,
    incident: Incident,
    link: IncidentLink,
) -> IncidentLinkOut:
    title = link.label or f"Missing {link.target_type.upper()}"
    slug = None
    if link.target_type == "doc":
        doc = db.get(Doc, link.target_id)
        if doc and doc.space_id == incident.space_id:
            title = doc.title
            slug = doc.slug
    elif link.target_type == "sop":
        sop = db.get(Sop, link.target_id)
        if sop and sop.space_id == incident.space_id:
            title = sop.title
            slug = sop.slug
    return IncidentLinkOut(
        id=link.id,
        incident_id=link.incident_id,
        target_type=link.target_type,
        target_id=link.target_id,
        title=title,
        slug=slug,
        label=link.label,
        created_by=link.created_by,
        created_at=link.created_at,
    )


def _transition_to_out(
    transition: IncidentStatusTransition,
    *,
    user_names: dict[str, str],
) -> IncidentStatusTransitionOut:
    return IncidentStatusTransitionOut(
        id=transition.id,
        incident_id=transition.incident_id,
        from_status=transition.from_status,
        to_status=transition.to_status,
        note_md=transition.note_md,
        changed_by=transition.changed_by,
        changed_by_name=user_names.get(transition.changed_by),
        changed_at=transition.changed_at,
    )


def _impact_to_out(impact: IncidentImpactService) -> IncidentImpactServiceOut:
    return IncidentImpactServiceOut(
        id=impact.id,
        incident_id=impact.incident_id,
        service_name=impact.service_name,
        impact_level=impact.impact_level,
        blast_radius=impact.blast_radius,
        customer_facing=impact.customer_facing,
        notes_md=impact.notes_md,
        created_by=impact.created_by,
        created_at=impact.created_at,
        updated_at=impact.updated_at,
    )


def _status_update_to_out(
    update: IncidentStatusUpdate, *, user_names: dict[str, str]
) -> IncidentStatusUpdateOut:
    return IncidentStatusUpdateOut(
        id=update.id,
        incident_id=update.incident_id,
        stream_type=update.stream_type,
        status=update.status,
        message_md=update.message_md,
        created_by=update.created_by,
        created_by_name=user_names.get(update.created_by),
        created_at=update.created_at,
    )


def _reminder_to_out(
    reminder: IncidentActionReminder, *, user_names: dict[str, str]
) -> IncidentActionReminderOut:
    return IncidentActionReminderOut(
        id=reminder.id,
        incident_id=reminder.incident_id,
        action_item_id=reminder.action_item_id,
        owner_user_id=reminder.owner_user_id,
        owner_name=user_names.get(reminder.owner_user_id or ""),
        reminder_key=reminder.reminder_key,
        channel=reminder.channel,
        due_at_snapshot=reminder.due_at_snapshot,
        created_at=reminder.created_at,
    )


def _template_to_out(template: IncidentTemplate) -> IncidentTemplateOut:
    impacts = _parse_template_impacts(template.default_impacts_json)
    return IncidentTemplateOut(
        id=template.id,
        space_id=template.space_id,
        name=template.name,
        incident_type=template.incident_type,
        severity=template.severity,
        title_template=template.title_template,
        summary_template_md=template.summary_template_md,
        postmortem_template_md=template.postmortem_template_md,
        default_impacts=[
            IncidentImpactServiceIn(
                service_name=str(impact.get("service_name", "")).strip(),
                impact_level=str(impact.get("impact_level", "degraded")),
                blast_radius=str(impact.get("blast_radius", "single-service")),
                customer_facing=bool(impact.get("customer_facing", True)),
                notes_md=str(impact.get("notes_md", "")),
            )
            for impact in impacts
        ],
        active=template.active,
        created_by=template.created_by,
        created_at=template.created_at,
        updated_at=template.updated_at,
    )


def _analytics_to_out(
    incident: Incident,
    *,
    action_items: list[IncidentActionItem],
    links: list[IncidentLink],
    transitions: list[IncidentStatusTransition],
    timeline_meta_map: dict[str, IncidentTimelineMeta],
) -> IncidentAnalyticsOut:
    return IncidentAnalyticsOut(
        mttr_minutes=_mttr_minutes(incident, transitions),
        transition_count=len(transitions),
        open_action_items=sum(1 for item in action_items if item.status != "done"),
        linked_entities=len(links),
        pinned_timeline_events=sum(
            1 for meta in timeline_meta_map.values() if meta.pinned
        ),
    )


def to_out(db: Session, incident: Incident) -> IncidentOut:
    open_action_items = (
        db.scalar(
            select(func.count())
            .select_from(IncidentActionItem)
            .where(
                IncidentActionItem.incident_id == incident.id,
                IncidentActionItem.status != "done",
            ),
        )
        or 0
    )
    linked_entities = (
        db.scalar(
            select(func.count())
            .select_from(IncidentLink)
            .where(IncidentLink.incident_id == incident.id),
        )
        or 0
    )
    linked_task_count = len(
        tasks_service.list_tasks_for_incident_source(db, incident_id=incident.id)
    )
    pinned_timeline_events = (
        db.scalar(
            select(func.count())
            .select_from(IncidentTimelineMeta)
            .join(
                IncidentTimeline,
                IncidentTimeline.id == IncidentTimelineMeta.timeline_id,
            )
            .where(
                IncidentTimeline.incident_id == incident.id,
                IncidentTimelineMeta.pinned.is_(True),
            ),
        )
        or 0
    )
    profile = _ensure_profile(db, incident.id)
    on_call_name = None
    if profile.on_call_user_id:
        on_call = db.get(User, profile.on_call_user_id)
        on_call_name = (on_call.name or on_call.email) if on_call else None
    return IncidentOut(
        id=incident.id,
        space_id=incident.space_id,
        folder_id=incident.folder_id,
        folder_path=_folder_path(db, incident.folder_id),
        title=incident.title,
        status=incident.status,
        severity=incident.severity,
        summary_md=incident.summary_md,
        created_by=incident.created_by,
        created_at=incident.created_at,
        open_action_items=int(open_action_items),
        linked_entities=int(linked_entities),
        linked_task_count=linked_task_count,
        pinned_timeline_events=int(pinned_timeline_events),
        archived=profile.archived,
        incident_type=profile.incident_type,
        on_call_user_id=profile.on_call_user_id,
        on_call_user_name=on_call_name,
        escalation_policy=profile.escalation_policy,
        escalation_status=profile.escalation_status,
        blast_radius_summary=profile.blast_radius_summary,
    )


def list_incidents(
    db: Session, space_id: str, *, include_archived: bool = False
) -> list[Incident]:
    q = (
        select(Incident)
        .where(Incident.space_id == space_id)
        .order_by(Incident.created_at.desc())
    )
    rows = list(db.execute(q).scalars().all())
    if include_archived:
        return rows
    return [row for row in rows if not _ensure_profile(db, row.id).archived]


def get(db: Session, incident_id: str) -> Incident | None:
    return db.get(Incident, incident_id)


def get_timeline_entry(db: Session, timeline_id: str) -> IncidentTimeline | None:
    return db.get(IncidentTimeline, timeline_id)


def get_action_item(db: Session, action_item_id: str) -> IncidentActionItem | None:
    return db.get(IncidentActionItem, action_item_id)


def get_link(db: Session, link_id: str) -> IncidentLink | None:
    return db.get(IncidentLink, link_id)


def get_profile(db: Session, incident_id: str) -> IncidentProfile:
    return _ensure_profile(db, incident_id)


def get_template(db: Session, template_id: str) -> IncidentTemplate | None:
    return db.get(IncidentTemplate, template_id)


def get_impact_service(db: Session, impact_id: str) -> IncidentImpactService | None:
    return db.get(IncidentImpactService, impact_id)


def list_impacted_services(
    db: Session, incident_id: str
) -> list[IncidentImpactService]:
    rows = (
        db.execute(
            select(IncidentImpactService)
            .where(IncidentImpactService.incident_id == incident_id)
            .order_by(
                IncidentImpactService.service_name.asc(),
                IncidentImpactService.created_at.asc(),
            ),
        )
        .scalars()
        .all()
    )
    return list(rows)


def list_status_updates(
    db: Session,
    incident_id: str,
    *,
    stream_type: str | None = None,
) -> list[IncidentStatusUpdate]:
    q = (
        select(IncidentStatusUpdate)
        .where(IncidentStatusUpdate.incident_id == incident_id)
        .order_by(IncidentStatusUpdate.created_at.desc())
    )
    if stream_type is not None:
        q = q.where(
            IncidentStatusUpdate.stream_type == _normalize_stream_type(stream_type)
        )
    rows = db.execute(q).scalars().all()
    return list(rows)


def list_action_reminders(
    db: Session, incident_id: str
) -> list[IncidentActionReminder]:
    rows = (
        db.execute(
            select(IncidentActionReminder)
            .where(IncidentActionReminder.incident_id == incident_id)
            .order_by(IncidentActionReminder.created_at.desc())
        )
        .scalars()
        .all()
    )
    return list(rows)


def list_templates(
    db: Session,
    *,
    space_id: str,
    include_inactive: bool = False,
) -> list[IncidentTemplate]:
    q = select(IncidentTemplate).where(
        (IncidentTemplate.space_id == space_id) | (IncidentTemplate.space_id.is_(None))
    )
    if not include_inactive:
        q = q.where(IncidentTemplate.active.is_(True))
    rows = (
        db.execute(
            q.order_by(
                IncidentTemplate.space_id.desc().nulls_last(),
                IncidentTemplate.incident_type.asc(),
                IncidentTemplate.severity.asc(),
                IncidentTemplate.name.asc(),
            )
        )
        .scalars()
        .all()
    )
    return list(rows)


def get_space_analytics(db: Session, space_id: str) -> IncidentSpaceAnalyticsOut:
    incidents = list_incidents(db, space_id)
    mttr_values: list[int] = []
    severity_counts = {1: 0, 2: 0, 3: 0, 4: 0}
    open_count = 0
    monitoring_count = 0
    resolved_count = 0
    for incident in incidents:
        severity_counts[incident.severity] = (
            severity_counts.get(incident.severity, 0) + 1
        )
        if incident.status == "resolved":
            resolved_count += 1
        elif incident.status == "monitoring":
            monitoring_count += 1
        else:
            open_count += 1
        transitions = list_status_history(db, incident.id)
        mttr = _mttr_minutes(incident, transitions)
        if mttr is not None:
            mttr_values.append(mttr)
    avg_mttr = int(sum(mttr_values) / len(mttr_values)) if mttr_values else None
    return IncidentSpaceAnalyticsOut(
        total_incidents=len(incidents),
        open_incidents=open_count,
        monitoring_incidents=monitoring_count,
        resolved_incidents=resolved_count,
        avg_mttr_minutes=avg_mttr,
        severity_1=severity_counts.get(1, 0),
        severity_2=severity_counts.get(2, 0),
        severity_3=severity_counts.get(3, 0),
        severity_4=severity_counts.get(4, 0),
    )


def create(
    db: Session,
    user_id: str,
    space_id: str,
    title: str,
    severity: int | None,
    summary_md: str,
    postmortem_md: str = "",
    incident_type: str = "service",
    template_id: str | None = None,
    *,
    folder_id: str | None = None,
) -> Incident:
    template: IncidentTemplate | None = None
    if template_id:
        template = db.get(IncidentTemplate, template_id)
        if not template or not template.active:
            raise bad_request("Incident template not found")
        if template.space_id and template.space_id != space_id:
            raise bad_request("Incident template is not available in this space")

    normalized_type = _normalize_incident_type(
        incident_type
        if incident_type
        else (template.incident_type if template else "service")
    )
    resolved_severity = max(
        1,
        min(
            int(
                severity
                if severity is not None
                else (template.severity if template else 3)
            ),
            4,
        ),
    )
    title_text = title.strip() or (template.title_template.strip() if template else "")
    if not title_text:
        raise bad_request("Incident title is required")
    summary_text = sanitize_rich_html(
        summary_md.strip() or (template.summary_template_md if template else "")
    )

    incident = Incident(
        id=str(uuid.uuid4()),
        space_id=space_id,
        folder_id=_validate_folder(db, space_id=space_id, folder_id=folder_id),
        title=title_text,
        severity=resolved_severity,
        summary_md=summary_text,
        status="open",
        created_by=user_id,
    )
    db.add(incident)
    db.flush()
    profile = _ensure_profile(db, incident.id)
    profile.incident_type = normalized_type
    profile.template_id = template.id if template else None
    meta = _ensure_meta(db, incident.id)
    meta.postmortem_md = sanitize_rich_html(
        postmortem_md.strip()
        or (template.postmortem_template_md if template else POSTMORTEM_TEMPLATE)
    )
    if template:
        for impact in _parse_template_impacts(template.default_impacts_json):
            db.add(
                IncidentImpactService(
                    id=str(uuid.uuid4()),
                    incident_id=incident.id,
                    service_name=str(impact["service_name"]),
                    impact_level=_normalize_impact_level(
                        str(impact.get("impact_level", "degraded"))
                    ),
                    blast_radius=_normalize_blast_radius(
                        str(impact.get("blast_radius", "single-service"))
                    ),
                    customer_facing=bool(impact.get("customer_facing", True)),
                    notes_md=str(impact.get("notes_md", "")),
                    created_by=user_id,
                )
            )
    _record_transition(db, incident.id, user_id, None, "open", "Incident created")
    media_service.sync_usage_refs(
        db,
        entity_type="incident",
        entity_id=incident.id,
        field_name="summary",
        content=summary_text,
        space_id=space_id,
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="incident",
        content_id=incident.id,
        fields={
            "title": title_text,
            "summary": summary_text,
            "postmortem": meta.postmortem_md,
        },
        actor_user_id=user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(incident)
    return incident


def update(
    db: Session,
    user_id: str,
    incident_id: str,
    title: str,
    status: str,
    severity: int,
    folder_id: str | None,
    incident_type: str | None,
    summary_md: str,
    transition_note: str = "",
) -> Incident:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    next_status = _normalize_status(status)
    title_text = title.strip()
    if not title_text:
        raise bad_request("Incident title is required")
    previous_status = incident.status
    sanitized_summary = sanitize_rich_html(summary_md)
    incident.title = title_text
    incident.status = next_status
    incident.severity = max(1, min(int(severity), 4))
    incident.folder_id = _validate_folder(
        db,
        space_id=incident.space_id,
        folder_id=folder_id,
    )
    incident.summary_md = sanitized_summary
    profile = _ensure_profile(db, incident.id)
    if incident_type is not None:
        profile.incident_type = _normalize_incident_type(incident_type)
    if previous_status != next_status:
        _record_transition(
            db,
            incident.id,
            user_id,
            previous_status,
            next_status,
            transition_note,
        )
    media_service.sync_usage_refs(
        db,
        entity_type="incident",
        entity_id=incident.id,
        field_name="summary",
        content=sanitized_summary,
        space_id=incident.space_id,
    )
    meta = _ensure_meta(db, incident.id)
    localization_service.try_queue_content_translations(
        db,
        content_kind="incident",
        content_id=incident.id,
        fields={
            "title": title_text,
            "summary": sanitized_summary,
            "postmortem": meta.postmortem_md,
        },
        actor_user_id=user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(incident)
    return incident


def update_meta(db: Session, incident_id: str, postmortem_md: str) -> IncidentMeta:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    meta = _ensure_meta(db, incident_id)
    meta.postmortem_md = sanitize_rich_html(
        postmortem_md.strip() or POSTMORTEM_TEMPLATE
    )
    media_service.sync_usage_refs(
        db,
        entity_type="incident",
        entity_id=incident.id,
        field_name="postmortem",
        content=meta.postmortem_md,
        space_id=incident.space_id,
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="incident",
        content_id=incident.id,
        fields={"postmortem": meta.postmortem_md},
        actor_user_id=None,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(meta)
    return meta


def update_profile(
    db: Session,
    incident_id: str,
    *,
    incident_type: str | None = None,
    on_call_user_id: str | None = None,
    escalation_policy: str | None = None,
    escalation_status: str | None = None,
    escalation_notes: str | None = None,
    blast_radius_summary: str | None = None,
    public_status_enabled: bool | None = None,
    private_status_enabled: bool | None = None,
) -> IncidentProfile:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    profile = _ensure_profile(db, incident_id)
    if incident_type is not None:
        profile.incident_type = _normalize_incident_type(incident_type)
    if on_call_user_id is not None:
        profile.on_call_user_id = _ensure_user_exists(
            db, on_call_user_id.strip() or None
        )
    if escalation_policy is not None:
        profile.escalation_policy = _normalize_escalation_policy(escalation_policy)
    if escalation_status is not None:
        profile.escalation_status = _normalize_escalation_status(escalation_status)
    if escalation_notes is not None:
        profile.escalation_notes = escalation_notes.strip()
    if blast_radius_summary is not None:
        profile.blast_radius_summary = blast_radius_summary.strip()
    if public_status_enabled is not None:
        profile.public_status_enabled = bool(public_status_enabled)
    if private_status_enabled is not None:
        profile.private_status_enabled = bool(private_status_enabled)
    db.commit()
    db.refresh(profile)
    return profile


def archive_incident(db: Session, *, user_id: str, incident_id: str) -> Incident:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    profile = _ensure_profile(db, incident_id)
    profile.archived = True
    _record_transition(
        db, incident.id, user_id, incident.status, incident.status, "Incident archived"
    )
    db.commit()
    db.refresh(incident)
    return incident


def restore_incident(db: Session, *, user_id: str, incident_id: str) -> Incident:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    profile = _ensure_profile(db, incident_id)
    profile.archived = False
    _record_transition(
        db, incident.id, user_id, incident.status, incident.status, "Incident restored"
    )
    db.commit()
    db.refresh(incident)
    return incident


def delete_incident(db: Session, incident_id: str) -> None:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    timeline_ids = (
        db.execute(
            select(IncidentTimeline.id).where(
                IncidentTimeline.incident_id == incident_id
            )
        )
        .scalars()
        .all()
    )
    if timeline_ids:
        db.execute(
            delete(IncidentTimelineMeta).where(
                IncidentTimelineMeta.timeline_id.in_(timeline_ids)
            )
        )
    db.execute(
        delete(IncidentActionReminder).where(
            IncidentActionReminder.incident_id == incident_id
        )
    )
    db.execute(
        delete(IncidentStatusUpdate).where(
            IncidentStatusUpdate.incident_id == incident_id
        )
    )
    db.execute(
        delete(IncidentImpactService).where(
            IncidentImpactService.incident_id == incident_id
        )
    )
    db.execute(delete(IncidentLink).where(IncidentLink.incident_id == incident_id))
    db.execute(
        delete(IncidentStatusTransition).where(
            IncidentStatusTransition.incident_id == incident_id
        )
    )
    db.execute(
        delete(IncidentTimeline).where(IncidentTimeline.incident_id == incident_id)
    )
    db.execute(delete(IncidentMeta).where(IncidentMeta.incident_id == incident_id))
    db.execute(
        delete(IncidentProfile).where(IncidentProfile.incident_id == incident_id)
    )
    db.execute(
        delete(IncidentActionItem).where(IncidentActionItem.incident_id == incident_id)
    )
    db.delete(incident)
    db.commit()


def add_timeline(
    db: Session,
    user_id: str,
    incident_id: str,
    entry_md: str,
    *,
    category: str = "update",
    pinned: bool = False,
) -> IncidentTimeline:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    sanitized_entry = sanitize_rich_html(entry_md)
    timeline = IncidentTimeline(
        id=str(uuid.uuid4()),
        incident_id=incident_id,
        entry_md=sanitized_entry,
        created_by=user_id,
    )
    db.add(timeline)
    db.flush()
    meta = _ensure_timeline_meta(db, timeline.id)
    meta.category = _normalize_timeline_category(category)
    meta.pinned = pinned
    media_service.sync_usage_refs(
        db,
        entity_type="incident_timeline",
        entity_id=timeline.id,
        field_name="entry",
        content=sanitized_entry,
        space_id=incident.space_id,
    )
    db.commit()
    db.refresh(timeline)
    return timeline


def delete_timeline(db: Session, timeline_id: str) -> None:
    timeline = get_timeline_entry(db, timeline_id)
    if not timeline:
        raise not_found("Timeline entry not found")
    meta = db.get(IncidentTimelineMeta, timeline_id)
    if meta is not None:
        db.delete(meta)
    db.delete(timeline)
    db.commit()


def update_timeline(
    db: Session,
    timeline_id: str,
    *,
    entry_md: str | None = None,
    category: str | None = None,
    pinned: bool | None = None,
) -> IncidentTimeline:
    timeline = get_timeline_entry(db, timeline_id)
    if not timeline:
        raise not_found("Timeline entry not found")
    incident = get(db, timeline.incident_id)
    if not incident:
        raise not_found("Incident not found")
    if entry_md is not None:
        sanitized_entry = sanitize_rich_html(entry_md)
        timeline.entry_md = sanitized_entry
        media_service.sync_usage_refs(
            db,
            entity_type="incident_timeline",
            entity_id=timeline.id,
            field_name="entry",
            content=sanitized_entry,
            space_id=incident.space_id,
        )
    meta = _ensure_timeline_meta(db, timeline.id)
    if category is not None:
        meta.category = _normalize_timeline_category(category)
    if pinned is not None:
        meta.pinned = pinned
    db.commit()
    db.refresh(timeline)
    return timeline


def list_timeline(db: Session, incident_id: str) -> list[IncidentTimeline]:
    q = (
        select(IncidentTimeline)
        .where(IncidentTimeline.incident_id == incident_id)
        .order_by(IncidentTimeline.ts.asc())
    )
    return list(db.execute(q).scalars().all())


def list_timeline_meta(
    db: Session, incident_id: str
) -> dict[str, IncidentTimelineMeta]:
    rows = (
        db.execute(
            select(IncidentTimelineMeta)
            .join(
                IncidentTimeline,
                IncidentTimeline.id == IncidentTimelineMeta.timeline_id,
            )
            .where(IncidentTimeline.incident_id == incident_id),
        )
        .scalars()
        .all()
    )
    return {row.timeline_id: row for row in rows}


def list_status_history(
    db: Session, incident_id: str
) -> list[IncidentStatusTransition]:
    q = (
        select(IncidentStatusTransition)
        .where(IncidentStatusTransition.incident_id == incident_id)
        .order_by(IncidentStatusTransition.changed_at.asc())
    )
    return list(db.execute(q).scalars().all())


def list_action_items(db: Session, incident_id: str) -> list[IncidentActionItem]:
    q = (
        select(IncidentActionItem)
        .where(IncidentActionItem.incident_id == incident_id)
        .order_by(
            IncidentActionItem.status.asc(),
            IncidentActionItem.due_at.asc().nulls_last(),
            IncidentActionItem.created_at.asc(),
        )
    )
    return list(db.execute(q).scalars().all())


def create_action_item(
    db: Session,
    user_id: str,
    incident_id: str,
    *,
    title: str,
    owner_user_id: str | None,
    due_at: datetime | None,
    status: str,
    notes_md: str,
) -> IncidentActionItem:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    title_text = title.strip()
    if not title_text:
        raise bad_request("Action item title is required")
    normalized_status = _normalize_action_status(status)
    owner_id = _ensure_user_exists(db, owner_user_id)
    sanitized_notes = sanitize_rich_html(notes_md)
    action_item = IncidentActionItem(
        id=str(uuid.uuid4()),
        incident_id=incident_id,
        title=title_text,
        owner_user_id=owner_id,
        due_at=due_at,
        status=normalized_status,
        notes_md=sanitized_notes,
        created_by=user_id,
        completed_at=_now_utc() if normalized_status == "done" else None,
    )
    db.add(action_item)
    db.commit()
    db.refresh(action_item)
    return action_item


def create_task_for_action_item(
    db: Session,
    *,
    user_id: str,
    incident_id: str,
    action_item_id: str,
) -> tuple[str, bool]:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    action_item = get_action_item(db, action_item_id)
    if not action_item or action_item.incident_id != incident.id:
        raise not_found("Action item not found")

    existing = tasks_service.get_task_by_source(
        db,
        source_kind="incident_action_item",
        source_id=incident.id,
        source_step_id=action_item.id,
    )
    if existing:
        return existing.id, False

    status = {
        "open": "todo",
        "in_progress": "in_progress",
        "blocked": "blocked",
        "done": "done",
    }.get(action_item.status, "todo")

    task = tasks_service.create_task(
        db,
        space_id=incident.space_id,
        title=action_item.title,
        description=action_item.notes_md,
        status=status,
        priority="medium",
        assignee_user_id=action_item.owner_user_id,
        created_by=user_id,
        source_kind="incident_action_item",
        source_id=incident.id,
        source_step_id=action_item.id,
        due_at=action_item.due_at,
    )
    return task.id, True


def update_action_item(
    db: Session,
    action_item_id: str,
    *,
    title: str,
    owner_user_id: str | None,
    due_at: datetime | None,
    status: str,
    notes_md: str,
) -> IncidentActionItem:
    action_item = get_action_item(db, action_item_id)
    if not action_item:
        raise not_found("Action item not found")
    title_text = title.strip()
    if not title_text:
        raise bad_request("Action item title is required")
    normalized_status = _normalize_action_status(status)
    sanitized_notes = sanitize_rich_html(notes_md)
    action_item.title = title_text
    action_item.owner_user_id = _ensure_user_exists(db, owner_user_id)
    action_item.due_at = due_at
    action_item.status = normalized_status
    action_item.notes_md = sanitized_notes
    action_item.completed_at = _now_utc() if normalized_status == "done" else None
    db.commit()
    db.refresh(action_item)
    return action_item


def delete_action_item(db: Session, action_item_id: str) -> None:
    action_item = get_action_item(db, action_item_id)
    if not action_item:
        raise not_found("Action item not found")
    db.execute(
        delete(IncidentActionReminder).where(
            IncidentActionReminder.action_item_id == action_item_id
        )
    )
    db.delete(action_item)
    db.commit()


def create_impacted_service(
    db: Session,
    user_id: str,
    incident_id: str,
    *,
    service_name: str,
    impact_level: str,
    blast_radius: str,
    customer_facing: bool,
    notes_md: str,
) -> IncidentImpactService:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    name = service_name.strip()
    if not name:
        raise bad_request("Service name is required")
    sanitized_notes = sanitize_rich_html(notes_md)
    row = IncidentImpactService(
        id=str(uuid.uuid4()),
        incident_id=incident_id,
        service_name=name[:220],
        impact_level=_normalize_impact_level(impact_level),
        blast_radius=_normalize_blast_radius(blast_radius),
        customer_facing=bool(customer_facing),
        notes_md=sanitized_notes,
        created_by=user_id,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def update_impacted_service(
    db: Session,
    impact_id: str,
    *,
    service_name: str,
    impact_level: str,
    blast_radius: str,
    customer_facing: bool,
    notes_md: str,
) -> IncidentImpactService:
    row = get_impact_service(db, impact_id)
    if not row:
        raise not_found("Impacted service not found")
    name = service_name.strip()
    if not name:
        raise bad_request("Service name is required")
    sanitized_notes = sanitize_rich_html(notes_md)
    row.service_name = name[:220]
    row.impact_level = _normalize_impact_level(impact_level)
    row.blast_radius = _normalize_blast_radius(blast_radius)
    row.customer_facing = bool(customer_facing)
    row.notes_md = sanitized_notes
    db.commit()
    db.refresh(row)
    return row


def delete_impacted_service(db: Session, impact_id: str) -> None:
    row = get_impact_service(db, impact_id)
    if not row:
        raise not_found("Impacted service not found")
    db.delete(row)
    db.commit()


def add_status_update(
    db: Session,
    user_id: str,
    incident_id: str,
    *,
    stream_type: str,
    status: str,
    message_md: str,
) -> IncidentStatusUpdate:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    message = sanitize_rich_html(message_md)
    if not message:
        raise bad_request("Status update message is required")
    row = IncidentStatusUpdate(
        id=str(uuid.uuid4()),
        incident_id=incident_id,
        stream_type=_normalize_stream_type(stream_type),
        status=status.strip()[:40] or "update",
        message_md=message,
        created_by=user_id,
    )
    db.add(row)
    db.add(
        Event(
            id=str(uuid.uuid4()),
            user_id=user_id,
            session_id=f"incident-status:{incident_id}",
            event_type="incident_status_update",
            space_id=incident.space_id,
            entity_type="incident_status_update",
            entity_id=row.id,
            path=f"/spaces/{incident.space_id}",
            meta_json=json.dumps(
                {
                    "incident_id": incident_id,
                    "stream_type": row.stream_type,
                    "status": row.status,
                },
                ensure_ascii=False,
            ),
        )
    )
    db.commit()
    db.refresh(row)
    return row


def list_links(db: Session, incident_id: str) -> list[IncidentLink]:
    q = (
        select(IncidentLink)
        .where(IncidentLink.incident_id == incident_id)
        .order_by(IncidentLink.created_at.asc())
    )
    return list(db.execute(q).scalars().all())


def create_link(
    db: Session,
    user_id: str,
    incident_id: str,
    *,
    target_type: str,
    target_id: str,
    label: str = "",
) -> IncidentLink:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    normalized_type = target_type.strip().lower()
    _link_target_snapshot(db, incident.space_id, normalized_type, target_id)
    existing = db.execute(
        select(IncidentLink).where(
            IncidentLink.incident_id == incident_id,
            IncidentLink.target_type == normalized_type,
            IncidentLink.target_id == target_id,
        ),
    ).scalar_one_or_none()
    if existing:
        raise bad_request("That link already exists")
    link = IncidentLink(
        id=str(uuid.uuid4()),
        incident_id=incident_id,
        target_type=normalized_type,
        target_id=target_id,
        label=label.strip(),
        created_by=user_id,
    )
    db.add(link)
    db.commit()
    db.refresh(link)
    return link


def delete_link(db: Session, link_id: str) -> None:
    link = get_link(db, link_id)
    if not link:
        raise not_found("Link not found")
    db.delete(link)
    db.commit()


def create_template(
    db: Session,
    *,
    user_id: str,
    space_id: str,
    name: str,
    incident_type: str,
    severity: int,
    title_template: str,
    summary_template_md: str,
    postmortem_template_md: str,
    default_impacts: Sequence[IncidentImpactServiceIn | dict[str, object]],
    active: bool,
) -> IncidentTemplate:
    normalized_name = name.strip()
    if not normalized_name:
        raise bad_request("Template name is required")
    sanitized_summary_template = sanitize_rich_html(summary_template_md)
    sanitized_postmortem_template = sanitize_rich_html(postmortem_template_md)
    template = IncidentTemplate(
        id=str(uuid.uuid4()),
        space_id=space_id,
        name=normalized_name[:220],
        incident_type=_normalize_incident_type(incident_type),
        severity=max(1, min(int(severity), 4)),
        title_template=title_template.strip(),
        summary_template_md=sanitized_summary_template,
        postmortem_template_md=sanitized_postmortem_template or POSTMORTEM_TEMPLATE,
        default_impacts_json=_template_impacts_json(
            _normalize_template_impacts(default_impacts)
        ),
        active=bool(active),
        created_by=user_id,
    )
    db.add(template)
    db.commit()
    db.refresh(template)
    return template


def update_template(
    db: Session,
    *,
    template_id: str,
    name: str,
    incident_type: str,
    severity: int,
    title_template: str,
    summary_template_md: str,
    postmortem_template_md: str,
    default_impacts: Sequence[IncidentImpactServiceIn | dict[str, object]],
    active: bool,
) -> IncidentTemplate:
    template = get_template(db, template_id)
    if not template:
        raise not_found("Incident template not found")
    normalized_name = name.strip()
    if not normalized_name:
        raise bad_request("Template name is required")
    sanitized_summary_template = sanitize_rich_html(summary_template_md)
    sanitized_postmortem_template = sanitize_rich_html(postmortem_template_md)
    template.name = normalized_name[:220]
    template.incident_type = _normalize_incident_type(incident_type)
    template.severity = max(1, min(int(severity), 4))
    template.title_template = title_template.strip()
    template.summary_template_md = sanitized_summary_template
    template.postmortem_template_md = (
        sanitized_postmortem_template or POSTMORTEM_TEMPLATE
    )
    template.default_impacts_json = _template_impacts_json(
        _normalize_template_impacts(default_impacts)
    )
    template.active = bool(active)
    db.commit()
    db.refresh(template)
    return template


def delete_template(db: Session, template_id: str) -> None:
    template = get_template(db, template_id)
    if not template:
        raise not_found("Incident template not found")
    db.delete(template)
    db.commit()


def get_detail(db: Session, incident_id: str) -> IncidentDetailOut:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    profile = _ensure_profile(db, incident.id)
    meta = _ensure_meta(db, incident_id)
    timeline = list_timeline(db, incident_id)
    timeline_meta_map = list_timeline_meta(db, incident_id)
    action_items = list_action_items(db, incident_id)
    action_item_task_map = _action_item_task_map(
        db,
        incident_id=incident_id,
        action_item_ids=[row.id for row in action_items],
    )
    links = list_links(db, incident_id)
    transitions = list_status_history(db, incident_id)
    status_updates = list_status_updates(db, incident_id)
    impacted_services = list_impacted_services(db, incident_id)
    reminders = list_action_reminders(db, incident_id)
    template = (
        db.get(IncidentTemplate, profile.template_id) if profile.template_id else None
    )
    user_ids = {
        incident.created_by,
        *[row.created_by for row in timeline],
        *[row.owner_user_id for row in action_items if row.owner_user_id],
        *[row.created_by for row in action_items],
        *[row.changed_by for row in transitions],
        *[row.created_by for row in status_updates],
        *[row.owner_user_id for row in reminders if row.owner_user_id],
        *([profile.on_call_user_id] if profile.on_call_user_id else []),
    }
    user_names = _user_name_map(db, user_ids)
    base = to_out(db, incident)
    return IncidentDetailOut(
        **base.model_dump(),
        postmortem_md=meta.postmortem_md or POSTMORTEM_TEMPLATE,
        timeline=[
            _timeline_to_out(row, meta_map=timeline_meta_map, user_names=user_names)
            for row in timeline
        ],
        action_items=[
            _action_item_to_out(
                row,
                user_names=user_names,
                linked_task_id=action_item_task_map.get(row.id),
            )
            for row in action_items
        ],
        links=[_link_to_out(db, incident, row) for row in links],
        status_history=[
            _transition_to_out(row, user_names=user_names) for row in transitions
        ],
        status_updates=[
            _status_update_to_out(row, user_names=user_names) for row in status_updates
        ],
        impacted_services=[_impact_to_out(row) for row in impacted_services],
        reminders=[_reminder_to_out(row, user_names=user_names) for row in reminders],
        template_id=profile.template_id,
        template_name=template.name if template else None,
        escalation_notes=profile.escalation_notes,
        public_status_enabled=profile.public_status_enabled,
        private_status_enabled=profile.private_status_enabled,
        analytics=_analytics_to_out(
            incident,
            action_items=action_items,
            links=links,
            transitions=transitions,
            timeline_meta_map=timeline_meta_map,
        ),
    )


def export_incident_report(db: Session, *, incident_id: str) -> IncidentReportOut:
    incident = get(db, incident_id)
    if not incident:
        raise not_found("Incident not found")
    detail = get_detail(db, incident_id)
    impacted = detail.impacted_services
    public_updates = [
        row for row in detail.status_updates if row.stream_type == "public"
    ]
    private_updates = [
        row for row in detail.status_updates if row.stream_type == "private"
    ]
    lines = [
        f"Incident Report: {detail.title}",
        f"Incident ID: {detail.id}",
        f"Status: {detail.status}",
        f"Severity: {detail.severity}",
        f"Type: {detail.incident_type}",
        f"Created: {_safe_iso(detail.created_at)}",
        f"On-call: {detail.on_call_user_name or detail.on_call_user_id or 'unassigned'}",
        f"Escalation: {detail.escalation_policy} / {detail.escalation_status}",
        f"Blast Radius: {detail.blast_radius_summary or 'n/a'}",
        "",
        "Summary:",
        _strip_html(detail.summary_md) or "n/a",
        "",
        "Impacted Services:",
    ]
    if impacted:
        for item in impacted:
            lines.append(
                f"- {item.service_name} ({item.impact_level}, {item.blast_radius}, "
                f"{'customer-facing' if item.customer_facing else 'internal'})"
            )
    else:
        lines.append("- none")

    lines.extend(
        [
            "",
            f"Public Updates ({len(public_updates)}):",
        ]
    )
    if public_updates:
        for row in public_updates[:20]:
            lines.append(
                f"- {_safe_iso(row.created_at)} [{row.status}] {_strip_html(row.message_md)}"
            )
    else:
        lines.append("- none")

    lines.extend(
        [
            "",
            f"Private Updates ({len(private_updates)}):",
        ]
    )
    if private_updates:
        for row in private_updates[:20]:
            lines.append(
                f"- {_safe_iso(row.created_at)} [{row.status}] {_strip_html(row.message_md)}"
            )
    else:
        lines.append("- none")

    lines.extend(
        [
            "",
            "Open Action Items:",
        ]
    )
    open_items = [row for row in detail.action_items if row.status != "done"]
    if open_items:
        for row in open_items:
            lines.append(
                f"- {row.title} (owner={row.owner_name or row.owner_user_id or 'unassigned'}, "
                f"due={_safe_iso(row.due_at)}, status={row.status})"
            )
    else:
        lines.append("- none")
    return IncidentReportOut(title=detail.title, text="\n".join(lines).strip())


def export_incident_report_csv(db: Session, *, incident_id: str) -> str:
    detail = get_detail(db, incident_id)
    output = StringIO()
    writer = csv.writer(output)
    writer.writerow(["field", "value"])
    writer.writerow(["incident_id", detail.id])
    writer.writerow(["title", detail.title])
    writer.writerow(["status", detail.status])
    writer.writerow(["severity", detail.severity])
    writer.writerow(["incident_type", detail.incident_type])
    writer.writerow(["created_at", _safe_iso(detail.created_at)])
    writer.writerow(
        ["on_call", detail.on_call_user_name or detail.on_call_user_id or ""]
    )
    writer.writerow(["escalation_policy", detail.escalation_policy])
    writer.writerow(["escalation_status", detail.escalation_status])
    writer.writerow(["blast_radius_summary", detail.blast_radius_summary])
    writer.writerow([])
    writer.writerow(
        [
            "impact_service_name",
            "impact_level",
            "blast_radius",
            "customer_facing",
            "notes",
        ]
    )
    for row in detail.impacted_services:
        writer.writerow(
            [
                row.service_name,
                row.impact_level,
                row.blast_radius,
                "yes" if row.customer_facing else "no",
                _strip_html(row.notes_md),
            ]
        )
    writer.writerow([])
    writer.writerow(["action_title", "owner", "due_at", "status", "notes"])
    for row in detail.action_items:
        writer.writerow(
            [
                row.title,
                row.owner_name or row.owner_user_id or "",
                _safe_iso(row.due_at),
                row.status,
                _strip_html(row.notes_md),
            ]
        )
    return output.getvalue()


def export_incident_report_pdf_bytes(db: Session, *, incident_id: str) -> bytes:
    report = export_incident_report(db, incident_id=incident_id)
    return _simple_pdf_bytes(report.text.splitlines())


def export_postmortem_pdf_bytes(db: Session, *, incident_id: str) -> bytes:
    detail = get_detail(db, incident_id)
    lines = [
        f"Postmortem: {detail.title}",
        f"Incident ID: {detail.id}",
        f"Status: {detail.status}",
        "",
    ]
    body = _strip_html(detail.postmortem_md)
    if body:
        lines.extend(body.splitlines())
    else:
        lines.append("No postmortem details.")
    return _simple_pdf_bytes(lines)


def process_overdue_action_item_reminders(db: Session) -> int:
    now = _now_utc()
    key = f"overdue:{now.date().isoformat()}"
    items = (
        db.execute(
            select(IncidentActionItem)
            .join(Incident, Incident.id == IncidentActionItem.incident_id)
            .where(
                IncidentActionItem.status != "done",
                IncidentActionItem.due_at.is_not(None),
                IncidentActionItem.due_at <= now,
            )
            .order_by(IncidentActionItem.due_at.asc()),
        )
        .scalars()
        .all()
    )

    created = 0
    for item in items:
        profile = _ensure_profile(db, item.incident_id)
        if profile.archived:
            continue
        exists = db.execute(
            select(IncidentActionReminder.id).where(
                IncidentActionReminder.action_item_id == item.id,
                IncidentActionReminder.reminder_key == key,
            )
        ).scalar_one_or_none()
        if exists:
            continue
        reminder = IncidentActionReminder(
            id=str(uuid.uuid4()),
            incident_id=item.incident_id,
            action_item_id=item.id,
            owner_user_id=item.owner_user_id,
            reminder_key=key,
            channel="in_app",
            due_at_snapshot=item.due_at,
        )
        db.add(reminder)
        incident = get(db, item.incident_id)
        db.add(
            Event(
                id=str(uuid.uuid4()),
                user_id=item.owner_user_id,
                session_id=f"incident-reminder:{item.incident_id}",
                event_type="incident_action_reminder",
                space_id=incident.space_id if incident else None,
                entity_type="incident_action_item",
                entity_id=item.id,
                path=f"/spaces/{incident.space_id}" if incident else None,
                meta_json=json.dumps(
                    {
                        "incident_id": item.incident_id,
                        "action_item_id": item.id,
                        "due_at": _safe_iso(item.due_at),
                        "title": item.title,
                    },
                    ensure_ascii=False,
                ),
            )
        )
        created += 1
    if created:
        db.commit()
    return created
