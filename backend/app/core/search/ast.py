# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Parsed search-query token and AST types shared by backend search compilation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Mapping, Literal
import re

SearchBooleanOperator = Literal["and", "or", "nor", "xor"]


@dataclass(frozen=True)
class SearchFieldToken:
    source: str
    field: str
    normalized_field: str
    value: str
    normalized_value: str
    has_value_separator: bool
    is_negated: bool
    start: int
    end: int

    @property
    def has_value(self) -> bool:
        return bool(self.normalized_value)


@dataclass(frozen=True)
class SearchTextToken:
    source: str
    value: str
    normalized_value: str
    is_negated: bool
    start: int
    end: int


@dataclass(frozen=True)
class SearchParseDiagnostic:
    code: str
    message: str
    start: int
    end: int


@dataclass(frozen=True)
class SearchExpressionGroup:
    operator: SearchBooleanOperator
    children: tuple[SearchExpressionNode, ...]


@dataclass(frozen=True)
class SearchExpressionNot:
    child: SearchExpressionNode


@dataclass(frozen=True)
class SearchExpressionAtomField:
    token: SearchFieldToken


@dataclass(frozen=True)
class SearchExpressionAtomText:
    token: SearchTextToken


SearchExpressionNode = SearchExpressionGroup | SearchExpressionNot | SearchExpressionAtomField | SearchExpressionAtomText


@dataclass(frozen=True)
class ParsedSearchQuery:
    raw: str
    field_tokens: tuple[SearchFieldToken, ...]
    text_tokens: tuple[SearchTextToken, ...]
    expression: SearchExpressionNode | None
    diagnostics: tuple[SearchParseDiagnostic, ...]

    @property
    def normalized_terms(self) -> tuple[str, ...]:
        return tuple(token.normalized_value for token in self.text_tokens)

    @property
    def has_diagnostics(self) -> bool:
        return bool(self.diagnostics)


@dataclass(frozen=True)
class _Lexeme:
    kind: str
    text: str
    start: int
    end: int


_FIELD_NAME_PATTERN = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_-]*$")


def parse_search_query_ast(raw: str) -> ParsedSearchQuery:
    parser = _SearchExpressionParser(raw=raw, lexemes=_scan_lexemes(raw))
    expression = parser.parse()
    return ParsedSearchQuery(
        raw=raw,
        field_tokens=tuple(parser.field_tokens),
        text_tokens=tuple(parser.text_tokens),
        expression=expression,
        diagnostics=tuple(parser.diagnostics),
    )


def evaluate_search_expression(
    expression: SearchExpressionNode | None,
    *,
    matches_field: Callable[[SearchFieldToken], bool],
    matches_text: Callable[[SearchTextToken], bool],
) -> bool:
    if expression is None:
        return True
    if isinstance(expression, SearchExpressionAtomField):
        return matches_field(expression.token)
    if isinstance(expression, SearchExpressionAtomText):
        return matches_text(expression.token)
    if isinstance(expression, SearchExpressionNot):
        return not evaluate_search_expression(
            expression.child,
            matches_field=matches_field,
            matches_text=matches_text,
        )
    if isinstance(expression, SearchExpressionGroup):
        if expression.operator == "or":
            return any(
                evaluate_search_expression(
                    child,
                    matches_field=matches_field,
                    matches_text=matches_text,
                )
                for child in expression.children
            )
        if expression.operator == "nor":
            return not any(
                evaluate_search_expression(
                    child,
                    matches_field=matches_field,
                    matches_text=matches_text,
                )
                for child in expression.children
            )
        if expression.operator == "xor":
            return (
                sum(
                    1
                    for child in expression.children
                    if evaluate_search_expression(
                        child,
                        matches_field=matches_field,
                        matches_text=matches_text,
                    )
                )
                == 1
            )
        return all(
            evaluate_search_expression(
                child,
                matches_field=matches_field,
                matches_text=matches_text,
            )
            for child in expression.children
        )
    return False


def to_canonical_ast_dict(parsed: ParsedSearchQuery) -> dict[str, Any]:
    return {
        "raw": parsed.raw,
        "field_tokens": [
            {
                "source": token.source,
                "field": token.field,
                "normalized_field": token.normalized_field,
                "value": token.value,
                "normalized_value": token.normalized_value,
                "has_value_separator": token.has_value_separator,
                "is_negated": token.is_negated,
                "start": token.start,
                "end": token.end,
            }
            for token in parsed.field_tokens
        ],
        "text_tokens": [
            {
                "source": token.source,
                "value": token.value,
                "normalized_value": token.normalized_value,
                "is_negated": token.is_negated,
                "start": token.start,
                "end": token.end,
            }
            for token in parsed.text_tokens
        ],
        "expression": _expression_to_dict(parsed.expression),
        "diagnostics": [
            {
                "code": diagnostic.code,
                "message": diagnostic.message,
                "start": diagnostic.start,
                "end": diagnostic.end,
            }
            for diagnostic in parsed.diagnostics
        ],
    }


