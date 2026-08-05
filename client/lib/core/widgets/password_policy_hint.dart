// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Password policy hint widgets used by login and account flows.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../theme/theme.dart';

class PasswordPolicySnapshot {
  final bool hasMinLength;
  final bool hasUpper;
  final bool hasLower;
  final bool hasDigit;
  final bool hasSymbol;
  final bool avoidsEmailName;
  final bool avoidsNameToken;

  const PasswordPolicySnapshot({
    required this.hasMinLength,
    required this.hasUpper,
    required this.hasLower,
    required this.hasDigit,
    required this.hasSymbol,
    required this.avoidsEmailName,
    required this.avoidsNameToken,
  });

  int get totalChecks => 7;

  int get passedChecks => <bool>[
    hasMinLength,
    hasUpper,
    hasLower,
    hasDigit,
    hasSymbol,
    avoidsEmailName,
    avoidsNameToken,
  ].where((value) => value).length;

  double get progress => passedChecks / totalChecks;

  String get strengthLabel {
    if (progress >= 0.9) {
      return 'Strong';
    }
    if (progress >= 0.7) {
      return 'Good';
    }
    if (progress >= 0.45) {
      return 'Fair';
    }
    return 'Weak';
  }
}

PasswordPolicySnapshot evaluatePasswordPolicy({
  required String password,
  String? email,
  String? name,
  int minLength = 10,
}) {
  final candidate = password.trim();
  final lowered = candidate.toLowerCase();

  final localPart = (email ?? '').split('@').first.trim().toLowerCase();
  final hasEmailToken = localPart.length >= 3 && lowered.contains(localPart);

  final nameTokens = (name ?? '')
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((token) => token.length >= 3)
      .toList(growable: false);
  var hasNameToken = false;
  for (final token in nameTokens) {
    if (lowered.contains(token)) {
      hasNameToken = true;
      break;
    }
  }

  return PasswordPolicySnapshot(
    hasMinLength: candidate.length >= math.max(6, minLength),
    hasUpper: RegExp(r'[A-Z]').hasMatch(candidate),
    hasLower: RegExp(r'[a-z]').hasMatch(candidate),
    hasDigit: RegExp(r'\d').hasMatch(candidate),
    hasSymbol: RegExp(r'[^A-Za-z0-9]').hasMatch(candidate),
    avoidsEmailName: !hasEmailToken,
    avoidsNameToken: !hasNameToken,
  );
}

class PasswordPolicyHint extends StatelessWidget {
  final String password;
  final String? email;
  final String? name;
  final int minLength;

  const PasswordPolicyHint({
    super.key,
    required this.password,
    this.email,
    this.name,
    this.minLength = 10,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = evaluatePasswordPolicy(
      password: password,
      email: email,
      name: name,
      minLength: minLength,
    );
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final strengthColor = _strengthColor(snapshot.progress, cs);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.65)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n
                        .text('password_strength_label')
                        .replaceAll(
                          '{strength}',
                          _strengthLabel(snapshot, l10n),
                        ),
                    style: textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: strengthColor,
                    ),
                  ),
                ),
                Text(
                  '${snapshot.passedChecks}/${snapshot.totalChecks}',
                  style: textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: snapshot.progress,
                minHeight: 6,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(strengthColor),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            _RuleRow(
              ok: snapshot.hasMinLength,
              label: l10n
                  .text('password_rule_min_length')
                  .replaceAll('{minLength}', '$minLength'),
            ),
            _RuleRow(
              ok: snapshot.hasUpper,
              label: l10n.text('password_rule_has_uppercase'),
            ),
            _RuleRow(
              ok: snapshot.hasLower,
              label: l10n.text('password_rule_has_lowercase'),
            ),
            _RuleRow(
              ok: snapshot.hasDigit,
              label: l10n.text('password_rule_has_number'),
            ),
            _RuleRow(
              ok: snapshot.hasSymbol,
              label: l10n.text('password_rule_has_special_character'),
            ),
            _RuleRow(
              ok: snapshot.avoidsEmailName,
              label: l10n.text('password_rule_avoids_email_name'),
            ),
            _RuleRow(
              ok: snapshot.avoidsNameToken,
              label: l10n.text('password_rule_avoids_name'),
            ),
          ],
        ),
      ),
    );
  }

  String _strengthLabel(
    PasswordPolicySnapshot snapshot,
    AppLocalizations l10n,
  ) {
    if (snapshot.progress >= 0.9) {
      return l10n.text('password_strength_strong');
    }
    if (snapshot.progress >= 0.7) {
      return l10n.text('password_strength_good');
    }
    if (snapshot.progress >= 0.45) {
      return l10n.text('password_strength_fair');
    }
    return l10n.text('password_strength_weak');
  }

  Color _strengthColor(double progress, ColorScheme cs) {
    if (progress >= 0.9) {
      return const Color(0xFF16A34A);
    }
    if (progress >= 0.7) {
      return cs.primary;
    }
    if (progress >= 0.45) {
      return const Color(0xFFD97706);
    }
    return cs.error;
  }
}

class _RuleRow extends StatelessWidget {
  final bool ok;
  final String label;

  const _RuleRow({required this.ok, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = ok ? const Color(0xFF16A34A) : cs.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxs),
      child: Row(
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_outline : Icons.radio_button_unchecked,
            size: 14,
            color: color,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
