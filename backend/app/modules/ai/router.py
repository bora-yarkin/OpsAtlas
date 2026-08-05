# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for AI-assisted backend features."""

import threading
import time
from collections import defaultdict, deque
from typing import cast

from fastapi import APIRouter, Depends, HTTPException

from app.core.config import settings
from app.modules.auth.deps import require_role
from app.modules.auth.models import User

from . import service
from .schemas import (
    AiStatusOut,
    AiSummaryOut,
    AiTextIn,
    DocSuggestIn,
    DocSuggestOut,
    IncidentPostmortemDraftIn,
    IncidentPostmortemDraftOut,
)

router = APIRouter(prefix="/ai", tags=["ai"])


class _RateLimiter:
    def __init__(self) -> None:
        self._hits: dict[tuple[str, str], deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def check(self, key: tuple[str, str], max_per_minute: int) -> None:
        if max_per_minute <= 0:
            return
        now = time.time()
        cutoff = now - 60.0
        with self._lock:
            q = self._hits[key]
            while q and q[0] < cutoff:
                q.popleft()
            if len(q) >= max_per_minute:
                raise HTTPException(status_code=429, detail="AI rate limit exceeded; try again in a minute")
            q.append(now)


_rate_limiter = _RateLimiter()


def _guard_ai(user_id: str, route_key: str, text_size: int) -> None:
    if not settings.ai_enabled:
        raise HTTPException(status_code=503, detail="AI features are disabled")
    if text_size > settings.ai_max_input_chars:
        raise HTTPException(
            status_code=400,
            detail=f"AI input too large ({text_size} chars). Max is {settings.ai_max_input_chars}",
        )
    _rate_limiter.check((user_id, route_key), settings.ai_rate_limit_per_minute)


@router.get("/status", response_model=AiStatusOut)
def status(user: User = Depends(require_role("admin", "moderator"))):
    return AiStatusOut(
        enabled=settings.ai_enabled,
        provider=settings.ai_provider,
        rate_limit_per_minute=settings.ai_rate_limit_per_minute,
        max_input_chars=settings.ai_max_input_chars,
    )


@router.post("/summarize", response_model=AiSummaryOut)
def summarize(payload: AiTextIn, user: User = Depends(require_role("admin", "moderator"))):
    _guard_ai(user.id, "summarize", len(payload.text))
    return AiSummaryOut(summary=service.summarize_text(payload.text, limit=settings.ai_summary_char_limit), provider=settings.ai_provider)


@router.post("/suggest/doc-metadata", response_model=DocSuggestOut)
def suggest_doc_metadata(payload: DocSuggestIn, user: User = Depends(require_role("admin", "moderator", "member"))):
    size = len(payload.text) + len(payload.existing_title or "")
    _guard_ai(user.id, "doc-metadata", size)
    result = service.suggest_doc_metadata(
        text=payload.text,
        existing_title=payload.existing_title,
        max_tags=payload.max_tags,
    )
    return DocSuggestOut(
        provider=settings.ai_provider,
        title=cast(str, result["title"]),
        summary=cast(str, result["summary"]),
        tags=cast(list[str], result["tags"]),
    )


@router.post("/draft/incident-postmortem", response_model=IncidentPostmortemDraftOut)
def draft_incident_postmortem(payload: IncidentPostmortemDraftIn, user: User = Depends(require_role("admin", "moderator", "member"))):
    size = len(payload.incident_title) + len(payload.summary_md) + sum(len(i) for i in payload.timeline_items)
    _guard_ai(user.id, "incident-postmortem", size)
    result = service.draft_incident_postmortem(
        incident_title=payload.incident_title,
        summary_md=payload.summary_md,
        timeline_items=payload.timeline_items,
    )
    return IncidentPostmortemDraftOut(
        provider=settings.ai_provider,
        title=cast(str, result["title"]),
        executive_summary=cast(str, result["executive_summary"]),
        postmortem_md=cast(str, result["postmortem_md"]),
        suggested_action_items=cast(list[str], result["suggested_action_items"]),
    )
