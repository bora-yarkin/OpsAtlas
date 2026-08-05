# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""HTTP routes for space listing, membership, and workspace access APIs."""

from fastapi import APIRouter, Depends
import json
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session
from app.core.deps import get_db
from app.core.search.ast import ParsedSearchQuery, evaluate_search_expression, parse_search_query_ast
from app.modules.analytics import service as analytics_service
from app.modules.analytics.schemas import TrackEventIn
from app.modules.auth.deps import get_current_user
from app.modules.auth.models import User
from app.modules.incidents.models import Incident, IncidentProfile
from app.modules.localization import service as localization_service
from app.modules.tasks.models import Task
from .schemas import (
    SpaceCreateIn,
    SpaceMemberDetailOut,
    SpaceMemberOut,
    SpaceOut,
)
from . import service

router = APIRouter(prefix="/spaces", tags=["spaces"])


def _meta_from_json(value: object | None) -> dict[str, object] | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        decoded = json.loads(value)
    except Exception:
        return None
    return decoded if isinstance(decoded, dict) else None


def _localized_space_names_by_id(
    db: Session,
    *,
    user_id: str,
    space_ids: list[str],
) -> dict[str, str]:
    localized_fields = localization_service.localized_fields_for_contents(
        db,
        content_kind="org_space",
        content_ids=space_ids,
        field_keys=["name"],
        user_id=user_id,
    )
    return {space_id: name for space_id, fields in localized_fields.items() for name in [str(fields.get("name", "")).strip()] if name}


def _member_count_by_space_id(
    db: Session,
    *,
    space_ids: list[str],
) -> dict[str, int]:
    return {
        space_id: len(service.list_members(db, space_id))
        for space_id in space_ids
    }


def _open_task_count_by_space_id(
    db: Session,
    *,
    space_ids: list[str],
) -> dict[str, int]:
    if not space_ids:
      return {}
    rows = db.execute(
        select(Task.space_id, func.count(Task.id))
        .where(
            Task.space_id.in_(space_ids),
            Task.status != "done",
        )
        .group_by(Task.space_id)
    ).all()
    return {
        str(space_id): int(count or 0)
        for space_id, count in rows
        if isinstance(space_id, str)
    }


def _active_incident_count_by_space_id(
    db: Session,
    *,
    space_ids: list[str],
) -> dict[str, int]:
    if not space_ids:
      return {}
    rows = db.execute(
        select(Incident.space_id, func.count(Incident.id))
        .outerjoin(
            IncidentProfile,
            IncidentProfile.incident_id == Incident.id,
        )
        .where(
            Incident.space_id.in_(space_ids),
            Incident.status != "resolved",
            or_(
                IncidentProfile.incident_id.is_(None),
                IncidentProfile.archived.is_(False),
            ),
        )
        .group_by(Incident.space_id)
    ).all()
    return {
        str(space_id): int(count or 0)
        for space_id, count in rows
        if isinstance(space_id, str)
    }


def _space_search_values(*, space, localized_name: str) -> dict[str, str]:
    name = (localized_name or space.name or "").strip().lower()
    slug = (space.slug or "").strip().lower()
    space_id = (space.id or "").strip().lower()
    region_code = (space.region_code or "").strip().lower()
    text = " ".join([name, slug, space_id, region_code]).strip()
    return {
        "name": name,
        "slug": slug,
        "space_id": space_id,
        "region_code": region_code,
        "text": text,
    }


def _space_term_score(
    field_value: str,
    term: str,
    *,
    exact: float,
    prefix: float,
    contains: float,
) -> float:
    if not field_value or not term:
        return 0.0
    if field_value == term:
        return exact
    if field_value.startswith(term):
        return prefix
    words = field_value.replace("-", " ").replace("_", " ").split()
    if any(word.startswith(term) for word in words):
        return max(prefix - 0.5, contains)
    if term in field_value:
        return contains
    return 0.0


