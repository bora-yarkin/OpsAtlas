// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Editor-focused helper methods for the organization management screen.

part of 'admin_organization_screen.dart';

extension _AdminOrganizationScreenStateEditorHelpers
    on _AdminOrganizationScreenState {
  String _auditActionLabel(String action, AppLocalizations l10n) {
    final normalized = action.trim().toLowerCase();
    return switch (normalized) {
      'create' => l10n.text('audit_action_link_created'),
      'update' => l10n.text('audit_action_link_updated'),
      'delete' => l10n.text('audit_action_link_deleted'),
      'meta_create' => l10n.text('audit_action_meta_created'),
      'meta_update' => l10n.text('audit_action_meta_updated'),
      'owner_update' => l10n.text('audit_action_owner_updated'),
      'user_create' => l10n.text('audit_action_user_created'),
      'invite' => l10n.text('audit_action_user_invited'),
      'password_reset' => l10n.text('audit_action_user_password_reset'),
      'activate' => l10n.text('audit_action_user_activated'),
      'deactivate' => l10n.text('audit_action_user_deactivated'),
      'onboarding_complete' => l10n.text('audit_action_onboarding_completed'),
      _ => normalized.isEmpty ? l10n.text('activity_feed') : normalized,
    };
  }

  String _auditWhenLabel(Map<String, dynamic> event, AppLocalizations l10n) {
    final createdAtRaw = (event['created_at'] ?? '').toString().trim();
    if (createdAtRaw.isEmpty) return l10n.text('unknown');
    final parsed = DateTime.tryParse(createdAtRaw);
    if (parsed == null) return createdAtRaw;
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  String _localDateTimeLabel(Object? value, AppLocalizations l10n) {
    final raw = _trimmedOrNull(value);
    if (raw == null) return l10n.text('unknown');
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int item) => item.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  String _auditEventSummary(Map<String, dynamic> event, AppLocalizations l10n) {
    final summary = _trimmedOrNull(event['summary']);
    if (summary != null) return summary;
    return _auditActionLabel((event['action'] ?? '').toString(), l10n);
  }

  String? _auditChangesPreview(Map<String, dynamic> event) {
    final before = event['before'];
    final after = event['after'];
    final beforeMap = before is Map ? before.cast<String, dynamic>() : null;
    final afterMap = after is Map ? after.cast<String, dynamic>() : null;
    if (beforeMap == null && afterMap == null) return null;
    final encoder = const JsonEncoder.withIndent('  ');
    final beforeText = beforeMap == null ? 'null' : encoder.convert(beforeMap);
    final afterText = afterMap == null ? 'null' : encoder.convert(afterMap);
    return 'before:\n$beforeText\n\nafter:\n$afterText';
  }

  String? _trimmedOrNull(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  String _metaTypeKey(_MetaValueType type) {
    return switch (type) {
      _MetaValueType.text => 'text',
      _MetaValueType.number => 'number',
      _MetaValueType.boolean => 'boolean',
      _MetaValueType.file => 'file',
    };
  }

  _MetaValueType _metaTypeFromKey(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      'number' => _MetaValueType.number,
      'boolean' => _MetaValueType.boolean,
      'file' => _MetaValueType.file,
      _ => _MetaValueType.text,
    };
  }

  String _humanizeMetaKey(String key) {
    final cleaned = key
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .replaceAll(RegExp(r'\burl\b', caseSensitive: false), '')
        .trim();
    if (cleaned.isEmpty) return 'Metadata';
    final words = cleaned.split(RegExp(r'\s+'));
    return words
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  _MetaDraft _newMetaDraft() {
    return _MetaDraft(name: '', type: _MetaValueType.text);
  }

  List<_MetaDraft> _metaDraftsFromValue(Object? value) {
    if (value is! Map) return <_MetaDraft>[];
    final drafts = <_MetaDraft>[];
    value.forEach((rawKey, rawValue) {
      final key = rawKey.toString();
      if (rawValue is Map) {
        final type = _metaTypeFromKey((rawValue['type'] ?? '').toString());
        final displayName = (rawValue['name'] ?? '').toString().trim();
        final mappedValue = rawValue.containsKey('value')
            ? rawValue['value']
            : rawValue['url'];
        if (type == _MetaValueType.boolean) {
          drafts.add(
            _MetaDraft(
              name: displayName.isEmpty ? _humanizeMetaKey(key) : displayName,
              type: _MetaValueType.boolean,
              boolValue: mappedValue == true,
            ),
          );
          return;
        }
        if (type == _MetaValueType.number) {
          drafts.add(
            _MetaDraft(
              name: displayName.isEmpty ? _humanizeMetaKey(key) : displayName,
              type: _MetaValueType.number,
              textValue: mappedValue?.toString() ?? '',
            ),
          );
          return;
        }
        if (type == _MetaValueType.file) {
          drafts.add(
            _MetaDraft(
              name: displayName.isEmpty ? _humanizeMetaKey(key) : displayName,
              type: _MetaValueType.file,
              textValue: mappedValue?.toString() ?? '',
            ),
          );
          return;
        }
        drafts.add(
          _MetaDraft(
            name: displayName.isEmpty ? _humanizeMetaKey(key) : displayName,
            type: _MetaValueType.text,
            textValue: mappedValue?.toString() ?? '',
          ),
        );
        return;
      }
      if (rawValue is bool) {
        drafts.add(
          _MetaDraft(
            name: _humanizeMetaKey(key),
            type: _MetaValueType.boolean,
            boolValue: rawValue,
          ),
        );
        return;
      }
      if (rawValue is num) {
        drafts.add(
          _MetaDraft(
            name: _humanizeMetaKey(key),
            type: _MetaValueType.number,
            textValue: rawValue.toString(),
          ),
        );
        return;
      }
      final textValue = rawValue is String
          ? rawValue.trim()
          : jsonEncode(rawValue);
      final keyLower = key.toLowerCase();
      final fileLike =
          keyLower.contains('file') ||
          keyLower.contains('document') ||
          keyLower.contains('attachment');
      drafts.add(
        _MetaDraft(
          name: _humanizeMetaKey(key),
          type: fileLike ? _MetaValueType.file : _MetaValueType.text,
          textValue: textValue,
        ),
      );
    });
    return drafts;
  }

  String _metaTypeLabel(AppLocalizations l10n, _MetaValueType type) {
    return switch (type) {
      _MetaValueType.text => l10n.text('meta_type_text'),
      _MetaValueType.number => l10n.text('meta_type_number'),
      _MetaValueType.boolean => l10n.text('meta_type_boolean'),
      _MetaValueType.file => l10n.text('meta_type_document'),
    };
  }

  String _metaUsageFor(_ItemKind kind, String key) {
    final normalized = _slugify(key.trim().isEmpty ? 'file' : key.trim());
    return 'org_${kind.name}_meta_$normalized';
  }

  Future<String?> _pickMetaFile({
    required _ItemKind kind,
    required String key,
  }) async {
    final l10n = AppLocalizations.of(context);
    final usage = _metaUsageFor(kind, key);
    String? selectedUrl;
    await showAppDialog<void>(
      context: context,
      announcement: l10n.text('select_meta_file'),
      builder: (context) => AlertDialog(
        title: Text(l10n.text('select_meta_file')),
        content: SizedBox(
          width: 860,
          child: MediaUploadSection(
            title: l10n.text('upload_or_choose_file'),
            usage: usage,
            compact: true,
            emptyLabel: l10n.text('no_media_uploaded_yet'),
            showMetadataControls: false,
            onInsert: (url, _) {
              selectedUrl = url;
              Navigator.pop(context);
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.text('close')),
          ),
        ],
      ),
    );
    return selectedUrl;
  }

  Map<String, dynamic>? _metaFromDrafts(List<_MetaDraft> drafts) {
    if (drafts.isEmpty) return null;
    final result = <String, dynamic>{};
    final usedKeys = <String>{};
    var sequence = 1;
    for (final draft in drafts) {
      final name = draft.name.trim();
      if (name.isEmpty) throw const _MetaDraftException('meta_name_required');
      final baseKey = _slugify(name).isEmpty ? 'meta_item' : _slugify(name);
      var key = baseKey;
      while (usedKeys.contains(key)) {
        key = '${baseKey}_$sequence';
        sequence += 1;
      }
      usedKeys.add(key);
      Object value;
      switch (draft.type) {
        case _MetaValueType.text:
          value = draft.textValue.trim();
        case _MetaValueType.number:
          final parsed = num.tryParse(draft.textValue.trim());
          if (parsed == null) {
            throw const _MetaDraftException('meta_value_number_invalid');
          }
          value = parsed;
        case _MetaValueType.boolean:
          value = draft.boolValue;
        case _MetaValueType.file:
          final url = draft.textValue.trim();
          if (url.isEmpty) {
            throw const _MetaDraftException('meta_document_required');
          }
          value = url;
      }
      result[key] = <String, dynamic>{
        'name': name,
        'type': _metaTypeKey(draft.type),
        'value': value,
      };
    }
    return result;
  }

  Widget _buildMetaEditor({
    required AppLocalizations l10n,
    required _ItemKind kind,
    required List<_MetaDraft> drafts,
    required StateSetter setDialogState,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              l10n.text('metadata'),
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () =>
                  setDialogState(() => drafts.add(_newMetaDraft())),
              icon: const Icon(Icons.add),
              label: Text(l10n.text('add_meta_field')),
            ),
          ],
        ),
        if (drafts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              l10n.text('no_metadata_entries'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          Column(
            children: <Widget>[
              for (int index = 0; index < drafts.length; index++) ...[
                if (index > 0) const SizedBox(height: AppSpacing.sm),
                Builder(
                  builder: (context) {
                    final draft = drafts[index];
                    return DecoratedBox(
                      key: ObjectKey(draft),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: Column(
                          children: <Widget>[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Expanded(
                                  child: TextFormField(
                                    initialValue: draft.name,
                                    onChanged: (value) => draft.name = value,
                                    decoration: InputDecoration(
                                      labelText: l10n.text('meta_name'),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.text('delete'),
                                  onPressed: () => setDialogState(
                                    () => drafts.removeAt(index),
                                  ),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            DropdownButtonFormField<_MetaValueType>(
                              initialValue: draft.type,
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: l10n.text('meta_value_type'),
                              ),
                              items: <DropdownMenuItem<_MetaValueType>>[
                                for (final type in _MetaValueType.values)
                                  DropdownMenuItem<_MetaValueType>(
                                    value: type,
                                    child: Text(_metaTypeLabel(l10n, type)),
                                  ),
                              ],
                              onChanged: (value) => setDialogState(() {
                                if (value != null) draft.type = value;
                              }),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (draft.type == _MetaValueType.boolean)
                              DropdownButtonFormField<bool>(
                                initialValue: draft.boolValue,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: l10n.text('meta_value'),
                                ),
                                items: <DropdownMenuItem<bool>>[
                                  DropdownMenuItem<bool>(
                                    value: true,
                                    child: Text(l10n.text('meta_value_true')),
                                  ),
                                  DropdownMenuItem<bool>(
                                    value: false,
                                    child: Text(l10n.text('meta_value_false')),
                                  ),
                                ],
                                onChanged: (value) => setDialogState(() {
                                  draft.boolValue = value ?? false;
                                }),
                              )
                            else if (draft.type == _MetaValueType.file)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      FilledButton.tonalIcon(
                                        onPressed: () async {
                                          final picked = await _pickMetaFile(
                                            kind: kind,
                                            key: draft.name,
                                          );
                                          if (picked == null || !mounted) {
                                            return;
                                          }
                                          setDialogState(() {
                                            draft.textValue = picked;
                                          });
                                        },
                                        icon: const Icon(
                                          Icons.upload_file_outlined,
                                        ),
                                        label: Text(
                                          l10n.text('upload_or_choose_file'),
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.xs),
                                      if (draft.textValue.trim().isNotEmpty)
                                        OutlinedButton.icon(
                                          onPressed: () async {
                                            await showMediaPreviewDialog(
                                              context: context,
                                              filename:
                                                  draft.name.trim().isEmpty
                                                  ? l10n.text('meta_document')
                                                  : draft.name.trim(),
                                              url: draft.textValue.trim(),
                                            );
                                          },
                                          icon: const Icon(
                                            Icons.visibility_outlined,
                                          ),
                                          label: Text(l10n.text('view_file')),
                                        ),
                                      const Spacer(),
                                      if (draft.textValue.trim().isNotEmpty)
                                        IconButton(
                                          tooltip: l10n.text('clear'),
                                          onPressed: () => setDialogState(
                                            () => draft.textValue = '',
                                          ),
                                          icon: const Icon(Icons.clear),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  SelectableText(
                                    draft.textValue.trim().isEmpty
                                        ? l10n.text('no_file_selected')
                                        : draft.textValue.trim(),
                                    maxLines: 2,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              )
                            else
                              TextFormField(
                                initialValue: draft.textValue,
                                onChanged: (value) {
                                  draft.textValue = value;
                                },
                                keyboardType:
                                    draft.type == _MetaValueType.number
                                    ? const TextInputType.numberWithOptions(
                                        decimal: true,
                                        signed: true,
                                      )
                                    : TextInputType.text,
                                decoration: InputDecoration(
                                  labelText: l10n.text('meta_value'),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _brandingAssetEditor({
    required String label,
    required String uploadTitle,
    required String usage,
    required String? url,
    required ValueChanged<String?> onUrlChanged,
    required String emptyLabel,
  }) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.xs),
        SelectableText(
          url ?? l10n.text('not_selected'),
          maxLines: 1,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: <Widget>[
            TextButton.icon(
              onPressed: url == null ? null : () => onUrlChanged(null),
              icon: const Icon(Icons.clear),
              label: Text(l10n.text('clear')),
            ),
          ],
        ),
        MediaUploadSection(
          key: ValueKey<String>('branding_media_$usage'),
          title: uploadTitle,
          usage: usage,
          emptyLabel: emptyLabel,
          onInsert: (nextUrl, _) => onUrlChanged(nextUrl),
          showMetadataControls: false,
        ),
      ],
    );
  }
}
