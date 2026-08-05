// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/search/query_ast.dart';

void main() {
  group('search chip labels', () {
    test('quotes values containing spaces and keeps negation', () {
      const token = SearchFieldToken(
        source: '-@status:in progress',
        field: 'status',
        normalizedField: 'status',
        value: 'in progress',
        normalizedValue: 'in progress',
        hasValueSeparator: true,
        isNegated: true,
        start: 0,
        end: 19,
      );

      expect(token.toChipLabel(), '-@status:"in progress"');
    });

    test('renders empty value when a separator is present', () {
      const token = SearchFieldToken(
        source: '@status:',
        field: 'status',
        normalizedField: 'status',
        value: '',
        normalizedValue: '',
        hasValueSeparator: true,
        isNegated: false,
        start: 0,
        end: 8,
      );

      expect(token.toChipLabel(), '@status:');
    });
  });

  group('at-token suggestion transforms', () {
    test('replaces active token and keeps negation', () {
      final replaced = applyAtTokenSuggestion(
        raw: 'alpha -@sta',
        suggestionToken: '@status:closed',
        appendSpace: false,
      );

      expect(replaced, 'alpha -@status:closed');
    });

    test('appends with delimiter when no active at-token exists', () {
      final replaced = applyAtTokenSuggestion(
        raw: 'alpha beta',
        suggestionToken: '@kind:user',
        appendSpace: false,
      );

      expect(replaced, 'alpha beta; @kind:user');
    });
  });

  group('query normalization helpers', () {
    test('removes a query range and normalizes separators', () {
      const query = 'alpha; @status:open; beta';
      final start = query.indexOf('@status:open');
      final end = start + '@status:open'.length;

      final updated = removeSearchRangeFromQuery(query, start: start, end: end);

      expect(updated, 'alpha; beta');
    });

    test('splits, normalizes and deduplicates flag values', () {
      final values = splitSearchFlagValues(' Open,closed open  pending ');

      expect(values, <String>['open', 'closed', 'pending']);
    });
  });
}