def _space_search_score(
    *,
    space,
    localized_name: str,
    parsed: ParsedSearchQuery | None,
) -> float:
    if parsed is None:
        return 0.0

    values = _space_search_values(space=space, localized_name=localized_name)
    name = values["name"]
    slug = values["slug"]
    space_id = values["space_id"]
    region_code = values["region_code"]
    normalized_query = parsed.raw.strip().lower()
    score = 0.0

    score += _space_term_score(name, normalized_query, exact=12.0, prefix=8.0, contains=5.0)
    score += _space_term_score(slug, normalized_query, exact=10.0, prefix=7.0, contains=4.0)
    score += _space_term_score(space_id, normalized_query, exact=8.0, prefix=5.5, contains=3.0)
    score += _space_term_score(region_code, normalized_query, exact=6.0, prefix=4.0, contains=2.0)

    positive_text_terms = {
        token.normalized_value
        for token in parsed.text_tokens
        if token.normalized_value and not token.is_negated
    }
    for term in positive_text_terms:
        score += _space_term_score(name, term, exact=5.0, prefix=3.5, contains=2.0)
        score += _space_term_score(slug, term, exact=4.0, prefix=3.0, contains=1.5)
        score += _space_term_score(space_id, term, exact=3.0, prefix=2.0, contains=1.0)
        score += _space_term_score(region_code, term, exact=2.0, prefix=1.5, contains=0.8)

    for token in parsed.field_tokens:
        if token.is_negated or not token.normalized_value:
            continue
        value = token.normalized_value
        field = token.normalized_field
        if field in {"name", "title"}:
            score += _space_term_score(name, value, exact=4.5, prefix=3.0, contains=2.0)
        elif field in {"slug"}:
            score += _space_term_score(slug, value, exact=4.0, prefix=2.8, contains=1.8)
        elif field in {"id", "space", "space_id", "spaceid"}:
            score += _space_term_score(space_id, value, exact=3.5, prefix=2.4, contains=1.5)
        elif field in {"region", "region_code"}:
            score += _space_term_score(region_code, value, exact=3.0, prefix=2.2, contains=1.4)

    return score


def _space_search_sort_key(
    *,
    space,
    localized_name: str,
    parsed: ParsedSearchQuery | None,
) -> tuple[float, str, str, str]:
    values = _space_search_values(space=space, localized_name=localized_name)
    return (
        -_space_search_score(
            space=space,
            localized_name=localized_name,
            parsed=parsed,
        ),
        values["name"],
        values["slug"],
        values["space_id"],
    )


def _space_matches_query(
    *,
    space,
    localized_name: str,
    parsed: ParsedSearchQuery | None,
) -> bool:
    if parsed is None:
        return True
    values = _space_search_values(space=space, localized_name=localized_name)
    name = values["name"]
    slug = values["slug"]
    space_id = values["space_id"]
    region_code = values["region_code"]
    text = values["text"]

    def matches_field(token) -> bool:
        field = token.normalized_field
        value = token.normalized_value
        if not value:
            return True
        if field in {"name", "title"}:
            base = value in name
        elif field in {"slug"}:
            base = value in slug
        elif field in {"id", "space", "space_id", "spaceid"}:
            base = value in space_id
        elif field in {"region", "region_code"}:
            base = value in region_code
        else:
            base = value in text
        return (not base) if token.is_negated else base

    def matches_text(token) -> bool:
        return token.normalized_value in text

    return evaluate_search_expression(
        parsed.expression,
        matches_field=matches_field,
        matches_text=matches_text,
    )


