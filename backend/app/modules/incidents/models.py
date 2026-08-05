# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for incidents, timelines, action items, and linked records."""

from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column
from app.core.db import Base


class Incident(Base):
    __tablename__ = "incidents"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str] = mapped_column(String(36), ForeignKey("spaces.id"), index=True, nullable=False)
    folder_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("folders.id"), index=True, nullable=True)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False, default="open")
    severity: Mapped[int] = mapped_column(Integer, nullable=False, default=3)
    summary_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

class IncidentTimeline(Base):
    __tablename__ = "incident_timeline"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), index=True, nullable=False)
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    entry_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)


class IncidentMeta(Base):
    __tablename__ = "incident_meta"
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), primary_key=True)
    postmortem_md: Mapped[str] = mapped_column(Text, nullable=False, default="")


class IncidentTimelineMeta(Base):
    __tablename__ = "incident_timeline_meta"
    timeline_id: Mapped[str] = mapped_column(String(36), ForeignKey("incident_timeline.id"), primary_key=True)
    category: Mapped[str] = mapped_column(String(30), nullable=False, default="update")
    pinned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)


class IncidentActionItem(Base):
    __tablename__ = "incident_action_items"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    owner_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    status: Mapped[str] = mapped_column(String(30), nullable=False, default="open")
    notes_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class IncidentLink(Base):
    __tablename__ = "incident_links"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), index=True, nullable=False)
    target_type: Mapped[str] = mapped_column(String(20), nullable=False)
    target_id: Mapped[str] = mapped_column(String(36), nullable=False)
    label: Mapped[str] = mapped_column(String(300), nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class IncidentStatusTransition(Base):
    __tablename__ = "incident_status_transitions"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), index=True, nullable=False)
    from_status: Mapped[str | None] = mapped_column(String(30), nullable=True)
    to_status: Mapped[str] = mapped_column(String(30), nullable=False)
    note_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    changed_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    changed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class IncidentProfile(Base):
    __tablename__ = "incident_profiles"

    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), primary_key=True)
    archived: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, index=True)
    incident_type: Mapped[str] = mapped_column(String(40), nullable=False, default="service", index=True)
    template_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("incident_templates.id"), nullable=True, index=True)
    on_call_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    escalation_policy: Mapped[str] = mapped_column(String(40), nullable=False, default="standard")
    escalation_status: Mapped[str] = mapped_column(String(40), nullable=False, default="normal")
    escalation_notes: Mapped[str] = mapped_column(Text, nullable=False, default="")
    blast_radius_summary: Mapped[str] = mapped_column(Text, nullable=False, default="")
    public_status_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    private_status_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class IncidentImpactService(Base):
    __tablename__ = "incident_impact_services"
    __table_args__ = (UniqueConstraint("incident_id", "service_name", name="uq_incident_impact_service"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), nullable=False, index=True)
    service_name: Mapped[str] = mapped_column(String(220), nullable=False)
    impact_level: Mapped[str] = mapped_column(String(40), nullable=False, default="degraded")
    blast_radius: Mapped[str] = mapped_column(String(40), nullable=False, default="single-service")
    customer_facing: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    notes_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class IncidentStatusUpdate(Base):
    __tablename__ = "incident_status_updates"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), nullable=False, index=True)
    stream_type: Mapped[str] = mapped_column(String(20), nullable=False, default="private", index=True)
    status: Mapped[str] = mapped_column(String(40), nullable=False, default="update")
    message_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class IncidentTemplate(Base):
    __tablename__ = "incident_templates"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    space_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("spaces.id"), nullable=True, index=True)
    name: Mapped[str] = mapped_column(String(220), nullable=False)
    incident_type: Mapped[str] = mapped_column(String(40), nullable=False, default="service", index=True)
    severity: Mapped[int] = mapped_column(Integer, nullable=False, default=3, index=True)
    title_template: Mapped[str] = mapped_column(String(320), nullable=False, default="")
    summary_template_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    postmortem_template_md: Mapped[str] = mapped_column(Text, nullable=False, default="")
    default_impacts_json: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_by: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class IncidentActionReminder(Base):
    __tablename__ = "incident_action_reminders"
    __table_args__ = (UniqueConstraint("action_item_id", "reminder_key", name="uq_incident_action_reminder_key"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    incident_id: Mapped[str] = mapped_column(String(36), ForeignKey("incidents.id"), nullable=False, index=True)
    action_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("incident_action_items.id"), nullable=False, index=True)
    owner_user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True, index=True)
    reminder_key: Mapped[str] = mapped_column(String(80), nullable=False, index=True)
    channel: Mapped[str] = mapped_column(String(20), nullable=False, default="in_app")
    due_at_snapshot: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
