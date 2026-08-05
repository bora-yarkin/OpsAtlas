// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared help dialogs and affordances for structured-search syntax.

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../widgets/app_dialog.dart';
import 'search_capabilities.dart';

const List<String> _searchBooleanOperators = <String>[
  'AND',
  'OR',
  'NOT',
  'NOR',
  'XOR',
];

String structuredSearchHint({
  required AppLocalizations l10n,
  required SearchSurfaceCapability capability,
  String? baseHint,
}) {
  final normalizedBase = (baseHint ?? '').trim();
  final fallbackExample = capability.examples.isEmpty
      ? ''
      : capability.examples.first.trim();
  final hintBase = normalizedBase.isEmpty ? fallbackExample : normalizedBase;
  final opsHint = l10n.text('search_boolean_ops_hint').trim();
  if (hintBase.isEmpty) {
    return opsHint;
  }

  final upper = hintBase.toUpperCase();
  final hasAllOperators = _searchBooleanOperators.every(
    (op) => upper.contains(op),
  );
  if (hasAllOperators || opsHint.isEmpty) {
    return hintBase;
  }
  return '$hintBase $opsHint';
}

class SearchHowToButton extends StatelessWidget {
  final SearchSurfaceCapability capability;
  final String? dialogTitle;

  const SearchHowToButton({
    super.key,
    required this.capability,
    this.dialogTitle,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton(
      tooltip: l10n.text('search_how_to'),
      onPressed: () => showSearchHowToDialog(
        context,
        capability: capability,
        title: dialogTitle,
      ),
      icon: const Icon(Icons.info_outline),
    );
  }
}

Future<void> showSearchHowToDialog(
  BuildContext context, {
  required SearchSurfaceCapability capability,
  String? title,
}) async {
  final l10n = AppLocalizations.of(context);
  final examples = capability.examples.isEmpty
      ? <String>[
          'error AND @status:open',
          '(@status:open OR @status:monitoring) XOR @archived:true',
        ]
      : capability.examples;
  final fields =
      capability.fields
          .map((field) => field.key.trim())
          .where((field) => field.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  final flags = capability.flags.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));

  await showAppDialog<void>(
    context: context,
    announcement: l10n.text('search_how_to'),
    builder: (dialogContext) => AlertDialog(
      title: Text(title ?? l10n.text('search_how_to')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.text('search_how_to_basics')),
              const SizedBox(height: 8),
              Text(l10n.text('search_how_to_boolean_ops')),
              if (fields.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  l10n.text('search_how_to_supported_fields'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final field in fields)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('@$field'),
                      ),
                  ],
                ),
              ],
              if (flags.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  l10n.text('search_how_to_supported_flags'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                for (final flag in flags)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SelectableText(
                      'flag:${flag.key} - ${l10n.text(flag.descriptionLocalizationKey)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
              ],
              if (examples.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  l10n.text('search_how_to_examples'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                for (final example in examples.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SelectableText(
                      example,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.text('close')),
        ),
      ],
    ),
  );
}
