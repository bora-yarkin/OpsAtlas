# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for knowledge-base authoring, search, review, and lifecycle flows."""

from __future__ import annotations

import difflib
import json
import re
import unicodedata
import uuid
from collections import Counter
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy import and_, case, func, literal, select, text as sql_text
from sqlalchemy.orm import Session
from sqlalchemy.sql.elements import ColumnElement

from app.core.deps import bad_request, not_found
from app.core.search.ast import parse_search_query_ast
from app.core.search.translation import SearchFieldCapability, compile_search_translation
from app.core.rich_html import sanitize_rich_html
from app.modules.analytics import service as analytics_service
from app.modules.analytics.models import Event
from app.modules.analytics.schemas import TrackEventIn
from app.modules.auth.models import User
from app.modules.auth.deps import resolve_user_auth_role
from app.modules.localization.models import LocalizationTranslationVariant
from app.modules.localization import service as localization_service
from app.modules.media import service as media_service
from app.modules.spaces import service as spaces_service
from app.modules.spaces.models import Space

from . import repo
from .models import (
    Doc,
    DocComment,
    DocMentionNotification,
    DocMeta,
    DocReviewAssignment,
    DocVersion,
    Folder,
    KbSpacePolicy,
)
from .schemas import (
    DocCommentOut,
    DocDiffOut,
    DocDiffRowOut,
    DocMentionNotificationOut,
    DocOut,
    KbRelevanceBenchmarkSummaryOut,
    DocReviewSummaryOut,
    DocReviewerSuggestionOut,
    KbSearchSuggestionOut,
    KbSpacePolicyOut,
)

TRASH_RETENTION_DAYS = 30
DEFAULT_REVIEW_REMINDER_DAYS = 3
MAX_REVIEW_REMINDER_DAYS = 14
MAX_TRASH_RETENTION_DAYS = 365
AUTO_PURGE_INTERVAL = timedelta(hours=12)

_MENTION_PATTERN = re.compile(r"(?<!\w)@([A-Za-z0-9._-]{2,64})")
_SEARCH_INDEX_CACHE: set[str] = set()
_SEARCH_SYNONYMS: dict[str, set[str]] = {
    "login": {"signin", "sign-in", "authentication", "auth"},
    "incident": {"outage", "issue", "degradation", "sev"},
    "deploy": {"release", "rollout", "shipment"},
    "refund": {"reimbursement", "chargeback", "return"},
    "customer": {"client", "buyer", "shopper"},
    "backup": {"snapshot", "restore", "recovery"},
}

MAX_LEXICON_TERMS = 64
MAX_SYNONYM_ROOTS = 64
MAX_SYNONYMS_PER_ROOT = 12
MAX_LOCALIZED_SEARCH_LANGUAGES = 12
MAX_RELEVANCE_BENCHMARK_CASES = 64
MAX_SEARCH_SUGGESTIONS = 12
RELEVANCE_BENCHMARK_INTERVAL = timedelta(hours=12)
_DISPLAYABLE_TRANSLATION_VARIANT_STATUSES = frozenset(
    {"translated", "needs_review", "approved", "fallback", "locked"}
)
_SEARCH_TS_CONFIGS: dict[str, str] = {
    "de": "german",
    "en": "english",
    "tr": "turkish",
}
_TRANSLITERATION_EXPANSIONS = str.maketrans(
    {
        "ä": "ae",
        "ö": "oe",
        "ü": "ue",
        "ß": "ss",
        "ç": "c",
        "ğ": "g",
        "ı": "i",
        "İ": "i",
        "ş": "s",
    }
)


def _normalize_optional_id(value: str | None) -> str | None:
    normalized = (value or "").strip()
    return normalized or None


def _normalize_search_bool(value: str) -> bool | None:
    normalized = value.strip().lower()
    if not normalized:
        return None
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return None


def _normalize_language_code(value: object | None) -> str | None:
    normalized = str(value or "").strip().lower().replace("_", "-")
    if not normalized:
        return None
    if not re.fullmatch(r"[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})*", normalized):
        return None
    return normalized[:16]


def _language_candidates(language_code: str | None) -> tuple[str, ...]:
    normalized = _normalize_language_code(language_code)
    if normalized is None:
        return ()
    candidates = [normalized]
    if "-" in normalized:
        base = normalized.split("-", 1)[0]
        if base not in candidates:
            candidates.append(base)
    return tuple(candidates)


def _search_config_for_language(language_code: str | None) -> str:
    for candidate in _language_candidates(language_code):
        config = _SEARCH_TS_CONFIGS.get(candidate)
        if config is not None:
            return config
    return "simple"


