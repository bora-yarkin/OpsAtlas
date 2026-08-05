# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Translate parsed search AST nodes into SQLAlchemy filter and ranking clauses."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Mapping, cast as typing_cast

from sqlalchemy import Float, and_, case, cast, func, literal, not_, or_
from sqlalchemy.sql.elements import ColumnElement
from sqlalchemy.sql.sqltypes import String

from .ast import (
    ParsedSearchQuery,
    SearchExpressionAtomField,
    SearchExpressionAtomText,
    SearchExpressionGroup,
    SearchExpressionNode,
    SearchExpressionNot,
)

SearchBooleanClause = ColumnElement[bool]
SearchNumericClause = ColumnElement[float]


@dataclass(frozen=True)
class SearchFieldCapability:
    """Describes how a named search field maps to filtering and scoring logic."""
    name: str
    aliases: tuple[str, ...]
    value_type: str
    predicate_builder: Callable[[str], SearchBooleanClause | None]
    score_builder: Callable[[str], SearchNumericClause] | None = None
    allow_empty_value: bool = False


@dataclass(frozen=True)
class SearchTranslationResult:
    """Holds the SQL WHERE clause and ranking expression for a compiled search query."""
    where_clause: SearchBooleanClause
    ranking_clause: SearchNumericClause


def compile_search_translation(
    parsed: ParsedSearchQuery,
    *,
    capabilities: tuple[SearchFieldCapability, ...],
    text_columns: tuple[object, ...],
    updated_at_column: object | None = None,
    unknown_field_falls_back_to_text: bool = True,
) -> SearchTranslationResult:
    """Compile a parsed search query into SQLAlchemy filter and relevance expressions."""
    capability_by_alias = _capability_lookup(capabilities)

    def text_predicate(value: str) -> SearchBooleanClause:
        normalized = value.strip().lower()
        if not normalized:
            return literal(True)
        pattern = _like_pattern(normalized)
        clauses: list[SearchBooleanClause] = []
        for column in text_columns:
            clauses.append(
                _lower_text(typing_cast(ColumnElement[object], column)).like(
                    pattern,
                    escape="\\",
                )
            )
        if not clauses:
            return literal(True)
        return or_(*clauses)

    def compile_node(node: SearchExpressionNode | None) -> SearchBooleanClause:
        if node is None:
            return literal(True)

        if isinstance(node, SearchExpressionAtomText):
            token = node.token
            if not token.normalized_value:
                return literal(True)
            return text_predicate(token.normalized_value)

        if isinstance(node, SearchExpressionAtomField):
            token = node.token
            capability = capability_by_alias.get(token.normalized_field)
            if capability is None:
                if unknown_field_falls_back_to_text and token.normalized_value:
                    base = text_predicate(token.normalized_value)
                else:
                    base = literal(True)
            else:
                if not token.has_value and not capability.allow_empty_value:
                    base = literal(True)
                else:
                    value = token.normalized_value
                    built = capability.predicate_builder(value)
                    base = built if built is not None else literal(True)
            return not_(base) if token.is_negated else base

        if isinstance(node, SearchExpressionNot):
            return not_(compile_node(node.child))

        if isinstance(node, SearchExpressionGroup):
            children = [compile_node(child) for child in node.children]
            if not children:
                return literal(True)
            if node.operator == "or":
                return or_(*children)
            if node.operator == "nor":
                return not_(or_(*children))
            if node.operator == "xor":
                true_count = literal(0)
                for child in children:
                    true_count = true_count + case((child, 1), else_=0)
                return typing_cast(SearchBooleanClause, true_count == 1)
            return and_(*children)

        return literal(True)

    where_clause = compile_node(parsed.expression)
    ranking_clause = _build_ranking_clause(
        parsed,
        capability_by_alias=capability_by_alias,
        text_columns=text_columns,
        updated_at_column=updated_at_column,
    )
    return SearchTranslationResult(where_clause=where_clause, ranking_clause=ranking_clause)


def _capability_lookup(
    capabilities: tuple[SearchFieldCapability, ...],
) -> dict[str, SearchFieldCapability]:
    """Index capabilities by both canonical name and supported aliases."""
    lookup: dict[str, SearchFieldCapability] = {}
    for capability in capabilities:
        lookup[capability.name] = capability
        for alias in capability.aliases:
            lookup[alias] = capability
    return lookup


def _build_ranking_clause(
    parsed: ParsedSearchQuery,
    *,
    capability_by_alias: Mapping[str, SearchFieldCapability],
    text_columns: tuple[object, ...],
    updated_at_column: object | None,
) -> SearchNumericClause:
    """Build a numeric relevance expression for positive text and field matches."""
    score: SearchNumericClause = literal(0.0)

    positive_text_terms = {token.normalized_value.strip().lower() for token in parsed.text_tokens if token.normalized_value.strip() and not token.is_negated}
    for term in positive_text_terms:
        pattern = _like_pattern(term)
        for index, column in enumerate(text_columns):
            weight = 2.0 if index == 0 else (1.5 if index == 1 else 1.0)
            lowered = _lower_text(typing_cast(ColumnElement[object], column))
            score = score + case(
                (lowered == term, weight * 2.0),
                (lowered.like(pattern, escape="\\"), weight),
                else_=0.0,
            )

    for token in parsed.field_tokens:
        if token.is_negated:
            continue
        if not token.normalized_value:
            continue
        capability = capability_by_alias.get(token.normalized_field)
        if capability is None:
            continue
        if capability.score_builder is None:
            continue
        score = score + capability.score_builder(token.normalized_value)

    if updated_at_column is not None:
        updated_column = typing_cast(ColumnElement[object], updated_at_column)
        now_epoch = datetime.now(timezone.utc).timestamp()
        updated_epoch = func.extract("epoch", updated_column)
        elapsed_hours = cast(
            (literal(now_epoch) - updated_epoch) / 3600.0,
            Float(),
        )
        hours_ago = case(
            (elapsed_hours < 0.0, 0.0),
            else_=elapsed_hours,
        )
        recency_boost = 1.0 / (1.0 + hours_ago / 48.0)
        score = score + case(
            (updated_column.is_not(None), cast(recency_boost, Float())),
            else_=0.0,
        )

    return score


def _lower_text(column: ColumnElement[object]) -> ColumnElement[str]:
    """Cast a SQL column to text and lowercase it for case-insensitive matching."""
    return func.lower(cast(column, String()))


def _like_pattern(value: str) -> str:
    """Escape a user value for a `%...%` SQL LIKE search."""
    escaped = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"
