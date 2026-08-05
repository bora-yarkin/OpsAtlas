// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Account profile and security management screen.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/api_client.dart';
import '../../core/api/auth_store.dart';
import '../../core/api/mfa_guard.dart';
import '../../core/api/request_error.dart';
import '../../core/command_palette.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/notification_prefs.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/atlas_ui.dart';
import '../../core/widgets/password_policy_hint.dart';

/// Loads the current account profile and keeps auth role state synchronized.
final accountMeProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final r = await api.dio.get('/auth/me');
  final payload = (r.data as Map).cast<String, dynamic>();
  ref
      .read(authStoreProvider)
      .setRoleFromProfile((payload['global_role'] ?? '').toString());
  return payload;
});

/// Loads MFA enrollment and verification state for the current account.
final accountMfaStatusProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(apiClientProvider);
  final r = await api.dio.get('/auth/me/mfa/status');
  return (r.data as Map).cast<String, dynamic>();
});

/// Loads active sessions shown in the account security section.
final accountSessionsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(apiClientProvider);
  final response = await api.dio.get(
    '/auth/me/sessions',
    queryParameters: const <String, dynamic>{'scope': 'active'},
  );
  final data = response.data;
  if (data is! List) {
    return const <Map<String, dynamic>>[];
  }

  return data
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
});

/// Loads revoked sessions so they can live outside the primary sessions list.
final accountRevokedSessionsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(apiClientProvider);
      final response = await api.dio.get(
        '/auth/me/sessions',
        queryParameters: const <String, dynamic>{'scope': 'revoked'},
      );
      final data = response.data;
      if (data is! List) {
        return const <Map<String, dynamic>>[];
      }

      return data
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(growable: false);
    });

