// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Structured-search parsing and validation helpers.

import 'query_ast.dart';
import 'search_capabilities.dart';

class SearchValidationResult {
  final List<SearchParseDiagnostic> diagnostics;

  const SearchValidationResult({required this.diagnostics});

  bool get hasDiagnostics => diagnostics.isNotEmpty;
}

SearchValidationResult validateSearchQueryAst(
  SearchQueryAst ast, {
  required SearchSurfaceCapability capability,
}) {
  final diagnostics = <SearchParseDiagnostic>[...ast.diagnostics];
  final trimmedRightLength = ast.raw.replaceFirst(RegExp(r'\s+$'), '').length;
  final hasTrailingDelimiter = RegExp(r'[\s;]$').hasMatch(ast.raw);

  bool isCommittedToken(SearchFieldToken token) {
    final atTail = token.end >= trimmedRightLength;
    if (!atTail) {
      return true;
    }
    return hasTrailingDelimiter;
  }

  for (final token in ast.fieldTokens) {
    if (!isCommittedToken(token)) {
      continue;
    }

    final field = capability.findField(token.normalizedField);
    if (field == null) {
      diagnostics.add(
        SearchParseDiagnostic(
          code: 'unknown_field',
          message: 'Unsupported filter on this screen: ${token.field}',
          start: token.start,
          end: token.end,
        ),
      );
      continue;
    }

    if (token.hasValueSeparator && token.normalizedValue.trim().isEmpty) {
      diagnostics.add(
        SearchParseDiagnostic(
          code: 'missing_value',
          message: 'Field ${field.key} requires a value.',
          start: token.start,
          end: token.end,
        ),
      );
      continue;
    }

    if (!token.hasValue) {
      continue;
    }

    final parsedOperator = _parsePrefixedOperator(token.value);
    final operator = parsedOperator?.operator ?? SearchFieldOperator.contains;
    final operatorValue = (parsedOperator?.value ?? token.value)
        .trim()
        .toLowerCase();

    if (!field.operators.contains(operator)) {
      diagnostics.add(
        SearchParseDiagnostic(
          code: 'invalid_operator',
          message: 'Operator is not supported for ${field.key}.',
          start: token.start,
          end: token.end,
        ),
      );
      continue;
    }

    if (!_isValidValueForField(field.valueType, operatorValue)) {
      diagnostics.add(
        SearchParseDiagnostic(
          code: 'invalid_value_type',
          message: 'Invalid value for ${field.key}.',
          start: token.start,
          end: token.end,
        ),
      );
    }
  }

  return SearchValidationResult(diagnostics: diagnostics);
}

class _PrefixedOperatorValue {
  final SearchFieldOperator operator;
  final String value;

  const _PrefixedOperatorValue({required this.operator, required this.value});
}

_PrefixedOperatorValue? _parsePrefixedOperator(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('>=')) {
    return _PrefixedOperatorValue(
      operator: SearchFieldOperator.greaterOrEqual,
      value: value.substring(2),
    );
  }
  if (value.startsWith('<=')) {
    return _PrefixedOperatorValue(
      operator: SearchFieldOperator.lessOrEqual,
      value: value.substring(2),
    );
  }
  if (value.startsWith('>')) {
    return _PrefixedOperatorValue(
      operator: SearchFieldOperator.greaterThan,
      value: value.substring(1),
    );
  }
  if (value.startsWith('<')) {
    return _PrefixedOperatorValue(
      operator: SearchFieldOperator.lessThan,
      value: value.substring(1),
    );
  }
  if (value.startsWith('=')) {
    return _PrefixedOperatorValue(
      operator: SearchFieldOperator.equals,
      value: value.substring(1),
    );
  }
  return null;
}

bool _isValidValueForField(SearchFieldValueType valueType, String rawValue) {
  final value = rawValue.trim();
  if (value.isEmpty) {
    return false;
  }
  switch (valueType) {
    case SearchFieldValueType.text:
    case SearchFieldValueType.enumeration:
      return true;
    case SearchFieldValueType.booleanValue:
      return const <String>{
        'true',
        'false',
        'yes',
        'no',
        '1',
        '0',
        'on',
        'off',
      }.contains(value);
    case SearchFieldValueType.number:
      return num.tryParse(value) != null;
    case SearchFieldValueType.dateTime:
      return DateTime.tryParse(value) != null;
  }
}
