// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/search/query_ast.dart';

void main() {
  group('parseSearchQueryAst', () {
    test('parses text and field tokens with negation', () {
      final ast = parseSearchQueryAst('alpha @status:open -@kind:user');

      expect(ast.textTokens.length, 1);
      expect(ast.textTokens.first.normalizedValue, 'alpha');

      expect(ast.fieldTokens.length, 2);
      expect(ast.fieldTokens[0].normalizedField, 'status');
      expect(ast.fieldTokens[0].normalizedValue, 'open');
      expect(ast.fieldTokens[0].isNegated, isFalse);

      expect(ast.fieldTokens[1].normalizedField, 'kind');
      expect(ast.fieldTokens[1].normalizedValue, 'user');
      expect(ast.fieldTokens[1].isNegated, isTrue);
      expect(ast.expression, isNotNull);
    });

    test('supports boolean grouping and NOT operators', () {
      final ast = parseSearchQueryAst('(alpha OR beta) AND NOT gamma');

      bool evaluateFor(Set<String> terms) {
        return evaluateSearchExpression(
          ast.expression,
          matchesField: (_) => false,
          matchesText: (token) => terms.contains(token.normalizedValue),
        );
      }

      expect(evaluateFor({'alpha'}), isTrue);
      expect(evaluateFor({'beta'}), isTrue);
      expect(evaluateFor({'gamma'}), isFalse);
      expect(evaluateFor({'beta', 'gamma'}), isFalse);
      expect(evaluateFor({'delta'}), isFalse);
    });

    test('applies implicit AND before OR precedence', () {
      final ast = parseSearchQueryAst('alpha beta OR gamma');

      bool evaluateFor(Set<String> terms) {
        return evaluateSearchExpression(
          ast.expression,
          matchesField: (_) => false,
          matchesText: (token) => terms.contains(token.normalizedValue),
        );
      }

      expect(evaluateFor({'alpha', 'beta'}), isTrue);
      expect(evaluateFor({'gamma'}), isTrue);
      expect(evaluateFor({'alpha'}), isFalse);
      expect(evaluateFor({'beta'}), isFalse);
    });

    test('supports NOR operator', () {
      final ast = parseSearchQueryAst('alpha NOR beta');

      bool evaluateFor(Set<String> terms) {
        return evaluateSearchExpression(
          ast.expression,
          matchesField: (_) => false,
          matchesText: (token) => terms.contains(token.normalizedValue),
        );
      }

      expect(evaluateFor(<String>{}), isTrue);
      expect(evaluateFor({'alpha'}), isFalse);
      expect(evaluateFor({'beta'}), isFalse);
      expect(evaluateFor({'alpha', 'beta'}), isFalse);
    });

    test('supports XOR operator', () {
      final ast = parseSearchQueryAst('alpha XOR beta');

      bool evaluateFor(Set<String> terms) {
        return evaluateSearchExpression(
          ast.expression,
          matchesField: (_) => false,
          matchesText: (token) => terms.contains(token.normalizedValue),
        );
      }

      expect(evaluateFor(<String>{}), isFalse);
      expect(evaluateFor({'alpha'}), isTrue);
      expect(evaluateFor({'beta'}), isTrue);
      expect(evaluateFor({'alpha', 'beta'}), isFalse);
    });

    test('supports field token negation inside expression callback', () {
      final ast = parseSearchQueryAst('-@status:open OR @status:closed');

      bool evaluateFor(String currentStatus) {
        return evaluateSearchExpression(
          ast.expression,
          matchesField: (token) {
            final base = token.normalizedValue == currentStatus;
            return token.isNegated ? !base : base;
          },
          matchesText: (_) => false,
        );
      }

      expect(evaluateFor('open'), isFalse);
      expect(evaluateFor('closed'), isTrue);
      expect(evaluateFor('other'), isTrue);
    });

    test('reports diagnostics for unclosed groups', () {
      final ast = parseSearchQueryAst('((alpha OR beta)');

      expect(ast.hasDiagnostics, isTrue);
      expect(ast.diagnostics.any((d) => d.code == 'unclosed_group'), isTrue);
    });
  });

  group('parseAtTokenSuggestionContext', () {
    test('extracts active field and value partials', () {
      final context = parseAtTokenSuggestionContext('foo @status:op');

      expect(context, isNotNull);
      expect(context!.fieldLower, 'status');
      expect(context.partialValueLower, 'op');
      expect(context.hasValueSeparator, isTrue);
    });
  });
}