/// Current-user profile and security settings screen.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _currentPwCtrl = TextEditingController();
  final _newPwCtrl = TextEditingController();
  final _confirmPwCtrl = TextEditingController();

  bool _profileSaving = false;
  bool _passwordSaving = false;
  bool _mfaSaving = false;
  bool _newPasswordFocused = false;
  String? _revokingSessionId;
  bool _revokingOtherSessions = false;
  String? _loadedUserId;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _currentPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    super.dispose();
  }

  void _seedFieldsFromMe(Map<String, dynamic> me) {
    final uid = (me['id'] ?? '').toString();
    if (_loadedUserId == uid) return;
    _loadedUserId = uid;
    _nameCtrl.text = (me['name'] ?? '').toString();
    _emailCtrl.text = (me['email'] ?? '').toString();
  }

  void _refreshAccountData() {
    ref.invalidate(accountMeProvider);
    ref.invalidate(accountMfaStatusProvider);
    ref.invalidate(accountSessionsProvider);
    ref.invalidate(accountRevokedSessionsProvider);
  }

  /// Clears local auth state and returns the user to the login route.
  Future<void> _signOutToLogin() async {
    final auth = ref.read(authStoreProvider);
    await auth.clearSession();
    if (!mounted) {
      return;
    }
    context.go('/login');
  }

  String _formatSessionDate(dynamic value, AppLocalizations l10n) {
    if (value is! String || value.trim().isEmpty) {
      return l10n.text('not_available_short');
    }
    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null) {
      return value;
    }
    final local = parsed.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  String _sessionLabel(String createdAt, AppLocalizations l10n) {
    final normalized = createdAt.trim();
    if (normalized.isEmpty || normalized == l10n.text('not_available_short')) {
      return l10n.text('unknown_session');
    }
    return '${l10n.text('session_label_prefix')} • $normalized';
  }

  /// Revokes a single session, signing out immediately if it is the current one.
  Future<void> _revokeSession(Map<String, dynamic> session) async {
    if (_revokingSessionId != null || _revokingOtherSessions) {
      return;
    }

    final l10n = AppLocalizations.of(context);

    final sessionId = (session['id'] ?? '').toString().trim();
    if (sessionId.isEmpty) {
      return;
    }
    final isCurrent = session['current'] == true;

    final api = ref.read(apiClientProvider);
    setState(() {
      _revokingSessionId = sessionId;
    });

    try {
      await api.dio.post('/auth/me/sessions/$sessionId/revoke');
      if (!mounted) {
        return;
      }

      if (isCurrent) {
        await _signOutToLogin();
        return;
      }

      ref.invalidate(accountSessionsProvider);
      ref.invalidate(accountRevokedSessionsProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.text('session_revoked'))));
    } on DioException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dioErrorMessage(error, context: context))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _revokingSessionId = null;
        });
      }
    }
  }

  /// Revokes every session except the one backing the current screen.
  Future<void> _revokeOtherSessions() async {
    if (_revokingSessionId != null || _revokingOtherSessions) {
      return;
    }

    final l10n = AppLocalizations.of(context);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.text('revoke_other_sessions')),
        content: Text(l10n.text('revoke_other_sessions_confirm')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.text('cancel')),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.logout_outlined),
            label: Text(l10n.text('revoke_other_sessions')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final api = ref.read(apiClientProvider);
    setState(() {
      _revokingOtherSessions = true;
    });

    try {
      await api.dio.post('/auth/me/sessions/revoke-others');
      if (!mounted) {
        return;
      }
      ref.invalidate(accountSessionsProvider);
      ref.invalidate(accountRevokedSessionsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.text('other_sessions_revoked'))),
      );
    } on DioException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dioErrorMessage(error, context: context))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _revokingOtherSessions = false;
        });
      }
    }
  }

  /// Shows the secondary revoked-sessions list without cluttering the main card.
  Future<void> _openRevokedSessionsDialog() async {
    final l10n = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('revoked_sessions'),
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.text('revoked_sessions')),
        content: SizedBox(
          width: 720,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 520),
            child: _RevokedSessionsDialogBody(
              l10n: l10n,
              formatSessionDate: _formatSessionDate,
              sessionLabel: _sessionLabel,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _saveProfile() async {
    if (_profileSaving) return;
    final api = ref.read(apiClientProvider);
    setState(() => _profileSaving = true);
    try {
      final r = await api.dio.patch(
        '/auth/me',
        data: <String, dynamic>{
          'name': _nameCtrl.text.trim(),
          'email': _emailCtrl.text.trim(),
        },
      );
      _loadedUserId = (r.data['id'] ?? '').toString();
      ref.invalidate(accountMeProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).text('profile_updated')),
        ),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dioErrorMessage(e, context: context))),
      );
    } finally {
      if (mounted) setState(() => _profileSaving = false);
    }
  }

  Future<void> _changePassword() async {
    if (_passwordSaving) return;
    final l10n = AppLocalizations.of(context);
    if (_newPwCtrl.text != _confirmPwCtrl.text) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.text('password_mismatch'))));
      return;
    }

    final api = ref.read(apiClientProvider);
    setState(() => _passwordSaving = true);
    try {
      await api.dio.post(
        '/auth/me/password',
        data: <String, dynamic>{
          'current_password': _currentPwCtrl.text,
          'new_password': _newPwCtrl.text,
        },
      );
      _currentPwCtrl.clear();
      _newPwCtrl.clear();
      _confirmPwCtrl.clear();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.text('password_changed_sign_in_again'))),
      );
      await _signOutToLogin();
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dioErrorMessage(e, context: context))),
      );
    } finally {
      if (mounted) setState(() => _passwordSaving = false);
    }
  }

  Future<void> _verifyMfaSession() async {
    if (_mfaSaving) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final verified = await promptForMfaVerification(context, ref);
    if (!verified || !mounted) {
      return;
    }
    ref.invalidate(accountMfaStatusProvider);
    ref.invalidate(accountSessionsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.text('mfa_verification_completed'))),
    );
  }

  Future<void> _setupMfa() async {
    if (_mfaSaving) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final api = ref.read(apiClientProvider);
    final auth = ref.read(authStoreProvider);
    setState(() => _mfaSaving = true);

    try {
      final setupResponse = await api.dio.post('/auth/me/mfa/setup');
      final setupPayload = (setupResponse.data as Map).cast<String, dynamic>();
      final secret = (setupPayload['secret'] ?? '').toString().trim();
      final otpauthUrl = (setupPayload['otpauth_url'] ?? '').toString().trim();
      final issuer = (setupPayload['issuer'] ?? '').toString().trim();
      final accountName = (setupPayload['account_name'] ?? '')
          .toString()
          .trim();

      if (!mounted) {
        return;
      }

      final codeCtrl = TextEditingController();
      String? dialogError;
      bool enabling = false;

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
          enabling = true;
          dialogError = null;
        });

        try {
          await api.dio.post(
            '/auth/me/mfa/enable',
            data: <String, dynamic>{'code': code},
          );
          final verifyResponse = await api.dio.post(
            '/auth/me/mfa/verify',
            data: <String, dynamic>{'code': code},
          );
          final token = (verifyResponse.data['access_token'] ?? '')
              .toString()
              .trim();
          if (token.isNotEmpty) {
            await auth.setToken(token);
          }
          if (dialogContext.mounted) {
            Navigator.pop(dialogContext, true);
          }
        } on DioException catch (error) {
          if (!dialogContext.mounted) {
            return;
          }
          setDialogState(() {
            dialogError = dioErrorMessage(error, context: dialogContext);
          });
        } catch (error) {
          setDialogState(() {
            dialogError = error.toString();
          });
        } finally {
          if (dialogContext.mounted) {
            setDialogState(() {
              enabling = false;
            });
          }
        }
      }

      final enabled = await showAppDialog<bool>(
        context: context,
        announcement: l10n.text('set_up_mfa'),
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(l10n.text('set_up_mfa')),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.text('mfa_setup_help'),
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SelectableText('${l10n.text('mfa_issuer_prefix')}: $issuer'),
                  SelectableText(
                    '${l10n.text('mfa_account_prefix')}: $accountName',
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SelectableText('${l10n.text('mfa_secret_prefix')}: $secret'),
                  const SizedBox(height: AppSpacing.xs),
                  SelectableText(
                    '${l10n.text('mfa_otpauth_uri_prefix')}: $otpauthUrl',
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(
                          color: Theme.of(
                            dialogContext,
                          ).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  if (otpauthUrl.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Align(
                      alignment: Alignment.center,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: QrImageView(
                            data: otpauthUrl,
                            version: QrVersions.auto,
                            size: 180,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: secret));
                        if (!dialogContext.mounted) {
                          return;
                        }
                        ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                          SnackBar(
                            content: Text(l10n.text('mfa_secret_copied')),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                      label: Text(l10n.text('copy_secret')),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
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
                    const SizedBox(height: AppSpacing.xs),
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
                onPressed: enabling
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: enabling
                    ? null
                    : () => submit(setDialogState, dialogContext),
                child: enabling
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.text('enable_mfa')),
              ),
            ],
          ),
        ),
      );

      codeCtrl.dispose();
      if (enabled == true && mounted) {
        ref.invalidate(accountMfaStatusProvider);
        ref.invalidate(accountSessionsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.text('mfa_enabled_success'))),
        );
      }
    } on DioException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dioErrorMessage(error, context: context))),
      );
    } finally {
      if (mounted) {
        setState(() => _mfaSaving = false);
      }
    }
  }

  Future<void> _disableMfa() async {
    if (_mfaSaving) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final api = ref.read(apiClientProvider);
    final codeCtrl = TextEditingController();
    String? dialogError;
    bool disabling = false;

    final disabled = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('disable_mfa'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l10n.text('disable_mfa')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.text('disable_mfa_help'),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) async {
                    final code = codeCtrl.text.trim();
                    if (code.length != 6) {
                      setDialogState(() {
                        dialogError = l10n.text('mfa_enter_valid_code');
                      });
                      return;
                    }
                    setDialogState(() {
                      disabling = true;
                      dialogError = null;
                    });
                    try {
                      await api.dio.post(
                        '/auth/me/mfa/disable',
                        data: <String, dynamic>{'code': code},
                      );
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    } on DioException catch (error) {
                      if (!dialogContext.mounted) {
                        return;
                      }
                      setDialogState(() {
                        dialogError = dioErrorMessage(
                          error,
                          context: dialogContext,
                        );
                      });
                    } finally {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          disabling = false;
                        });
                      }
                    }
                  },
                  decoration: InputDecoration(
                    labelText: l10n.text('authenticator_code'),
                  ),
                ),
                if (dialogError != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
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
              onPressed: disabling
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: disabling
                  ? null
                  : () async {
                      final code = codeCtrl.text.trim();
                      if (code.length != 6) {
                        setDialogState(() {
                          dialogError = l10n.text('mfa_enter_valid_code');
                        });
                        return;
                      }
                      setDialogState(() {
                        disabling = true;
                        dialogError = null;
                      });
                      try {
                        await api.dio.post(
                          '/auth/me/mfa/disable',
                          data: <String, dynamic>{'code': code},
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, true);
                        }
                      } on DioException catch (error) {
                        if (!dialogContext.mounted) {
                          return;
                        }
                        setDialogState(() {
                          dialogError = dioErrorMessage(
                            error,
                            context: dialogContext,
                          );
                        });
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            disabling = false;
                          });
                        }
                      }
                    },
              child: disabling
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.text('disable_mfa')),
            ),
          ],
        ),
      ),
    );

    codeCtrl.dispose();
    if (!mounted || disabled != true) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.text('mfa_disabled_sign_in_again'))),
    );
    await _signOutToLogin();
  }

  @override
  Widget build(BuildContext context) {
    final meAsync = ref.watch(accountMeProvider);
    final mfaStatusAsync = ref.watch(accountMfaStatusProvider);
    final sessionsAsync = ref.watch(accountSessionsProvider);
    final revokedSessionsAsync = ref.watch(accountRevokedSessionsProvider);
    final localeCtrl = ref.watch(localeControllerProvider);
    final localeNotifier = ref.read(localeControllerProvider);
    final l10n = AppLocalizations.of(context);
    final notificationController = ref.watch(notificationPrefsProvider);
    final notificationPrefs = notificationController.value;
    final nextDelivery = notificationPrefs.nextDeliveryWindow(DateTime.now());
    final hourOptions = List<int>.generate(24, (i) => i);
    final minuteOptions = const <int>[0, 15, 30, 45];

    final commands = <ContextCommand>[
      ContextCommand(
        label: l10n.text('refresh'),
        subtitle: l10n.text('account'),
        icon: Icons.refresh,
        action: _refreshAccountData,
      ),
      ContextCommand(
        label: l10n.text('save_profile'),
        subtitle: l10n.text('profile_settings_help'),
        icon: Icons.save_outlined,
        action: _saveProfile,
      ),
      ContextCommand(
        label: l10n.text('change_password'),
        subtitle: l10n.text('password_settings_help'),
        icon: Icons.password_outlined,
        action: _changePassword,
      ),
    ];

    return CommandPaletteScope(
      commands: commands,
      child: AtlasPageFrame(
        title: l10n.text('account'),
        subtitle: l10n.text('profile_settings_help'),
        actions: <Widget>[
          OutlinedButton.icon(
            onPressed: () => context.go('/dashboard'),
            icon: const Icon(Icons.dashboard_outlined),
            label: Text(l10n.text('dashboard')),
          ),
          OutlinedButton.icon(
            onPressed: () => context.go('/spaces'),
            icon: const Icon(Icons.hub_outlined),
            label: Text(l10n.text('spaces')),
          ),
          FilledButton.icon(
            onPressed: _refreshAccountData,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.text('refresh')),
          ),
        ],
        child: meAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => AtlasEmptyState(
            icon: Icons.error_outline,
            title: l10n.text('failed_to_load_account'),
            subtitle: e.toString(),
          ),
          data: (me) {
            _seedFieldsFromMe(me);
            final cs = Theme.of(context).colorScheme;
            final role = (me['global_role'] ?? 'member').toString();
            final roleLabel = switch (role) {
              'admin' => l10n.text('admin'),
              'moderator' => l10n.text('moderator'),
              'viewer' => l10n.text('viewer'),
              _ => l10n.text('member'),
            };
            final roleColor = switch (role) {
              'admin' => cs.primary,
              'moderator' => const Color(0xFFF59E0B),
              'viewer' => cs.outline,
              _ => const Color(0xFF22C55E),
            };

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AtlasPanel(
                    title: l10n.text('your_account'),
                    subtitle: (me['email'] ?? '').toString(),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: roleColor.withValues(alpha: 0.18),
                          child: Text(
                            (_nameCtrl.text.trim().isEmpty
                                    ? (l10n.text('user').trim().isEmpty
                                          ? '?'
                                          : l10n.text('user').trim()[0])
                                    : _nameCtrl.text.trim()[0])
                                .toUpperCase(),
                            style: TextStyle(
                              color: roleColor,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _nameCtrl.text.trim().isEmpty
                                    ? l10n.text('your_account')
                                    : _nameCtrl.text.trim(),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.sm,
                                children: <Widget>[
                                  Chip(
                                    avatar: Icon(
                                      Icons.verified_user,
                                      color: roleColor,
                                      size: 18,
                                    ),
                                    label: Text(
                                      '${l10n.text('role_prefix')}: $roleLabel',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _AccountCredentialsSection(
                    l10n: l10n,
                    nameCtrl: _nameCtrl,
                    emailCtrl: _emailCtrl,
                    currentPwCtrl: _currentPwCtrl,
                    newPwCtrl: _newPwCtrl,
                    confirmPwCtrl: _confirmPwCtrl,
                    profileSaving: _profileSaving,
                    passwordSaving: _passwordSaving,
                    showPasswordPolicy:
                        _newPasswordFocused &&
                        _newPwCtrl.text.trim().isNotEmpty,
                    onSaveProfile: _saveProfile,
                    onChangePassword: _changePassword,
                    onNewPasswordFocusChanged: (focused) {
                      setState(() => _newPasswordFocused = focused);
                    },
                    onPasswordDraftChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _AccountMfaPanel(
                    l10n: l10n,
                    mfaStatusAsync: mfaStatusAsync,
                    mfaSaving: _mfaSaving,
                    onSetupMfa: _setupMfa,
                    onVerifyMfaSession: _verifyMfaSession,
                    onDisableMfa: _disableMfa,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AtlasPanel(
                    title: l10n.text('language'),
                    subtitle: l10n.text('language_settings_help'),
                    child: Builder(
                      builder: (context) {
                        final serverLanguages = localeCtrl.languageOptions
                            .where((item) => item.enabled || item.isDefault)
                            .toList(growable: false);
                        final hasServerCatalog =
                            localeCtrl.loadedFromServer &&
                            serverLanguages.isNotEmpty;

                        final itemValues = <String>{};
                        final items = <DropdownMenuItem<String>>[];

                        void addItem({
                          required String value,
                          required String label,
                        }) {
                          if (!itemValues.add(value)) {
                            return;
                          }
                          items.add(
                            DropdownMenuItem<String>(
                              value: value,
                              child: Text(label),
                            ),
                          );
                        }

                        if (hasServerCatalog) {
                          addItem(
                            value: '__org_default__',
                            label: l10n.text('organization_default'),
                          );
                          for (final option in serverLanguages) {
                            addItem(value: option.code, label: option.name);
                          }
                        } else {
                          addItem(value: 'system', label: l10n.text('system'));
                          addItem(value: 'en', label: l10n.text('english'));
                          addItem(value: 'de', label: l10n.text('german'));
                          addItem(value: 'tr', label: l10n.text('turkish'));
                        }

                        final preferredValue = hasServerCatalog
                            ? (localeCtrl.useOrganizationDefault
                                  ? '__org_default__'
                                  : (localeCtrl.userLanguageCode ??
                                        localeCtrl.effectiveLanguageCode))
                            : (localeCtrl.locale?.languageCode ?? 'system');

                        final selectedValue =
                            itemValues.contains(preferredValue)
                            ? preferredValue
                            : (items.isNotEmpty ? items.first.value : null);

                        return DropdownButtonFormField<String>(
                          key: ValueKey<String>('language-$selectedValue'),
                          initialValue: selectedValue,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.text('language'),
                            helperText: hasServerCatalog
                                ? l10n.text('server_synced')
                                : l10n.text('device_cache'),
                          ),
                          items: items,
                          onChanged: (value) async {
                            if (value == null) {
                              return;
                            }
                            if (value == 'system' ||
                                value == '__org_default__') {
                              await localeNotifier.setSystemLocale();
                              return;
                            }
                            await localeNotifier.setLocale(Locale(value));
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _AccountNotificationsPanel(
                    l10n: l10n,
                    notificationController: notificationController,
                    notificationPrefs: notificationPrefs,
                    nextDelivery: nextDelivery,
                    hourOptions: hourOptions,
                    minuteOptions: minuteOptions,
                    formatScheduleDate: _formatScheduleDate,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _AccountSessionsPanel(
                    l10n: l10n,
                    sessionsAsync: sessionsAsync,
                    revokedSessionsAsync: revokedSessionsAsync,
                    revokingSessionId: _revokingSessionId,
                    revokingOtherSessions: _revokingOtherSessions,
                    formatSessionDate: _formatSessionDate,
                    sessionLabel: _sessionLabel,
                    onRevokeSession: _revokeSession,
                    onRevokeOtherSessions: _revokeOtherSessions,
                    onShowRevokedSessions: _openRevokedSessionsDialog,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AccountCredentialsSection extends StatelessWidget {
  final AppLocalizations l10n;
  final TextEditingController nameCtrl;
  final TextEditingController emailCtrl;
  final TextEditingController currentPwCtrl;
  final TextEditingController newPwCtrl;
  final TextEditingController confirmPwCtrl;
  final bool profileSaving;
  final bool passwordSaving;
  final bool showPasswordPolicy;
  final VoidCallback onSaveProfile;
  final VoidCallback onChangePassword;
  final ValueChanged<bool> onNewPasswordFocusChanged;
  final VoidCallback onPasswordDraftChanged;

  const _AccountCredentialsSection({
    required this.l10n,
    required this.nameCtrl,
    required this.emailCtrl,
    required this.currentPwCtrl,
    required this.newPwCtrl,
    required this.confirmPwCtrl,
    required this.profileSaving,
    required this.passwordSaving,
    required this.showPasswordPolicy,
    required this.onSaveProfile,
    required this.onChangePassword,
    required this.onNewPasswordFocusChanged,
    required this.onPasswordDraftChanged,
  });

  @override
  Widget build(BuildContext context) {
    final profilePanel = AtlasPanel(
      title: l10n.text('profile'),
      subtitle: l10n.text('profile_settings_help'),
      child: Column(
        children: <Widget>[
          TextField(
            controller: nameCtrl,
            decoration: InputDecoration(labelText: l10n.text('name_username')),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: l10n.text('email')),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: profileSaving ? null : onSaveProfile,
              icon: profileSaving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                profileSaving ? l10n.text('saving') : l10n.text('save_profile'),
              ),
            ),
          ),
        ],
      ),
    );

    final passwordPanel = AtlasPanel(
      title: l10n.text('password'),
      subtitle: l10n.text('password_settings_help'),
      child: Column(
        children: <Widget>[
          TextField(
            controller: currentPwCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.text('current_password'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Focus(
            onFocusChange: onNewPasswordFocusChanged,
            child: TextField(
              controller: newPwCtrl,
              obscureText: true,
              onChanged: (_) => onPasswordDraftChanged(),
              decoration: InputDecoration(labelText: l10n.text('new_password')),
            ),
          ),
          if (showPasswordPolicy) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            PasswordPolicyHint(
              password: newPwCtrl.text,
              email: emailCtrl.text,
              name: nameCtrl.text,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: confirmPwCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.text('confirm_new_password'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: passwordSaving ? null : onChangePassword,
              icon: passwordSaving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.password_outlined),
              label: Text(
                passwordSaving
                    ? l10n.text('updating')
                    : l10n.text('change_password'),
              ),
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        profilePanel,
        const SizedBox(height: AppSpacing.md),
        passwordPanel,
      ],
    );
  }
}

class _AccountMfaPanel extends StatelessWidget {
  final AppLocalizations l10n;
  final AsyncValue<Map<String, dynamic>> mfaStatusAsync;
  final bool mfaSaving;
  final VoidCallback onSetupMfa;
  final VoidCallback onVerifyMfaSession;
  final VoidCallback onDisableMfa;

  const _AccountMfaPanel({
    required this.l10n,
    required this.mfaStatusAsync,
    required this.mfaSaving,
    required this.onSetupMfa,
    required this.onVerifyMfaSession,
    required this.onDisableMfa,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AtlasPanel(
      title: l10n.text('mfa_panel_title'),
      subtitle: l10n.text('mfa_panel_subtitle'),
      child: mfaStatusAsync.when(
        loading: () => const Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (error, _) => Text(error.toString()),
        data: (status) {
          final enabled = status['enabled'] == true;
          final requiredForSensitive =
              status['required_for_sensitive_actions'] == true;
          final verifiedForSession = status['verified_for_session'] == true;
          final devBypass = status['dev_bypass_active'] == true;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  Chip(
                    avatar: Icon(
                      enabled
                          ? Icons.verified_user_outlined
                          : Icons.security_outlined,
                      size: 18,
                    ),
                    label: Text(
                      enabled
                          ? l10n.text('mfa_enabled_status')
                          : l10n.text('mfa_disabled_status'),
                    ),
                  ),
                  Chip(
                    avatar: Icon(
                      verifiedForSession
                          ? Icons.check_circle_outline
                          : Icons.pending_outlined,
                      size: 18,
                    ),
                    label: Text(
                      verifiedForSession
                          ? l10n.text('mfa_session_verified')
                          : l10n.text('mfa_session_not_verified'),
                    ),
                  ),
                  if (requiredForSensitive)
                    Chip(
                      avatar: const Icon(
                        Icons.admin_panel_settings_outlined,
                        size: 18,
                      ),
                      label: Text(
                        l10n.text('mfa_required_for_elevated_actions'),
                      ),
                    ),
                ],
              ),
              if (devBypass) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.text('mfa_dev_bypass_notice'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  if (!enabled)
                    FilledButton.icon(
                      onPressed: mfaSaving ? null : onSetupMfa,
                      icon: const Icon(Icons.shield_outlined),
                      label: Text(
                        mfaSaving
                            ? l10n.text('working')
                            : l10n.text('set_up_mfa'),
                      ),
                    )
                  else ...<Widget>[
                    OutlinedButton.icon(
                      onPressed: mfaSaving ? null : onVerifyMfaSession,
                      icon: const Icon(Icons.verified_outlined),
                      label: Text(l10n.text('verify_now')),
                    ),
                    TextButton.icon(
                      onPressed: mfaSaving ? null : onDisableMfa,
                      icon: const Icon(
                        Icons.no_encryption_gmailerrorred_outlined,
                      ),
                      label: Text(l10n.text('disable_mfa')),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AccountSessionsPanel extends StatelessWidget {
  final AppLocalizations l10n;
  final AsyncValue<List<Map<String, dynamic>>> sessionsAsync;
  final AsyncValue<List<Map<String, dynamic>>> revokedSessionsAsync;
  final String? revokingSessionId;
  final bool revokingOtherSessions;
  final String Function(dynamic value, AppLocalizations l10n) formatSessionDate;
  final String Function(String createdAt, AppLocalizations l10n) sessionLabel;
  final ValueChanged<Map<String, dynamic>> onRevokeSession;
  final VoidCallback onRevokeOtherSessions;
  final VoidCallback onShowRevokedSessions;

  const _AccountSessionsPanel({
    required this.l10n,
    required this.sessionsAsync,
    required this.revokedSessionsAsync,
    required this.revokingSessionId,
    required this.revokingOtherSessions,
    required this.formatSessionDate,
    required this.sessionLabel,
    required this.onRevokeSession,
    required this.onRevokeOtherSessions,
    required this.onShowRevokedSessions,
  });

  @override
  Widget build(BuildContext context) {
    final sessions = sessionsAsync.asData?.value;
    final revokedSessions = revokedSessionsAsync.asData?.value;
    final revokedSessionCount = revokedSessions?.length ?? 0;
    final hasRevocableOtherSessions =
        sessions?.any((session) {
          final isCurrent = session['current'] == true;
          final isRevoked = (session['revoked_at'] ?? '')
              .toString()
              .trim()
              .isNotEmpty;
          return !isCurrent && !isRevoked;
        }) ??
        false;
    final trailingActions = <Widget>[
      if (revokedSessionCount > 0)
        TextButton.icon(
          onPressed: onShowRevokedSessions,
          icon: const Icon(Icons.history_outlined),
          label: Text(
            '${l10n.text('revoked_sessions')} ($revokedSessionCount)',
          ),
        ),
      if (hasRevocableOtherSessions || revokingOtherSessions)
        TextButton.icon(
          onPressed: revokingOtherSessions ? null : onRevokeOtherSessions,
          icon: revokingOtherSessions
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout_outlined),
          label: Text(l10n.text('revoke_other_sessions')),
        ),
    ];

    return AtlasPanel(
      title: l10n.text('sessions_title'),
      subtitle: l10n.text('sessions_subtitle'),
      trailing: trailingActions.isEmpty
          ? null
          : Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              alignment: WrapAlignment.end,
              children: trailingActions,
            ),
      child: sessionsAsync.when(
        loading: () => const Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (error, _) => Text(error.toString()),
        data: (sessions) {
          if (sessions.isEmpty) {
            return Text(l10n.text('no_active_sessions_found'));
          }

          return Column(
            children: sessions
                .map(
                  (session) => _AccountSessionCard(
                    session: session,
                    l10n: l10n,
                    isRevoking:
                        revokingSessionId ==
                        (session['id'] ?? '').toString().trim(),
                    formatSessionDate: formatSessionDate,
                    sessionLabel: sessionLabel,
                    onRevokeSession: onRevokeSession,
                  ),
                )
                .toList(growable: false),
          );
        },
      ),
    );
  }
}

class _AccountSessionCard extends StatelessWidget {
  final Map<String, dynamic> session;
  final AppLocalizations l10n;
  final bool isRevoking;
  final String Function(dynamic value, AppLocalizations l10n) formatSessionDate;
  final String Function(String createdAt, AppLocalizations l10n) sessionLabel;
  final ValueChanged<Map<String, dynamic>> onRevokeSession;

  const _AccountSessionCard({
    required this.session,
    required this.l10n,
    required this.isRevoking,
    required this.formatSessionDate,
    required this.sessionLabel,
    required this.onRevokeSession,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sessionId = (session['id'] ?? '').toString().trim();
    final isCurrent = session['current'] == true;
    final isRevoked = (session['revoked_at'] ?? '')
        .toString()
        .trim()
        .isNotEmpty;
    final lastSeenAt = formatSessionDate(session['last_seen_at'], l10n);
    final expiresAt = formatSessionDate(session['refresh_expires_at'], l10n);
    final createdAt = formatSessionDate(session['created_at'], l10n);
    final userAgent = (session['user_agent'] ?? '').toString().trim();
    final ipAddress = (session['ip_address'] ?? '').toString().trim();
    final mfaSessionVerified = session['mfa_verified'] == true;
    final revokedAt = formatSessionDate(session['revoked_at'], l10n);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    isCurrent
                        ? l10n.text('this_device')
                        : sessionLabel(createdAt, l10n),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (isCurrent)
                    Chip(
                      avatar: const Icon(Icons.check_circle_outline, size: 16),
                      label: Text(l10n.text('current')),
                    ),
                  if (mfaSessionVerified)
                    Chip(
                      avatar: const Icon(Icons.verified_outlined, size: 16),
                      label: Text(l10n.text('mfa_session_verified')),
                    ),
                  if (isRevoked)
                    Chip(
                      avatar: const Icon(Icons.block_outlined, size: 16),
                      label: Text(l10n.text('revoked')),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${l10n.text('session_created_prefix')}: $createdAt · ${l10n.text('session_last_seen_prefix')}: $lastSeenAt · ${l10n.text('session_refresh_expiry_prefix')}: $expiresAt${isRevoked ? ' · ${l10n.text('revoked')}: $revokedAt' : ''}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (ipAddress.isNotEmpty || userAgent.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${l10n.text('ip_prefix')}: ${ipAddress.isEmpty ? l10n.text('not_available_short') : ipAddress}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '${l10n.text('agent_prefix')}: ${userAgent.isEmpty ? l10n.text('not_available_short') : userAgent}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (!isRevoked) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: (sessionId.isEmpty || isRevoking)
                        ? null
                        : () => onRevokeSession(session),
                    icon: isRevoking
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.logout_outlined),
                    label: Text(
                      isCurrent
                          ? l10n.text('sign_out_this_device')
                          : l10n.text('revoke_session'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RevokedSessionsDialogBody extends ConsumerWidget {
  final AppLocalizations l10n;
  final String Function(dynamic value, AppLocalizations l10n) formatSessionDate;
  final String Function(String createdAt, AppLocalizations l10n) sessionLabel;

  const _RevokedSessionsDialogBody({
    required this.l10n,
    required this.formatSessionDate,
    required this.sessionLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revokedSessionsAsync = ref.watch(accountRevokedSessionsProvider);
    return revokedSessionsAsync.when(
      loading: () => const Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (error, _) => Text(error.toString()),
      data: (sessions) {
        if (sessions.isEmpty) {
          return Text(l10n.text('no_revoked_sessions_found'));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              l10n.text('revoked_sessions_retention_notice'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: sessions
                      .map(
                        (session) => _AccountSessionCard(
                          session: session,
                          l10n: l10n,
                          isRevoking: false,
                          formatSessionDate: formatSessionDate,
                          sessionLabel: sessionLabel,
                          onRevokeSession: (_) {},
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AccountNotificationsPanel extends StatelessWidget {
  final AppLocalizations l10n;
  final NotificationPrefsController notificationController;
  final NotificationPrefs notificationPrefs;
  final DateTime? nextDelivery;
  final List<int> hourOptions;
  final List<int> minuteOptions;
  final String Function(DateTime value) formatScheduleDate;

  const _AccountNotificationsPanel({
    required this.l10n,
    required this.notificationController,
    required this.notificationPrefs,
    required this.nextDelivery,
    required this.hourOptions,
    required this.minuteOptions,
    required this.formatScheduleDate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AtlasPanel(
      title: l10n.text('notifications'),
      subtitle: l10n.text('notification_settings_help'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                notificationController.loadedFromServer
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.text('notification_storage'),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      notificationController.loadedFromServer
                          ? l10n.text('server_synced')
                          : l10n.text('device_cache'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.text('task_events')),
            subtitle: Text(l10n.text('task_events_types')),
            value: notificationPrefs.includeTask,
            onChanged: (value) => notificationController.update(
              notificationPrefs.copyWith(includeTask: value),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.text('publish_events')),
            subtitle: Text(l10n.text('publish_events_type')),
            value: notificationPrefs.includePublish,
            onChanged: (value) => notificationController.update(
              notificationPrefs.copyWith(includePublish: value),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.text('view_events')),
            subtitle: Text(l10n.text('view_events_type')),
            value: notificationPrefs.includeView,
            onChanged: (value) => notificationController.update(
              notificationPrefs.copyWith(includeView: value),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.text('search_events')),
            subtitle: Text(l10n.text('search_events_type')),
            value: notificationPrefs.includeSearch,
            onChanged: (value) => notificationController.update(
              notificationPrefs.copyWith(includeSearch: value),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            initialValue: notificationPrefs.digestMode,
            decoration: InputDecoration(labelText: l10n.text('digest_mode')),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem(
                value: 'realtime',
                child: Text(l10n.text('realtime')),
              ),
              DropdownMenuItem(
                value: 'hourly',
                child: Text(l10n.text('hourly_digest')),
              ),
              DropdownMenuItem(
                value: 'daily',
                child: Text(l10n.text('daily_digest')),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              notificationController.update(
                notificationPrefs.copyWith(digestMode: value),
              );
            },
          ),
          if (notificationPrefs.digestMode != 'realtime') ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: notificationPrefs.digestHour,
                    decoration: InputDecoration(
                      labelText: l10n.text('delivery_hour'),
                    ),
                    items: <DropdownMenuItem<int>>[
                      for (final hour in hourOptions)
                        DropdownMenuItem<int>(
                          value: hour,
                          child: Text(hour.toString().padLeft(2, '0')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      notificationController.update(
                        notificationPrefs.copyWith(digestHour: value),
                      );
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: notificationPrefs.digestMinute,
                    decoration: InputDecoration(
                      labelText: l10n.text('delivery_minute'),
                    ),
                    items: <DropdownMenuItem<int>>[
                      for (final minute in minuteOptions)
                        DropdownMenuItem<int>(
                          value: minute,
                          child: Text(minute.toString().padLeft(2, '0')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      notificationController.update(
                        notificationPrefs.copyWith(digestMinute: value),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              notificationPrefs.scheduleSummaryText(l10n),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (nextDelivery != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xxs),
              Text(
                '${l10n.text('next_batch')}: ${formatScheduleDate(nextDelivery!)}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

String _formatScheduleDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$month/$day $hour:$minute';
}
