# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for analytics events and derived reporting inputs."""

from datetime import datetime

from sqlalchemy import String, DateTime, func, Text, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column
from app.core.db import Base


class Event(Base):
    __tablename__ = "events"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id"), nullable=True)
    session_id: Mapped[str] = mapped_column(String(100), index=True, nullable=False)
    event_type: Mapped[str] = mapped_column(String(80), index=True, nullable=False)
    space_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("spaces.id"), nullable=True)
    entity_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    entity_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    path: Mapped[str | None] = mapped_column(String(400), nullable=True)
    meta_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")
