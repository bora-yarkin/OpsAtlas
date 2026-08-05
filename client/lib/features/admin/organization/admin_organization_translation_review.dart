// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Translation review dialog and UI for organization-managed content.

part of 'admin_organization_screen.dart';

class _ItemTranslationReviewDialog extends StatefulWidget {
  final ApiClient api;
  final AppLocalizations l10n;
  final String contentKind;
  final String contentId;
  final String title;

  const _ItemTranslationReviewDialog({
    required this.api,
    required this.l10n,
    required this.contentKind,
    required this.contentId,
    required this.title,
  });

  @override
  State<_ItemTranslationReviewDialog> createState() =>
      _ItemTranslationReviewDialogState();
}

class _ItemTranslationReviewDialogState
    extends State<_ItemTranslationReviewDialog> {
  bool _loading = true;
  bool _savingAutoApprove = false;
  bool _bulkRetranslating = false;
  String? _error;
  bool _autoApprove = false;
  List<Map<String, dynamic>> _variants = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final aiSettingsResponse = await widget.api.dio.get(
        '/localization/ai-settings',
      );
      final variantsResponse = await widget.api.dio.get(
        '/localization/translations/variants',
        queryParameters: <String, dynamic>{
          'content_kind': widget.contentKind,
          'content_id': widget.contentId,
          'limit': 300,
          'offset': 0,
        },
      );
      final aiSettings = (aiSettingsResponse.data as Map)
          .cast<String, dynamic>();
      final variantsPayload = (variantsResponse.data as Map)
          .cast<String, dynamic>();
      final items = (variantsPayload['items'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList(growable: false);
      setState(() {
        _autoApprove = aiSettings['auto_approve'] == true;
        _variants = items;
        _loading = false;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _dioMessage(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _setAutoApprove(bool value) async {
    setState(() {
      _savingAutoApprove = true;
      _error = null;
    });
    try {
      await widget.api.dio.patch(
        '/localization/ai-settings',
        data: <String, dynamic>{'auto_approve': value},
      );
      if (!mounted) return;
      setState(() => _autoApprove = value);
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _savingAutoApprove = false);
      }
    }
  }

  Future<void> _bulkRetranslateCurrentItem() async {
    setState(() {
      _bulkRetranslating = true;
      _error = null;
    });
    try {
      await widget.api.dio.post(
        '/localization/translations/retranslate',
        data: <String, dynamic>{
          'content_kind': widget.contentKind,
          'content_id': widget.contentId,
          'include_locked': false,
          'reason': 'manual_item_retranslate',
        },
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(widget.l10n.text('retranslate_item_jobs_queued')),
        ),
      );
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _bulkRetranslating = false);
      }
    }
  }

  Future<void> _updateVariant({
    required String variantId,
    required String action,
    String? translatedText,
  }) async {
    setState(() => _error = null);
    try {
      await widget.api.dio.patch(
        '/localization/translations/variants/$variantId',
        data: <String, dynamic>{
          'action': action,
          ...?translatedText == null
              ? null
              : <String, dynamic>{'translated_text': translatedText},
        },
      );
      if (!mounted) return;
      await _load();
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _error = _dioMessage(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  Future<void> _editVariant(Map<String, dynamic> variant) async {
    final ctrl = TextEditingController(
      text: (variant['translated_text'] ?? '').toString(),
    );
    final accepted = await showAppDialog<bool>(
      context: context,
      announcement: widget.l10n.text('edit_translation'),
      builder: (context) => AlertDialog(
        title: Text(widget.l10n.text('edit_translation')),
        content: SizedBox(
          width: 640,
          child: TextField(
            controller: ctrl,
            minLines: 8,
            maxLines: 14,
            decoration: InputDecoration(
              labelText: widget.l10n.text('translated_text_label'),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.l10n.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.l10n.text('save')),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _updateVariant(
        variantId: (variant['id'] ?? '').toString(),
        action: 'edit',
        translatedText: ctrl.text,
      );
    }
    ctrl.dispose();
  }

  String _dioMessage(DioException error) {
    return requestErrorMessage(error, context: context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 620),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
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
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      widget.l10n.text('auto_approve_new_translations'),
                    ),
                    value: _autoApprove,
                    onChanged: _savingAutoApprove ? null : _setAutoApprove,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.tonalIcon(
                  onPressed: _bulkRetranslating
                      ? null
                      : _bulkRetranslateCurrentItem,
                  icon: _bulkRetranslating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restart_alt_outlined),
                  label: Text(widget.l10n.text('retranslate_item')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_variants.isEmpty)
              Text(
                widget.l10n.text('no_translation_variants_yet'),
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Column(
                children: <Widget>[
                  for (final variant in _variants) ...<Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
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
                                    '${(variant['field_key'] ?? '').toString()} • ${(variant['language_code'] ?? '').toString()}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    (variant['status'] ?? 'unknown').toString(),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              widget.l10n.text('source_label'),
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            SelectableText(
                              (variant['source_text'] ?? '').toString(),
                              maxLines: 4,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              widget.l10n.text('translated_label'),
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            SelectableText(
                              (variant['translated_text'] ?? '').toString(),
                              maxLines: 6,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Wrap(
                              spacing: AppSpacing.xs,
                              runSpacing: AppSpacing.xs,
                              children: <Widget>[
                                OutlinedButton(
                                  onPressed: () => _updateVariant(
                                    variantId: (variant['id'] ?? '').toString(),
                                    action: 'approve',
                                  ),
                                  child: Text(widget.l10n.text('approve')),
                                ),
                                OutlinedButton(
                                  onPressed: () => _editVariant(variant),
                                  child: Text(widget.l10n.text('edit')),
                                ),
                                OutlinedButton(
                                  onPressed: () => _updateVariant(
                                    variantId: (variant['id'] ?? '').toString(),
                                    action: variant['locked'] == true
                                        ? 'unlock'
                                        : 'lock',
                                  ),
                                  child: Text(
                                    variant['locked'] == true
                                        ? widget.l10n.text('unlock')
                                        : widget.l10n.text('lock'),
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: () => _updateVariant(
                                    variantId: (variant['id'] ?? '').toString(),
                                    action: 'retranslate',
                                  ),
                                  child: Text(widget.l10n.text('retranslate')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}
