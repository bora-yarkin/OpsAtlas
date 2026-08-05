// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// First-run server selection screen for generalized mobile app builds.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/auth_store.dart';
import '../../core/api/branding.dart';
import '../../core/api/server_config.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/widgets/brand_asset_image.dart';

class ServerConnectScreen extends ConsumerStatefulWidget {
  const ServerConnectScreen({super.key});

  @override
  ConsumerState<ServerConnectScreen> createState() =>
      _ServerConnectScreenState();
}

class _ServerConnectScreenState extends ConsumerState<ServerConnectScreen> {
  final _domainCtrl = TextEditingController();
  final _domainFocus = FocusNode();

  bool _busy = false;
  String? _error;
  String? _previewName;

  @override
  void initState() {
    super.initState();
    final serverConfig = ref.read(serverConfigProvider);
    _domainCtrl.text = serverConfig.storedBaseUrl ?? '';
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    _domainFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final raw = _domainCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = l10n.text('company_domain_required'));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _previewName = null;
    });

    try {
      final probe = await probeOpsAtlasServer(raw);
      final serverConfig = ref.read(serverConfigProvider);
      await serverConfig.setBaseUrl(probe.baseUrl);
      await ref.read(authStoreProvider).clearSession();
      if (!mounted) {
        return;
      }
      setState(() => _previewName = probe.displayName);
      context.go('/login');
    } on FormatException {
      if (!mounted) {
        return;
      }
      setState(() => _error = l10n.text('company_domain_invalid'));
    } on DioException {
      if (!mounted) {
        return;
      }
      setState(() => _error = l10n.text('company_domain_unreachable'));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = l10n.text('company_domain_unreachable'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeControllerProvider);
    final themeCtrl = ref.read(themeControllerProvider);
    final isDark = theme.isDarkFor(Theme.of(context).brightness);
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
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  cs.surface.withValues(alpha: 0.96),
                  cs.surfaceContainerLowest.withValues(alpha: 0.98),
                  cs.surface.withValues(alpha: 0.96),
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
                                    Icons.apartment_rounded,
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
                                child: Icon(
                                  Icons.apartment_rounded,
                                  color: cs.primary,
                                ),
                              ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    l10n.text('opsatlas_name'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    l10n.text('connect_company_domain_help'),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
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
                        Text(
                          l10n.text('connect_company_domain'),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          l10n.text('connect_company_domain_description'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        TextField(
                          controller: _domainCtrl,
                          focusNode: _domainFocus,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _busy ? null : _submit(),
                          decoration: InputDecoration(
                            labelText: l10n.text('company_domain'),
                            hintText: l10n.text('company_domain_placeholder'),
                            helperText: l10n.text('company_domain_example'),
                            prefixIcon: const Icon(Icons.language_rounded),
                          ),
                        ),
                        if (_previewName != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            l10n
                                .text('company_domain_connected')
                                .replaceAll('{company}', _previewName!),
                            style: TextStyle(color: cs.primary),
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
                            onPressed: _busy ? null : _submit,
                            icon: _busy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_forward_rounded),
                            label: Text(l10n.text('verify_company_domain')),
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