def parse_canonical_ast_dict(payload: Mapping[str, Any] | None) -> ParsedSearchQuery | None:
    if not isinstance(payload, Mapping):
        return None
    raw = str(payload.get("raw", ""))

    field_tokens: list[SearchFieldToken] = []
    for row in payload.get("field_tokens", []) if isinstance(payload.get("field_tokens"), list) else []:
        if not isinstance(row, Mapping):
            continue
        field_tokens.append(
            SearchFieldToken(
                source=str(row.get("source", "")),
                field=str(row.get("field", "")),
                normalized_field=str(row.get("normalized_field", "")).lower(),
                value=str(row.get("value", "")),
                normalized_value=str(row.get("normalized_value", "")).lower(),
                has_value_separator=bool(row.get("has_value_separator", False)),
                is_negated=bool(row.get("is_negated", False)),
                start=_safe_int(row.get("start", 0)),
                end=_safe_int(row.get("end", 0)),
            )
        )

    text_tokens: list[SearchTextToken] = []
    for row in payload.get("text_tokens", []) if isinstance(payload.get("text_tokens"), list) else []:
        if not isinstance(row, Mapping):
            continue
        text_tokens.append(
            SearchTextToken(
                source=str(row.get("source", "")),
                value=str(row.get("value", "")),
                normalized_value=str(row.get("normalized_value", "")).lower(),
                is_negated=bool(row.get("is_negated", False)),
                start=_safe_int(row.get("start", 0)),
                end=_safe_int(row.get("end", 0)),
            )
        )

    diagnostics: list[SearchParseDiagnostic] = []
    for row in payload.get("diagnostics", []) if isinstance(payload.get("diagnostics"), list) else []:
        if not isinstance(row, Mapping):
            continue
        diagnostics.append(
            SearchParseDiagnostic(
                code=str(row.get("code", "")),
                message=str(row.get("message", "")),
                start=_safe_int(row.get("start", 0)),
                end=_safe_int(row.get("end", 0)),
            )
        )

    expression = _expression_from_dict(payload.get("expression"), field_tokens, text_tokens)

    return ParsedSearchQuery(
        raw=raw,
        field_tokens=tuple(field_tokens),
        text_tokens=tuple(text_tokens),
        expression=expression,
        diagnostics=tuple(diagnostics),
    )


def _safe_int(value: object) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        stripped = value.strip()
        if stripped:
            try:
                return int(stripped)
            except ValueError:
                return 0
    return 0


def _expression_to_dict(node: SearchExpressionNode | None) -> dict[str, Any] | None:
    if node is None:
        return None
    if isinstance(node, SearchExpressionGroup):
        return {
            "kind": "group",
            "operator": node.operator,
            "children": [_expression_to_dict(child) for child in node.children],
        }
    if isinstance(node, SearchExpressionNot):
        return {
            "kind": "not",
            "child": _expression_to_dict(node.child),
        }
    if isinstance(node, SearchExpressionAtomField):
        return {
            "kind": "field",
            "token": {
                "normalized_field": node.token.normalized_field,
                "normalized_value": node.token.normalized_value,
                "is_negated": node.token.is_negated,
            },
        }
    if isinstance(node, SearchExpressionAtomText):
        return {
            "kind": "text",
            "token": {
                "normalized_value": node.token.normalized_value,
                "is_negated": node.token.is_negated,
            },
        }
    return None


