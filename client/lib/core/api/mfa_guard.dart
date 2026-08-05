// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// MFA guard helpers for flows that require a verified session.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/app_localizations.dart';
import '../widgets/app_dialog.dart';
import 'api_client.dart';
import 'auth_store.dart';
import 'request_error.dart';

bool isMfaChallengeError(Object error) {
  if (error is! DioException) {
    return false;
  }
  final status = error.response?.statusCode;
  if (status != 403) {
    return false;
  }
  final detail = dioErrorMessage(error).toLowerCase();
  return detail.contains('mfa') && detail.contains('required');
}

String mfaChallengeMessage(Object error, [BuildContext? context]) {
  if (error is DioException) {
    final detail = dioErrorMessage(error, context: context).trim();
    if (detail.isNotEmpty) {
      return detail;
    }
  }
  if (context != null) {
    return AppLocalizations.of(
      context,
    ).text('mfa_verification_required_action');
  }
  return const AppLocalizations(
    Locale('en'),
  ).text('mfa_verification_required_action');
}

Future<bool> promptForMfaVerification(
  BuildContext context,
  WidgetRef ref, {
  String? title,
  String? message,
}) async {
  final l10n = AppLocalizations.of(context);
  final resolvedTitle = (title ?? '').trim().isEmpty
      ? l10n.text('mfa_verification_required')
      : title!.trim();
  final resolvedMessage = (message ?? '').trim().isEmpty
      ? l10n.text('mfa_enter_code_to_continue')
      : message!.trim();

  final api = ref.read(apiClientProvider);
  final auth = ref.read(authStoreProvider);
  final codeCtrl = TextEditingController();
  String? dialogError;
  bool submitting = false;

  Future<void> submit(
    void Function(void Function()) setDialogState,
    BuildContext dialogContext,
  ) async {
    final code = codeCtrl.text.trim();
    if (code.length != 6) {
      setDialogState(() {
        dialogError = l10n.text('mfa_enter_valid_code');
      });
      return;
    }

    setDialogState(() {
      submitting = true;
      dialogError = null;
    });

    try {
      final response = await api.dio.post(
        '/auth/me/mfa/verify',
        data: <String, dynamic>{'code': code},
      );
      final token = (response.data['access_token'] ?? '').toString().trim();
      if (token.isEmpty) {
        throw StateError(l10n.text('mfa_verification_missing_token'));
      }
      await auth.setToken(token);
      if (dialogContext.mounted) {
        Navigator.pop(dialogContext, true);
      }
    } on DioException catch (error) {
      setDialogState(() {
        dialogError = dioErrorMessage(error, context: context);
      });
    } catch (error) {
      setDialogState(() {
        dialogError = error.toString();
      });
    } finally {
      if (dialogContext.mounted) {
        setDialogState(() {
          submitting = false;
        });
      }
    }
  }

  final verified = await showAppDialog<bool>(
    context: context,
    announcement: resolvedTitle,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(resolvedTitle),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                resolvedMessage,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: codeCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => submit(setDialogState, dialogContext),
                decoration: InputDecoration(
                  labelText: l10n.text('authenticator_code'),
                ),
              ),
              if (dialogError != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  dialogError!,
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: submitting
                ? null
                : () => Navigator.pop(dialogContext, false),
            child: Text(l10n.text('cancel')),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () => submit(setDialogState, dialogContext),
            child: submitting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.text('verify')),
          ),
        ],
      ),
    ),
  );

  codeCtrl.dispose();
  return verified == true;
}

Future<T> runWithMfaRetry<T>(
  BuildContext context,
  WidgetRef ref,
  Future<T> Function(ApiClient api) action, {
  String? title,
  String? message,
  void Function(DioException error)? onChallenge,
}) async {
  final api = ref.read(apiClientProvider);
  try {
    return await action(api);
  } on DioException catch (error) {
    if (!context.mounted || !isMfaChallengeError(error)) {
      rethrow;
    }
    onChallenge?.call(error);
    if (!context.mounted) {
      rethrow;
    }
    final verified = await promptForMfaVerification(
      context,
      ref,
      title: title,
      message: message,
    );
    if (!verified) {
      rethrow;
    }
    return action(api);
  }
}
