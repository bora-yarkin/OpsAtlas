// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Action handlers for the organization localization manager dialog.

part of 'admin_organization_screen.dart';

extension _LocalizationManagerDialogStateActions
    on _LocalizationManagerDialogState {
  void _setDialogState(VoidCallback update) {
    (this as dynamic).setState(update);
  }

  String? _normalizeCode(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.trim().replaceAll('_', '-').toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> _load() async {
    _setDialogState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalogResponse = await widget.api.dio.get('/localization/catalog');
      final healthResponse = await widget.api.dio.get('/localization/health');
      final aiSettingsResponse = await widget.api.dio.get(
        '/localization/ai-settings',
      );
      final queueStatusResponse = await widget.api.dio.get(
        '/localization/translations/queue',
        queryParameters: const <String, dynamic>{'limit': 20},
      );

      final catalog = (catalogResponse.data as Map).cast<String, dynamic>();
      final rawLanguages = (catalog['languages'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList(growable: false);
      final nextLanguages = <_LocalizationLanguageChoice>[];
      for (final row in rawLanguages) {
        final code = _normalizeCode(row['code']);
        if (code == null) continue;
        if (row['enabled'] != true && row['is_default'] != true) {
          continue;
        }
        final name = (row['name'] ?? '').toString().trim();
        nextLanguages.add(
          _LocalizationLanguageChoice(
            code: code,
            name: name.isEmpty ? code.toUpperCase() : name,
          ),
        );
      }
      nextLanguages.sort(
        (a, b) => a.code.toLowerCase().compareTo(b.code.toLowerCase()),
      );
      final nextDefault =
          _normalizeCode(catalog['default_language_code']) ?? 'en';
      if (!nextLanguages.any((row) => row.code == nextDefault)) {
        nextLanguages.insert(
          0,
          _LocalizationLanguageChoice(
            code: nextDefault,
            name: nextDefault.toUpperCase(),
          ),
        );
      }
      final aiSettings = (aiSettingsResponse.data as Map)
          .cast<String, dynamic>();
      final health = (healthResponse.data is Map)
          ? (healthResponse.data as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final providerDefaults = (aiSettings['provider_defaults'] is Map)
          ? (aiSettings['provider_defaults'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final resolvedProvider =
          _normalizeCode(aiSettings['provider']) ?? 'openai';
      String providerDefaultModelFromPayload(String provider) {
        final payload = providerDefaults[provider];
        if (payload is Map && payload['default_model'] is String) {
          final model = (payload['default_model'] as String).trim();
          if (model.isNotEmpty) return model;
        }
        return _providerDefaultModel(provider);
      }

      final selectedModel =
          (aiSettings['model'] ?? '').toString().trim().isEmpty
          ? providerDefaultModelFromPayload(resolvedProvider)
          : (aiSettings['model'] ?? '').toString().trim();
      final queueStatus = (queueStatusResponse.data is Map)
          ? (queueStatusResponse.data as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      _setDialogState(() {
        _languages
          ..clear()
          ..addAll(nextLanguages);
        _defaultLanguageCode = nextDefault;
        _providerDefaults = providerDefaults;
        _provider = resolvedProvider;
        _modelCtrl.text = selectedModel;
        _apiBaseUrlCtrl.text = (aiSettings['api_base_url'] ?? '')
            .toString()
            .trim();
        _resolvedApiBaseUrl = (aiSettings['resolved_api_base_url'] ?? '')
            .toString()
            .trim();
        _apiKeyCtrl.clear();
        _promptCtrl.text =
            (aiSettings['translation_prompt'] ?? '').toString().trim().isEmpty
            ? _LocalizationManagerDialogState._defaultTranslationPrompt
            : (aiSettings['translation_prompt'] ?? '').toString().trim();
        _glossaryCtrl.text = _glossaryMapToText(aiSettings['glossary']);
        _translationEnabled = aiSettings['translation_enabled'] != false;
        _autoTranslateOnWrite = aiSettings['auto_translate_on_write'] != false;
        _autoApprove = aiSettings['auto_approve'] == true;
        _autoRetranslateOnBundleChange =
            aiSettings['auto_retranslate_on_bundle_change'] == true;
        _fallbackToSource = aiSettings['fallback_to_source'] != false;
        _health = health;
        _queueAttemptsCtrl.text = _coerceInt(
          aiSettings['queue_max_attempts'],
          fallback: 4,
          min: 1,
          max: 10,
        ).toString();
        _queueBackoffCtrl.text = _coerceInt(
          aiSettings['queue_backoff_seconds'],
          fallback: 30,
          min: 1,
          max: 3600,
        ).toString();
        _queueBatchCtrl.text = _coerceInt(
          aiSettings['queue_batch_size'],
          fallback: 20,
          min: 1,
          max: 250,
        ).toString();
        _hasApiKey = aiSettings['has_api_key'] == true;
        _queueStatus = queueStatus;
        _loading = false;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() {
        _loading = false;
        _error = _dioMessage(error);
      });
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  int _coerceInt(
    Object? raw, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = switch (raw) {
      int v => v,
      String s => int.tryParse(s.trim()) ?? fallback,
      _ => fallback,
    };
    return parsed.clamp(min, max);
  }

  String _glossaryMapToText(Object? raw) {
    if (raw is! Map) return '';
    final lines = <String>[];
    for (final entry in raw.entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty) continue;
      final value = entry.value.toString().trim();
      lines.add('$key = ${value.isEmpty ? key : value}');
    }
    return lines.join('\n');
  }

  Map<String, String> _parseGlossaryText() {
    final out = <String, String>{};
    for (final line in _glossaryCtrl.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final sep = trimmed.contains('=')
          ? trimmed.indexOf('=')
          : trimmed.indexOf(':');
      if (sep <= 0) {
        out[trimmed] = trimmed;
        continue;
      }
      final key = trimmed.substring(0, sep).trim();
      if (key.isEmpty) continue;
      final value = trimmed.substring(sep + 1).trim();
      out[key] = value.isEmpty ? key : value;
    }
    return out;
  }

  String _providerLabel(String provider) {
    final payload = _providerDefaults[provider];
    if (payload is Map && payload['label'] is String) {
      final label = (payload['label'] as String).trim();
      if (label.isNotEmpty) return label;
    }
    return switch (provider) {
      'openai' => widget.l10n.text('provider_openai'),
      'gemini' => widget.l10n.text('provider_gemini'),
      'custom' => widget.l10n.text('provider_custom_http'),
      _ => provider,
    };
  }

  String _providerDefaultModel(String provider) {
    final payload = _providerDefaults[provider];
    if (payload is Map && payload['default_model'] is String) {
      final model = (payload['default_model'] as String).trim();
      if (model.isNotEmpty) return model;
    }
    return switch (provider) {
      'gemini' => 'gemini-3-flash',
      'custom' => 'custom-model',
      _ => 'gpt-5-mini',
    };
  }

  String? _providerDefaultBaseUrl(String provider) {
    final payload = _providerDefaults[provider];
    if (payload is Map && payload['default_base_url'] is String) {
      final url = (payload['default_base_url'] as String).trim();
      if (url.isNotEmpty) return url;
    }
    return switch (provider) {
      'openai' => 'https://api.openai.com/v1',
      'gemini' => 'https://generativelanguage.googleapis.com/v1beta',
      _ => null,
    };
  }

  List<_LocalizationProviderModelChoice> _providerModelChoices(
    String provider,
  ) {
    final payload = _providerDefaults[provider];
    if (payload is! Map) return const <_LocalizationProviderModelChoice>[];
    final models = payload['models'];
    if (models is! List) return const <_LocalizationProviderModelChoice>[];
    final choices = <_LocalizationProviderModelChoice>[];
    for (final raw in models) {
      if (raw is! Map) continue;
      final id = (raw['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final label = (raw['label'] ?? id).toString().trim();
      final multiplierRaw = raw['usage_multiplier'];
      final multiplier = switch (multiplierRaw) {
        num value => value.toDouble(),
        String text => double.tryParse(text) ?? 1.0,
        _ => 1.0,
      };
      choices.add(
        _LocalizationProviderModelChoice(
          id: id,
          label: label.isEmpty ? id : label,
          usageMultiplier: multiplier,
        ),
      );
    }
    return choices;
  }

  double? _modelUsageMultiplier({
    required String provider,
    required String model,
  }) {
    final normalizedModel = model.trim();
    if (normalizedModel.isEmpty) return null;
    for (final choice in _providerModelChoices(provider)) {
      if (choice.id == normalizedModel) return choice.usageMultiplier;
    }
    return null;
  }

  void _applyProviderDefaults({
    required String previousProvider,
    required String nextProvider,
  }) {
    final previousModel = _providerDefaultModel(previousProvider);
    final nextModel = _providerDefaultModel(nextProvider);
    final currentModel = _modelCtrl.text.trim();
    if (currentModel.isEmpty || currentModel == previousModel) {
      _modelCtrl.text = nextModel;
    }

    final previousBaseUrl = _providerDefaultBaseUrl(previousProvider) ?? '';
    final nextBaseUrl = _providerDefaultBaseUrl(nextProvider) ?? '';
    final currentBaseUrl = _apiBaseUrlCtrl.text.trim();
    if (currentBaseUrl.isEmpty || currentBaseUrl == previousBaseUrl) {
      _apiBaseUrlCtrl.text = nextBaseUrl;
    }
  }

  Future<void> _saveDefaultLanguage() async {
    _setDialogState(() {
      _savingDefault = true;
      _error = null;
    });
    try {
      await widget.api.dio.patch(
        '/localization/catalog',
        data: <String, dynamic>{'default_language_code': _defaultLanguageCode},
      );
      if (!mounted) return;
      widget.onApplied();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(widget.l10n.text('save_changes'))),
      );
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() {
        _savingDefault = false;
        _error = _dioMessage(error);
      });
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() {
        _savingDefault = false;
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        _setDialogState(() => _savingDefault = false);
      }
    }
  }

  Future<void> _exportBundles() async {
    _setDialogState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final response = await widget.api.dio.get(
        '/localization/bundles/export',
        queryParameters: <String, dynamic>{'format_name': _exportFormat},
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      final encoded = const JsonEncoder.withIndent('  ').convert(payload);
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '-',
      );
      await downloadBytes(
        bytes: utf8.encode(encoded),
        filename: 'localization_${_exportFormat}_bundles_$timestamp.json',
        mimeType: 'application/json',
      );
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(widget.l10n.text('bundle_export_downloaded'))),
      );
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _exporting = false);
      }
    }
  }

  Future<void> _importBundlesFromFile() async {
    _setDialogState(() {
      _importing = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        withData: true,
        type: FileType.custom,
        allowedExtensions: <String>['json'],
      );
      if (picked == null || picked.files.isEmpty) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError(widget.l10n.text('selected_file_empty'));
      }
      final raw = utf8.decode(bytes).trim();
      final decoded = jsonDecode(raw);
      Map<String, dynamic> bundles;
      if (decoded is Map && decoded['bundles'] is Map) {
        bundles = (decoded['bundles'] as Map).cast<String, dynamic>();
      } else if (decoded is Map) {
        bundles = decoded.cast<String, dynamic>();
      } else {
        throw StateError(
          widget.l10n.text('import_payload_must_be_json_object'),
        );
      }
      final response = await widget.api.dio.post(
        '/localization/bundles/import',
        data: <String, dynamic>{
          'format': _importFormat,
          'dry_run': false,
          'bundles': bundles,
        },
      );
      final result = (response.data as Map).cast<String, dynamic>();
      if (!mounted) return;
      if (result['applied'] == true) {
        widget.onApplied();
        await _load();
        if (!mounted) return;
        final updatedCount = (result['updated_languages'] is List)
            ? (result['updated_languages'] as List).length
            : 0;
        final warningCount = (result['warnings'] is List)
            ? (result['warnings'] as List).length
            : 0;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              warningCount > 0
                  ? widget.l10n
                        .text('imported_language_bundles_with_warnings')
                        .replaceAll('{updated}', '$updatedCount')
                        .replaceAll('{warnings}', '$warningCount')
                  : widget.l10n
                        .text('imported_language_bundles')
                        .replaceAll('{updated}', '$updatedCount'),
            ),
          ),
        );
      }
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _importing = false);
      }
    }
  }

  Future<void> _saveAiSettings() async {
    _setDialogState(() {
      _savingAi = true;
      _error = null;
    });
    try {
      final payload = <String, dynamic>{
        'provider': _provider,
        'model': _modelCtrl.text.trim().isEmpty
            ? _providerDefaultModel(_provider)
            : _modelCtrl.text.trim(),
        'api_base_url': _apiBaseUrlCtrl.text.trim().isEmpty
            ? null
            : _apiBaseUrlCtrl.text.trim(),
        'translation_enabled': _translationEnabled,
        'auto_translate_on_write': _autoTranslateOnWrite,
        'auto_approve': _autoApprove,
        'auto_retranslate_on_bundle_change': _autoRetranslateOnBundleChange,
        'fallback_to_source': _fallbackToSource,
        'queue_max_attempts': _coerceInt(
          _queueAttemptsCtrl.text,
          fallback: 4,
          min: 1,
          max: 10,
        ),
        'queue_backoff_seconds': _coerceInt(
          _queueBackoffCtrl.text,
          fallback: 30,
          min: 1,
          max: 3600,
        ),
        'queue_batch_size': _coerceInt(
          _queueBatchCtrl.text,
          fallback: 20,
          min: 1,
          max: 250,
        ),
        'glossary': _parseGlossaryText(),
        'translation_prompt': _promptCtrl.text.trim().isEmpty
            ? _LocalizationManagerDialogState._defaultTranslationPrompt
            : _promptCtrl.text.trim(),
      };
      final apiKey = _apiKeyCtrl.text.trim();
      if (apiKey.isNotEmpty) {
        payload['api_key'] = apiKey;
      }

      await widget.api.dio.patch('/localization/ai-settings', data: payload);
      if (!mounted) return;
      _apiKeyCtrl.clear();
      widget.onApplied();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(widget.l10n.text('save_changes'))),
      );
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _savingAi = false);
      }
    }
  }

  Future<void> _clearApiKey() async {
    _setDialogState(() {
      _savingAi = true;
      _error = null;
    });
    try {
      await widget.api.dio.patch(
        '/localization/ai-settings',
        data: const <String, dynamic>{'clear_api_key': true},
      );
      if (!mounted) return;
      _apiKeyCtrl.clear();
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _savingAi = false);
      }
    }
  }

  Future<void> _processQueueNow() async {
    _setDialogState(() {
      _processingQueue = true;
      _error = null;
    });
    try {
      final response = await widget.api.dio.post(
        '/localization/translations/queue/process',
        queryParameters: <String, dynamic>{
          'limit': _coerceInt(
            _queueBatchCtrl.text,
            fallback: 20,
            min: 1,
            max: 250,
          ),
        },
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            widget.l10n
                .text('processed_jobs_summary')
                .replaceAll('{processed}', '${payload['processed'] ?? 0}')
                .replaceAll('{succeeded}', '${payload['succeeded'] ?? 0}')
                .replaceAll('{retried}', '${payload['retried'] ?? 0}'),
          ),
        ),
      );
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _processingQueue = false);
      }
    }
  }

  Future<void> _bulkRetranslateAll() async {
    _setDialogState(() {
      _bulkRetranslating = true;
      _error = null;
    });
    try {
      final response = await widget.api.dio.post(
        '/localization/translations/retranslate',
        data: const <String, dynamic>{
          'reason': 'manual_bulk',
          'include_locked': false,
        },
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            widget.l10n
                .text('queued_jobs_count')
                .replaceAll('{count}', '${payload['queued_jobs'] ?? 0}'),
          ),
        ),
      );
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _bulkRetranslating = false);
      }
    }
  }

  Future<void> _translateMissingAll() async {
    _setDialogState(() {
      _translatingMissing = true;
      _error = null;
    });
    try {
      final response = await widget.api.dio.post(
        '/localization/translations/translate-missing',
        data: const <String, dynamic>{'include_locked': false},
      );
      final payload = (response.data as Map).cast<String, dynamic>();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            widget.l10n
                .text('queued_missing_translation_jobs')
                .replaceAll('{count}', '${payload['queued_jobs'] ?? 0}'),
          ),
        ),
      );
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      _setDialogState(() => _error = error.toString());
    } finally {
      if (mounted) {
        _setDialogState(() => _translatingMissing = false);
      }
    }
  }

  String _dioMessage(DioException error) {
    return requestErrorMessage(error, context: context);
  }
}
