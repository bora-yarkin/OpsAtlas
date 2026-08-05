// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Login, onboarding continuation, and session-profile selection screen.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/api/auth_store.dart';
import '../../core/api/branding.dart';
import '../../core/api/request_error.dart';
import '../../core/api/server_config.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/brand_asset_image.dart';
import '../../core/widgets/password_policy_hint.dart';

/// Entry screen for login, onboarding continuation, and MFA prerequisites.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  String? _error;
  bool _busy = false;
  String? _inviteTokenFromQuery;
  String? _pendingOnboardingEmail;
  String? _pendingOnboardingPassword;
  String? _selectedSessionProfile;
  late final Future<Map<String, dynamic>> _sessionPolicyFuture;

  @override
  void initState() {
    super.initState();
    _inviteTokenFromQuery = (Uri.base.queryParameters['invite_token'] ?? '')
        .trim();
    _sessionPolicyFuture = _loadSessionPolicy();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Map<String, dynamic> _fallbackSessionPolicy() {
    return <String, dynamic>{
      'allow_remember_device': true,
      'default_profile': 'this_browser',
      'this_browser_days': 1,
      'remember_device_days': 14,
      'warning_minutes': 15,
      'available_profiles': const <String>['this_browser', 'remember_device'],
    };
  }

  /// Loads the backend session policy while keeping login usable on failure.
  Future<Map<String, dynamic>> _loadSessionPolicy() async {
    final serverConfig = ref.read(serverConfigProvider);
    if (serverConfig.effectiveBaseUrl == null ||
        serverConfig.effectiveBaseUrl!.trim().isEmpty) {
      return _fallbackSessionPolicy();
    }
    final api = ref.read(apiClientProvider);
    try {
      final response = await api.dio.get('/auth/session/policy');
      final payload = response.data;
      if (payload is Map) {
        return payload.cast<String, dynamic>();
      }
    } catch (_) {
      // Keep login usable if the live policy endpoint is temporarily
      // unavailable.
    }
    return _fallbackSessionPolicy();
  }

  List<String> _availableSessionProfiles(Map<String, dynamic> policy) {
    final rawProfiles = policy['available_profiles'];
    if (rawProfiles is List) {
      final normalized = rawProfiles
          .map((value) => value.toString().trim())
          .where(
            (value) => value == 'this_browser' || value == 'remember_device',
          )
          .toList(growable: false);
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return (policy['allow_remember_device'] == true)
        ? const <String>['this_browser', 'remember_device']
        : const <String>['this_browser'];
  }

  String _sessionProfileForPolicy(Map<String, dynamic> policy) {
    final availableProfiles = _availableSessionProfiles(policy);
    final requested =
        (_selectedSessionProfile ?? policy['default_profile'] ?? '')
            .toString()
            .trim();
    if (availableProfiles.contains(requested)) {
      return requested;
    }
    return availableProfiles.first;
  }

  String _sessionProfileLabel(AppLocalizations l10n, String profile) {
    switch (profile) {
      case 'remember_device':
        return l10n.text('remember_this_device');
      case 'this_browser':
      default:
        return l10n.text('this_browser_only');
    }
  }

  int _sessionProfileDays(Map<String, dynamic> policy, String profile) {
    final key = profile == 'remember_device'
        ? 'remember_device_days'
        : 'this_browser_days';
    final raw = policy[key];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse((raw ?? '').toString()) ??
        (profile == 'remember_device' ? 14 : 1);
  }

  String _sessionProfileDescription(
    AppLocalizations l10n,
    Map<String, dynamic> policy,
    String profile,
  ) {
    final days = _sessionProfileDays(policy, profile);
    final warningMinutes = (policy['warning_minutes'] is num)
        ? (policy['warning_minutes'] as num).toInt()
        : int.tryParse((policy['warning_minutes'] ?? '').toString()) ?? 15;
    return l10n
        .text('session_profile_duration_format')
        .replaceAll('{days}', '$days')
        .replaceAll('{minutes}', '$warningMinutes');
  }

  Future<void> _applyAuthPayload(
    AuthStore auth,
    Map<String, dynamic> payload, {
    required String missingTokenError,
  }) async {
    final accessToken = (payload['access_token'] ?? '').toString().trim();
    if (accessToken.isEmpty) {
      throw StateError(missingTokenError);
    }

    final refreshToken = (payload['refresh_token'] ?? '').toString().trim();
    final sessionId = (payload['session_id'] ?? '').toString().trim();

    if (refreshToken.isNotEmpty && sessionId.isNotEmpty) {
      await auth.setSessionBundle(
        accessToken: accessToken,
        refreshToken: refreshToken,
        sessionId: sessionId,
      );
      return;
    }

    await auth.setToken(accessToken);
  }

  Future<bool> _completeOnboarding(
    ApiClient api,
    AuthStore auth, {
    required String email,
    required String currentPassword,
  }) async {
    final l10n = AppLocalizations.of(context);
    final newPasswordCtrl = TextEditingController();
    final confirmPasswordCtrl = TextEditingController();
    String? dialogError;
    bool submitting = false;
    bool newPasswordFocused = false;

    Future<void> submit(
      void Function(void Function()) setDialogState,
      BuildContext dialogContext,
    ) async {
      if (newPasswordCtrl.text != confirmPasswordCtrl.text) {
        setDialogState(() {
          dialogError = l10n.text('password_mismatch');
        });
        return;
      }
      setDialogState(() {
        submitting = true;
        dialogError = null;
      });
      try {
        final response = await api.dio.post(
          '/auth/onboarding/complete',
          data: <String, dynamic>{
            'email': email,
            'current_password': currentPassword,
            'new_password': newPasswordCtrl.text,
          },
        );
        final payload = (response.data as Map).cast<String, dynamic>();
        await _applyAuthPayload(
          auth,
          payload,
          missingTokenError: l10n.text('login_failed'),
        );
        if (dialogContext.mounted) {
          Navigator.pop(dialogContext, true);
        }
      } on DioException catch (error) {
        setDialogState(() {
          dialogError = dioErrorMessage(
            error,
            context: dialogContext,
            fallbackMessage: l10n.text('onboarding_password_setup_failed'),
          );
        });
      } catch (_) {
        setDialogState(() {
          dialogError = l10n.text('onboarding_password_setup_failed');
        });
      } finally {
        if (dialogContext.mounted) {
          setDialogState(() {
            submitting = false;
          });
        }
      }
    }

    final completed = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('complete_onboarding'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l10n.text('complete_onboarding')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.text('onboarding_password_setup_help'),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                Focus(
                  onFocusChange: (focused) {
                    setDialogState(() => newPasswordFocused = focused);
                  },
                  child: TextField(
                    controller: newPasswordCtrl,
                    obscureText: true,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: l10n.text('new_password'),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: confirmPasswordCtrl,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => submit(setDialogState, dialogContext),
                  decoration: InputDecoration(
                    labelText: l10n.text('confirm_new_password'),
                  ),
                ),
                if (newPasswordFocused &&
                    newPasswordCtrl.text.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  PasswordPolicyHint(
                    password: newPasswordCtrl.text,
                    email: email,
                  ),
                ],
                if (dialogError != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
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
                  : Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    newPasswordCtrl.dispose();
    confirmPasswordCtrl.dispose();
    return completed == true;
  }

  Future<bool> _completeOnboardingWithInviteToken(
    ApiClient api,
    AuthStore auth,
  ) async {
    final l10n = AppLocalizations.of(context);
    final tokenCtrl = TextEditingController(text: _inviteTokenFromQuery ?? '');
    final newPasswordCtrl = TextEditingController();
    final confirmPasswordCtrl = TextEditingController();
    String? dialogError;
    bool submitting = false;
    bool newPasswordFocused = false;

    Future<void> submit(
      void Function(void Function()) setDialogState,
      BuildContext dialogContext,
    ) async {
      final onboardingToken = tokenCtrl.text.trim();
      if (onboardingToken.isEmpty) {
        setDialogState(() {
          dialogError = l10n.text('onboarding_token_required');
        });
        return;
      }
      if (newPasswordCtrl.text != confirmPasswordCtrl.text) {
        setDialogState(() {
          dialogError = l10n.text('password_mismatch');
        });
        return;
      }
      setDialogState(() {
        submitting = true;
        dialogError = null;
      });
      try {
        final response = await api.dio.post(
          '/auth/onboarding/token/complete',
          data: <String, dynamic>{
            'token': onboardingToken,
            'new_password': newPasswordCtrl.text,
          },
        );
        final payload = (response.data as Map).cast<String, dynamic>();
        await _applyAuthPayload(
          auth,
          payload,
          missingTokenError: l10n.text('login_failed'),
        );
        if (dialogContext.mounted) {
          Navigator.pop(dialogContext, true);
        }
      } on DioException catch (error) {
        setDialogState(() {
          dialogError = dioErrorMessage(
            error,
            context: dialogContext,
            fallbackMessage: l10n.text('onboarding_token_setup_failed'),
          );
        });
      } catch (_) {
        setDialogState(() {
          dialogError = l10n.text('onboarding_token_setup_failed');
        });
      } finally {
        if (dialogContext.mounted) {
          setDialogState(() {
            submitting = false;
          });
        }
      }
    }

    final completed = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('complete_onboarding'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l10n.text('complete_onboarding')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.text('onboarding_token_setup_help'),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: tokenCtrl,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: l10n.text('invite_token'),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Focus(
                  onFocusChange: (focused) {
                    setDialogState(() => newPasswordFocused = focused);
                  },
                  child: TextField(
                    controller: newPasswordCtrl,
                    obscureText: true,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: l10n.text('new_password'),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: confirmPasswordCtrl,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => submit(setDialogState, dialogContext),
                  decoration: InputDecoration(
                    labelText: l10n.text('confirm_new_password'),
                  ),
                ),
                if (newPasswordFocused &&
                    newPasswordCtrl.text.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  PasswordPolicyHint(password: newPasswordCtrl.text),
                ],
                if (dialogError != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
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
                  : Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    tokenCtrl.dispose();
    newPasswordCtrl.dispose();
    confirmPasswordCtrl.dispose();
    if (completed == true) {
      _inviteTokenFromQuery = null;
    }
    return completed == true;
  }

  Future<bool> _verifyMfaAfterLogin(ApiClient api, AuthStore auth) async {
    final l10n = AppLocalizations.of(context);
    final codeCtrl = TextEditingController();
    String? dialogError;
    bool verifying = false;

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
        verifying = true;
        dialogError = null;
      });

      try {
        final response = await api.dio.post(
          '/auth/me/mfa/verify',
          data: <String, dynamic>{'code': code},
        );
        final payload = response.data;
        if (payload is Map) {
          final token = (payload['access_token'] ?? '').toString().trim();
          if (token.isNotEmpty) {
            await auth.setToken(token);
          }
        }
        if (dialogContext.mounted) {
          Navigator.pop(dialogContext, true);
        }
      } on DioException catch (error) {
        setDialogState(() {
          dialogError = dioErrorMessage(
            error,
            context: dialogContext,
            fallbackMessage: l10n.text('mfa_verification_failed'),
          );
        });
      } catch (_) {
        setDialogState(() {
          dialogError = l10n.text('mfa_verification_failed');
        });
      } finally {
        if (dialogContext.mounted) {
          setDialogState(() {
            verifying = false;
          });
        }
      }
    }

    final verified = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('verify_mfa'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l10n.text('verify_mfa')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.text('verify_mfa_help'),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
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
                  const SizedBox(height: AppSpacing.sm),
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
              onPressed: verifying
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: verifying
                  ? null
                  : () => submit(setDialogState, dialogContext),
              child: verifying
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

  Future<void> _openOnboardingFlow(ApiClient api, AuthStore auth) async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pendingEmail = _pendingOnboardingEmail;
      final pendingPassword = _pendingOnboardingPassword;
      if (pendingEmail != null &&
          pendingEmail.isNotEmpty &&
          pendingPassword != null &&
          pendingPassword.isNotEmpty) {
        final completed = await _completeOnboarding(
          api,
          auth,
          email: pendingEmail,
          currentPassword: pendingPassword,
        );
        if (completed && mounted) {
          await ref.read(localeControllerProvider).refreshRuntime();
          if (!mounted) {
            return;
          }
          setState(() {
            _pendingOnboardingEmail = null;
            _pendingOnboardingPassword = null;
            _error = null;
          });
        } else if (!completed && mounted) {
          setState(() {
            _error = l10n.text('onboarding_password_setup_required');
          });
        }
        return;
      }

      final completed = await _completeOnboardingWithInviteToken(api, auth);
      if (completed) {
        await ref.read(localeControllerProvider).refreshRuntime();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _submit(ApiClient api, AuthStore auth) async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final normalizedEmail = _emailCtrl.text.trim();
      final password = _passwordCtrl.text;
      final sessionPolicy = await _loadSessionPolicy();
      final requestedSessionProfile = _sessionProfileForPolicy(sessionPolicy);
      final r = await api.dio.post(
        '/auth/login',
        data: <String, dynamic>{
          'email': normalizedEmail,
          'password': password,
          'session_profile': requestedSessionProfile,
        },
      );
      final payload = (r.data as Map).cast<String, dynamic>();
      final onboardingRequired = payload['onboarding_required'] == true;
      if (onboardingRequired) {
        if (mounted) {
          setState(() {
            _pendingOnboardingEmail = normalizedEmail;
            _pendingOnboardingPassword = password;
            _error = l10n.text('onboarding_password_setup_required');
          });
        }
        return;
      }
      await _applyAuthPayload(
        auth,
        payload,
        missingTokenError: l10n.text('login_failed'),
      );
      if (!mounted) {
        return;
      }
      final mfaRequired = payload['mfa_required'] == true;
      final mfaSetupRequired = payload['mfa_setup_required'] == true;
      final mfaVerified = payload['mfa_verified'] == true;
      if (mfaRequired && !mfaVerified) {
        final verified = await _verifyMfaAfterLogin(api, auth);
        if (!verified) {
          await auth.clearSession();
          if (!mounted) {
            return;
          }
          setState(() {
            _error = l10n.text('mfa_verification_required_finish_sign_in');
          });
          return;
        }
      }

      await ref.read(localeControllerProvider).refreshRuntime();
      if (!mounted) {
        return;
      }

      setState(() {
        _pendingOnboardingEmail = null;
        _pendingOnboardingPassword = null;
      });

      if (mfaSetupRequired) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.text('mfa_setup_required_notice'))),
        );
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['detail'] != null) {
        setState(() => _error = data['detail'].toString());
      } else {
        setState(() => _error = l10n.text('login_failed'));
      }
    } catch (_) {
      setState(() => _error = l10n.text('login_failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiClientProvider);
    final auth = ref.watch(authStoreProvider);
    final theme = ref.watch(themeControllerProvider);
    final themeCtrl = ref.read(themeControllerProvider);
    final isDark = theme.isDarkFor(Theme.of(context).brightness);
    final serverConfig = ref.watch(serverConfigProvider);
    final branding = ref.watch(brandingProvider).asData?.value;
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final activeLogoUrl =
        ((isDark ? branding?.darkLogoUrl : branding?.lightLogoUrl) ??
                branding?.logoUrl ??
                (isDark
                    ? branding?.lightLogoUrl
                    : branding?.darkLogoUrl) ??
                '')
            .trim();

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (branding?.loginBackgroundUrl != null &&
              branding!.loginBackgroundUrl!.trim().isNotEmpty)
            Image.network(
              branding.loginBackgroundUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  cs.surface.withValues(alpha: 0.94),
                  cs.surfaceContainerLowest.withValues(alpha: 0.96),
                  cs.surface.withValues(alpha: 0.94),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Material(
                  color: cs.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.78),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            if (activeLogoUrl.isNotEmpty)
                              Container(
                                width: 44,
                                height: 44,
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: cs.surfaceContainer,
                                ),
                                child: BrandAssetImage(
                                  url: activeLogoUrl,
                                  fit: BoxFit.contain,
                                  fallback: Icon(
                                    Icons.business,
                                    color: cs.primary,
                                  ),
                                ),
                              )
                            else
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: cs.primary.withValues(alpha: 0.15),
                                ),
                                child: Icon(Icons.business, color: cs.primary),
                              ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    branding?.companyName ??
                                        l10n.text('company_platform'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    l10n.text('organization_managed_login'),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                  if (serverConfig.supportsUserManagedBaseUrl &&
                                      serverConfig.displayHost !=
                                          null) ...<Widget>[
                                    const SizedBox(height: AppSpacing.xxs),
                                    InkWell(
                                      onTap: _busy
                                          ? null
                                          : () => context.go('/connect'),
                                      borderRadius: BorderRadius.circular(999),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(
                                              Icons.language_rounded,
                                              size: 16,
                                              color: cs.primary,
                                            ),
                                            const SizedBox(
                                              width: AppSpacing.xxs,
                                            ),
                                            Flexible(
                                              child: Text(
                                                l10n
                                                    .text(
                                                      'connected_company_domain',
                                                    )
                                                    .replaceAll(
                                                      '{domain}',
                                                      serverConfig.displayHost!,
                                                    ),
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: cs.primary,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: isDark
                                  ? l10n.text('switch_to_light_mode')
                                  : l10n.text('switch_to_dark_mode'),
                              icon: Icon(
                                isDark
                                    ? Icons.light_mode
                                    : Icons.dark_mode,
                              ),
                              onPressed: () => themeCtrl.toggleLightDarkFor(
                                Theme.of(context).brightness,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        TextField(
                          controller: _emailCtrl,
                          focusNode: _emailFocus,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => FocusScope.of(
                            context,
                          ).requestFocus(_passwordFocus),
                          decoration: InputDecoration(
                            labelText: l10n.text('email'),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextField(
                          controller: _passwordCtrl,
                          focusNode: _passwordFocus,
                          obscureText: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(api, auth),
                          decoration: InputDecoration(
                            labelText: l10n.text('password'),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        FutureBuilder<Map<String, dynamic>>(
                          future: _sessionPolicyFuture,
                          builder: (context, snapshot) {
                            final sessionPolicy =
                                snapshot.data ?? _fallbackSessionPolicy();
                            final availableProfiles = _availableSessionProfiles(
                              sessionPolicy,
                            );
                            final selectedProfile = _sessionProfileForPolicy(
                              sessionPolicy,
                            );

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  l10n.text('session_sign_in_profile'),
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: AppSpacing.xxs),
                                Text(
                                  l10n.text('session_sign_in_profile_help'),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                if (availableProfiles.length == 1)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    leading: const Icon(
                                      Icons.check_circle_outline,
                                    ),
                                    title: Text(
                                      _sessionProfileLabel(
                                        l10n,
                                        selectedProfile,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _sessionProfileDescription(
                                        l10n,
                                        sessionPolicy,
                                        selectedProfile,
                                      ),
                                    ),
                                  )
                                else
                                  IgnorePointer(
                                    ignoring: _busy,
                                    child: RadioGroup<String>(
                                      groupValue: selectedProfile,
                                      onChanged: (value) {
                                        if (value == null) {
                                          return;
                                        }
                                        setState(() {
                                          _selectedSessionProfile = value;
                                        });
                                      },
                                      child: Column(
                                        children: <Widget>[
                                          for (final profile
                                              in availableProfiles)
                                            RadioListTile<String>(
                                              contentPadding: EdgeInsets.zero,
                                              dense: true,
                                              value: profile,
                                              title: Text(
                                                _sessionProfileLabel(
                                                  l10n,
                                                  profile,
                                                ),
                                              ),
                                              subtitle: Text(
                                                _sessionProfileDescription(
                                                  l10n,
                                                  sessionPolicy,
                                                  profile,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        if (_pendingOnboardingEmail != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            l10n.text('onboarding_password_setup_required'),
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ],
                        if (_error != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          Text(_error!, style: TextStyle(color: cs.error)),
                        ],
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _busy ? null : () => _submit(api, auth),
                            icon: _busy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(l10n.text('login')),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (serverConfig
                            .supportsUserManagedBaseUrl) ...<Widget>[
                          SizedBox(
                            width: double.infinity,
                            child: TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => context.go('/connect'),
                              icon: const Icon(Icons.apartment_rounded),
                              label: Text(l10n.text('change_company_domain')),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _openOnboardingFlow(api, auth),
                            icon: const Icon(Icons.key_outlined),
                            label: Text(
                              _pendingOnboardingEmail != null
                                  ? l10n.text('complete_onboarding')
                                  : l10n.text('complete_onboarding_with_token'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
