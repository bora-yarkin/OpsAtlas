// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// UI widgets for rendering structured-search diagnostics and hints.

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import 'query_ast.dart';

class SearchDiagnosticsList extends StatelessWidget {
  final List<SearchParseDiagnostic> diagnostics;

  const SearchDiagnosticsList({super.key, required this.diagnostics});

  @override
  Widget build(BuildContext context) {
    if (diagnostics.isEmpty) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final uniqueMessages = diagnostics
        .map(
          (diagnostic) => _localizedDiagnosticMessage(diagnostic, l10n).trim(),
        )
        .where((message) => message.isNotEmpty)
        .toSet()
        .toList(growable: false);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.text('query_checks'),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final message in uniqueMessages)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('- $message', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  String _localizedDiagnosticMessage(
    SearchParseDiagnostic diagnostic,
    AppLocalizations l10n,
  ) {
    switch (diagnostic.code) {
      case 'missing_operand':
        return l10n.text('search_missing_operand_not');
      case 'unclosed_group':
        return l10n.text('search_missing_closing_parenthesis');
      case 'unexpected_close_paren':
        return l10n.text('search_unexpected_closing_parenthesis');
      case 'empty_term':
        return l10n.text('search_empty_term');
      case 'unexpected_operator':
        final message = diagnostic.message.trim();
        final separator = message.lastIndexOf(':');
        if (separator != -1 && separator + 1 < message.length) {
          final operator = message.substring(separator + 1).trim();
          return l10n
              .text('search_unexpected_operator_prefix')
              .replaceAll('{operator}', operator);
        }
        return message;
      default:
        return diagnostic.message;
    }
  }
}
