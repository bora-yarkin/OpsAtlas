// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Mutation workflows and dialogs for the organization management screen.

part of 'admin_organization_screen.dart';

extension _AdminOrganizationScreenStateMutations
    on _AdminOrganizationScreenState {
  String _normalizeEditableUnitType(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'team') {
      return 'department';
    }
    if (normalized == 'region' ||
        normalized == 'store' ||
        normalized == 'department') {
      return normalized;
    }
    return 'department';
  }

  Future<void> _openBrandingCustomizerDialog() async {
    final l10n = AppLocalizations.of(context);
    Map<String, dynamic> customization;
    try {
      customization =
          ref.read(adminCustomizationProvider).asData?.value ??
          await ref.read(adminCustomizationProvider.future);
    } on DioException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
      }
      return;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }

    if (!mounted) return;

    var published = _brandingStateMap(customization['published']);
    var draft = _brandingStateMap(customization['draft']);
    var history = _brandingHistoryRows(customization['history']);
    var hasUnpublishedChanges =
        customization['has_unpublished_changes'] == true;

    final companyCtrl = TextEditingController();
    final applicationTitleCtrl = TextEditingController();
    final applicationShortNameCtrl = TextEditingController();
    final webDescriptionCtrl = TextEditingController();
    final appleWebAppTitleCtrl = TextEditingController();
    final lightSeedCtrl = TextEditingController();
    final darkAccentCtrl = TextEditingController();
    final darkBgCtrl = TextEditingController();
    final browserThemeCtrl = TextEditingController();
    final installBackgroundCtrl = TextEditingController();

    String? lightLogoUrl;
    String? darkLogoUrl;
    String? faviconUrl;
    String? loginBackgroundUrl;

    void loadDraftIntoForm(Map<String, dynamic> source) {
      companyCtrl.text = _trimmedOrNull(source['company_name']) ?? '';
      applicationTitleCtrl.text =
          _trimmedOrNull(source['application_title']) ?? '';
      applicationShortNameCtrl.text =
          _trimmedOrNull(source['application_short_name']) ?? '';
      webDescriptionCtrl.text = _trimmedOrNull(source['web_description']) ?? '';
      appleWebAppTitleCtrl.text =
          _trimmedOrNull(source['apple_web_app_title']) ?? '';
      lightSeedCtrl.text = _trimmedOrNull(source['light_seed_hex']) ?? '';
      darkAccentCtrl.text = _trimmedOrNull(source['dark_accent_hex']) ?? '';
      darkBgCtrl.text = _trimmedOrNull(source['dark_bg_hex']) ?? '';
      browserThemeCtrl.text = _trimmedOrNull(source['browser_theme_hex']) ?? '';
      installBackgroundCtrl.text =
          _trimmedOrNull(source['install_background_hex']) ?? '';
      lightLogoUrl = _trimmedOrNull(source['light_logo_url']);
      darkLogoUrl = _trimmedOrNull(source['dark_logo_url']);
      faviconUrl = _trimmedOrNull(source['favicon_url']);
      loginBackgroundUrl = _trimmedOrNull(source['login_background_url']);
    }

    loadDraftIntoForm(draft);

    Map<String, dynamic> currentDraftPayload() {
      return _buildBrandingPayload(
        companyName: companyCtrl.text,
        applicationTitle: applicationTitleCtrl.text,
        applicationShortName: applicationShortNameCtrl.text,
        webDescription: webDescriptionCtrl.text,
        appleWebAppTitle: appleWebAppTitleCtrl.text,
        lightLogoUrl: lightLogoUrl,
        darkLogoUrl: darkLogoUrl,
        faviconUrl: faviconUrl,
        loginBackgroundUrl: loginBackgroundUrl,
        lightSeedHex: lightSeedCtrl.text,
        darkAccentHex: darkAccentCtrl.text,
        darkBgHex: darkBgCtrl.text,
        browserThemeHex: browserThemeCtrl.text,
        installBackgroundHex: installBackgroundCtrl.text,
      );
    }

    void applyServerState(Map<String, dynamic> state) {
      published = _brandingStateMap(state['published']);
      draft = _brandingStateMap(state['draft']);
      history = _brandingHistoryRows(state['history']);
      hasUnpublishedChanges = state['has_unpublished_changes'] == true;
      loadDraftIntoForm(draft);
    }

    bool busy = false;
    bool shouldRefresh = false;
    final messenger = ScaffoldMessenger.maybeOf(context);

    final didMutate = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('branding_theme'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> saveDraft() async {
            if (busy) return;
            setDialogState(() => busy = true);
            final api = ref.read(apiClientProvider);
            try {
              final response = await api.dio.put(
                '/admin/customization',
                data: currentDraftPayload(),
              );
              if (!dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                applyServerState(
                  (response.data as Map).cast<String, dynamic>(),
                );
                shouldRefresh = true;
              });
              messenger?.showSnackBar(
                SnackBar(content: Text(l10n.text('branding_draft_saved'))),
              );
            } on DioException catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(_dioMessage(error))),
              );
            } catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(error.toString())),
              );
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => busy = false);
              }
            }
          }

          Future<void> discardDraft() async {
            final hasLocalEdits = !_brandingPayloadMatchesSource(
              currentDraftPayload(),
              draft,
            );
            if (busy || (!hasLocalEdits && !hasUnpublishedChanges)) {
              return;
            }
            final confirmed = await _confirmBrandingAction(
              title: l10n.text('discard_draft'),
              message: l10n.text('branding_discard_draft_help'),
              confirmLabel: l10n.text('discard_draft'),
            );
            if (confirmed != true || !dialogContext.mounted) {
              return;
            }
            setDialogState(() => busy = true);
            final api = ref.read(apiClientProvider);
            try {
              final response = await api.dio.post(
                '/admin/customization/discard-draft',
              );
              if (!dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                applyServerState(
                  (response.data as Map).cast<String, dynamic>(),
                );
                shouldRefresh = true;
              });
              messenger?.showSnackBar(
                SnackBar(
                  content: Text(l10n.text('branding_draft_reset_to_published')),
                ),
              );
            } on DioException catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(_dioMessage(error))),
              );
            } catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(error.toString())),
              );
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => busy = false);
              }
            }
          }

          Future<void> publishDraft() async {
            final hasLocalEdits = !_brandingPayloadMatchesSource(
              currentDraftPayload(),
              draft,
            );
            if (busy || (!hasLocalEdits && !hasUnpublishedChanges)) {
              return;
            }
            final confirmed = await _confirmBrandingAction(
              title: l10n.text('publish_branding'),
              message: l10n.text('branding_publish_help'),
              confirmLabel: l10n.text('publish_live'),
            );
            if (confirmed != true || !dialogContext.mounted) {
              return;
            }
            setDialogState(() => busy = true);
            final api = ref.read(apiClientProvider);
            try {
              await api.dio.put(
                '/admin/customization',
                data: currentDraftPayload(),
              );
              final response = await _runWithMfaRetry<Response<dynamic>>(
                (api) => api.dio.post('/admin/customization/publish'),
              );
              if (!dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                applyServerState(
                  (response.data as Map).cast<String, dynamic>(),
                );
                shouldRefresh = true;
              });
              messenger?.showSnackBar(
                SnackBar(content: Text(l10n.text('branding_published'))),
              );
            } on DioException catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(_dioMessage(error))),
              );
            } catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(error.toString())),
              );
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => busy = false);
              }
            }
          }

          Future<void> rollbackRevision(Map<String, dynamic> entry) async {
            if (busy) return;
            final revisionId = _trimmedOrNull(entry['id']);
            final revisionNumber = (entry['revision_number'] ?? '').toString();
            if (revisionId == null) {
              return;
            }
            final confirmed = await _confirmBrandingAction(
              title: l10n.text('rollback_branding'),
              message: l10n.textWith('branding_rollback_help', {
                'revisionNumber': revisionNumber,
              }),
              confirmLabel: l10n.text('rollback'),
            );
            if (confirmed != true || !dialogContext.mounted) {
              return;
            }
            setDialogState(() => busy = true);
            try {
              final response = await _runWithMfaRetry<Response<dynamic>>(
                (api) =>
                    api.dio.post('/admin/customization/rollback/$revisionId'),
              );
              if (!dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                applyServerState(
                  (response.data as Map).cast<String, dynamic>(),
                );
                shouldRefresh = true;
              });
              messenger?.showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.textWith('branding_rolled_back_to_revision', {
                      'revisionNumber': revisionNumber,
                    }),
                  ),
                ),
              );
            } on DioException catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(_dioMessage(error))),
              );
            } catch (error) {
              if (!mounted) return;
              messenger?.showSnackBar(
                SnackBar(content: Text(error.toString())),
              );
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => busy = false);
              }
            }
          }

          Future<void> closeDialog() async {
            final hasLocalEdits = !_brandingPayloadMatchesSource(
              currentDraftPayload(),
              draft,
            );
            if (hasLocalEdits) {
              final confirmed = await _confirmBrandingAction(
                title: l10n.text('discard_unsaved_changes'),
                message: l10n.text('branding_close_discard_unsaved_help'),
                confirmLabel: l10n.text('discard'),
              );
              if (confirmed != true || !dialogContext.mounted) {
                return;
              }
            }
            Navigator.pop(dialogContext, shouldRefresh);
          }

          final currentDraft = _resolvedBrandingPreview(currentDraftPayload());
          final hasLocalEdits = !_brandingPayloadMatchesSource(
            currentDraftPayload(),
            draft,
          );
          final canSaveDraft = !busy && hasLocalEdits;
          final canPublish = !busy && (hasLocalEdits || hasUnpublishedChanges);
          final canDiscard = !busy && (hasLocalEdits || hasUnpublishedChanges);

          return AlertDialog(
            title: Text(l10n.text('branding_theme')),
            content: SizedBox(
              width: 840,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      l10n.text('company_identity'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: companyCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('company_name'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: applicationTitleCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('application_title'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: applicationShortNameCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('application_short_name'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: appleWebAppTitleCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('apple_web_app_title'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: webDescriptionCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      minLines: 3,
                      maxLines: 5,
                      decoration: InputDecoration(
                        labelText: l10n.text('web_description'),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      l10n.text('browser_and_install_colors'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: lightSeedCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('light_seed_color'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: browserThemeCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('browser_theme_color'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _brandingAssetEditor(
                      label: l10n.text('light_logo'),
                      uploadTitle: l10n.text('upload_light_logo'),
                      usage: 'branding_logo_light',
                      url: lightLogoUrl,
                      onUrlChanged: (value) =>
                          setDialogState(() => lightLogoUrl = value),
                      emptyLabel: l10n.text('used_for_main_shell_logo'),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      l10n.text('dark_mode_and_install_surface'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: darkAccentCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('dark_accent_color'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: darkBgCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('dark_bg_color'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: installBackgroundCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: l10n.text('install_background_color'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _brandingAssetEditor(
                      label: l10n.text('dark_logo'),
                      uploadTitle: l10n.text('upload_dark_logo'),
                      usage: 'branding_logo_dark',
                      url: darkLogoUrl,
                      onUrlChanged: (value) =>
                          setDialogState(() => darkLogoUrl = value),
                      emptyLabel: l10n.text('used_for_collapsed_sidebars'),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      l10n.text('media_manager'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _brandingAssetEditor(
                      label: l10n.text('favicon_label'),
                      uploadTitle: l10n.text('upload_favicon'),
                      usage: 'branding_favicon',
                      url: faviconUrl,
                      onUrlChanged: (value) =>
                          setDialogState(() => faviconUrl = value),
                      emptyLabel: l10n.text('used_for_browser_tab_icon'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _brandingAssetEditor(
                      label: l10n.text('login_background'),
                      uploadTitle: l10n.text('upload_login_background'),
                      usage: 'branding_login_bg',
                      url: loginBackgroundUrl,
                      onUrlChanged: (value) =>
                          setDialogState(() => loginBackgroundUrl = value),
                      emptyLabel: l10n.text('shown_behind_login_card'),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      l10n.text('preview'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      hasUnpublishedChanges
                          ? l10n.text('branding_draft_waiting_to_publish')
                          : l10n.text('branding_no_saved_draft_waiting'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cardWidth = constraints.maxWidth > 760
                            ? (constraints.maxWidth - AppSpacing.md) / 2
                            : constraints.maxWidth;
                        return Wrap(
                          spacing: AppSpacing.md,
                          runSpacing: AppSpacing.md,
                          children: <Widget>[
                            SizedBox(
                              width: cardWidth,
                              child: _brandingPreviewCard(
                                title: l10n.text('published_live'),
                                snapshot: published,
                                emphasized: false,
                              ),
                            ),
                            SizedBox(
                              width: cardWidth,
                              child: _brandingPreviewCard(
                                title: hasLocalEdits
                                    ? l10n.text('current_editor_preview')
                                    : l10n.text('saved_draft_preview'),
                                snapshot: currentDraft,
                                emphasized: true,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            l10n.text('version_history'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Text(
                          l10n.textWith('revisions_count', {
                            'count': history.length,
                          }),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (history.isEmpty)
                      Text(
                        l10n.text('branding_history_after_first_publish'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Column(
                        children: <Widget>[
                          for (final entry in history.take(8)) ...<Widget>[
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              Text(
                                                _brandingHistoryTitle(entry),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                _brandingHistorySubtitle(entry),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        OutlinedButton.icon(
                                          onPressed: busy
                                              ? null
                                              : () => rollbackRevision(entry),
                                          icon: const Icon(Icons.history),
                                          label: Text(l10n.text('rollback')),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: AppSpacing.sm),
                                    Text(
                                      _trimmedOrNull(
                                            _brandingStateMap(
                                              entry['snapshot'],
                                            )['resolved_app_title'],
                                          ) ??
                                          'OpsAtlas',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _localizedBrandingDescription(
                                        _brandingStateMap(entry['snapshot']),
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: busy ? null : closeDialog,
                child: Text(l10n.text('cancel')),
              ),
              OutlinedButton.icon(
                onPressed: canDiscard ? discardDraft : null,
                icon: const Icon(Icons.restore_outlined),
                label: Text(l10n.text('discard_draft')),
              ),
              FilledButton.tonalIcon(
                onPressed: canSaveDraft ? saveDraft : null,
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  busy ? l10n.text('saving') : l10n.text('save_draft'),
                ),
              ),
              FilledButton.icon(
                onPressed: canPublish ? publishDraft : null,
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.publish_outlined),
                label: Text(
                  busy ? l10n.text('saving') : l10n.text('publish_live'),
                ),
              ),
            ],
          );
        },
      ),
    );

    companyCtrl.dispose();
    applicationTitleCtrl.dispose();
    applicationShortNameCtrl.dispose();
    webDescriptionCtrl.dispose();
    appleWebAppTitleCtrl.dispose();
    lightSeedCtrl.dispose();
    darkAccentCtrl.dispose();
    darkBgCtrl.dispose();
    browserThemeCtrl.dispose();
    installBackgroundCtrl.dispose();

    if (didMutate == true && mounted) {
      _refreshAll();
    }
  }

  Future<bool?> _confirmBrandingAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showAppDialog<bool>(
      context: context,
      announcement: title,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _brandingStateMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _brandingHistoryRows(Object? value) {
    if (value is! List) {
      return const <Map<String, dynamic>>[];
    }
    return value
        .whereType<Map>()
        .map((entry) => entry.cast<String, dynamic>())
        .toList(growable: false);
  }

  Map<String, dynamic> _buildBrandingPayload({
    required String companyName,
    required String applicationTitle,
    required String applicationShortName,
    required String webDescription,
    required String appleWebAppTitle,
    required String? lightLogoUrl,
    required String? darkLogoUrl,
    required String? faviconUrl,
    required String? loginBackgroundUrl,
    required String lightSeedHex,
    required String darkAccentHex,
    required String darkBgHex,
    required String browserThemeHex,
    required String installBackgroundHex,
  }) {
    return <String, dynamic>{
      'company_name': _trimmedOrNull(companyName),
      'application_title': _trimmedOrNull(applicationTitle),
      'application_short_name': _trimmedOrNull(applicationShortName),
      'web_description': _trimmedOrNull(webDescription),
      'apple_web_app_title': _trimmedOrNull(appleWebAppTitle),
      'light_logo_url': _trimmedOrNull(lightLogoUrl),
      'dark_logo_url': _trimmedOrNull(darkLogoUrl),
      'favicon_url': _trimmedOrNull(faviconUrl),
      'login_background_url': _trimmedOrNull(loginBackgroundUrl),
      'light_seed_hex': _trimmedOrNull(lightSeedHex),
      'dark_accent_hex': _trimmedOrNull(darkAccentHex),
      'dark_bg_hex': _trimmedOrNull(darkBgHex),
      'browser_theme_hex': _trimmedOrNull(browserThemeHex),
      'install_background_hex': _trimmedOrNull(installBackgroundHex),
    };
  }

  Map<String, dynamic> _resolvedBrandingPreview(Map<String, dynamic> snapshot) {
    final l10n = AppLocalizations.of(context);
    final companyName = _trimmedOrNull(snapshot['company_name']);
    final applicationTitle = _trimmedOrNull(snapshot['application_title']);
    final applicationShortName = _trimmedOrNull(
      snapshot['application_short_name'],
    );
    final webDescription = _trimmedOrNull(snapshot['web_description']);
    final appleWebAppTitle = _trimmedOrNull(snapshot['apple_web_app_title']);
    final lightSeedHex = _trimmedOrNull(snapshot['light_seed_hex']);
    final darkBgHex = _trimmedOrNull(snapshot['dark_bg_hex']);
    final browserThemeHex = _trimmedOrNull(snapshot['browser_theme_hex']);
    final installBackgroundHex = _trimmedOrNull(
      snapshot['install_background_hex'],
    );
    return <String, dynamic>{
      ...snapshot,
      'resolved_app_title': applicationTitle ?? companyName ?? 'OpsAtlas',
      'resolved_application_short_name':
          applicationShortName ?? applicationTitle ?? companyName ?? 'OpsAtlas',
      'resolved_web_description':
          webDescription ?? l10n.text('default_web_description'),
      'resolved_apple_web_app_title':
          appleWebAppTitle ??
          applicationShortName ??
          applicationTitle ??
          companyName ??
          'OpsAtlas',
      'resolved_theme_color_hex': browserThemeHex ?? lightSeedHex ?? '#0F67E8',
      'resolved_install_background_hex':
          installBackgroundHex ?? darkBgHex ?? '#0A0D12',
    };
  }

  bool _brandingPayloadMatchesSource(
    Map<String, dynamic> payload,
    Map<String, dynamic> source,
  ) {
    const keys = <String>[
      'company_name',
      'application_title',
      'application_short_name',
      'web_description',
      'apple_web_app_title',
      'light_logo_url',
      'dark_logo_url',
      'favicon_url',
      'login_background_url',
      'light_seed_hex',
      'dark_accent_hex',
      'dark_bg_hex',
      'browser_theme_hex',
      'install_background_hex',
    ];
    for (final key in keys) {
      if (_trimmedOrNull(payload[key]) != _trimmedOrNull(source[key])) {
        return false;
      }
    }
    return true;
  }

  Widget _brandingPreviewCard({
    required String title,
    required Map<String, dynamic> snapshot,
    required bool emphasized,
  }) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final cs = theme.colorScheme;
    final appTitle =
        _trimmedOrNull(snapshot['resolved_app_title']) ?? 'OpsAtlas';
    final shortName =
        _trimmedOrNull(snapshot['resolved_application_short_name']) ??
        'OpsAtlas';
    final description = _localizedBrandingDescription(snapshot);
    final appleTitle =
        _trimmedOrNull(snapshot['resolved_apple_web_app_title']) ?? 'OpsAtlas';
    final themeHex =
        _trimmedOrNull(snapshot['resolved_theme_color_hex']) ?? '#0F67E8';
    final installHex =
        _trimmedOrNull(snapshot['resolved_install_background_hex']) ??
        '#0A0D12';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasized
            ? cs.primaryContainer.withValues(alpha: 0.32)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: emphasized ? cs.primary.withValues(alpha: 0.4) : cs.outline,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _brandingPreviewField(l10n.text('application_title'), appTitle),
            _brandingPreviewField(
              l10n.text('application_short_name'),
              shortName,
            ),
            _brandingPreviewField(l10n.text('apple_web_app_title'), appleTitle),
            _brandingPreviewField(
              l10n.text('description'),
              description,
              maxLines: 4,
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                _brandingColorChip(
                  label: l10n.text('browser_theme'),
                  hex: themeHex,
                ),
                _brandingColorChip(
                  label: l10n.text('install_background'),
                  hex: installHex,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                _brandingAssetChip(
                  label: l10n.text('light_logo'),
                  present: _trimmedOrNull(snapshot['light_logo_url']) != null,
                ),
                _brandingAssetChip(
                  label: l10n.text('dark_logo'),
                  present: _trimmedOrNull(snapshot['dark_logo_url']) != null,
                ),
                _brandingAssetChip(
                  label: l10n.text('favicon_label'),
                  present: _trimmedOrNull(snapshot['favicon_url']) != null,
                ),
                _brandingAssetChip(
                  label: l10n.text('login_background'),
                  present:
                      _trimmedOrNull(snapshot['login_background_url']) != null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _brandingPreviewField(String label, String value, {int maxLines = 2}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _brandingColorChip({required String label, required String hex}) {
    final l10n = AppLocalizations.of(context);
    final swatch = parseHexColor(hex) ?? Colors.transparent;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: swatch,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            l10n.textWith('branding_label_value', {
              'label': label,
              'value': hex,
            }),
          ),
        ],
      ),
    );
  }

  Widget _brandingAssetChip({required String label, required bool present}) {
    final l10n = AppLocalizations.of(context);
    return Chip(
      avatar: Icon(
        present ? Icons.check_circle_outline : Icons.remove_circle_outline,
        size: 16,
      ),
      label: Text(
        l10n.textWith(
          present
              ? 'branding_asset_status_set'
              : 'branding_asset_status_missing',
          {'label': label},
        ),
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  String _brandingHistoryTitle(Map<String, dynamic> entry) {
    final l10n = AppLocalizations.of(context);
    final revisionNumber = (entry['revision_number'] ?? '').toString();
    final sourceKindKey = switch ((_trimmedOrNull(entry['source_kind']) ??
        'publish')) {
      'rollback' => 'branding_history_source_rollback',
      'seed' => 'branding_history_source_seed',
      _ => 'branding_history_source_publish',
    };
    return l10n.textWith('branding_revision_title', {
      'revisionNumber': revisionNumber,
      'sourceKind': l10n.text(sourceKindKey),
    });
  }

  String _brandingHistorySubtitle(Map<String, dynamic> entry) {
    final actor = _trimmedOrNull(entry['published_by_name']) ?? 'System';
    final timestamp = _formatBrandingTimestamp(entry['published_at']);
    if (timestamp == null) {
      return actor;
    }
    return '$actor • $timestamp';
  }

  String _localizedBrandingDescription(Map<String, dynamic> snapshot) {
    final l10n = AppLocalizations.of(context);
    final rawDescription = _trimmedOrNull(snapshot['resolved_web_description']);
    if (rawDescription == null) {
      return l10n.text('no_description');
    }
    if (rawDescription == defaultBrandingWebDescription) {
      return l10n.text('default_web_description');
    }
    return rawDescription;
  }

  String? _formatBrandingTimestamp(Object? value) {
    final raw = _trimmedOrNull(value);
    if (raw == null) {
      return null;
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return raw;
    }
    final local = parsed.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatMediumDate(local);
    final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    return '$date $time';
  }

  Future<void> _call(
    Future<void> Function(ApiClient api) action, {
    required String successMessage,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _runWithMfaRetry<void>(action);
      _refreshAll();
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text(successMessage)));
    } on DioException catch (error) {
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
    } catch (error) {
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<T> _runWithMfaRetry<T>(
    Future<T> Function(ApiClient api) action,
  ) async {
    return runWithMfaRetry<T>(
      context,
      ref,
      action,
      title: AppLocalizations.of(context).text('mfa_verification_required'),
      message: AppLocalizations.of(
        context,
      ).text('mfa_verify_to_continue_admin_action'),
      onChallenge: (error) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          SnackBar(content: Text(mfaChallengeMessage(error, context))),
        );
      },
    );
  }

  Future<void> _openSpaceEditor({
    Map<String, dynamic>? existing,
    required _TreeData data,
  }) async {
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final slugCtrl = TextEditingController(
      text: (existing?['slug'] ?? '').toString(),
    );
    final regionCtrl = TextEditingController(
      text: (existing?['region_code'] ?? '').toString(),
    );
    final ownerOptions = data.users.toList()
      ..sort((a, b) {
        final left = (a['name'] ?? a['email'] ?? '').toString().toLowerCase();
        final right = (b['name'] ?? b['email'] ?? '').toString().toLowerCase();
        return left.compareTo(right);
      });
    final me = ref.read(adminOrgMeProvider).asData?.value;
    final currentAdminId = _trimmedOrNull(me?['id']);
    final currentAdminLabel =
        _trimmedOrNull(me?['name']) ??
        _trimmedOrNull(me?['email']) ??
        l10n.text('admin');
    String? selectedOwnerUserId =
        _trimmedOrNull(existing?['owner_user_id']) ?? currentAdminId;
    if (selectedOwnerUserId != null &&
        !ownerOptions.any(
          (user) => (user['id'] ?? '').toString().trim() == selectedOwnerUserId,
        )) {
      selectedOwnerUserId = null;
    }
    final metaDrafts = _metaDraftsFromValue(existing?['meta']);

    final shouldSave = await showAppDialog<bool>(
      context: context,
      announcement: existing == null
          ? l10n.text('create_space')
          : l10n.text('edit'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? l10n.text('create_space') : l10n.text('edit'),
          ),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(labelText: l10n.text('name')),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: slugCtrl,
                    decoration: InputDecoration(labelText: l10n.text('slug')),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: regionCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.text('unit_type_region'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedOwnerUserId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('owner_prefix'),
                    ),
                    items: <DropdownMenuItem<String?>>[
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(l10n.text('none')),
                      ),
                      for (final user in ownerOptions)
                        DropdownMenuItem<String?>(
                          value: (user['id'] ?? '').toString().trim(),
                          child: Text(
                            (user['name'] ?? user['email'] ?? '').toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      selectedOwnerUserId = value;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: currentAdminId == null
                          ? null
                          : () => setDialogState(() {
                              selectedOwnerUserId = currentAdminId;
                            }),
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: Text(
                        '${l10n.text('use_current_admin')}: $currentAdminLabel',
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _buildMetaEditor(
                    l10n: l10n,
                    kind: _ItemKind.space,
                    drafts: metaDrafts,
                    setDialogState: setDialogState,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        slugCtrl.text = _slugify(nameCtrl.text);
                        setDialogState(() {});
                      },
                      icon: const Icon(Icons.auto_fix_high),
                      label: Text(l10n.text('generate_slug')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    if (shouldSave == true) {
      final name = nameCtrl.text.trim();
      final slug = slugCtrl.text.trim().isEmpty
          ? _slugify(name)
          : slugCtrl.text.trim();
      Map<String, dynamic>? meta;
      try {
        meta = _metaFromDrafts(metaDrafts);
      } on _MetaDraftException catch (error) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(l10n.text(error.messageKey))));
        }
        nameCtrl.dispose();
        slugCtrl.dispose();
        regionCtrl.dispose();
        return;
      }
      if (name.isEmpty || slug.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(l10n.text('name_and_slug_required'))),
          );
        }
      } else if (existing == null) {
        await _call(
          (api) => api.dio.post(
            '/admin/spaces',
            data: {
              'name': name,
              'slug': slug,
              'owner_user_id': selectedOwnerUserId,
              'region_code': regionCtrl.text.trim().isEmpty
                  ? null
                  : regionCtrl.text.trim(),
              'meta': meta,
            },
          ),
          successMessage: l10n.text('space_created'),
        );
      } else {
        await _call(
          (api) => api.dio.put(
            '/admin/spaces/${existing['id']}',
            data: {
              'name': name,
              'slug': slug,
              'owner_user_id': selectedOwnerUserId,
              'region_code': regionCtrl.text.trim().isEmpty
                  ? null
                  : regionCtrl.text.trim(),
              'meta': meta,
            },
          ),
          successMessage: l10n.text('save_changes'),
        );
      }
    }

    nameCtrl.dispose();
    slugCtrl.dispose();
    regionCtrl.dispose();
  }

  Future<void> _deleteSpace(Map<String, dynamic> space) async {
    final l10n = AppLocalizations.of(context);
    final approved = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('delete'),
      builder: (context) => AlertDialog(
        title: Text(l10n.text('delete')),
        content: SelectableText(
          '${l10n.text('space')}: ${(space['name'] ?? '').toString()} (${(space['slug'] ?? '').toString()})',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.text('delete')),
          ),
        ],
      ),
    );
    if (approved != true) return;

    final deletedId = (space['id'] ?? '').toString();
    await _call(
      (api) => api.dio.delete('/admin/spaces/$deletedId'),
      successMessage: l10n.text('save_changes'),
    );
  }

  Future<void> _openUnitEditor({
    Map<String, dynamic>? existing,
    String? initialParentId,
    _TreeData? data,
  }) async {
    final l10n = AppLocalizations.of(context);
    final editorData =
        data ??
        _buildTreeData(
          items:
              ref.read(adminOrganizationItemsProvider).asData?.value ??
              const <Map<String, dynamic>>[],
          itemLinks:
              ref.read(adminOrganizationItemLinksProvider).asData?.value ??
              const <Map<String, dynamic>>[],
        );
    final units = editorData.units;

    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final slugCtrl = TextEditingController(
      text: (existing?['slug'] ?? '').toString(),
    );
    final metaDrafts = _metaDraftsFromValue(existing?['meta']);
    final languageChoices = await _loadLocalizationLanguageChoices();
    if (!mounted) {
      nameCtrl.dispose();
      slugCtrl.dispose();
      return;
    }

    var unitType = _normalizeEditableUnitType(
      (existing?['unit_type'] ?? 'department').toString(),
    );
    String? selectedRegionDefaultLanguage = _regionDefaultLanguageCodeFromMeta(
      existing,
    );
    if (selectedRegionDefaultLanguage != null &&
        !languageChoices.any(
          (option) => option.code == selectedRegionDefaultLanguage,
        )) {
      selectedRegionDefaultLanguage = null;
    }
    String? parentId;
    if (existing == null) {
      parentId = initialParentId;
    } else {
      final raw = (existing['parent_id'] ?? '').toString().trim();
      parentId = raw.isEmpty ? null : raw;
    }
    var active = existing == null ? true : existing['active'] == true;

    final shouldSave = await showAppDialog<bool>(
      context: context,
      announcement: existing == null ? l10n.text('create') : l10n.text('edit'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? l10n.text('create') : l10n.text('edit_org_unit'),
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(labelText: l10n.text('name')),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: slugCtrl,
                    decoration: InputDecoration(labelText: l10n.text('slug')),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _buildMetaEditor(
                    l10n: l10n,
                    kind: _ItemKind.department,
                    drafts: metaDrafts,
                    setDialogState: setDialogState,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: unitType,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('unit_type'),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: 'region',
                        child: Text(l10n.text('unit_type_region')),
                      ),
                      DropdownMenuItem(
                        value: 'store',
                        child: Text(l10n.text('unit_type_store')),
                      ),
                      DropdownMenuItem(
                        value: 'department',
                        child: Text(l10n.text('unit_type_department')),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      unitType = value ?? unitType;
                    }),
                  ),
                  if (unitType == 'region') ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<String?>(
                      initialValue: selectedRegionDefaultLanguage,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.text('language'),
                        helperText: l10n.text('organization_default'),
                      ),
                      items: <DropdownMenuItem<String?>>[
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(l10n.text('organization_default')),
                        ),
                        for (final option in languageChoices)
                          DropdownMenuItem<String?>(
                            value: option.code,
                            child: Text('${option.name} (${option.code})'),
                          ),
                      ],
                      onChanged: (value) => setDialogState(() {
                        selectedRegionDefaultLanguage = value;
                      }),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String?>(
                    initialValue: parentId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('parent_unit'),
                    ),
                    items: <DropdownMenuItem<String?>>[
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(l10n.text('no_parent')),
                      ),
                      for (final unit in units)
                        if ((unit['id'] ?? '').toString() !=
                            (existing?['id'] ?? '').toString())
                          DropdownMenuItem<String?>(
                            value: (unit['id'] ?? '').toString(),
                            child: Text((unit['name'] ?? '').toString()),
                          ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      parentId = value;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.text('active_label')),
                    value: active,
                    onChanged: (value) => setDialogState(() {
                      active = value;
                    }),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    if (shouldSave == true) {
      Map<String, dynamic>? meta;
      try {
        meta = _metaFromDrafts(metaDrafts);
      } on _MetaDraftException catch (error) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(l10n.text(error.messageKey))));
        }
        nameCtrl.dispose();
        slugCtrl.dispose();
        return;
      }
      final normalizedRegionLanguage = _normalizeLanguageCode(
        selectedRegionDefaultLanguage,
      );
      if (unitType == 'region') {
        final nextMeta = <String, dynamic>{
          ...(meta ?? const <String, dynamic>{}),
        };
        if (normalizedRegionLanguage == null) {
          nextMeta.remove('default_language_code');
        } else {
          nextMeta['default_language_code'] = normalizedRegionLanguage;
        }
        meta = nextMeta.isEmpty ? null : nextMeta;
      } else if (meta != null && meta.containsKey('default_language_code')) {
        final nextMeta = <String, dynamic>{...meta};
        nextMeta.remove('default_language_code');
        meta = nextMeta.isEmpty ? null : nextMeta;
      }
      final payload = <String, dynamic>{
        'name': nameCtrl.text.trim(),
        'slug': slugCtrl.text.trim().isEmpty
            ? _slugify(nameCtrl.text)
            : slugCtrl.text.trim(),
        'unit_type': _normalizeEditableUnitType(unitType),
        'parent_id': parentId,
        'active': active,
        'meta': meta,
      };
      if (existing == null) {
        await _call(
          (api) => api.dio.post('/admin/org/units', data: payload),
          successMessage: l10n.text('save_changes'),
        );
      } else {
        await _call(
          (api) =>
              api.dio.put('/admin/org/units/${existing['id']}', data: payload),
          successMessage: l10n.text('save_changes'),
        );
      }
    }

    nameCtrl.dispose();
    slugCtrl.dispose();
  }

  Future<void> _deleteUnit(Map<String, dynamic> unit) async {
    final l10n = AppLocalizations.of(context);
    final approved = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('delete'),
      builder: (context) => AlertDialog(
        title: Text(l10n.text('delete')),
        content: SelectableText(
          '${l10n.text('parent_unit')}: ${(unit['name'] ?? '').toString()} (${(unit['slug'] ?? '').toString()})',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.text('delete')),
          ),
        ],
      ),
    );
    if (approved != true) return;

    final deletedId = (unit['id'] ?? '').toString();
    await _call(
      (api) => api.dio.delete('/admin/org/units/$deletedId'),
      successMessage: l10n.text('save_changes'),
    );
  }

  bool _isItemLinkRow(
    Map<String, dynamic> row, {
    required String parentKind,
    required String parentId,
    required String childKind,
    required String childId,
  }) {
    final rowParentKind = (row['parent_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final rowChildKind = (row['child_kind'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (rowParentKind != parentKind || rowChildKind != childKind) return false;
    if (row['active'] == false) return false;
    final rowParentId = (row['parent_id'] ?? '').toString().trim();
    final rowChildId = (row['child_id'] ?? '').toString().trim();
    return rowParentId == parentId && rowChildId == childId;
  }

  Future<void> _ensureItemLink({
    required String parentKind,
    required String parentId,
    required String childKind,
    required String childId,
    required List<Map<String, dynamic>> links,
    String grantRole = 'member',
    bool inheritToDescendants = true,
  }) async {
    final exists = links.any(
      (row) => _isItemLinkRow(
        row,
        parentKind: parentKind,
        parentId: parentId,
        childKind: childKind,
        childId: childId,
      ),
    );
    if (exists) return;

    final l10n = AppLocalizations.of(context);
    await _call(
      (api) => api.dio.post(
        '/admin/org/item-links',
        data: {
          'parent_kind': parentKind,
          'parent_id': parentId,
          'child_kind': childKind,
          'child_id': childId,
          'grant_role': grantRole,
          'inherit_to_descendants': inheritToDescendants,
          'active': true,
        },
      ),
      successMessage: l10n.text('save_changes'),
    );
  }

  Future<void> _unlinkItemLink({
    required String parentKind,
    required String parentId,
    required String childKind,
    required String childId,
    required List<Map<String, dynamic>> links,
  }) async {
    final matchingLinks = links
        .where(
          (row) => _isItemLinkRow(
            row,
            parentKind: parentKind,
            parentId: parentId,
            childKind: childKind,
            childId: childId,
          ),
        )
        .toList();
    if (matchingLinks.isEmpty) return;

    final l10n = AppLocalizations.of(context);
    await _call((api) async {
      for (final link in matchingLinks) {
        final linkId = (link['id'] ?? '').toString();
        if (linkId.isEmpty) continue;
        await api.dio.delete('/admin/org/item-links/$linkId');
      }
    }, successMessage: l10n.text('save_changes'));
  }

  Future<void> _ensureSpaceUnitLink({
    required String spaceId,
    required String unitId,
    required List<Map<String, dynamic>> links,
  }) async {
    await _ensureItemLink(
      parentKind: 'department',
      parentId: unitId,
      childKind: 'space',
      childId: spaceId,
      links: links,
      grantRole: 'member',
      inheritToDescendants: true,
    );
  }

  Future<void> _unlinkSpaceFromUnit({
    required String spaceId,
    required String unitId,
    required List<Map<String, dynamic>> links,
  }) async {
    await _unlinkItemLink(
      parentKind: 'department',
      parentId: unitId,
      childKind: 'space',
      childId: spaceId,
      links: links,
    );
  }

  Map<String, dynamic> _userMetaObject(Map<String, dynamic> user) {
    final raw = user['meta'];
    if (raw is Map) {
      return raw.cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  String? _linkedRoleKeyForUser(
    String userId,
    _TreeData data, {
    bool includeBuiltIn = true,
  }) {
    final roleKeys = data.roleKeysByUser[userId] ?? const <String>{};
    if (roleKeys.isEmpty) return null;
    final custom =
        roleKeys
            .where((key) => !_TreeData.builtInRoleKeys.contains(key))
            .toList()
          ..sort();
    if (custom.isNotEmpty) return custom.first;
    if (!includeBuiltIn) return null;
    final builtIn =
        roleKeys
            .where((key) => _TreeData.builtInRoleKeys.contains(key))
            .toList()
          ..sort();
    return builtIn.isEmpty ? null : builtIn.first;
  }

  String? _userCustomRoleKey(Map<String, dynamic> user, {_TreeData? data}) {
    final userId = (user['id'] ?? '').toString().trim();
    if (data != null && userId.isNotEmpty) {
      final linked = _linkedRoleKeyForUser(userId, data, includeBuiltIn: false);
      if (linked != null) return linked;
    }
    return null;
  }

  String _resolvedRoleKeyForUser(Map<String, dynamic> user, _TreeData data) {
    final userId = (user['id'] ?? '').toString().trim();
    if (userId.isNotEmpty) {
      final linked = _linkedRoleKeyForUser(userId, data);
      if (linked != null) return linked;
    }
    return (user['global_role'] ?? 'member').toString().trim().toLowerCase();
  }

  Future<void> _setUserRoleBinding({
    required String userId,
    required String? roleKey,
    required List<Map<String, dynamic>> links,
    required List<Map<String, dynamic>> users,
  }) async {
    final normalizedRoleKey = (roleKey ?? '').trim().toLowerCase();
    final currentBindings = links
        .where((link) {
          if (link['active'] == false) return false;
          final parentKind = (link['parent_kind'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final childKind = (link['child_kind'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final childId = (link['child_id'] ?? '').toString().trim();
          return parentKind == 'role' &&
              childKind == 'user' &&
              childId == userId;
        })
        .toList(growable: false);
    final currentBuiltInParentIds = currentBindings
        .map(
          (link) => (link['parent_id'] ?? '').toString().trim().toLowerCase(),
        )
        .where((id) => _TreeData.builtInRoleKeys.contains(id))
        .toSet();
    final currentCustomParentIds = currentBindings
        .map((link) => (link['parent_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .where((id) => !_TreeData.builtInRoleKeys.contains(id.toLowerCase()))
        .toSet();
    for (final parentId in currentCustomParentIds) {
      await _unlinkItemLink(
        parentKind: 'role',
        parentId: parentId,
        childKind: 'user',
        childId: userId,
        links: links,
      );
    }

    if (_TreeData.builtInRoleKeys.contains(normalizedRoleKey)) {
      for (final parentId in currentBuiltInParentIds) {
        if (parentId == normalizedRoleKey) continue;
        await _unlinkItemLink(
          parentKind: 'role',
          parentId: parentId,
          childKind: 'user',
          childId: userId,
          links: links,
        );
      }
    }

    if (normalizedRoleKey.isNotEmpty) {
      await _ensureItemLink(
        parentKind: 'role',
        parentId: normalizedRoleKey,
        childKind: 'user',
        childId: userId,
        links: links,
        grantRole: normalizedRoleKey,
        inheritToDescendants: false,
      );
    }

    if (_TreeData.builtInRoleKeys.contains(normalizedRoleKey)) {
      await _setUserRoleAssignment(
        userId: userId,
        users: users,
        globalRole: normalizedRoleKey,
      );
      return;
    }

    if (normalizedRoleKey.isNotEmpty) {
      await _setUserRoleAssignment(
        userId: userId,
        users: users,
        globalRole: 'member',
      );
    }
  }

  Future<void> _assignUserToUnit({
    required String userId,
    required String unitId,
    required List<Map<String, dynamic>> links,
  }) async {
    await _ensureItemLink(
      parentKind: 'department',
      parentId: unitId,
      childKind: 'user',
      childId: userId,
      links: links,
      grantRole: 'member',
      inheritToDescendants: true,
    );
  }

  Future<void> _replaceUserUnit({
    required String userId,
    required String fromUnitId,
    required String toUnitId,
    required List<Map<String, dynamic>> links,
  }) async {
    await _ensureItemLink(
      parentKind: 'department',
      parentId: toUnitId,
      childKind: 'user',
      childId: userId,
      links: links,
      grantRole: 'member',
      inheritToDescendants: true,
    );
    await _unlinkItemLink(
      parentKind: 'department',
      parentId: fromUnitId,
      childKind: 'user',
      childId: userId,
      links: links,
    );
  }

  Future<void> _removeUserFromUnit({
    required String userId,
    required String unitId,
    required List<Map<String, dynamic>> links,
  }) async {
    await _unlinkItemLink(
      parentKind: 'department',
      parentId: unitId,
      childKind: 'user',
      childId: userId,
      links: links,
    );
  }

  Future<void> _replaceUserManager({
    required String reportUserId,
    required String fromManagerUserId,
    required String toManagerUserId,
    required List<Map<String, dynamic>> links,
  }) async {
    if (reportUserId == toManagerUserId) return;
    await _ensureItemLink(
      parentKind: 'user',
      parentId: toManagerUserId,
      childKind: 'user',
      childId: reportUserId,
      links: links,
      grantRole: 'member',
      inheritToDescendants: true,
    );
    await _unlinkItemLink(
      parentKind: 'user',
      parentId: fromManagerUserId,
      childKind: 'user',
      childId: reportUserId,
      links: links,
    );
  }

  Future<void> _setUserRoleAssignment({
    required String userId,
    required List<Map<String, dynamic>> users,
    String? globalRole,
  }) async {
    final user = users.firstWhere(
      (row) => (row['id'] ?? '').toString() == userId,
      orElse: () => const <String, dynamic>{},
    );
    if (user.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final nextGlobalRole = (globalRole ?? user['global_role'] ?? 'member')
        .toString()
        .trim()
        .toLowerCase();
    await _call(
      (api) => api.dio.put(
        '/admin/users/$userId',
        data: {
          'name': (user['name'] ?? '').toString(),
          'email': (user['email'] ?? '').toString(),
          'global_role': nextGlobalRole,
          'meta': _userMetaObject(user),
        },
      ),
      successMessage: l10n.text('save_changes'),
    );
  }

  Future<void> _openRoleEditor({Map<String, dynamic>? existing}) async {
    final l10n = AppLocalizations.of(context);
    final keyCtrl = TextEditingController(
      text: (existing?['role_key'] ?? '').toString(),
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final descCtrl = TextEditingController(
      text: (existing?['description'] ?? '').toString(),
    );
    final metaDrafts = _metaDraftsFromValue(existing?['meta']);
    final levels = <String>['viewer', 'member', 'moderator', 'admin'];
    var effectiveLevel = (existing?['effective_level'] ?? 'member').toString();
    if (!levels.contains(effectiveLevel)) effectiveLevel = 'member';
    var active = (existing?['active'] ?? true) == true;

    final shouldSave = await showAppDialog<bool>(
      context: context,
      announcement: existing == null
          ? l10n.text('create_role_template')
          : l10n.text('edit'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null
                ? l10n.text('create_role_template')
                : '${l10n.text('edit')} • ${(existing['role_key'] ?? '').toString()}',
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: keyCtrl,
                    enabled: existing == null,
                    decoration: InputDecoration(
                      labelText: l10n.text('role_key_example'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.text('display_name'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: descCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: l10n.text('description_acceptance'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _buildMetaEditor(
                    l10n: l10n,
                    kind: _ItemKind.role,
                    drafts: metaDrafts,
                    setDialogState: setDialogState,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: effectiveLevel,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('effective_permission_level'),
                    ),
                    items: [
                      for (final level in levels)
                        DropdownMenuItem<String>(
                          value: level,
                          child: Text(level),
                        ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      effectiveLevel = value ?? effectiveLevel;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.text('active_label')),
                    value: active,
                    onChanged: (value) => setDialogState(() {
                      active = value;
                    }),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    if (shouldSave == true) {
      Map<String, dynamic>? meta;
      try {
        meta = _metaFromDrafts(metaDrafts);
      } on _MetaDraftException catch (error) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(l10n.text(error.messageKey))));
        }
        keyCtrl.dispose();
        nameCtrl.dispose();
        descCtrl.dispose();
        return;
      }
      if (existing == null) {
        await _call(
          (api) => api.dio.post(
            '/admin/custom-roles',
            data: {
              'role_key': keyCtrl.text.trim(),
              'name': nameCtrl.text.trim(),
              'description': descCtrl.text.trim().isEmpty
                  ? null
                  : descCtrl.text.trim(),
              'effective_level': effectiveLevel,
              'active': active,
              'meta': meta,
            },
          ),
          successMessage: l10n.text('role_template_created'),
        );
      } else {
        final roleKey = (existing['role_key'] ?? '').toString();
        await _call(
          (api) => api.dio.put(
            '/admin/custom-roles/$roleKey',
            data: {
              'name': nameCtrl.text.trim(),
              'description': descCtrl.text.trim().isEmpty
                  ? null
                  : descCtrl.text.trim(),
              'effective_level': effectiveLevel,
              'active': active,
              'meta': meta,
            },
          ),
          successMessage: l10n.text('save_changes'),
        );
      }
      ref.invalidate(adminOrganizationItemsProvider);
    }

    keyCtrl.dispose();
    nameCtrl.dispose();
    descCtrl.dispose();
  }

  Future<void> _deleteRole(Map<String, dynamic> role) async {
    final l10n = AppLocalizations.of(context);
    final roleKey = (role['role_key'] ?? '').toString();
    if (roleKey.isEmpty) return;

    final approved = await showAppDialog<bool>(
      context: context,
      announcement: l10n.text('delete'),
      builder: (context) => AlertDialog(
        title: Text(l10n.text('delete')),
        content: SelectableText('${l10n.text('role_templates')}: $roleKey'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.text('delete')),
          ),
        ],
      ),
    );
    if (approved != true) return;

    await _call(
      (api) => api.dio.delete('/admin/custom-roles/$roleKey'),
      successMessage: l10n.text('role_template_deleted'),
    );
    ref.invalidate(adminOrganizationItemsProvider);
  }

  Future<void> _openUserEditor({
    Map<String, dynamic>? existing,
    _TreeData? data,
  }) async {
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final emailCtrl = TextEditingController(
      text: (existing?['email'] ?? '').toString(),
    );
    final passwordCtrl = TextEditingController();
    final metaDrafts = _metaDraftsFromValue(existing?['meta']);
    final dataForSelection =
        data ??
        _buildTreeData(
          items:
              ref.read(adminOrganizationItemsProvider).asData?.value ??
              const <Map<String, dynamic>>[],
          itemLinks:
              ref.read(adminOrganizationItemLinksProvider).asData?.value ??
              const <Map<String, dynamic>>[],
        );
    final customRoles = dataForSelection.customRoles;
    final availableRoleKeys =
        customRoles
            .where((role) => role['active'] != false)
            .map((role) => (role['role_key'] ?? '').toString())
            .where((key) => key.isNotEmpty)
            .toList()
          ..sort();

    final existingUserId = (existing?['id'] ?? '').toString();
    final languageChoices = await _loadLocalizationLanguageChoices();
    if (!mounted) {
      nameCtrl.dispose();
      emailCtrl.dispose();
      passwordCtrl.dispose();
      return;
    }
    String selectedLanguagePreference = '__org_default__';
    if (existingUserId.trim().isNotEmpty) {
      final preference = await _loadUserLocalizationPreference(existingUserId);
      if (!mounted) {
        nameCtrl.dispose();
        emailCtrl.dispose();
        passwordCtrl.dispose();
        return;
      }
      final useOrgDefault = preference?['use_org_default'] == true;
      final preferredLanguage = _normalizeLanguageCode(
        preference?['language_code'],
      );
      if (!useOrgDefault &&
          preferredLanguage != null &&
          languageChoices.any((option) => option.code == preferredLanguage)) {
        selectedLanguagePreference = preferredLanguage;
      }
    }
    String? selectedCustomRole = existing == null
        ? null
        : _userCustomRoleKey(existing, data: dataForSelection);
    if (selectedCustomRole != null &&
        !availableRoleKeys.contains(selectedCustomRole)) {
      selectedCustomRole = null;
    }
    final existingUserIsActive = existing == null
        ? true
        : existing['is_active'] != false;
    String? quickUserAction;

    final shouldSave = await showAppDialog<bool>(
      context: context,
      announcement: existing == null ? l10n.text('create') : l10n.text('edit'),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null
                ? l10n.text('create_user')
                : '${l10n.text('edit')} • ${(existing['name'] ?? '').toString()}',
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(labelText: l10n.text('name')),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(labelText: l10n.text('email')),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedCustomRole,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('custom_role_template'),
                    ),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(l10n.text('none')),
                      ),
                      for (final roleKey in availableRoleKeys)
                        DropdownMenuItem<String?>(
                          value: roleKey,
                          child: Text(
                            (customRoles.firstWhere(
                                      (r) =>
                                          (r['role_key'] ?? '').toString() ==
                                          roleKey,
                                      orElse: () => const <String, dynamic>{},
                                    )['name'] ??
                                    roleKey)
                                .toString(),
                          ),
                        ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      selectedCustomRole = value;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: selectedLanguagePreference,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.text('language'),
                      helperText: l10n.text('language_settings_help'),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: '__org_default__',
                        child: Text(l10n.text('organization_default')),
                      ),
                      for (final option in languageChoices)
                        DropdownMenuItem<String>(
                          value: option.code,
                          child: Text('${option.name} (${option.code})'),
                        ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      if (value == null) return;
                      selectedLanguagePreference = value;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: passwordCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: existing == null
                          ? l10n.text('password')
                          : l10n.text('password_leave_empty_to_keep'),
                    ),
                  ),
                  if (existing != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.text('profile_actions'),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: () {
                            quickUserAction = 'invite';
                            Navigator.pop(context, false);
                          },
                          icon: const Icon(Icons.mail_outline),
                          label: Text(l10n.text('invite_user')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            quickUserAction = 'reset_password';
                            Navigator.pop(context, false);
                          },
                          icon: const Icon(Icons.lock_reset_outlined),
                          label: Text(l10n.text('reset_password')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            quickUserAction = existingUserIsActive
                                ? 'deactivate'
                                : 'activate';
                            Navigator.pop(context, false);
                          },
                          icon: Icon(
                            existingUserIsActive
                                ? Icons.person_off_outlined
                                : Icons.check_circle_outline,
                          ),
                          label: Text(
                            existingUserIsActive
                                ? l10n.text('deactivate')
                                : l10n.text('activate'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  _buildMetaEditor(
                    l10n: l10n,
                    kind: _ItemKind.user,
                    drafts: metaDrafts,
                    setDialogState: setDialogState,
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.text('save')),
            ),
          ],
        ),
      ),
    );

    if (quickUserAction != null && existingUserId.trim().isNotEmpty) {
      switch (quickUserAction) {
        case 'invite':
          await _issueUserOnboardingToken(
            userId: existingUserId,
            endpoint: 'invite',
            titleKey: 'invite_user',
            successKey: 'invite_issued',
          );
          break;
        case 'reset_password':
          await _issueUserOnboardingToken(
            userId: existingUserId,
            endpoint: 'password-reset',
            titleKey: 'reset_password',
            successKey: 'password_reset_issued',
          );
          break;
        case 'deactivate':
          await _setUserActiveState(userId: existingUserId, active: false);
          break;
        case 'activate':
          await _setUserActiveState(userId: existingUserId, active: true);
          break;
      }
      nameCtrl.dispose();
      emailCtrl.dispose();
      passwordCtrl.dispose();
      return;
    }

    if (shouldSave == true) {
      Map<String, dynamic>? meta;
      try {
        meta = _metaFromDrafts(metaDrafts);
      } on _MetaDraftException catch (error) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(l10n.text(error.messageKey))));
        }
        nameCtrl.dispose();
        emailCtrl.dispose();
        passwordCtrl.dispose();
        return;
      }
      try {
        String userId = existingUserId;
        if (existing == null) {
          final response = await _runWithMfaRetry<Response<dynamic>>(
            (api) => api.dio.post(
              '/admin/users',
              data: {
                'name': nameCtrl.text.trim(),
                'email': emailCtrl.text.trim(),
                'password': passwordCtrl.text,
                'meta': meta,
              },
            ),
          );
          userId = (response.data['id'] ?? '').toString();
        } else {
          await _runWithMfaRetry<Response<dynamic>>(
            (api) => api.dio.put(
              '/admin/users/$existingUserId',
              data: {
                'name': nameCtrl.text.trim(),
                'email': emailCtrl.text.trim(),
                'password': passwordCtrl.text.trim().isEmpty
                    ? null
                    : passwordCtrl.text,
                'meta': meta,
              },
            ),
          );
        }

        if (userId.isEmpty) return;
        ref.invalidate(adminOrganizationItemsProvider);
        ref.invalidate(adminOrganizationItemLinksProvider);
        final latestLinks = await ref.read(
          adminOrganizationItemLinksProvider.future,
        );
        final latestData = _buildTreeData(
          items: await ref.read(adminOrganizationItemsProvider.future),
          itemLinks: latestLinks,
        );
        await _setUserRoleBinding(
          userId: userId,
          roleKey: selectedCustomRole,
          links: latestLinks,
          users: latestData.users,
        );
        await _saveUserLocalizationPreference(
          userId: userId,
          selection: selectedLanguagePreference,
        );
        _refreshAll();
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(l10n.text('save_changes'))));
      } on DioException catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }

    nameCtrl.dispose();
    emailCtrl.dispose();
    passwordCtrl.dispose();
  }

  Future<void> _showOnboardingTokenDialog({
    required String title,
    required String email,
    required String onboardingToken,
    required String? onboardingUrl,
    required String? expiresAt,
  }) async {
    final l10n = AppLocalizations.of(context);
    await showAppDialog<void>(
      context: context,
      announcement: title,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.text('onboarding_token_help'),
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              SelectableText('${l10n.text('email')}: $email'),
              const SizedBox(height: AppSpacing.xs),
              if (onboardingUrl != null && onboardingUrl.trim().isNotEmpty)
                SelectableText(
                  '${l10n.text('onboarding_link')}: $onboardingUrl',
                ),
              if (onboardingUrl != null && onboardingUrl.trim().isNotEmpty)
                const SizedBox(height: AppSpacing.xs),
              SelectableText(
                '${l10n.text('onboarding_token')}: $onboardingToken',
                style: Theme.of(
                  dialogContext,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.xs),
              SelectableText(
                '${l10n.text('expires_at')}: ${_localDateTimeLabel(expiresAt, l10n)}',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          if (onboardingUrl != null && onboardingUrl.trim().isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: onboardingUrl));
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                  SnackBar(content: Text(l10n.text('link_copied'))),
                );
              },
              icon: const Icon(Icons.link),
              label: Text(l10n.text('copy_link')),
            ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: onboardingToken));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                SnackBar(content: Text(l10n.text('invite_token_copied'))),
              );
            },
            icon: const Icon(Icons.key_outlined),
            label: Text(l10n.text('copy_token')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
  }

  Future<void> _issueUserOnboardingToken({
    required String userId,
    required String endpoint,
    required String titleKey,
    required String successKey,
  }) async {
    final l10n = AppLocalizations.of(context);
    try {
      final response = await _runWithMfaRetry<Response<dynamic>>(
        (api) => api.dio.post('/admin/users/$userId/$endpoint'),
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      final email = (payload['email'] ?? '').toString().trim();
      final onboardingToken = (payload['onboarding_token'] ?? '')
          .toString()
          .trim();
      final onboardingUrl = _trimmedOrNull(payload['onboarding_url']);
      final expiresAt = _trimmedOrNull(payload['expires_at']);
      if (onboardingToken.isEmpty) {
        throw StateError(l10n.text('onboarding_token_missing'));
      }
      if (!mounted) return;
      await _showOnboardingTokenDialog(
        title: l10n.text(titleKey),
        email: email,
        onboardingToken: onboardingToken,
        onboardingUrl: onboardingUrl,
        expiresAt: expiresAt,
      );
      _refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(l10n.text(successKey))));
    } on DioException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _setUserActiveState({
    required String userId,
    required bool active,
  }) async {
    final l10n = AppLocalizations.of(context);
    final approved = await showAppDialog<bool>(
      context: context,
      announcement: active ? l10n.text('activate') : l10n.text('deactivate'),
      builder: (context) => AlertDialog(
        title: Text(active ? l10n.text('activate') : l10n.text('deactivate')),
        content: Text(
          active
              ? l10n.text('activate_user_confirmation')
              : l10n.text('deactivate_user_confirmation'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              active ? l10n.text('activate') : l10n.text('deactivate'),
            ),
          ),
        ],
      ),
    );
    if (approved != true) return;
    try {
      await _call(
        (api) => api.dio.post(
          '/admin/users/$userId/${active ? 'activate' : 'deactivate'}',
        ),
        successMessage: l10n.text(
          active ? 'user_activated' : 'user_deactivated',
        ),
      );
      _refreshAll();
    } on DioException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_dioMessage(error))));
    }
  }
}