def _expression_from_dict(
    payload: object,
    field_tokens: list[SearchFieldToken],
    text_tokens: list[SearchTextToken],
) -> SearchExpressionNode | None:
    if not isinstance(payload, Mapping):
        return None
    kind = str(payload.get("kind", "")).strip().lower()

    if kind == "group":
        raw_operator = str(payload.get("operator", "")).strip().lower()
        operator: SearchBooleanOperator = "or" if raw_operator == "or" else "nor" if raw_operator == "nor" else "xor" if raw_operator == "xor" else "and"
        raw_children = payload.get("children", [])
        children: list[SearchExpressionNode] = []
        if isinstance(raw_children, list):
            for child in raw_children:
                parsed_child = _expression_from_dict(child, field_tokens, text_tokens)
                if parsed_child is not None:
                    children.append(parsed_child)
        if not children:
            return None
        return SearchExpressionGroup(operator=operator, children=tuple(children))

    if kind == "not":
        child = _expression_from_dict(payload.get("child"), field_tokens, text_tokens)
        return SearchExpressionNot(child=child) if child is not None else None

    if kind == "field":
        token_payload = payload.get("token")
        normalized_field = ""
        normalized_value = ""
        is_negated = False
        if isinstance(token_payload, Mapping):
            normalized_field = str(token_payload.get("normalized_field", "")).strip().lower()
            normalized_value = str(token_payload.get("normalized_value", "")).strip().lower()
            is_negated = bool(token_payload.get("is_negated", False))
        for token in field_tokens:
            if token.normalized_field == normalized_field and token.normalized_value == normalized_value and token.is_negated == is_negated:
                return SearchExpressionAtomField(token=token)
        token = SearchFieldToken(
            source=f"@{normalized_field}:{normalized_value}" if normalized_value else f"@{normalized_field}",
            field=normalized_field,
            normalized_field=normalized_field,
            value=normalized_value,
            normalized_value=normalized_value,
            has_value_separator=bool(normalized_value),
            is_negated=is_negated,
            start=0,
            end=0,
        )
        return SearchExpressionAtomField(token=token)

    if kind == "text":
        token_payload = payload.get("token")
        normalized_value = ""
        is_negated = False
        if isinstance(token_payload, Mapping):
            normalized_value = str(token_payload.get("normalized_value", "")).strip().lower()
            is_negated = bool(token_payload.get("is_negated", False))
        for token in text_tokens:
            if token.normalized_value == normalized_value and token.is_negated == is_negated:
                return SearchExpressionAtomText(token=token)
        token = SearchTextToken(
            source=normalized_value,
            value=normalized_value,
            normalized_value=normalized_value,
            is_negated=is_negated,
            start=0,
            end=0,
        )
        return SearchExpressionAtomText(token=token)

    return None


class _SearchExpressionParser:
    def __init__(self, *, raw: str, lexemes: list[_Lexeme]):
        self.raw = raw
        self.lexemes = lexemes
        self.field_tokens: list[SearchFieldToken] = []
        self.text_tokens: list[SearchTextToken] = []
        self.diagnostics: list[SearchParseDiagnostic] = []
        self._index = 0

    @property
    def _is_at_end(self) -> bool:
        return self._index >= len(self.lexemes)

    @property
    def _current(self) -> _Lexeme | None:
        return None if self._is_at_end else self.lexemes[self._index]

    def _match(self, kind: str) -> bool:
        if self._current is None or self._current.kind != kind:
            return False
        self._index += 1
        return True

    def parse(self) -> SearchExpressionNode | None:
        expression = self._parse_or()
        while not self._is_at_end:
            token = self.lexemes[self._index]
            self._add_diagnostic(
                code="unexpected_token",
                message=f"Unexpected token: {token.text}",
                start=token.start,
                end=token.end,
            )
            self._index += 1
        return expression

    def _parse_or(self) -> SearchExpressionNode | None:
        node = self._parse_and()
        while True:
            operator = self._match_disjunction_operator()
            if operator is None:
                break
            rhs = self._parse_and()
            node = self._join_group(operator, node, rhs)
        return node

    def _match_disjunction_operator(self) -> SearchBooleanOperator | None:
        if self._match("or"):
            return "or"
        if self._match("nor"):
            return "nor"
        if self._match("xor"):
            return "xor"
        return None

    def _parse_and(self) -> SearchExpressionNode | None:
        node = self._parse_unary()
        while True:
            if self._match("and"):
                rhs = self._parse_unary()
                node = self._join_group("and", node, rhs)
                continue
            next_kind = self._current.kind if self._current is not None else None
            is_implicit_and = next_kind in {"value", "lparen", "not"}
            if not is_implicit_and:
                break
            rhs = self._parse_unary()
            node = self._join_group("and", node, rhs)
        return node

    def _parse_unary(self) -> SearchExpressionNode | None:
        if self._match("not"):
            token = self.lexemes[self._index - 1]
            child = self._parse_unary()
            if child is None:
                self._add_diagnostic(
                    code="missing_operand",
                    message="NOT requires an operand.",
                    start=token.start,
                    end=token.end,
                )
                return None
            return SearchExpressionNot(child=child)
        return self._parse_primary()

    def _parse_primary(self) -> SearchExpressionNode | None:
        if self._match("lparen"):
            opening = self.lexemes[self._index - 1]
            expression = self._parse_or()
            if not self._match("rparen"):
                self._add_diagnostic(
                    code="unclosed_group",
                    message="Missing closing parenthesis.",
                    start=opening.start,
                    end=opening.end,
                )
            return expression

        if self._match("rparen"):
            token = self.lexemes[self._index - 1]
            self._add_diagnostic(
                code="unexpected_close_paren",
                message="Unexpected closing parenthesis.",
                start=token.start,
                end=token.end,
            )
            return None

        if self._match("and") or self._match("or") or self._match("nor") or self._match("xor"):
            token = self.lexemes[self._index - 1]
            self._add_diagnostic(
                code="unexpected_operator",
                message=f"Unexpected operator: {token.text.upper()}",
                start=token.start,
                end=token.end,
            )
            return None

        if self._match("value"):
            token = self.lexemes[self._index - 1]
            return self._parse_value(token)

        return None

    def _parse_value(self, lexeme: _Lexeme) -> SearchExpressionNode | None:
        token_text = lexeme.text
        is_leading_negated_text = False
        if token_text.startswith("-") and len(token_text) > 1:
            is_leading_negated_text = True
            token_text = token_text[1:]

        field_token = _try_parse_field_token(
            source=lexeme.text,
            token=token_text,
            is_negated=is_leading_negated_text,
            start=lexeme.start,
            end=lexeme.end,
        )
        if field_token is not None:
            self.field_tokens.append(field_token)
            return SearchExpressionAtomField(token=field_token)

        text_value = _strip_wrapping_quotes(token_text).strip()
        if not text_value:
            self._add_diagnostic(
                code="empty_term",
                message="Empty search term.",
                start=lexeme.start,
                end=lexeme.end,
            )
            return None

        text_token = SearchTextToken(
            source=lexeme.text,
            value=text_value,
            normalized_value=text_value.lower(),
            is_negated=is_leading_negated_text,
            start=lexeme.start,
            end=lexeme.end,
        )
        self.text_tokens.append(text_token)

        atom: SearchExpressionNode = SearchExpressionAtomText(token=text_token)
        if is_leading_negated_text:
            atom = SearchExpressionNot(child=atom)
        return atom

    def _join_group(
        self,
        operator: SearchBooleanOperator,
        left: SearchExpressionNode | None,
        right: SearchExpressionNode | None,
    ) -> SearchExpressionNode | None:
        if left is None:
            return right
        if right is None:
            return left
        if isinstance(left, SearchExpressionGroup) and left.operator == operator:
            return SearchExpressionGroup(operator=operator, children=(*left.children, right))
        return SearchExpressionGroup(operator=operator, children=(left, right))

    def _add_diagnostic(
        self,
        *,
        code: str,
        message: str,
        start: int,
        end: int,
    ) -> None:
        self.diagnostics.append(
            SearchParseDiagnostic(
                code=code,
                message=message,
                start=start,
                end=end,
            )
        )