def _json_tag_like_pattern(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f'%"{escaped}"%'


def _kb_doc_search_capabilities(*, now_utc: datetime) -> tuple[SearchFieldCapability, ...]:
    return (
        SearchFieldCapability(
            name="status",
            aliases=("state",),
            value_type="enum",
            predicate_builder=lambda value: func.lower(Doc.status) == value,
            score_builder=lambda value: case((func.lower(Doc.status) == value, 2.6), else_=0.0),
        ),
        SearchFieldCapability(
            name="tag",
            aliases=("tags",),
            value_type="text",
            predicate_builder=lambda value: func.lower(func.coalesce(DocMeta.tags_json, "")).like(
                _json_tag_like_pattern(value),
                escape="\\",
            ),
            score_builder=lambda value: case(
                (
                    func.lower(func.coalesce(DocMeta.tags_json, "")).like(
                        _json_tag_like_pattern(value),
                        escape="\\",
                    ),
                    2.2,
                ),
                else_=0.0,
            ),
        ),
        SearchFieldCapability(
            name="folder",
            aliases=("folder_id",),
            value_type="text",
            predicate_builder=lambda value: func.lower(func.coalesce(Doc.folder_id, "")).like(f"%{value.replace('%', '').replace('_', '')}%"),
            score_builder=lambda value: case(
                (
                    func.lower(func.coalesce(Doc.folder_id, "")) == value,
                    1.8,
                ),
                (
                    func.lower(func.coalesce(Doc.folder_id, "")).like(f"%{value.replace('%', '').replace('_', '')}%"),
                    0.9,
                ),
                else_=0.0,
            ),
        ),
        SearchFieldCapability(
            name="trash",
            aliases=("deleted",),
            value_type="bool",
            predicate_builder=lambda value: _kb_bool_clause(DocMeta.deleted_at.is_not(None), value),
            score_builder=lambda value: case(
                (_kb_bool_clause_or_false(DocMeta.deleted_at.is_not(None), value), 1.6),
                else_=0.0,
            ),
        ),
        SearchFieldCapability(
            name="stale",
            aliases=("needs_review",),
            value_type="bool",
            predicate_builder=lambda value: _kb_bool_clause(
                and_(DocMeta.review_due_at.is_not(None), DocMeta.review_due_at <= now_utc),
                value,
            ),
            score_builder=lambda value: case(
                (
                    _kb_bool_clause_or_false(
                        and_(DocMeta.review_due_at.is_not(None), DocMeta.review_due_at <= now_utc),
                        value,
                    ),
                    1.6,
                ),
                else_=0.0,
            ),
        ),
    )


def _kb_bool_clause(base_clause: ColumnElement[bool], value: str) -> ColumnElement[bool] | None:
    parsed = _normalize_search_bool(value)
    if parsed is None:
        return None
    return base_clause if parsed else ~base_clause


def _kb_bool_clause_or_false(base_clause: ColumnElement[bool], value: str) -> ColumnElement[bool]:
    return _kb_bool_clause(base_clause, value) or literal(False)


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _coerce_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _normalize_tags(raw: list[str] | None) -> list[str]:
    if raw is None:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        tag = item.strip().lower()
        if not tag:
            continue
        tag = "-".join(part for part in tag.replace("_", "-").split() if part).strip("-")
        if not tag or tag in seen:
            continue
        seen.add(tag)
        out.append(tag[:40])
    return out[:12]


def _tags_to_json(tags: list[str]) -> str:
    return json.dumps(tags, separators=(",", ":"))


def _tags_from_json(raw: str | None) -> list[str]:
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    return [str(v) for v in decoded if isinstance(v, str)]


def _normalize_reminder_days(value: int | None) -> int:
    if value is None:
        return DEFAULT_REVIEW_REMINDER_DAYS
    return max(0, min(MAX_REVIEW_REMINDER_DAYS, int(value)))


def _normalize_trash_retention_days(value: int | None) -> int:
    if value is None:
        return TRASH_RETENTION_DAYS
    return max(1, min(MAX_TRASH_RETENTION_DAYS, int(value)))


def _search_terms(text: str) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for variant in _search_text_variants(text):
        for token in re.findall(r"[^\W_]+", variant, flags=re.UNICODE):
            if not token or token in seen:
                continue
            seen.add(token)
            out.append(token)
    return out


def _search_text_variants(text: str) -> tuple[str, ...]:
    normalized = " ".join(str(text or "").casefold().split())
    if not normalized:
        return ()
    variants = {normalized}
    transliterated = " ".join(normalized.translate(_TRANSLITERATION_EXPANSIONS).split())
    if transliterated:
        variants.add(transliterated)
    stripped = "".join(
        char
        for char in unicodedata.normalize("NFKD", normalized)
        if not unicodedata.combining(char)
    )
    stripped = " ".join(stripped.split())
    if stripped:
        variants.add(stripped)
    return tuple(sorted(variant for variant in variants if variant))


def _normalize_lexicon(raw: list[str] | None) -> list[str]:
    if raw is None:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        clean = " ".join(part for part in str(item).strip().lower().split() if part)
        if not clean or clean in seen:
            continue
        seen.add(clean)
        out.append(clean[:80])
        if len(out) >= MAX_LEXICON_TERMS:
            break
    return out


def _normalize_synonym_map(raw: dict[str, list[str]] | None) -> dict[str, list[str]]:
    if raw is None:
        return {}
    out: dict[str, list[str]] = {}
    for key, values in raw.items():
        root = " ".join(part for part in str(key).strip().lower().split() if part)
        if not root:
            continue
        synonyms = _normalize_lexicon(values)
        if not synonyms:
            continue
        out[root[:80]] = synonyms[:MAX_SYNONYMS_PER_ROOT]
        if len(out) >= MAX_SYNONYM_ROOTS:
            break
    return out


def _normalize_localized_synonym_map(
    raw: dict[str, dict[str, list[str]]] | None,
) -> dict[str, dict[str, list[str]]]:
    if raw is None:
        return {}
    out: dict[str, dict[str, list[str]]] = {}
    for key, values in raw.items():
        language_code = _normalize_language_code(key)
        if language_code is None:
            continue
        normalized = _normalize_synonym_map(values)
        if not normalized:
            continue
        out[language_code] = normalized
        if len(out) >= MAX_LOCALIZED_SEARCH_LANGUAGES:
            break
    return out


def _localized_synonym_map_to_json(values: dict[str, dict[str, list[str]]]) -> str:
    return json.dumps(
        _normalize_localized_synonym_map(values),
        ensure_ascii=False,
        separators=(",", ":"),
    )


def _localized_synonym_map_from_json(raw: str | None) -> dict[str, dict[str, list[str]]]:
    if not raw:
        return {}
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(decoded, dict):
        return {}
    normalized: dict[str, dict[str, list[str]]] = {}
    for key, value in decoded.items():
        if not isinstance(value, dict):
            continue
        inner: dict[str, list[str]] = {}
        for inner_key, inner_value in value.items():
            if isinstance(inner_value, list):
                inner[str(inner_key)] = [str(item) for item in inner_value]
        normalized[str(key)] = inner
    return _normalize_localized_synonym_map(normalized)


def _synonym_map_to_json(values: dict[str, list[str]]) -> str:
    return json.dumps(_normalize_synonym_map(values), separators=(",", ":"))


def _synonym_map_from_json(raw: str | None) -> dict[str, list[str]]:
    if not raw:
        return {}
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(decoded, dict):
        return {}
    normalized: dict[str, list[str]] = {}
    for key, value in decoded.items():
        if isinstance(value, list):
            normalized[str(key)] = [str(item) for item in value]
    return _normalize_synonym_map(normalized)


def _lexicon_to_json(values: list[str]) -> str:
    return json.dumps(_normalize_lexicon(values), separators=(",", ":"))


def _lexicon_from_json(raw: str | None) -> list[str]:
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    return _normalize_lexicon([str(item) for item in decoded])


def _normalize_localized_lexicon_map(
    raw: dict[str, list[str]] | None,
) -> dict[str, list[str]]:
    if raw is None:
        return {}
    out: dict[str, list[str]] = {}
    for key, values in raw.items():
        language_code = _normalize_language_code(key)
        if language_code is None:
            continue
        normalized = _normalize_lexicon(values)
        if not normalized:
            continue
        out[language_code] = normalized
        if len(out) >= MAX_LOCALIZED_SEARCH_LANGUAGES:
            break
    return out


def _localized_lexicon_to_json(values: dict[str, list[str]]) -> str:
    return json.dumps(
        _normalize_localized_lexicon_map(values),
        ensure_ascii=False,
        separators=(",", ":"),
    )


def _localized_lexicon_from_json(raw: str | None) -> dict[str, list[str]]:
    if not raw:
        return {}
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(decoded, dict):
        return {}
    normalized: dict[str, list[str]] = {}
    for key, value in decoded.items():
        if isinstance(value, list):
            normalized[str(key)] = [str(item) for item in value]
    return _normalize_localized_lexicon_map(normalized)


def _normalize_relevance_benchmark_case(item: object) -> dict[str, str | None] | None:
    raw = item.model_dump() if hasattr(item, "model_dump") else item
    if not isinstance(raw, dict):
        return None
    language_code = _normalize_language_code(raw.get("language_code")) or "en"
    query = " ".join(str(raw.get("query") or "").strip().split())
    expected_doc_id = str(raw.get("expected_doc_id") or "").strip()
    expected_slug = str(raw.get("expected_slug") or "").strip().lower()
    if not query or (not expected_doc_id and not expected_slug):
        return None
    return {
        "language_code": language_code,
        "query": query[:240],
        "expected_doc_id": expected_doc_id[:120] or None,
        "expected_slug": expected_slug[:300] or None,
    }


def _normalize_relevance_benchmarks(
    raw: list[object] | None,
) -> list[dict[str, str | None]]:
    if raw is None:
        return []
    out: list[dict[str, str | None]] = []
    seen: set[tuple[str, str, str | None, str | None]] = set()
    for item in raw:
        normalized = _normalize_relevance_benchmark_case(item)
        if normalized is None:
            continue
        key = (
            normalized["language_code"],
            normalized["query"],
            normalized["expected_doc_id"],
            normalized["expected_slug"],
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(normalized)
        if len(out) >= MAX_RELEVANCE_BENCHMARK_CASES:
            break
    return out


def _relevance_benchmarks_to_json(values: list[object]) -> str:
    return json.dumps(
        _normalize_relevance_benchmarks(values),
        ensure_ascii=False,
        separators=(",", ":"),
    )


def _relevance_benchmarks_from_json(raw: str | None) -> list[dict[str, str | None]]:
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, list):
        return []
    return _normalize_relevance_benchmarks(decoded)


def _benchmark_results_to_json(values: list[dict[str, object]]) -> str:
    return json.dumps(values, ensure_ascii=False, separators=(",", ":"))


def _benchmark_results_from_json(raw: str | None) -> list[dict[str, object]]:
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
        if isinstance(item, dict):
            out.append({str(key): value for key, value in item.items()})
    return out


def _expanded_search_terms(
    text: str,
    *,
    space_synonyms: dict[str, list[str]] | None = None,
) -> set[str]:
    terms = set(_search_terms(text))
    expanded = set(terms)
    for term in terms:
        for key, synonyms in _SEARCH_SYNONYMS.items():
            if term == key or term in synonyms:
                expanded.add(key)
                expanded.update(synonyms)
        for key, synonyms in (space_synonyms or {}).items():
            synonym_set = set(synonyms)
            if term == key or term in synonym_set:
                expanded.add(key)
                expanded.update(synonym_set)
    return expanded


def _merged_search_profile(
    policy: KbSpacePolicy,
    *,
    language_code: str,
) -> tuple[dict[str, list[str]], list[str]]:
    base_synonyms = _synonym_map_from_json(policy.synonyms_json)
    base_lexicon = _lexicon_from_json(policy.lexicon_json)
    localized_synonyms = _localized_synonym_map_from_json(policy.localized_synonyms_json)
    localized_lexicon = _localized_lexicon_from_json(policy.localized_lexicon_json)

    merged_synonyms = {key: list(values) for key, values in base_synonyms.items()}
    for candidate in _language_candidates(language_code):
        for key, values in localized_synonyms.get(candidate, {}).items():
            merged = _normalize_lexicon([*(merged_synonyms.get(key, [])), *values])
            if merged:
                merged_synonyms[key] = merged[:MAX_SYNONYMS_PER_ROOT]

    merged_lexicon = list(base_lexicon)
    for candidate in _language_candidates(language_code):
        merged_lexicon = _normalize_lexicon(
            [*merged_lexicon, *localized_lexicon.get(candidate, [])]
        )

    return merged_synonyms, merged_lexicon


def _text_similarity(a: str, b: str) -> float:
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def _ensure_search_indexes(db: Session) -> None:
    bind = db.get_bind()
    if bind is None or bind.dialect.name != "postgresql":
        return
    key = str(bind.engine.url)
    if key in _SEARCH_INDEX_CACHE:
        return
    for config in sorted(set(_SEARCH_TS_CONFIGS.values()) | {"simple"}):
        safe_name = config.replace("-", "_")
        db.execute(
            sql_text(
                f"""
                CREATE INDEX IF NOT EXISTS ix_docs_search_title_slug_{safe_name}
                ON docs USING GIN (
                  to_tsvector('{config}', coalesce(title, '') || ' ' || coalesce(slug, ''))
                )
                """
            )
        )
        db.execute(
            sql_text(
                f"""
                CREATE INDEX IF NOT EXISTS ix_docs_search_content_{safe_name}
                ON docs USING GIN (
                  to_tsvector('{config}', coalesce(content_md, ''))
                )
                """
            )
        )
    db.commit()
    _SEARCH_INDEX_CACHE.add(key)


def _weighted_search_vector(
    search_config: str,
    *,
    localized_title_column: object | None = None,
    localized_content_column: object | None = None,
):
    title_vector = func.setweight(
        func.to_tsvector(search_config, func.coalesce(Doc.title, "")),
        "A",
    )
    slug_vector = func.setweight(
        func.to_tsvector(search_config, func.coalesce(Doc.slug, "")),
        "B",
    )
    body_vector = func.setweight(
        func.to_tsvector(search_config, func.coalesce(Doc.content_md, "")),
        "C",
    )
    vector = title_vector.op("||")(slug_vector).op("||")(body_vector)
    if localized_title_column is not None:
        localized_title_vector = func.setweight(
            func.to_tsvector(search_config, func.coalesce(localized_title_column, "")),
            "A",
        )
        vector = vector.op("||")(localized_title_vector)
    if localized_content_column is not None:
        localized_content_vector = func.setweight(
            func.to_tsvector(search_config, func.coalesce(localized_content_column, "")),
            "C",
        )
        vector = vector.op("||")(localized_content_vector)
    return vector


def _localized_doc_search_fields_subquery(language_code: str):
    normalized_language = _normalize_language_code(language_code) or "en"
    return (
        select(
            LocalizationTranslationVariant.content_id.label("doc_id"),
            func.max(
                case(
                    (
                        LocalizationTranslationVariant.field_key == "title",
                        LocalizationTranslationVariant.translated_text,
                    ),
                    else_="",
                )
            ).label("localized_title"),
            func.max(
                case(
                    (
                        LocalizationTranslationVariant.field_key == "content",
                        LocalizationTranslationVariant.translated_text,
                    ),
                    else_="",
                )
            ).label("localized_content"),
        )
        .where(
            LocalizationTranslationVariant.content_kind == "doc",
            LocalizationTranslationVariant.language_code == normalized_language,
            LocalizationTranslationVariant.field_key.in_(("title", "content")),
            LocalizationTranslationVariant.status.in_(
                sorted(_DISPLAYABLE_TRANSLATION_VARIANT_STATUSES)
            ),
        )
        .group_by(LocalizationTranslationVariant.content_id)
        .subquery()
    )


def _localized_doc_search_text_map(
    db: Session,
    *,
    doc_ids: list[str],
    language_code: str,
) -> dict[str, dict[str, str]]:
    normalized_ids = [doc_id for doc_id in doc_ids if doc_id]
    if not normalized_ids:
        return {}
    normalized_language = _normalize_language_code(language_code) or "en"
    rows = db.execute(
        select(
            LocalizationTranslationVariant.content_id,
            LocalizationTranslationVariant.field_key,
            LocalizationTranslationVariant.translated_text,
        ).where(
            LocalizationTranslationVariant.content_kind == "doc",
            LocalizationTranslationVariant.content_id.in_(normalized_ids),
            LocalizationTranslationVariant.language_code == normalized_language,
            LocalizationTranslationVariant.field_key.in_(("title", "content")),
            LocalizationTranslationVariant.status.in_(
                sorted(_DISPLAYABLE_TRANSLATION_VARIANT_STATUSES)
            ),
        )
    ).all()
    out: dict[str, dict[str, str]] = {}
    for content_id, field_key, translated_text in rows:
        if not translated_text:
            continue
        doc_fields = out.setdefault(str(content_id), {})
        doc_fields[str(field_key)] = str(translated_text)
    return out


def _recent_search_query_counts(
    db: Session,
    *,
    space_id: str,
) -> Counter[str]:
    rows = db.execute(
        select(Event.event_type, Event.meta_json)
        .where(
            Event.space_id == space_id,
            Event.entity_type == "doc",
            Event.event_type.in_(("search_query_issued", "open")),
        )
        .order_by(Event.ts.desc())
        .limit(400)
    ).all()
    counts: Counter[str] = Counter()
    for event_type, meta_json in rows:
        meta = analytics_service._parse_meta_json(meta_json)
        query = " ".join(
            str(meta.get("search_query") or meta.get("query") or "").split()
        )
        if not query:
            continue
        weight = 1.0
        if event_type == "open" and meta.get("positive_search_outcome") is True:
            weight = 3.0
        counts[query] += weight
    return counts


def _suggestion_matches(query: str, candidate: str) -> bool:
    normalized_query = " ".join(query.casefold().split())
    normalized_candidate = " ".join(candidate.casefold().split())
    if not normalized_query:
        return True
    query_variants = set(_search_text_variants(normalized_query))
    candidate_variants = set(_search_text_variants(normalized_candidate))
    if any(
        query_variant in candidate_variant
        for query_variant in query_variants
        for candidate_variant in candidate_variants
    ):
        return True
    query_terms = set(_search_terms(normalized_query))
    candidate_terms = set(_search_terms(normalized_candidate))
    return bool(query_terms.intersection(candidate_terms))


def _trash_expires_at(meta: DocMeta | None, *, retention_days: int = TRASH_RETENTION_DAYS) -> datetime | None:
    if meta is None or meta.deleted_at is None:
        return None
    deleted_at = _coerce_utc(meta.deleted_at)
    if deleted_at is None:
        return None
    return deleted_at + timedelta(days=retention_days)


def _mention_aliases(user: User) -> set[str]:
    aliases: set[str] = set()
    email = user.email.strip().lower()
    if email:
        aliases.add(email)
        aliases.add(email.split("@", 1)[0])
    name = user.name.strip().lower()
    if name:
        aliases.add(name)
        aliases.add(name.replace(" ", ""))
        aliases.add(name.replace(" ", "."))
        aliases.add(name.replace(" ", "_"))
        aliases.add(name.replace(" ", "-"))
    return {alias for alias in aliases if alias}


def _ensure_doc_meta(db: Session, doc_id: str) -> DocMeta:
    meta = repo.get_doc_meta(db, doc_id)
    if meta:
        return meta
    meta = DocMeta(doc_id=doc_id, tags_json="[]")
    db.add(meta)
    db.flush()
    return meta


def _ensure_review_assignment(db: Session, doc_id: str) -> DocReviewAssignment:
    assignment = repo.get_review_assignment(db, doc_id)
    if assignment:
        return assignment
    assignment = DocReviewAssignment(
        doc_id=doc_id,
        reviewer_user_id=None,
        reminder_days=DEFAULT_REVIEW_REMINDER_DAYS,
    )
    db.add(assignment)
    db.flush()
    return assignment


def _ensure_space_policy(db: Session, space_id: str) -> KbSpacePolicy:
    policy = repo.get_space_policy(db, space_id)
    if policy:
        return policy
    policy = KbSpacePolicy(
        space_id=space_id,
        trash_retention_days=TRASH_RETENTION_DAYS,
        synonyms_json="{}",
        lexicon_json="[]",
        localized_synonyms_json="{}",
        localized_lexicon_json="{}",
        relevance_benchmarks_json="[]",
        last_purge_run_at=None,
        last_relevance_benchmark_run_at=None,
        last_relevance_benchmark_score=None,
        last_relevance_benchmark_results_json="[]",
    )
    db.add(policy)
    db.flush()
    return policy


def _validate_reviewer(db: Session, *, space_id: str, reviewer_user_id: str | None) -> str | None:
    normalized = (reviewer_user_id or "").strip() or None
    if normalized is None:
        return None
    role_key = spaces_service.get_space_role(db, space_id, normalized)
    if role_key is None:
        raise bad_request("Reviewer must be a member of this space")
    return normalized


def _is_deleted(meta: DocMeta | None) -> bool:
    return meta is not None and meta.deleted_at is not None


def _is_stale(meta: DocMeta | None) -> bool:
    if meta is None or meta.review_due_at is None:
        return False
    due_at = _coerce_utc(meta.review_due_at)
    if due_at is None:
        return False
    return due_at <= _now_utc()


def _comment_count_map(db: Session, doc_ids: list[str]) -> dict[str, int]:
    if not doc_ids:
        return {}
    q = select(DocComment.doc_id, func.count(DocComment.id)).where(DocComment.doc_id.in_(doc_ids)).group_by(DocComment.doc_id)
    return {str(doc_id): int(count or 0) for doc_id, count in db.execute(q).all()}


def _mentioned_aliases(body_md: str) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for match in _MENTION_PATTERN.findall(body_md):
        token = match.strip().lower()
        if token and token not in seen:
            seen.add(token)
            out.append(token)
    return out


def _resolve_mentions_for_doc(db: Session, *, doc: Doc, body_md: str) -> list[User]:
    aliases = _mentioned_aliases(body_md)
    if not aliases:
        return []
    member_ids = [member.user_id for member in spaces_service.list_members(db, doc.space_id)]
    if not member_ids:
        return []
    rows = db.execute(select(User).where(User.id.in_(member_ids))).scalars().all()
    matched: list[User] = []
    for user in rows:
        if any(alias in _mention_aliases(user) for alias in aliases):
            matched.append(user)
    unique: dict[str, User] = {}
    for user in matched:
        unique[user.id] = user
    return list(unique.values())


def _comment_to_out(db: Session, comment: DocComment, *, author_name: str | None = None) -> DocCommentOut:
    doc = repo.get_doc(db, comment.doc_id)
    mentions: list[str] = []
    if doc is not None:
        mentions = [user.name for user in _resolve_mentions_for_doc(db, doc=doc, body_md=comment.body_md)]
    if author_name is None:
        author = db.get(User, comment.user_id)
        author_name = author.name if author else None
    return DocCommentOut(
        id=comment.id,
        doc_id=comment.doc_id,
        user_id=comment.user_id,
        author_name=author_name,
        body_md=comment.body_md,
        mentions=mentions,
        created_at=comment.created_at,
        updated_at=comment.updated_at,
    )


def _emit_comment_mentions(db: Session, *, actor_user_id: str, doc: Doc, comment: DocComment) -> None:
    for mentioned_user in _resolve_mentions_for_doc(db, doc=doc, body_md=comment.body_md):
        if mentioned_user.id == actor_user_id:
            continue
        notification = db.scalar(
            select(DocMentionNotification).where(
                DocMentionNotification.comment_id == comment.id,
                DocMentionNotification.user_id == mentioned_user.id,
            )
        )
        if notification is None:
            db.add(
                DocMentionNotification(
                    id=str(uuid.uuid4()),
                    doc_id=doc.id,
                    comment_id=comment.id,
                    user_id=mentioned_user.id,
                    read_at=None,
                )
            )
        analytics_service.track(
            db,
            actor_user_id,
            TrackEventIn(
                session_id="kb-comment",
                event_type="doc_comment_mention",
                space_id=doc.space_id,
                entity_type="doc",
                entity_id=doc.id,
                path=f"/spaces/{doc.space_id}?docSlug={doc.slug}",
                meta={
                    "comment_id": comment.id,
                    "mentioned_user_id": mentioned_user.id,
                    "mentioned_name": mentioned_user.name,
                },
            ),
        )
    db.commit()


def _mention_notification_to_out(db: Session, row: DocMentionNotification) -> DocMentionNotificationOut:
    doc = repo.get_doc(db, row.doc_id)
    comment = repo.get_doc_comment(db, row.comment_id)
    excerpt = ""
    if comment:
        excerpt = comment.body_md.strip().replace("\n", " ")[:180]
    if doc is None:
        raise not_found("Doc not found")
    return DocMentionNotificationOut(
        id=row.id,
        doc_id=row.doc_id,
        comment_id=row.comment_id,
        doc_title=doc.title,
        doc_slug=doc.slug,
        comment_excerpt=excerpt,
        created_at=row.created_at,
        read_at=row.read_at,
    )


def _to_out(db: Session, doc: Doc, *, comment_count: int | None = None) -> DocOut:
    meta = repo.get_doc_meta(db, doc.id)
    assignment = repo.get_review_assignment(db, doc.id)
    policy = _ensure_space_policy(db, doc.space_id)
    reviewer = db.get(User, assignment.reviewer_user_id) if assignment and assignment.reviewer_user_id else None
    folder = repo.get_folder(db, doc.folder_id) if doc.folder_id else None
    comments = comment_count
    if comments is None:
        comments = len(repo.list_comments(db, doc.id))
    return DocOut(
        id=doc.id,
        space_id=doc.space_id,
        folder_id=doc.folder_id,
        folder_path=folder.path if folder else None,
        title=doc.title,
        slug=doc.slug,
        status=doc.status,
        content_md=doc.content_md,
        tags=_tags_from_json(meta.tags_json if meta else None),
        created_at=doc.created_at,
        updated_at=doc.updated_at,
        published_at=doc.published_at,
        deleted_at=meta.deleted_at if meta else None,
        deleted_by=meta.deleted_by if meta else None,
        review_due_at=meta.review_due_at if meta else None,
        last_reviewed_at=meta.last_reviewed_at if meta else None,
        last_reviewed_by=meta.last_reviewed_by if meta else None,
        reviewer_user_id=assignment.reviewer_user_id if assignment else None,
        reviewer_name=reviewer.name if reviewer else None,
        review_reminder_days=assignment.reminder_days if assignment else None,
        trash_expires_at=_trash_expires_at(meta, retention_days=policy.trash_retention_days),
        comment_count=comments,
        is_stale=_is_stale(meta),
    )


def _heuristic_search_score(
    doc: Doc,
    terms: set[str],
    *,
    lexicon: list[str] | None = None,
    localized_title: str | None = None,
    localized_content: str | None = None,
) -> float:
    title_terms = _search_terms(
        " ".join(part for part in [doc.title, localized_title or ""] if part)
    )
    slug_terms = _search_terms(doc.slug)
    body_terms = _search_terms(
        " ".join(
            part for part in [doc.content_md[:4000], localized_content or ""] if part
        )
    )
    counts = Counter(title_terms + slug_terms + body_terms)
    score = 0.0
    haystacks = [
        *(_search_text_variants(doc.title)),
        *(_search_text_variants(doc.slug)),
        *(_search_text_variants(doc.content_md)),
        *(_search_text_variants(localized_title or "")),
        *(_search_text_variants(localized_content or "")),
    ]
    for term in terms:
        if term in title_terms:
            score += 10.0
        if term in slug_terms:
            score += 7.0
        score += min(4.0, counts.get(term, 0) * 1.5)
        best_similarity = max(
            [_text_similarity(term, token) for token in set(title_terms + slug_terms + body_terms[:40])],
            default=0.0,
        )
        if best_similarity >= 0.72:
            score += best_similarity * 4.5
    phrase = " ".join(sorted(terms))
    if any(
        variant and variant in hay
        for variant in _search_text_variants(phrase)
        for hay in haystacks
    ):
        score += 6.0
    for phrase_term in lexicon or ():
        if any(
            variant and variant in hay
            for variant in _search_text_variants(phrase_term)
            for hay in haystacks
        ):
            score += 3.0
    return score


def _relevance_benchmark_summary(policy: KbSpacePolicy) -> KbRelevanceBenchmarkSummaryOut:
    results = _benchmark_results_from_json(policy.last_relevance_benchmark_results_json)
    return KbRelevanceBenchmarkSummaryOut(
        total_cases=len(results),
        passed_cases=sum(1 for row in results if row.get("passed") is True),
        score=round(float(policy.last_relevance_benchmark_score or 0.0), 4),
        last_run_at=policy.last_relevance_benchmark_run_at,
        results=results,
    )


def run_due_purge_jobs(db: Session, *, space_id: str) -> int:
    policy = _ensure_space_policy(db, space_id)
    now = _now_utc()
    last_run = _coerce_utc(policy.last_purge_run_at)
    if last_run is not None and last_run + AUTO_PURGE_INTERVAL > now:
        return 0
    deleted_count = purge_trashed_docs(db, space_id=space_id, only_expired=True)
    policy = _ensure_space_policy(db, space_id)
    policy.last_purge_run_at = now
    db.commit()
    return deleted_count


def run_all_due_purge_jobs(db: Session) -> int:
    deleted_total = 0
    space_ids = db.execute(select(Space.id)).scalars().all()
    for space_id in space_ids:
        deleted_total += run_due_purge_jobs(db, space_id=space_id)
    return deleted_total


def run_space_relevance_benchmarks(
    db: Session,
    *,
    space_id: str,
    force: bool = False,
) -> KbRelevanceBenchmarkSummaryOut:
    policy = _ensure_space_policy(db, space_id)
    now = _now_utc()
    last_run = _coerce_utc(policy.last_relevance_benchmark_run_at)
    if not force and last_run is not None and last_run + RELEVANCE_BENCHMARK_INTERVAL > now:
        return _relevance_benchmark_summary(policy)

    cases = _relevance_benchmarks_from_json(policy.relevance_benchmarks_json)
    if not cases:
        policy.last_relevance_benchmark_run_at = now
        policy.last_relevance_benchmark_score = 0.0
        policy.last_relevance_benchmark_results_json = "[]"
        db.commit()
        db.refresh(policy)
        return _relevance_benchmark_summary(policy)

    results: list[dict[str, object]] = []
    score_total = 0.0
    for benchmark_case in cases:
        docs = _search_docs_internal(
            db,
            user_id=None,
            space_id=space_id,
            query=benchmark_case["query"],
            limit=10,
            track_analytics=False,
            explicit_language_code=benchmark_case["language_code"],
        )
        matched_doc: DocOut | None = None
        matched_rank: int | None = None
        for index, doc in enumerate(docs, start=1):
            if benchmark_case.get("expected_doc_id") and doc.id == benchmark_case["expected_doc_id"]:
                matched_doc = doc
                matched_rank = index
                break
            if benchmark_case.get("expected_slug") and doc.slug == benchmark_case["expected_slug"]:
                matched_doc = doc
                matched_rank = index
                break
        passed = matched_rank is not None and matched_rank <= 3
        if matched_rank is not None:
            score_total += 1.0 / matched_rank
        results.append(
            {
                "language_code": benchmark_case["language_code"],
                "query": benchmark_case["query"],
                "passed": passed,
                "matched_doc_id": None if matched_doc is None else matched_doc.id,
                "matched_slug": None if matched_doc is None else matched_doc.slug,
                "matched_title": None if matched_doc is None else matched_doc.title,
                "rank": matched_rank,
            }
        )

    policy.last_relevance_benchmark_run_at = now
    policy.last_relevance_benchmark_score = round(score_total / len(cases), 4)
    policy.last_relevance_benchmark_results_json = _benchmark_results_to_json(results)
    db.commit()
    db.refresh(policy)
    return _relevance_benchmark_summary(policy)


def run_all_due_relevance_benchmark_jobs(db: Session) -> int:
    processed = 0
    now = _now_utc()
    for policy in db.execute(select(KbSpacePolicy)).scalars().all():
        cases = _relevance_benchmarks_from_json(policy.relevance_benchmarks_json)
        if not cases:
            continue
        last_run = _coerce_utc(policy.last_relevance_benchmark_run_at)
        if last_run is not None and last_run + RELEVANCE_BENCHMARK_INTERVAL > now:
            continue
        run_space_relevance_benchmarks(db, space_id=policy.space_id, force=True)
        processed += 1
    return processed


def _resolve_slug_collision(db: Session, space_id: str, slug: str, *, current_doc_id: str | None = None) -> str:
    base = slug.strip().lower().strip("-")
    if not base:
        raise bad_request("Slug is required")
    candidate = base
    suffix = 2
    while True:
        existing = repo.get_doc_by_slug(db, space_id, candidate)
        if not existing or existing.id == current_doc_id:
            return candidate
        candidate = f"{base}-{suffix}"
        suffix += 1


def create_folder(db: Session, space_id: str, parent_id: str | None, name: str) -> Folder:
    parent_id = _normalize_optional_id(parent_id)
    parent_path = ""
    if parent_id:
        parent = repo.get_folder(db, parent_id)
        if not parent:
            raise not_found("Parent folder not found")
        if parent.space_id != space_id:
            raise bad_request("Parent folder space mismatch")
        parent_path = parent.path

    path = f"{parent_path}/{name}".replace("//", "/")
    folder = Folder(id=str(uuid.uuid4()), space_id=space_id, parent_id=parent_id, name=name, path=path)
    db.add(folder)
    db.commit()
    db.refresh(folder)
    return folder


def update_folder(
    db: Session,
    folder_id: str,
    *,
    name: str,
    parent_id: str | None,
) -> Folder:
    folder = repo.get_folder(db, folder_id)
    if not folder:
        raise not_found("Folder not found")

    parent_id = _normalize_optional_id(parent_id)
    if parent_id == folder.id:
        raise bad_request("Folder cannot be its own parent")

    parent_path = ""
    if parent_id:
        parent = repo.get_folder(db, parent_id)
        if not parent:
            raise not_found("Parent folder not found")
        if parent.space_id != folder.space_id:
            raise bad_request("Parent folder space mismatch")
        if parent.path == folder.path or parent.path.startswith(f"{folder.path}/"):
            raise bad_request("Folder cannot be moved into one of its descendants")
        parent_path = parent.path

    old_path = folder.path
    new_name = name.strip()
    if not new_name:
        raise bad_request("Folder name is required")
    new_path = f"{parent_path}/{new_name}".replace("//", "/")

    folder.name = new_name
    folder.parent_id = parent_id
    folder.path = new_path

    descendants = db.execute(
        select(Folder)
        .where(Folder.space_id == folder.space_id, Folder.path.like(f"{old_path}/%"))
        .order_by(Folder.path.asc())
    ).scalars().all()
    for child in descendants:
        suffix = child.path[len(old_path) :]
        child.path = f"{new_path}{suffix}"

    db.commit()
    db.refresh(folder)
    return folder


def create_doc(
    db: Session,
    user_id: str,
    space_id: str,
    folder_id: str | None,
    title: str,
    slug: str,
    content_md: str,
    *,
    tags: list[str] | None = None,
    review_due_at: datetime | None = None,
    reviewer_user_id: str | None = None,
    review_reminder_days: int | None = None,
) -> Doc:
    folder_id = _normalize_optional_id(folder_id)
    if folder_id:
        folder = repo.get_folder(db, folder_id)
        if not folder or folder.space_id != space_id:
            raise bad_request("Invalid folder")
    resolved_slug = _resolve_slug_collision(db, space_id, slug)
    sanitized_content = sanitize_rich_html(content_md)
    doc = Doc(
        id=str(uuid.uuid4()),
        space_id=space_id,
        folder_id=folder_id,
        title=title,
        slug=resolved_slug,
        status="draft",
        content_md=sanitized_content,
        created_by=user_id,
        updated_by=user_id,
    )
    db.add(doc)
    db.flush()
    meta = _ensure_doc_meta(db, doc.id)
    meta.tags_json = _tags_to_json(_normalize_tags(tags))
    meta.review_due_at = _coerce_utc(review_due_at)
    assignment = _ensure_review_assignment(db, doc.id)
    assignment.reviewer_user_id = _validate_reviewer(
        db,
        space_id=space_id,
        reviewer_user_id=reviewer_user_id,
    )
    assignment.reminder_days = _normalize_reminder_days(review_reminder_days)
    db.add(
        DocVersion(
            id=str(uuid.uuid4()),
            doc_id=doc.id,
            title=title,
            content_md=sanitized_content,
            created_by=user_id,
        )
    )
    media_service.sync_usage_refs(
        db,
        entity_type="doc",
        entity_id=doc.id,
        field_name="content",
        content=sanitized_content,
        space_id=space_id,
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="doc",
        content_id=doc.id,
        fields={
            "title": title,
            "content": sanitized_content,
        },
        actor_user_id=user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(doc)
    return doc


def update_doc(
    db: Session,
    user_id: str,
    doc_id: str,
    title: str,
    slug: str,
    content_md: str,
    folder_id: str | None,
    *,
    tags: list[str] | None = None,
    review_due_at: datetime | None = None,
    reviewer_user_id: str | None = None,
    review_reminder_days: int | None = None,
    base_updated_at: datetime | None = None,
) -> Doc:
    folder_id = _normalize_optional_id(folder_id)
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    meta = _ensure_doc_meta(db, doc.id)
    if _is_deleted(meta):
        raise bad_request("Cannot edit a doc in trash. Restore it first.")
    if folder_id:
        folder = repo.get_folder(db, folder_id)
        if not folder or folder.space_id != doc.space_id:
            raise bad_request("Invalid folder")
    current_updated_at = _coerce_utc(doc.updated_at)
    expected_updated_at = _coerce_utc(base_updated_at)
    if current_updated_at and expected_updated_at and current_updated_at > expected_updated_at:
        raise HTTPException(
            status_code=409,
            detail=f"This document was updated by another user at {current_updated_at.isoformat()}. Reload before saving.",
        )
    sanitized_content = sanitize_rich_html(content_md)
    doc.title = title
    doc.slug = _resolve_slug_collision(db, doc.space_id, slug, current_doc_id=doc.id)
    doc.content_md = sanitized_content
    doc.folder_id = folder_id
    doc.updated_by = user_id
    if tags is not None:
        meta.tags_json = _tags_to_json(_normalize_tags(tags))
    meta.review_due_at = _coerce_utc(review_due_at)
    assignment = _ensure_review_assignment(db, doc.id)
    assignment.reviewer_user_id = _validate_reviewer(
        db,
        space_id=doc.space_id,
        reviewer_user_id=reviewer_user_id,
    )
    assignment.reminder_days = _normalize_reminder_days(review_reminder_days)
    db.add(
        DocVersion(
            id=str(uuid.uuid4()),
            doc_id=doc.id,
            title=title,
            content_md=sanitized_content,
            created_by=user_id,
        )
    )
    media_service.sync_usage_refs(
        db,
        entity_type="doc",
        entity_id=doc.id,
        field_name="content",
        content=sanitized_content,
        space_id=doc.space_id,
    )
    localization_service.try_queue_content_translations(
        db,
        content_kind="doc",
        content_id=doc.id,
        fields={
            "title": title,
            "content": sanitized_content,
        },
        actor_user_id=user_id,
        triggered_by="auto_write",
    )
    db.commit()
    db.refresh(doc)
    return doc


def publish_doc(db: Session, doc_id: str) -> Doc:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    if _is_deleted(repo.get_doc_meta(db, doc_id)):
        raise bad_request("Cannot publish a doc in trash")
    doc.status = "published"
    doc.published_at = _now_utc()
    db.commit()
    db.refresh(doc)
    return doc


def unpublish_doc(db: Session, doc_id: str) -> Doc:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    doc.status = "draft"
    db.commit()
    db.refresh(doc)
    return doc


def list_docs_filtered(
    db: Session,
    *,
    space_id: str,
    folder_id: str | None,
    published_only: bool,
    all_folders: bool = False,
    query: str | None = None,
    tag: str | None = None,
    include_deleted: bool = False,
    trash_only: bool = False,
    only_stale: bool = False,
) -> list[DocOut]:
    folder_id = _normalize_optional_id(folder_id)
    now_utc = _now_utc()
    parsed = parse_search_query_ast((query or "").strip())
    translation = compile_search_translation(
        parsed,
        capabilities=_kb_doc_search_capabilities(now_utc=now_utc),
        text_columns=(Doc.title, Doc.slug, Doc.content_md),
        updated_at_column=Doc.updated_at,
    )

    stmt = (
        select(Doc)
        .outerjoin(DocMeta, DocMeta.doc_id == Doc.id)
        .where(
            Doc.space_id == space_id,
            translation.where_clause,
        )
    )

    if not all_folders and folder_id is None:
        stmt = stmt.where(Doc.folder_id.is_(None))
    elif folder_id is not None:
        stmt = stmt.where(Doc.folder_id == folder_id)

    if published_only:
        stmt = stmt.where(Doc.status == "published")

    wanted_tag = tag.strip().lower() if tag else ""
    if wanted_tag:
        stmt = stmt.where(
            func.lower(func.coalesce(DocMeta.tags_json, "")).like(
                _json_tag_like_pattern(wanted_tag),
                escape="\\",
            )
        )

    if trash_only:
        stmt = stmt.where(DocMeta.deleted_at.is_not(None))
    elif not include_deleted:
        stmt = stmt.where(DocMeta.deleted_at.is_(None))

    if only_stale:
        stmt = stmt.where(
            and_(
                DocMeta.review_due_at.is_not(None),
                DocMeta.review_due_at <= now_utc,
            )
        )

    stmt = stmt.order_by(
        translation.ranking_clause.desc(),
        Doc.updated_at.desc(),
        Doc.title.asc(),
    )
    docs = list(db.execute(stmt).scalars().all())
    doc_ids = [doc.id for doc in docs]
    comment_counts = _comment_count_map(db, doc_ids)
    return [_to_out(db, doc, comment_count=comment_counts.get(doc.id, 0)) for doc in docs]


def _search_docs_internal(
    db: Session,
    *,
    user_id: str | None,
    space_id: str,
    query: str,
    limit: int = 25,
    track_analytics: bool = True,
    explicit_language_code: str | None = None,
) -> list[DocOut]:
    text = query.strip()
    if not text:
        return []

    effective_language_code = localization_service.resolve_effective_content_language_code(
        db,
        user_id=user_id,
        explicit_language_code=explicit_language_code,
    )

    if track_analytics and user_id is not None:
        analytics_service.track(
            db,
            user_id,
            TrackEventIn(
                session_id="kb-search",
                event_type="search_query_issued",
                space_id=space_id,
                entity_type="doc",
                path=f"/spaces/{space_id}",
                meta={
                    "surface": "kb",
                    "query": text,
                    "language_code": effective_language_code,
                },
            ),
        )

    policy = _ensure_space_policy(db, space_id)
    policy_synonyms, policy_lexicon = _merged_search_profile(
        policy,
        language_code=effective_language_code,
    )
    localized_search_fields = _localized_doc_search_fields_subquery(
        effective_language_code,
    )

    parsed = parse_search_query_ast(text)
    now_utc = _now_utc()
    translation = compile_search_translation(
        parsed,
        capabilities=_kb_doc_search_capabilities(now_utc=now_utc),
        text_columns=(
            Doc.title,
            func.coalesce(localized_search_fields.c.localized_title, ""),
            Doc.slug,
            Doc.content_md,
            func.coalesce(localized_search_fields.c.localized_content, ""),
        ),
        updated_at_column=Doc.updated_at,
    )

    docs: list[Doc] = []
    doc_score: dict[str, float] = {}
    bind = db.get_bind()
    dialect_name = bind.dialect.name if bind is not None else ""
    requested_limit = max(1, min(limit, 50))
    positive_terms = [
        token.normalized_value
        for token in parsed.text_tokens
        if token.normalized_value and not token.is_negated
    ]
    expanded_terms = sorted(
        _expanded_search_terms(" ".join(positive_terms), space_synonyms=policy_synonyms)
    )
    query_text_for_ranking = " ".join(expanded_terms or positive_terms)
    search_config = _search_config_for_language(effective_language_code)

    if dialect_name == "postgresql" and query_text_for_ranking:
        _ensure_search_indexes(db)
        search_vector = _weighted_search_vector(
            search_config,
            localized_title_column=localized_search_fields.c.localized_title,
            localized_content_column=localized_search_fields.c.localized_content,
        )
        search_query = func.plainto_tsquery(search_config, query_text_for_ranking)
        final_rank = func.ts_rank_cd(search_vector, search_query) * 10.0 + translation.ranking_clause
        stmt = (
            select(Doc, final_rank.label("rank"))
            .outerjoin(DocMeta, DocMeta.doc_id == Doc.id)
            .outerjoin(localized_search_fields, localized_search_fields.c.doc_id == Doc.id)
            .where(
                Doc.space_id == space_id,
                Doc.status == "published",
                search_vector.op("@@")(search_query),
                translation.where_clause,
            )
            .order_by(
                final_rank.desc(),
                Doc.published_at.desc().nullslast(),
                Doc.updated_at.desc(),
            )
            .limit(max(requested_limit * 3, 25))
        )
        for doc, rank in db.execute(stmt).all():
            docs.append(doc)
            doc_score[doc.id] = float(rank or 0.0)
    else:
        stmt = (
            select(Doc, translation.ranking_clause.label("rank"))
            .outerjoin(DocMeta, DocMeta.doc_id == Doc.id)
            .outerjoin(localized_search_fields, localized_search_fields.c.doc_id == Doc.id)
            .where(
                Doc.space_id == space_id,
                Doc.status == "published",
                translation.where_clause,
            )
            .order_by(
                translation.ranking_clause.desc(),
                Doc.published_at.desc().nullslast(),
                Doc.updated_at.desc(),
            )
            .limit(max(requested_limit * 3, 25))
        )
        for doc, rank in db.execute(stmt).all():
            docs.append(doc)
            doc_score[doc.id] = float(rank or 0.0)

    if positive_terms:
        terms = _expanded_search_terms(text, space_synonyms=policy_synonyms)
        candidates = [doc for doc in repo.list_all_docs(db, space_id) if doc.status == "published"]
        localized_fields_by_doc_id = _localized_doc_search_text_map(
            db,
            doc_ids=[doc.id for doc in candidates],
            language_code=effective_language_code,
        )
        for doc in candidates:
            localized_fields = localized_fields_by_doc_id.get(doc.id, {})
            heuristic = _heuristic_search_score(
                doc,
                terms,
                lexicon=policy_lexicon,
                localized_title=localized_fields.get("title"),
                localized_content=localized_fields.get("content"),
            )
            if heuristic <= 0 and doc.id not in doc_score:
                continue
            doc_score[doc.id] = doc_score.get(doc.id, 0.0) + heuristic
            if all(existing.id != doc.id for existing in docs):
                docs.append(doc)

    docs = [
        doc
        for doc in sorted(
            docs,
            key=lambda row: (
                doc_score.get(row.id, 0.0),
                row.published_at or datetime.min.replace(tzinfo=timezone.utc),
                row.updated_at or datetime.min.replace(tzinfo=timezone.utc),
            ),
            reverse=True,
        )
        if doc_score.get(doc.id, 0.0) > 0
    ][:requested_limit]

    if not docs and track_analytics and user_id is not None:
        analytics_service.track(
            db,
            user_id,
            TrackEventIn(
                session_id="kb-search",
                event_type="search_no_result",
                space_id=space_id,
                entity_type="doc",
                path=f"/spaces/{space_id}",
                meta={
                    "surface": "kb",
                    "query": text,
                    "language_code": effective_language_code,
                },
            ),
        )
        analytics_service.track(
            db,
            user_id,
            TrackEventIn(
                session_id="kb-search",
                event_type="kb_search_no_results",
                space_id=space_id,
                entity_type="doc",
                path=f"/spaces/{space_id}",
                meta={"query": text, "language_code": effective_language_code},
            ),
        )
    elif track_analytics and user_id is not None:
        analytics_service.track(
            db,
            user_id,
            TrackEventIn(
                session_id="kb-search",
                event_type="search_results_shown",
                space_id=space_id,
                entity_type="doc",
                path=f"/spaces/{space_id}",
                meta={
                    "surface": "kb",
                    "query": text,
                    "results": len(docs),
                    "language_code": effective_language_code,
                },
            ),
        )

    comment_counts = _comment_count_map(db, [doc.id for doc in docs])
    return [_to_out(db, doc, comment_count=comment_counts.get(doc.id, 0)) for doc in docs]


def search_docs(
    db: Session,
    *,
    user_id: str,
    space_id: str,
    query: str,
    limit: int = 25,
) -> list[DocOut]:
    return _search_docs_internal(
        db,
        user_id=user_id,
        space_id=space_id,
        query=query,
        limit=limit,
        track_analytics=True,
    )


def search_suggestions(
    db: Session,
    *,
    user_id: str,
    space_id: str,
    query: str,
    limit: int = 8,
) -> list[KbSearchSuggestionOut]:
    normalized_query = " ".join(query.strip().split())
    effective_language_code = localization_service.resolve_effective_content_language_code(
        db,
        user_id=user_id,
    )
    policy = _ensure_space_policy(db, space_id)
    policy_synonyms, policy_lexicon = _merged_search_profile(
        policy,
        language_code=effective_language_code,
    )
    candidate_scores: dict[str, tuple[str, float]] = {}

    def add_candidate(candidate: str, *, source: str, score: float) -> None:
        normalized_candidate = " ".join(candidate.split())
        if not normalized_candidate:
            return
        if normalized_query and not _suggestion_matches(normalized_query, normalized_candidate):
            return
        existing = candidate_scores.get(normalized_candidate)
        if existing is not None and existing[1] >= score:
            return
        candidate_scores[normalized_candidate] = (source, score)

    for phrase in policy_lexicon:
        base_score = (
            6.0
            if normalized_query and phrase.casefold().startswith(normalized_query.casefold())
            else 4.5
        )
        add_candidate(phrase, source="lexicon", score=base_score)

    for root, values in policy_synonyms.items():
        add_candidate(root, source="synonym", score=4.0)
        for value in values:
            add_candidate(value, source="synonym", score=3.5)

    for popular_query, score in _recent_search_query_counts(db, space_id=space_id).most_common(
        MAX_SEARCH_SUGGESTIONS * 3
    ):
        add_candidate(popular_query, source="popular", score=float(score) + 2.0)

    capped_limit = max(1, min(limit, MAX_SEARCH_SUGGESTIONS))
    return [
        KbSearchSuggestionOut(
            query=candidate,
            source=source,
            language_code=None if source == "popular" else effective_language_code,
            score=round(score, 2),
        )
        for candidate, (source, score) in sorted(
            candidate_scores.items(),
            key=lambda item: (-item[1][1], item[0]),
        )[:capped_limit]
    ]


def list_tags(db: Session, space_id: str) -> list[str]:
    tags: set[str] = set()
    for doc in repo.list_all_docs(db, space_id):
        meta = repo.get_doc_meta(db, doc.id)
        if _is_deleted(meta):
            continue
        tags.update(_tags_from_json(meta.tags_json if meta else None))
    return sorted(tags)


def trash_doc(db: Session, *, user_id: str, doc_id: str) -> DocMeta:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    meta = _ensure_doc_meta(db, doc.id)
    meta.deleted_at = _now_utc()
    meta.deleted_by = user_id
    db.commit()
    db.refresh(meta)
    return meta


def restore_doc(db: Session, *, user_id: str, doc_id: str) -> DocMeta:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    meta = _ensure_doc_meta(db, doc.id)
    meta.deleted_at = None
    meta.deleted_by = None
    meta.last_reviewed_at = _now_utc()
    meta.last_reviewed_by = user_id
    db.commit()
    db.refresh(meta)
    return meta


def update_doc_meta(
    db: Session,
    *,
    user_id: str,
    doc_id: str,
    tags: list[str] | None = None,
    review_due_at: datetime | None = None,
    reviewer_user_id: str | None = None,
    review_reminder_days: int | None = None,
) -> DocOut:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    meta = _ensure_doc_meta(db, doc.id)
    if tags is not None:
        meta.tags_json = _tags_to_json(_normalize_tags(tags))
    meta.review_due_at = _coerce_utc(review_due_at)
    assignment = _ensure_review_assignment(db, doc.id)
    assignment.reviewer_user_id = _validate_reviewer(
        db,
        space_id=doc.space_id,
        reviewer_user_id=reviewer_user_id,
    )
    assignment.reminder_days = _normalize_reminder_days(review_reminder_days)
    meta.last_reviewed_at = _now_utc()
    meta.last_reviewed_by = user_id
    db.commit()
    db.refresh(doc)
    return _to_out(db, doc)


def get_review_summary(db: Session, *, space_id: str) -> DocReviewSummaryOut:
    docs = repo.list_all_docs(db, space_id)
    total_docs = 0
    stale_docs = 0
    trashed_docs = 0
    due_docs = 0
    for doc in docs:
        total_docs += 1
        meta = repo.get_doc_meta(db, doc.id)
        if _is_deleted(meta):
            trashed_docs += 1
            continue
        if meta and meta.review_due_at is not None:
            due_docs += 1
            if _is_stale(meta):
                stale_docs += 1
    return DocReviewSummaryOut(
        space_id=space_id,
        total_docs=total_docs,
        stale_docs=stale_docs,
        trashed_docs=trashed_docs,
        docs_due_for_review=due_docs,
    )


def list_review_reminders(
    db: Session,
    *,
    space_id: str,
    reviewer_user_id: str | None = None,
) -> list[DocOut]:
    now = _now_utc()
    out: list[DocOut] = []
    for doc in repo.list_all_docs(db, space_id):
        meta = repo.get_doc_meta(db, doc.id)
        assignment = repo.get_review_assignment(db, doc.id)
        if _is_deleted(meta) or meta is None or meta.review_due_at is None or assignment is None:
            continue
        if assignment.reviewer_user_id is None:
            continue
        if reviewer_user_id and assignment.reviewer_user_id != reviewer_user_id:
            continue
        due_at = _coerce_utc(meta.review_due_at)
        if due_at is None:
            continue
        remind_at = due_at - timedelta(days=assignment.reminder_days)
        if remind_at <= now:
            out.append(_to_out(db, doc))
    out.sort(key=lambda row: row.review_due_at or datetime.max.replace(tzinfo=timezone.utc))
    return out


def get_space_policy(db: Session, *, space_id: str) -> KbSpacePolicyOut:
    policy = _ensure_space_policy(db, space_id)
    return KbSpacePolicyOut(
        space_id=policy.space_id,
        trash_retention_days=policy.trash_retention_days,
        synonyms=_synonym_map_from_json(policy.synonyms_json),
        lexicon=_lexicon_from_json(policy.lexicon_json),
        localized_synonyms=_localized_synonym_map_from_json(
            policy.localized_synonyms_json
        ),
        localized_lexicon=_localized_lexicon_from_json(policy.localized_lexicon_json),
        relevance_benchmarks=_relevance_benchmarks_from_json(
            policy.relevance_benchmarks_json
        ),
        relevance_benchmark_summary=_relevance_benchmark_summary(policy),
        last_purge_run_at=policy.last_purge_run_at,
    )


def update_space_policy(
    db: Session,
    *,
    space_id: str,
    trash_retention_days: int,
    synonyms: dict[str, list[str]] | None = None,
    lexicon: list[str] | None = None,
    localized_synonyms: dict[str, dict[str, list[str]]] | None = None,
    localized_lexicon: dict[str, list[str]] | None = None,
    relevance_benchmarks: list[object] | None = None,
) -> KbSpacePolicyOut:
    policy = _ensure_space_policy(db, space_id)
    policy.trash_retention_days = _normalize_trash_retention_days(trash_retention_days)
    if synonyms is not None:
        policy.synonyms_json = _synonym_map_to_json(synonyms)
    if lexicon is not None:
        policy.lexicon_json = _lexicon_to_json(lexicon)
    if localized_synonyms is not None:
        policy.localized_synonyms_json = _localized_synonym_map_to_json(
            localized_synonyms
        )
    if localized_lexicon is not None:
        policy.localized_lexicon_json = _localized_lexicon_to_json(localized_lexicon)
    if relevance_benchmarks is not None:
        policy.relevance_benchmarks_json = _relevance_benchmarks_to_json(
            relevance_benchmarks
        )
    db.commit()
    benchmark_summary = run_space_relevance_benchmarks(db, space_id=space_id, force=True)
    db.refresh(policy)
    return KbSpacePolicyOut(
        space_id=policy.space_id,
        trash_retention_days=policy.trash_retention_days,
        synonyms=_synonym_map_from_json(policy.synonyms_json),
        lexicon=_lexicon_from_json(policy.lexicon_json),
        localized_synonyms=_localized_synonym_map_from_json(
            policy.localized_synonyms_json
        ),
        localized_lexicon=_localized_lexicon_from_json(policy.localized_lexicon_json),
        relevance_benchmarks=_relevance_benchmarks_from_json(
            policy.relevance_benchmarks_json
        ),
        relevance_benchmark_summary=benchmark_summary,
        last_purge_run_at=policy.last_purge_run_at,
    )


def reviewer_suggestions(
    db: Session,
    *,
    space_id: str,
    doc_id: str | None = None,
    tags: list[str] | None = None,
    limit: int = 5,
) -> list[DocReviewerSuggestionOut]:
    members = spaces_service.list_members(db, space_id)
    member_user_ids = [member.user_id for member in members]
    users_by_id = {user.id: user for user in db.execute(select(User).where(User.id.in_(member_user_ids))).scalars().all()} if member_user_ids else {}
    assigned_counts: Counter[str] = Counter()
    due_soon_counts: Counter[str] = Counter()
    expertise_by_user: dict[str, Counter[str]] = {}
    now = _now_utc()
    target_tags = _normalize_tags(tags)
    if doc_id:
        target_doc = repo.get_doc(db, doc_id)
        if target_doc and target_doc.space_id == space_id:
            target_meta = repo.get_doc_meta(db, target_doc.id)
            target_tags = _tags_from_json(target_meta.tags_json if target_meta else None)
    for doc in repo.list_all_docs(db, space_id):
        meta = repo.get_doc_meta(db, doc.id)
        assignment = repo.get_review_assignment(db, doc.id)
        if assignment is None or assignment.reviewer_user_id is None or _is_deleted(meta):
            continue
        assigned_counts[assignment.reviewer_user_id] += 1
        due_at = _coerce_utc(meta.review_due_at if meta else None)
        if due_at is not None and due_at <= now + timedelta(days=7):
            due_soon_counts[assignment.reviewer_user_id] += 1
    for doc in repo.list_all_docs(db, space_id):
        meta = repo.get_doc_meta(db, doc.id)
        if _is_deleted(meta):
            continue
        doc_tags = _tags_from_json(meta.tags_json if meta else None)
        if not doc_tags:
            continue
        candidate_user_ids = {doc.created_by, doc.updated_by}
        assignment = repo.get_review_assignment(db, doc.id)
        if assignment and assignment.reviewer_user_id:
            candidate_user_ids.add(assignment.reviewer_user_id)
        for user_id in candidate_user_ids:
            expertise = expertise_by_user.setdefault(user_id, Counter())
            for tag in doc_tags:
                expertise[tag] += 1
    out: list[DocReviewerSuggestionOut] = []
    for member in members:
        user = users_by_id.get(member.user_id)
        if user is None:
            continue
        expertise_counter = expertise_by_user.get(user.id, Counter())
        matching_tags: list[str] = []
        expertise_score = 0
        if target_tags:
            ranked = sorted(
                ((tag, expertise_counter.get(tag, 0)) for tag in target_tags if expertise_counter.get(tag, 0) > 0),
                key=lambda item: (-item[1], item[0]),
            )
            matching_tags = [tag for tag, _ in ranked]
            expertise_score = sum(score for _, score in ranked)
        else:
            expertise_score = sum(expertise_counter.values())
        out.append(
            DocReviewerSuggestionOut(
                user_id=user.id,
                name=user.name,
                email=user.email,
                global_role=resolve_user_auth_role(db, user),
                open_reviews=assigned_counts.get(user.id, 0),
                due_soon_reviews=due_soon_counts.get(user.id, 0),
                expertise_score=expertise_score,
                matching_tags=matching_tags,
            )
        )
    out.sort(
        key=lambda row: (
            -len(row.matching_tags),
            -row.expertise_score,
            row.open_reviews,
            row.due_soon_reviews,
            row.name.lower(),
        )
    )
    return out[: max(1, min(limit, 10))]


def purge_trashed_docs(
    db: Session,
    *,
    space_id: str,
    only_expired: bool = True,
) -> int:
    now = _now_utc()
    policy = _ensure_space_policy(db, space_id)
    deleted_count = 0
    for doc in repo.list_all_docs(db, space_id):
        meta = repo.get_doc_meta(db, doc.id)
        if not _is_deleted(meta):
            continue
        expires_at = _trash_expires_at(meta, retention_days=policy.trash_retention_days)
        if only_expired and (expires_at is None or expires_at > now):
            continue
        media_service.clear_usage_refs(db, entity_type="doc", entity_id=doc.id)
        assignment = repo.get_review_assignment(db, doc.id)
        if assignment is not None:
            db.delete(assignment)
        mention_rows = db.execute(select(DocMentionNotification).where(DocMentionNotification.doc_id == doc.id)).scalars().all()
        for mention in mention_rows:
            db.delete(mention)
        for comment in repo.list_comments(db, doc.id):
            db.delete(comment)
        for version in repo.list_versions(db, doc.id):
            db.delete(version)
        if meta is not None:
            db.delete(meta)
        db.delete(doc)
        deleted_count += 1
    db.commit()
    return deleted_count


def list_comments(db: Session, *, doc_id: str) -> list[DocCommentOut]:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    comments = repo.list_comments(db, doc_id)
    user_ids = {comment.user_id for comment in comments}
    users = list(db.execute(select(User).where(User.id.in_(user_ids))).scalars().all()) if user_ids else []
    user_names = {user.id: user.name for user in users}
    out: list[DocCommentOut] = []
    for comment in comments:
        author_name = user_names.get(comment.user_id)
        out.append(_comment_to_out(db, comment, author_name=author_name))
    return out


def get_comment_detail(db: Session, *, comment_id: str) -> DocCommentOut:
    comment = repo.get_doc_comment(db, comment_id)
    if not comment:
        raise not_found("Comment not found")
    return _comment_to_out(db, comment)


def create_comment(db: Session, *, user_id: str, doc_id: str, body_md: str) -> DocComment:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    meta = repo.get_doc_meta(db, doc.id)
    if _is_deleted(meta):
        raise bad_request("Cannot comment on a doc in trash")
    cleaned = sanitize_rich_html(body_md)
    comment = DocComment(id=str(uuid.uuid4()), doc_id=doc_id, user_id=user_id, body_md=cleaned)
    if not comment.body_md:
        raise bad_request("Comment body is required")
    db.add(comment)
    db.commit()
    db.refresh(comment)
    _emit_comment_mentions(db, actor_user_id=user_id, doc=doc, comment=comment)
    return comment


def update_comment(db: Session, *, user_id: str, comment_id: str, body_md: str) -> DocComment:
    comment = repo.get_doc_comment(db, comment_id)
    if not comment:
        raise not_found("Comment not found")
    if comment.user_id != user_id:
        raise HTTPException(status_code=403, detail="Only the comment author can edit this comment")
    cleaned = sanitize_rich_html(body_md)
    if not cleaned:
        raise bad_request("Comment body is required")
    doc = repo.get_doc(db, comment.doc_id)
    if not doc:
        raise not_found("Doc not found")
    comment.body_md = cleaned
    db.commit()
    db.refresh(comment)
    _emit_comment_mentions(db, actor_user_id=user_id, doc=doc, comment=comment)
    return comment


def delete_comment(db: Session, *, user_id: str, comment_id: str) -> None:
    comment = repo.get_doc_comment(db, comment_id)
    if not comment:
        raise not_found("Comment not found")
    if comment.user_id != user_id:
        raise HTTPException(status_code=403, detail="Only the comment author can delete this comment")
    db.delete(comment)
    db.commit()


def list_mention_inbox(
    db: Session,
    *,
    user_id: str,
    space_id: str | None = None,
    doc_id: str | None = None,
    unread_only: bool = False,
    max_age_days: int | None = None,
) -> list[DocMentionNotificationOut]:
    rows = repo.list_mention_notifications(db, user_id, unread_only=unread_only)
    out: list[DocMentionNotificationOut] = []
    cutoff = _now_utc() - timedelta(days=max(1, int(max_age_days))) if max_age_days is not None else None
    for row in rows:
        created_at = _coerce_utc(row.created_at)
        if cutoff is not None and created_at is not None and created_at < cutoff:
            continue
        doc = repo.get_doc(db, row.doc_id)
        if doc is None:
            continue
        if space_id and doc.space_id != space_id:
            continue
        if doc_id and doc.id != doc_id:
            continue
        out.append(_mention_notification_to_out(db, row))
    return out


def mark_mention_read(db: Session, *, notification_id: str, user_id: str) -> DocMentionNotificationOut:
    row = repo.get_mention_notification(db, notification_id)
    if row is None:
        raise not_found("Notification not found")
    if row.user_id != user_id:
        raise HTTPException(status_code=403, detail="Cannot modify another user's notification")
    if row.read_at is None:
        row.read_at = _now_utc()
        db.commit()
        db.refresh(row)
    return _mention_notification_to_out(db, row)


def bulk_mark_mentions_read(
    db: Session,
    *,
    user_id: str,
    notification_ids: list[str] | None = None,
    space_id: str | None = None,
    doc_id: str | None = None,
    unread_only: bool = True,
    max_age_days: int | None = None,
) -> int:
    rows = repo.list_mention_notifications(db, user_id, unread_only=unread_only)
    wanted_ids = {item for item in (notification_ids or []) if item}
    cutoff = _now_utc() - timedelta(days=max(1, int(max_age_days))) if max_age_days is not None else None
    marked = 0
    for row in rows:
        if wanted_ids and row.id not in wanted_ids:
            continue
        created_at = _coerce_utc(row.created_at)
        if cutoff is not None and created_at is not None and created_at < cutoff:
            continue
        doc = repo.get_doc(db, row.doc_id)
        if doc is None:
            continue
        if space_id and doc.space_id != space_id:
            continue
        if doc_id and doc.id != doc_id:
            continue
        if row.read_at is None:
            row.read_at = _now_utc()
            marked += 1
    if marked:
        db.commit()
    return marked


def get_doc_detail(db: Session, *, doc_id: str) -> DocOut:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    return _to_out(db, doc)


def build_diff(
    db: Session,
    *,
    doc_id: str,
    from_version_id: str | None = None,
    to_version_id: str | None = None,
) -> DocDiffOut:
    doc = repo.get_doc(db, doc_id)
    if not doc:
        raise not_found("Doc not found")
    versions = repo.list_versions(db, doc_id)
    if not versions:
        raise bad_request("No versions available for diff")

    from_label = "Current"
    to_label = "Current"
    from_content = doc.content_md
    to_content = doc.content_md

    if from_version_id:
        from_version = repo.get_version(db, from_version_id)
        if not from_version or from_version.doc_id != doc_id:
            raise not_found("From version not found")
        from_label = f"{from_version.title} ({from_version.created_at.isoformat()})"
        from_content = from_version.content_md
    elif len(versions) >= 2:
        from_version = versions[1]
        from_label = f"{from_version.title} ({from_version.created_at.isoformat()})"
        from_content = from_version.content_md

    if to_version_id:
        to_version = repo.get_version(db, to_version_id)
        if not to_version or to_version.doc_id != doc_id:
            raise not_found("To version not found")
        to_label = f"{to_version.title} ({to_version.created_at.isoformat()})"
        to_content = to_version.content_md

    diff_html = difflib.HtmlDiff(wrapcolumn=100).make_table(
        from_content.splitlines(),
        to_content.splitlines(),
        fromdesc=from_label,
        todesc=to_label,
        context=True,
        numlines=3,
    )
    rows: list[DocDiffRowOut] = []
    from_lines = from_content.splitlines()
    to_lines = to_content.splitlines()
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, from_lines, to_lines).get_opcodes():
        max_count = max(i2 - i1, j2 - j1, 1)
        for offset in range(max_count):
            left_index = i1 + offset
            right_index = j1 + offset
            left_exists = left_index < i2
            right_exists = right_index < j2
            rows.append(
                DocDiffRowOut(
                    kind=tag,
                    left_line_no=left_index + 1 if left_exists else None,
                    right_line_no=right_index + 1 if right_exists else None,
                    left_text=from_lines[left_index] if left_exists else "",
                    right_text=to_lines[right_index] if right_exists else "",
                )
            )
    return DocDiffOut(
        doc_id=doc_id,
        from_version_id=from_version_id,
        to_version_id=to_version_id,
        from_label=from_label,
        to_label=to_label,
        diff_html=diff_html,
        rows=rows,
    )
