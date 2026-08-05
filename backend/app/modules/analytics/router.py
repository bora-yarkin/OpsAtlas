# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for analytics dashboards, trends, and activity feeds."""

from datetime import datetime
from typing import cast

from fastapi.responses import Response

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from app.core.deps import get_db
from app.modules.auth.deps import get_current_user
from app.modules.auth.models import User
from app.modules.spaces import service as spaces_service
from .schemas import (
    ActivityEventOut,
    AnalyticsSearchQualityOut,
    AnalyticsTrendPointOut,
    TrackEventIn,
    TopEntityOut,
)
from . import service

router = APIRouter(prefix="/analytics", tags=["analytics"])


def _string_or_none(value: object | None) -> str | None:
    return value if isinstance(value, str) else None


def _int_or_zero(value: object | None) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return 0
    return 0


def _split_event_types(raw: str | None) -> tuple[str, ...]:
    if raw is None:
        return ()
    return tuple(
        value.strip().lower()
        for value in raw.split(",")
        if value.strip()
    )

@router.post("/events")
def track_event(payload: TrackEventIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    if payload.space_id:
        spaces_service.require_space_role(db, payload.space_id, user.id, {"admin","moderator","member","viewer"})
    service.track(db, user.id, payload)
    return {"ok": True}

@router.get("/spaces/{space_id}/top/{entity_type}", response_model=list[TopEntityOut])
def top(
    space_id: str,
    entity_type: str,
    limit: int = 10,
    days: int | None = None,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    event_types: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin","moderator"})
    items = service.top_entities(
        db,
        space_id,
        entity_type,
        limit,
        days=days,
        start_at=start_at,
        end_at=end_at,
        event_types=_split_event_types(event_types),
    )
    return [
        TopEntityOut(
            entity_type=entity_type,
            entity_id=str(item["entity_id"]),
            views=_int_or_zero(item.get("views")),
            title=_string_or_none(item.get("title")),
            slug=_string_or_none(item.get("slug")),
            path=_string_or_none(item.get("path")),
        )
        for item in items
    ]


@router.get(
    "/spaces/{space_id}/search-quality",
    response_model=AnalyticsSearchQualityOut,
)
def search_quality(
    space_id: str,
    days: int | None = None,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    surface: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator"})
    return service.search_quality_summary(
        db,
        space_id=space_id,
        days=days,
        start_at=start_at,
        end_at=end_at,
        surface=surface,
    )


@router.get("/spaces/{space_id}/trends", response_model=list[AnalyticsTrendPointOut])
def trends(
    space_id: str,
    days: int | None = None,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    event_types: str | None = None,
    granularity: str = "day",
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator"})
    return [
        AnalyticsTrendPointOut(
            bucket_start=item["bucket_start"],
            bucket_label=str(item["bucket_label"]),
            count=_int_or_zero(item.get("count")),
        )
        for item in service.trend_counts(
            db,
            space_id=space_id,
            days=days,
            start_at=start_at,
            end_at=end_at,
            event_types=_split_event_types(event_types),
            granularity=granularity,
        )
    ]


@router.get("/spaces/{space_id}/export")
def export_events(
    space_id: str,
    format_name: str = "json",
    days: int | None = None,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    event_types: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces_service.require_space_role(db, space_id, user.id, {"admin", "moderator"})
    filename, payload, media_type = service.export_events_payload(
        db,
        space_id=space_id,
        format_name=format_name,
        days=days,
        start_at=start_at,
        end_at=end_at,
        event_types=_split_event_types(event_types),
    )
    return Response(
        content=payload,
        media_type=media_type,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/feed", response_model=list[ActivityEventOut])
def feed(
    space_id: str | None = None,
    limit: int = 25,
    days: int | None = None,
    start_at: datetime | None = None,
    end_at: datetime | None = None,
    event_types: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    rows = service.list_feed(
        db,
        user=user,
        space_id=space_id,
        limit=limit,
        days=days,
        start_at=start_at,
        end_at=end_at,
        event_types=_split_event_types(event_types),
    )
    enriched_rows = service.enrich_feed_rows(db, rows)
    out: list[ActivityEventOut] = []
    for item in enriched_rows:
        row = item["row"]
        meta = cast(dict[str, object], item["meta"])
        out.append(
            ActivityEventOut(
                id=row.id,
                ts=row.ts,
                user_id=row.user_id,
                actor_name=_string_or_none(item.get("actor_name")),
                event_type=row.event_type,
                space_id=row.space_id,
                space_name=_string_or_none(item.get("space_name")),
                entity_type=row.entity_type,
                entity_id=row.entity_id,
                entity_title=_string_or_none(item.get("entity_title")),
                detail_text=_string_or_none(item.get("detail_text")),
                path=_string_or_none(item.get("path")),
                meta=meta,
            )
        )
    return out