def _scan_lexemes(raw: str) -> list[_Lexeme]:
    lexemes: list[_Lexeme] = []
    index = 0
    while index < len(raw):
        ch = raw[index]
        if ch.isspace() or ch == ";":
            index += 1
            continue

        if ch == "(":
            lexemes.append(_Lexeme(kind="lparen", text="(", start=index, end=index + 1))
            index += 1
            continue

        if ch == ")":
            lexemes.append(_Lexeme(kind="rparen", text=")", start=index, end=index + 1))
            index += 1
            continue

        start = index
        in_quotes = False
        while index < len(raw):
            next_ch = raw[index]
            if next_ch == '"':
                in_quotes = not in_quotes
                index += 1
                continue
            if not in_quotes and (next_ch.isspace() or next_ch == ";" or next_ch == "(" or next_ch == ")"):
                break
            index += 1

        end = index
        text = raw[start:end].strip()
        if not text:
            continue

        lower = text.lower()
        if lower == "and" or text == "&&":
            kind = "and"
        elif lower == "or" or text == "||":
            kind = "or"
        elif lower == "nor":
            kind = "nor"
        elif lower == "xor" or text == "^":
            kind = "xor"
        elif lower == "not" or text == "!":
            kind = "not"
        else:
            kind = "value"

        lexemes.append(_Lexeme(kind=kind, text=text, start=start, end=end))

    return lexemes


def _try_parse_field_token(
    *,
    source: str,
    token: str,
    is_negated: bool,
    start: int,
    end: int,
) -> SearchFieldToken | None:
    has_at_prefix = token.startswith("@")
    payload = token[1:].strip() if has_at_prefix else token.strip()
    if not payload:
        return None

    separator_index = payload.find(":")
    has_value_separator = separator_index >= 0
    if not has_at_prefix and not has_value_separator:
        return None

    field = payload if separator_index < 0 else payload[:separator_index]
    field = field.strip()
    if not field or _FIELD_NAME_PATTERN.match(field) is None:
        return None

    value = "" if separator_index < 0 else payload[separator_index + 1 :].strip()
    value = _strip_wrapping_quotes(value)

    return SearchFieldToken(
        source=source,
        field=field,
        normalized_field=field.lower(),
        value=value,
        normalized_value=value.lower(),
        has_value_separator=has_value_separator,
        is_negated=is_negated,
        start=start,
        end=end,
    )


def _strip_wrapping_quotes(value: str) -> str:
    if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
        return value[1:-1].strip()
    return value