@router.get("", response_model=list[SpaceOut])
def list_spaces(
    q: str | None = None,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    spaces = service.list_spaces_for_user(db, user.id)
    normalized_query = (q or "").strip()
    parsed_query = parse_search_query_ast(normalized_query) if normalized_query else None
    localized_name_by_space_id = _localized_space_names_by_id(
        db,
        user_id=user.id,
        space_ids=[space.id for space in spaces],
    )

    filtered_spaces = [
        space
        for space in spaces
        if _space_matches_query(
            space=space,
            localized_name=localized_name_by_space_id.get(space.id, space.name),
            parsed=parsed_query,
        )
    ]
    if parsed_query is not None:
        filtered_spaces.sort(
            key=lambda space: _space_search_sort_key(
                space=space,
                localized_name=localized_name_by_space_id.get(
                    space.id,
                    space.name,
                ),
                parsed=parsed_query,
            )
        )
    filtered_space_ids = [space.id for space in filtered_spaces]
    member_count_by_space_id = _member_count_by_space_id(
        db,
        space_ids=filtered_space_ids,
    )
    active_incident_count_by_space_id = _active_incident_count_by_space_id(
        db,
        space_ids=filtered_space_ids,
    )
    open_task_count_by_space_id = _open_task_count_by_space_id(
        db,
        space_ids=filtered_space_ids,
    )

    out = [
        SpaceOut(
            id=s.id,
            name=localized_name_by_space_id.get(s.id, s.name),
            slug=s.slug,
            region_code=s.region_code,
            meta=_meta_from_json(s.meta_json),
            member_count=member_count_by_space_id.get(s.id, 0),
            active_incident_count=active_incident_count_by_space_id.get(s.id, 0),
            open_task_count=open_task_count_by_space_id.get(s.id, 0),
        )
        for s in filtered_spaces
    ]
    if normalized_query:
        analytics_service.track(
            db,
            user.id,
            TrackEventIn(
                session_id="spaces-search",
                event_type="search_query_issued",
                entity_type="space",
                path="/spaces",
                meta={"surface": "spaces", "query": normalized_query},
            ),
        )
        analytics_service.track(
            db,
            user.id,
            TrackEventIn(
                session_id="spaces-search",
                event_type="search_results_shown" if out else "search_no_result",
                entity_type="space",
                path="/spaces",
                meta={"surface": "spaces", "query": normalized_query, "results": len(out)},
            ),
        )

    return out


@router.post("", response_model=SpaceOut)
def create_space(payload: SpaceCreateIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    s = service.create_space(
        db,
        payload.name,
        payload.slug,
        user.id,
        region_code=payload.region_code,
        meta_json=None if payload.meta is None else json.dumps(payload.meta, ensure_ascii=False, separators=(",", ":")),
    )
    localized_name_by_space_id = _localized_space_names_by_id(
        db,
        user_id=user.id,
        space_ids=[s.id],
    )
    return SpaceOut(
        id=s.id,
        name=localized_name_by_space_id.get(s.id, s.name),
        slug=s.slug,
        region_code=s.region_code,
        meta=_meta_from_json(s.meta_json),
        member_count=0,
        active_incident_count=0,
        open_task_count=0,
    )


@router.get("/{space_id}/members", response_model=list[SpaceMemberOut])
def members(space_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    service.require_space_role(db, space_id, user.id, {"admin", "moderator"})
    ms = service.list_members(db, space_id)
    return [SpaceMemberOut(user_id=m.user_id, role=m.role) for m in ms]


@router.get("/{space_id}/members/detailed", response_model=list[SpaceMemberDetailOut])
def members_detailed(
    space_id: str,
    direct_reports_for_user_id: str | None = None,
    managers_only: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    service.require_space_role(db, space_id, user.id, {"admin", "moderator", "member"})
    if direct_reports_for_user_id and direct_reports_for_user_id != user.id:
        service.require_space_role(db, space_id, user.id, {"admin", "moderator"})
    ms = (
        service.list_direct_reports(
            db,
            space_id=space_id,
            manager_user_id=direct_reports_for_user_id,
        )
        if direct_reports_for_user_id
        else service.list_members(db, space_id)
    )
    users_by_id = {u.id: u for u in db.execute(select(User).where(User.id.in_([m.user_id for m in ms]))).scalars().all()} if ms else {}
    report_count_by_user_id = service.member_report_counts(db, space_id) if ms else {}
    out: list[SpaceMemberDetailOut] = []
    for m in ms:
        u = users_by_id.get(m.user_id)
        if not u:
            continue
        report_count = int(report_count_by_user_id.get(m.user_id, 0) or 0)
        if managers_only and report_count <= 0:
            continue
        out.append(
            SpaceMemberDetailOut(
                user_id=m.user_id,
                role=m.role,
                name=u.name,
                email=u.email,
                report_count=report_count,
                is_manager=report_count > 0,
            )
        )
    return out
