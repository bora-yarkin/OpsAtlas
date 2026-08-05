// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Localization manager dialog for organization-managed content.

part of 'admin_organization_screen.dart';

class _LocalizationManagerDialog extends StatefulWidget {
  final ApiClient api;
  final AppLocalizations l10n;
  final VoidCallback onApplied;

  const _LocalizationManagerDialog({
    required this.api,
    required this.l10n,
    required this.onApplied,
  });

  @override
  State<_LocalizationManagerDialog> createState() =>
      _LocalizationManagerDialogState();
}

class _LocalizationManagerDialogState
    extends State<_LocalizationManagerDialog> {
  bool _loading = true;
  bool _savingDefault = false;
  bool _savingAi = false;
  bool _importing = false;
  bool _exporting = false;
  bool _processingQueue = false;
  bool _bulkRetranslating = false;
  bool _translatingMissing = false;
  String? _error;

  String _defaultLanguageCode = 'en';
  final List<_LocalizationLanguageChoice> _languages =
      <_LocalizationLanguageChoice>[];

  String _exportFormat = 'arb';
  String _importFormat = 'arb';
  String _provider = 'openai';
  bool _hasApiKey = false;
  String? _resolvedApiBaseUrl;
  Map<String, dynamic> _providerDefaults = const <String, dynamic>{};
  Map<String, dynamic> _queueStatus = const <String, dynamic>{};
  Map<String, dynamic> _health = const <String, dynamic>{};

  final TextEditingController _modelCtrl = TextEditingController(
    text: 'gpt-5-mini',
  );
  final TextEditingController _apiBaseUrlCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _promptCtrl = TextEditingController();
  final TextEditingController _glossaryCtrl = TextEditingController();
  final TextEditingController _queueAttemptsCtrl = TextEditingController(
    text: '4',
  );
  final TextEditingController _queueBackoffCtrl = TextEditingController(
    text: '30',
  );
  final TextEditingController _queueBatchCtrl = TextEditingController(
    text: '20',
  );

  bool _autoTranslateOnWrite = true;
  bool _autoApprove = false;
  bool _autoRetranslateOnBundleChange = false;
  bool _fallbackToSource = true;
  bool _translationEnabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _apiBaseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _promptCtrl.dispose();
    _glossaryCtrl.dispose();
    _queueAttemptsCtrl.dispose();
    _queueBackoffCtrl.dispose();
    _queueBatchCtrl.dispose();
    super.dispose();
  }

  static const String _defaultTranslationPrompt =
      'You are a localization engine. Translate the provided source text '
      'exactly into the target language while preserving placeholders, '
      'markdown, urls, and product names. Return only the translated text.';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final providerOptions = <String>{
      'openai',
      'gemini',
      'custom',
      ..._providerDefaults.keys.map((entry) => entry.trim().toLowerCase()),
    }.toList(growable: false);
    providerOptions.sort((a, b) {
      const preferred = <String, int>{'openai': 0, 'gemini': 1, 'custom': 2};
      final aRank = preferred[a] ?? 99;
      final bRank = preferred[b] ?? 99;
      if (aRank != bRank) return aRank.compareTo(bRank);
      return a.compareTo(b);
    });
    final selectedModel = _modelCtrl.text.trim().isEmpty
        ? _providerDefaultModel(_provider)
        : _modelCtrl.text.trim();
    final modelChoices = _providerModelChoices(_provider);
    final usageMultiplier = _modelUsageMultiplier(
      provider: _provider,
      model: selectedModel,
    );
    final defaultBaseUrl = _providerDefaultBaseUrl(_provider);
    final resolvedBaseUrl = (_resolvedApiBaseUrl ?? '').trim();
    final effectiveBaseUrl = _apiBaseUrlCtrl.text.trim().isNotEmpty
        ? _apiBaseUrlCtrl.text.trim()
        : (resolvedBaseUrl.isNotEmpty
              ? resolvedBaseUrl
              : (defaultBaseUrl ?? ''));
    final healthLanguages = (_health['languages'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((row) => row.cast<String, dynamic>())
        .toList(growable: false);
    final staleBundles =
        (_health['stale_bundle_versions'] as List? ?? const <dynamic>[])
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 640),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _defaultLanguageCode,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('global_default_language'),
                    ),
                    items: _languages
                        .map(
                          (row) => DropdownMenuItem<String>(
                            value: row.code,
                            child: Text('${row.name} (${row.code})'),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _defaultLanguageCode = value);
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _savingDefault ? null : _saveDefaultLanguage,
                  icon: _savingDefault
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(widget.l10n.text('save')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _exportFormat,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('export_format'),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: 'arb',
                        child: Text(widget.l10n.text('format_arb')),
                      ),
                      DropdownMenuItem(
                        value: 'icu',
                        child: Text(widget.l10n.text('format_icu')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _exportFormat = value);
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.tonalIcon(
                  onPressed: _exporting ? null : _exportBundles,
                  icon: _exporting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(widget.l10n.text('export_bundle')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _importFormat,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('import_format'),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: 'arb',
                        child: Text(widget.l10n.text('format_arb')),
                      ),
                      DropdownMenuItem(
                        value: 'icu',
                        child: Text(widget.l10n.text('format_icu')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _importFormat = value);
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _importing ? null : _importBundlesFromFile,
                  icon: _importing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(widget.l10n.text('import_json_file')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            _buildLocalizationHealthSection(
              context,
              healthLanguages: healthLanguages,
              staleBundles: staleBundles,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              widget.l10n.text('ai_translation'),
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.l10n.text('ai_translation_settings_help'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _provider,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('provider'),
                    ),
                    items: providerOptions
                        .map(
                          (provider) => DropdownMenuItem<String>(
                            value: provider,
                            child: Text(_providerLabel(provider)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        final previous = _provider;
                        _provider = value;
                        _applyProviderDefaults(
                          previousProvider: previous,
                          nextProvider: value,
                        );
                      });
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey<String>(
                      'translation-model:$_provider:$selectedModel',
                    ),
                    initialValue: selectedModel,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('model_label'),
                    ),
                    items: <DropdownMenuItem<String>>[
                      ...modelChoices.map(
                        (choice) => DropdownMenuItem<String>(
                          value: choice.id,
                          child: Text(
                            '${choice.label} (x${choice.usageMultiplier.toStringAsFixed(2)})',
                          ),
                        ),
                      ),
                      if (!modelChoices.any((row) => row.id == selectedModel))
                        DropdownMenuItem<String>(
                          value: selectedModel,
                          child: Text(
                            '$selectedModel (${widget.l10n.text('custom')})',
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _modelCtrl.text = value.trim());
                    },
                  ),
                ),
              ],
            ),
            if (usageMultiplier != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.l10n
                    .text('usage_multiplier')
                    .replaceAll('{value}', usageMultiplier.toStringAsFixed(2)),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _apiBaseUrlCtrl,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('api_base_url_optional'),
                      hintText: defaultBaseUrl ?? '',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _apiKeyCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _hasApiKey
                          ? widget.l10n.text('api_key_leave_empty_to_keep')
                          : widget.l10n.text('api_key'),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  onPressed: _hasApiKey ? _clearApiKey : null,
                  tooltip: widget.l10n.text('clear_api_key'),
                  icon: const Icon(Icons.key_off_outlined),
                ),
              ],
            ),
            if (effectiveBaseUrl.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.l10n
                    .text('resolved_base_url')
                    .replaceAll('{url}', effectiveBaseUrl),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _promptCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: widget.l10n.text('translation_prompt'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _glossaryCtrl,
              minLines: 3,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: widget.l10n.text('translation_glossary_help'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(widget.l10n.text('enable_ai_translation')),
                    value: _translationEnabled,
                    onChanged: (value) =>
                        setState(() => _translationEnabled = value),
                  ),
                ),
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      widget.l10n.text('auto_translate_on_create_update'),
                    ),
                    value: _autoTranslateOnWrite,
                    onChanged: (value) =>
                        setState(() => _autoTranslateOnWrite = value),
                  ),
                ),
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(widget.l10n.text('auto_approve_translations')),
                    value: _autoApprove,
                    onChanged: (value) => setState(() => _autoApprove = value),
                  ),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      widget.l10n.text('fallback_to_source_on_failure'),
                    ),
                    value: _fallbackToSource,
                    onChanged: (value) =>
                        setState(() => _fallbackToSource = value),
                  ),
                ),
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      widget.l10n.text(
                        'auto_bulk_retranslate_on_language_updates',
                      ),
                    ),
                    value: _autoRetranslateOnBundleChange,
                    onChanged: (value) =>
                        setState(() => _autoRetranslateOnBundleChange = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _queueAttemptsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('max_retries'),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _queueBackoffCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('backoff_seconds'),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _queueBatchCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: widget.l10n.text('batch_size'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _savingAi ? null : _saveAiSettings,
                  icon: _savingAi
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(widget.l10n.text('save_ai_settings')),
                ),
                FilledButton.tonalIcon(
                  onPressed: _processingQueue || !_translationEnabled
                      ? null
                      : _processQueueNow,
                  icon: _processingQueue
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_circle_outline),
                  label: Text(widget.l10n.text('process_queue')),
                ),
                FilledButton.tonalIcon(
                  onPressed: _bulkRetranslating || !_translationEnabled
                      ? null
                      : _bulkRetranslateAll,
                  icon: _bulkRetranslating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restart_alt_outlined),
                  label: Text(widget.l10n.text('bulk_retranslate')),
                ),
                FilledButton.tonalIcon(
                  onPressed: _translatingMissing || !_translationEnabled
                      ? null
                      : _translateMissingAll,
                  icon: _translatingMissing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.translate_outlined),
                  label: Text(widget.l10n.text('translate_missing')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                Chip(
                  label: Text(
                    _translationEnabled
                        ? widget.l10n.text('engine_enabled')
                        : widget.l10n.text('engine_disabled'),
                  ),
                ),
                Chip(
                  label: Text(
                    '${widget.l10n.text('queued_label')} ${_queueStatus['queued'] ?? 0}',
                  ),
                ),
                Chip(
                  label: Text(
                    '${widget.l10n.text('retry_label')} ${_queueStatus['retry'] ?? 0}',
                  ),
                ),
                Chip(
                  label: Text(
                    '${widget.l10n.text('processing_label')} ${_queueStatus['processing'] ?? 0}',
                  ),
                ),
                Chip(
                  label: Text(
                    '${widget.l10n.text('failed_label')} ${_queueStatus['failed'] ?? 0}',
                  ),
                ),
                Chip(
                  label: Text(
                    '${widget.l10n.text('due_now_label')} ${_queueStatus['due_now'] ?? 0}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalizationHealthSection(
    BuildContext context, {
    required List<Map<String, dynamic>> healthLanguages,
    required List<String> staleBundles,
  }) {
    final l10n = widget.l10n;
    final theme = Theme.of(context);
    final referenceKeyCount =
        int.tryParse((_health['reference_key_count'] ?? '').toString()) ?? 0;
    final defaultLanguage = (_health['default_language_code'] ?? '')
        .toString()
        .trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.text('localization_health'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.text('localization_health_help'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: <Widget>[
            Chip(
              label: Text('${l10n.text('reference_keys')}: $referenceKeyCount'),
            ),
            Chip(
              label: Text(
                '${l10n.text('global_default_language')}: ${defaultLanguage.isEmpty ? '-' : defaultLanguage}',
              ),
            ),
            Chip(
              label: Text(
                '${l10n.text('stale_bundles')}: ${staleBundles.length}',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (healthLanguages.isEmpty)
          Text(l10n.text('no_data'), style: theme.textTheme.bodyMedium)
        else
          Column(
            children: healthLanguages
                .map((language) {
                  final code = (language['code'] ?? '').toString().trim();
                  final enabled = language['enabled'] == true;
                  final coverage = (language['coverage_pct'] is num)
                      ? (language['coverage_pct'] as num).toDouble()
                      : double.tryParse(
                              (language['coverage_pct'] ?? '').toString(),
                            ) ??
                            0.0;
                  final missingKeyCount =
                      int.tryParse(
                        (language['missing_key_count'] ?? '').toString(),
                      ) ??
                      0;
                  final bundleVersion =
                      int.tryParse(
                        (language['bundle_version'] ?? '').toString(),
                      ) ??
                      0;
                  final sample =
                      (language['missing_keys_sample'] as List? ??
                              const <dynamic>[])
                          .map((entry) => entry.toString().trim())
                          .where((entry) => entry.isNotEmpty)
                          .take(6)
                          .toList(growable: false);
                  final stale = language['stale_bundle'] == true;

                  return Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: stale
                            ? theme.colorScheme.error.withValues(alpha: 0.35)
                            : theme.colorScheme.outlineVariant,
                      ),
                      color: theme.colorScheme.surfaceContainerLow,
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
                                  code.isEmpty ? '-' : code.toUpperCase(),
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Chip(
                                label: Text(
                                  enabled
                                      ? l10n.text('enabled')
                                      : l10n.text('disabled'),
                                ),
                              ),
                              if (stale) ...<Widget>[
                                const SizedBox(width: AppSpacing.xs),
                                Chip(
                                  backgroundColor:
                                      theme.colorScheme.errorContainer,
                                  label: Text(l10n.text('stale_bundles')),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '${l10n.text('coverage')}: ${coverage.toStringAsFixed(2)}% • '
                            '${l10n.text('missing_keys')}: $missingKeyCount • '
                            '${l10n.text('bundle_version')}: $bundleVersion',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (sample.isNotEmpty) ...<Widget>[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              '${l10n.text('missing_keys_sample')}: ${sample.join(', ')}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                })
                .toList(growable: false),
          ),
      ],
    );
  }
}
