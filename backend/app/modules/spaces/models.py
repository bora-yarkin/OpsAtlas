# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""ORM models for spaces, memberships, and related workspace state."""

from datetime import datetime

from sqlalchemy import String, DateTime, Text, func
from sqlalchemy.orm import Mapped, mapped_column
from app.core.db import Base


class Space(Base):
    __tablename__ = "spaces"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    slug: Mapped[str] = mapped_column(String(200), unique=True, index=True, nullable=False)
    owner_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    region_code: Mapped[str | None] = mapped_column(String(120), nullable=True, index=True)
    meta_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
