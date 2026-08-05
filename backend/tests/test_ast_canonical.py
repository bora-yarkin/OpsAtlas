# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from app.core.search.ast import (
    SearchExpressionAtomField,
    evaluate_search_expression,
    parse_canonical_ast_dict,
    parse_search_query_ast,
    to_canonical_ast_dict,
)


def _matches_field(token, *, status: str) -> bool:
    if token.normalized_field != "status":
        return False
    base_match = token.normalized_value == status
    return (not base_match) if token.is_negated else base_match


def _matches_text(token, *, terms: set[str]) -> bool:
    return token.normalized_value in terms


def test_canonical_ast_round_trip_preserves_semantics() -> None:
    parsed = parse_search_query_ast("(alpha OR beta) AND -@status:closed")

    payload = to_canonical_ast_dict(parsed)
    restored = parse_canonical_ast_dict(payload)

    assert restored is not None
    assert [token.normalized_value for token in restored.text_tokens] == [
        "alpha",
        "beta",
    ]
    assert [token.normalized_field for token in restored.field_tokens] == ["status"]

    original_result = evaluate_search_expression(
        parsed.expression,
        matches_field=lambda token: _matches_field(token, status="open"),
        matches_text=lambda token: _matches_text(token, terms={"alpha"}),
    )
    restored_result = evaluate_search_expression(
        restored.expression,
        matches_field=lambda token: _matches_field(token, status="open"),
        matches_text=lambda token: _matches_text(token, terms={"alpha"}),
    )

    assert original_result is True
    assert restored_result is True



def test_parse_canonical_ast_synthesizes_missing_field_tokens() -> None:
    payload = {
        "raw": "",
        "field_tokens": [],
        "text_tokens": [],
        "expression": {
            "kind": "field",
            "token": {
                "normalized_field": "status",
                "normalized_value": "open",
                "is_negated": False,
            },
        },
        "diagnostics": [],
    }

    parsed = parse_canonical_ast_dict(payload)

    assert parsed is not None
    assert isinstance(parsed.expression, SearchExpressionAtomField)
    assert parsed.expression.token.source == "@status:open"
    assert parsed.expression.token.normalized_field == "status"
    assert parsed.expression.token.normalized_value == "open"



def test_parse_canonical_ast_rejects_non_mapping_payload() -> None:
    assert parse_canonical_ast_dict(None) is None
    assert parse_canonical_ast_dict("not-a-dict") is None
