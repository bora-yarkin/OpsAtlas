// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opsatlas_client/core/i18n/app_localizations_de.dart';
import 'package:opsatlas_client/core/i18n/app_localizations_en.dart';
import 'package:opsatlas_client/core/i18n/app_localizations_tr.dart';

void main() {
  group('localization guard', () {
    final localizationFile = File('lib/core/i18n/app_localizations.dart');
    final localeValues = <String, Map<String, String>>{
      'en': appLocalizationsEnValues,
      'de': appLocalizationsDeValues,
      'tr': appLocalizationsTrValues,
    };
    final localeKeys = {
      for (final entry in localeValues.entries)
        entry.key: entry.value.keys.toSet(),
    };
    final englishValues = localeValues['en'] ?? const <String, String>{};
    final englishKeys = englishValues.keys.toSet();
    const allowedLocalizedMatches = <String, Set<String>>{
      'de': {
        'agent_prefix',
        'blast_radius_global',
        'blast_radius_regional',
        'desktop',
        'escalation_policy_standard',
        'escalation_state_normal',
        'favicon_label',
        'incident_type_service',
        'meta_name',
        'meta_type_text',
        'mobile',
        'moderator',
        'name',
        'search_flags',
        'sops',
        'status',
        'system',
        'unit_type_region',
        'unit_type_team',
        'version',
      },
      'tr': {
        'escalation_state_normal',
        'favicon_label',
        'mfa_otpauth_uri_prefix',
        'model_label',
        'postmortem_pdf',
        'provider_gemini',
        'provider_openai',
      },
    };
    const rejectedCrossLanguageValues = <String, Set<String>>{
      'en': {
        'Akteur',
        'Arbeitsanweisungen',
        'Arbeitsgruppe',
        'Ausgabe',
        'Bereich',
        'Betreuer',
        'Bezeichnung',
        'Dienst',
        'Feldname',
        'Gemini-Anbieter',
        'Mobilgerät',
        'Model Etiketi',
        'OpenAI-Anbieter',
        'Postmortem PDF Raporu',
        'Rechner',
        'Regelbetrieb',
        'Regelzustand',
        'Regionalbereich',
        'Schalter',
        'Tab-Symbol',
        'Textwert',
        'Webhook-Endpunkt',
        'Weltweit',
        'Zustand',
        'otpauth baglantisi',
      },
      'de': {
        'Gemini Saglayicisi',
        'Normal Durum',
        'OpenAI Saglayicisi',
        'Webhook Uc Noktasi',
      },
    };

    test('every locale in app_localizations.dart contains the English keys', () {
      expect(
        englishKeys,
        isNotEmpty,
        reason: 'Expected to parse English keys.',
      );

      final failures = <String>[];
      for (final entry in localeKeys.entries) {
        final missing = englishKeys.difference(entry.value).toList()..sort();
        if (missing.isEmpty) {
          continue;
        }
        failures.add(
          '${entry.key} is missing ${missing.length} key(s): ${missing.join(', ')}',
        );
      }

      expect(
        failures,
        isEmpty,
        reason:
            'Every locale map should include the same keys as English in '
            'lib/core/i18n/app_localizations.dart.\n${failures.join('\n')}',
      );
    });

    test('locale catalogs exclude known cross-language labels', () {
      final failures = <String>[];
      for (final localeEntry in localeValues.entries) {
        final rejected =
            rejectedCrossLanguageValues[localeEntry.key] ?? const <String>{};
        for (final valueEntry in localeEntry.value.entries) {
          if (rejected.contains(valueEntry.value)) {
            failures.add(
              '${localeEntry.key}.${valueEntry.key} uses ${valueEntry.value}',
            );
          }
        }
      }

      expect(
        failures,
        isEmpty,
        reason:
            'Known cross-language labels should not be reintroduced.\n'
            '${failures.join('\n')}',
      );
    });

    test(
      'translated locale labels differ from English unless language-neutral',
      () {
        expect(
          englishValues,
          isNotEmpty,
          reason: 'Expected to parse English localization values.',
        );

        final failures = <String>[];
        for (final entry in localeValues.entries) {
          if (entry.key == 'en') {
            continue;
          }

          final sameAsEnglish = <String>[];
          final allowedMatches =
              allowedLocalizedMatches[entry.key] ?? const <String>{};
          for (final key in englishKeys) {
            final englishText = englishValues[key]?.trim() ?? '';
            final localizedText = entry.value[key]?.trim() ?? '';
            if (!_shouldRequireTranslatedDifference(englishText)) {
              continue;
            }
            if (localizedText == englishText && !allowedMatches.contains(key)) {
              sameAsEnglish.add(key);
            }
          }

          if (sameAsEnglish.isEmpty) {
            continue;
          }

          sameAsEnglish.sort();
          failures.add(
            '${entry.key} has ${sameAsEnglish.length} untranslated key(s): '
            '${sameAsEnglish.join(', ')}',
          );
        }

        expect(
          failures,
          isEmpty,
          reason:
              'Every available language should keep parity with English keys and '
              'use different text for translated values.\n'
              'This is a basic parity check only: it flags values that are still '
              'identical to English.\n${failures.join('\n')}',
        );
      },
    );

    test(
      'every localization key used in lib exists in app_localizations.dart',
      () {
        final missing = <String, List<String>>{};

        for (final file in _dartFilesUnder('lib')) {
          if (file.path == localizationFile.path) {
            continue;
          }

          final source = file.readAsStringSync();
          for (final key in _findLocalizationLookups(source)) {
            if (englishKeys.contains(key)) {
              continue;
            }
            missing.putIfAbsent(key, () => <String>[]).add(file.path);
          }
        }

        final failures = missing.entries.map((entry) {
          final files = entry.value.toSet().toList()..sort();
          return "${entry.key} referenced from ${files.join(', ')}";
        }).toList()..sort();

        expect(
          failures,
          isEmpty,
          reason:
              'Every l10n lookup must exist in '
              'lib/core/i18n/app_localizations.dart.\n'
              'Add missing entries in the same format as:\n'
              "'processed_jobs_summary': "
              "'Processed {processed} jobs: {succeeded} succeeded, {retried} retried.'.\n"
              '${failures.join('\n')}',
        );
      },
    );

    test('user-facing widgets do not use raw hardcoded strings', () {
      final violations = <String>[];

      for (final file in _dartFilesUnder('lib')) {
        if (file.path == localizationFile.path) {
          continue;
        }

        final source = file.readAsStringSync();
        if (!_isFlutterUiSource(source)) {
          continue;
        }
        for (final match in _findHardcodedUiStrings(source)) {
          violations.add(
            '${file.path}:${_lineNumberFor(source, match.offset)} '
            "uses raw UI text '${match.text}'.",
          );
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Convert user-facing string literals to localization keys and add '
            'them to lib/core/i18n/app_localizations.dart.\n'
            'Use entries in the same format as:\n'
            "'processed_jobs_summary': "
            "'Processed {processed} jobs: {succeeded} succeeded, {retried} retried.'.\n"
            '${violations.join('\n')}',
      );
    });
  });
}

class _UiStringMatch {
  final int offset;
  final String text;

  const _UiStringMatch({required this.offset, required this.text});
}

Iterable<File> _dartFilesUnder(String root) sync* {
  final entries = Directory(root).listSync(recursive: true, followLinks: false);
  for (final entry in entries) {
    if (entry is File && entry.path.endsWith('.dart')) {
      yield entry;
    }
  }
}

Set<String> _findLocalizationLookups(String source) {
  final keys = <String>{};
  final patterns = <RegExp>[
    RegExp(r"l10n\.text\(\s*'([^']+)'\s*\)", dotAll: true),
    RegExp(r'l10n\.text\(\s*"([^"]+)"\s*\)', dotAll: true),
    RegExp(
      r"AppLocalizations\.of\([^)]*\)\.text\(\s*'([^']+)'\s*\)",
      dotAll: true,
    ),
    RegExp(
      r'AppLocalizations\.of\([^)]*\)\.text\(\s*"([^"]+)"\s*\)',
      dotAll: true,
    ),
    RegExp(r"_t\(\s*[^,]+,\s*'([^']+)'\s*\)", dotAll: true),
    RegExp(r'_t\(\s*[^,]+,\s*"([^"]+)"\s*\)', dotAll: true),
  ];

  for (final pattern in patterns) {
    for (final match in pattern.allMatches(source)) {
      final key = match.group(1);
      if (key != null && key.trim().isNotEmpty) {
        keys.add(key.trim());
      }
    }
  }

  return keys;
}

List<_UiStringMatch> _findHardcodedUiStrings(String source) {
  final matches = <_UiStringMatch>[];
  final patterns = <RegExp>[
    RegExp(
      r"(?:Text|SelectableText)\(\s*(?:const\s+)?'([^'\n$]*[A-Za-z][^'\n$]*)'\s*[,)]",
      multiLine: true,
    ),
    RegExp(
      r'(?:Text|SelectableText)\(\s*(?:const\s+)?"([^"\n$]*[A-Za-z][^"\n$]*)"\s*[,)]',
      multiLine: true,
    ),
    RegExp(
      r"(?:title|subtitle|label|tooltip|labelText|hintText|helperText|message|announcement)\s*:\s*'([^'\n$]*[A-Za-z][^'\n$]*)'",
      multiLine: true,
    ),
    RegExp(
      r'(?:title|subtitle|label|tooltip|labelText|hintText|helperText|message|announcement)\s*:\s*"([^"\n$]*[A-Za-z][^"\n$]*)"',
      multiLine: true,
    ),
  ];

  for (final pattern in patterns) {
    for (final match in pattern.allMatches(source)) {
      final text = match.group(1)?.trim();
      if (text == null || !_isUserVisibleHardcodedText(text)) {
        continue;
      }
      matches.add(_UiStringMatch(offset: match.start, text: text));
    }
  }

  return matches;
}

bool _isUserVisibleHardcodedText(String text) {
  if (text.isEmpty) {
    return false;
  }
  if (!RegExp(r'[A-Za-z]').hasMatch(text)) {
    return false;
  }
  if (text.contains(r'$')) {
    return false;
  }

  const allowedExact = <String>{'KB', 'true', 'false', 'S1', 'S2', 'S3', 'S4'};
  if (allowedExact.contains(text)) {
    return false;
  }

  if (RegExp(r'^[A-Za-z0-9_@#:/.+ -]+$').hasMatch(text) &&
      (text.startsWith('@') ||
          text.startsWith('#') ||
          text.startsWith('http') ||
          text.contains(' -> ') ||
          text.contains('flag:'))) {
    return false;
  }

  return true;
}

bool _isFlutterUiSource(String source) {
  return source.contains("import 'package:flutter/") ||
      source.contains('import "package:flutter/');
}

bool _shouldRequireTranslatedDifference(String englishText) {
  if (englishText.isEmpty) {
    return false;
  }

  final withoutPlaceholders = englishText
      .replaceAll(RegExp(r'\{[^}]+\}'), '')
      .trim();
  if (withoutPlaceholders.isEmpty) {
    return false;
  }

  final lettersOnly = withoutPlaceholders.replaceAll(RegExp(r'[^A-Za-z]'), '');
  if (lettersOnly.isEmpty) {
    return false;
  }

  if (RegExp(r'^[A-Z0-9 /.+_-]{1,8}$').hasMatch(withoutPlaceholders)) {
    return false;
  }

  return true;
}

int _lineNumberFor(String source, int offset) {
  return '\n'.allMatches(source.substring(0, offset)).length + 1;
}
