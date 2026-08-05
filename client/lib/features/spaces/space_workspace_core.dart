// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Shared data types, search models, and low-level helpers for the space workspace.

part of 'space_workspace_screen.dart';

typedef JsonMap = Map<String, dynamic>;

class _WorkspaceSearchSuggestion {
  final String label;
  final String tokenText;
  final bool appendSpace;

  const _WorkspaceSearchSuggestion({
    required this.label,
    required this.tokenText,
    required this.appendSpace,
  });
}

bool? _parseBoolSearchValue(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  if (<String>{'true', 'yes', '1', 'on'}.contains(normalized)) {
    return true;
  }
  if (<String>{'false', 'no', '0', 'off'}.contains(normalized)) {
    return false;
  }
  return null;
}

int _asInt(dynamic value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}

class _SpaceMembersCacheEntry {
  final List<JsonMap> members;
  final DateTime fetchedAt;

  const _SpaceMembersCacheEntry({
    required this.members,
    required this.fetchedAt,
  });
}

const Duration _spaceMembersCacheTtl = Duration(seconds: 20);
final Map<String, _SpaceMembersCacheEntry> _spaceMembersDetailedCache =
    <String, _SpaceMembersCacheEntry>{};

Future<List<JsonMap>> _fetchSpaceMembersDetailed(
  WidgetRef ref,
  String spaceId, {
  bool forceRefresh = false,
}) async {
  if (!forceRefresh) {
    final cached = _spaceMembersDetailedCache[spaceId];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _spaceMembersCacheTtl) {
      return cached.members;
    }
  }
  final api = ref.read(apiClientProvider);
  final r = await api.dio.get('/spaces/$spaceId/members/detailed');
  final members = List<JsonMap>.unmodifiable(_asJsonList(r.data));
  _spaceMembersDetailedCache[spaceId] = _SpaceMembersCacheEntry(
    members: members,
    fetchedAt: DateTime.now(),
  );
  return members;
}

String _t(BuildContext context, String key) =>
    AppLocalizations.of(context).text(key);

String _tf(BuildContext context, String key, Map<String, Object?> variables) {
  var value = _t(context, key);
  variables.forEach((placeholder, replacement) {
    value = value.replaceAll(
      '{$placeholder}',
      replacement == null ? '' : replacement.toString(),
    );
  });
  return value;
}

String _memberNameOrFallback(BuildContext context, JsonMap member) {
  final candidate = (member['name'] ?? member['email'] ?? '').toString().trim();
  if (candidate.isNotEmpty) {
    return candidate;
  }
  return _t(context, 'member');
}

String _memberRoleLabel(BuildContext context, JsonMap member) {
  final normalizedRole = (member['role'] ?? '').toString().trim();
  if (normalizedRole.isEmpty) {
    return _t(context, 'member');
  }
  final localized = _t(context, normalizedRole);
  if (localized == normalizedRole) {
    return normalizedRole.replaceAll('_', ' ');
  }
  return localized;
}

String _memberLabel(BuildContext context, JsonMap member) {
  return '${_memberNameOrFallback(context, member)} (${_memberRoleLabel(context, member)})';
}

String _statusText(BuildContext context, String status) {
  return switch (status) {
    'open' => _t(context, 'status_open'),
    'monitoring' => _t(context, 'status_monitoring'),
    'resolved' => _t(context, 'status_resolved'),
    'draft' => _t(context, 'status_draft'),
    'published' => _t(context, 'status_published'),
    _ => status.replaceAll('_', ' '),
  };
}

const List<String> _incidentTypeOptions = <String>[
  'service',
  'security',
  'infra',
  'product',
  'support',
  'other',
];

const List<String> _escalationPolicyOptions = <String>[
  'standard',
  'sev1',
  'sev2',
  'watch',
];

const List<String> _escalationStateOptions = <String>[
  'normal',
  'escalated',
  'bridge_open',
  'handoff',
];

const List<String> _impactLevelOptions = <String>[
  'outage',
  'degraded',
  'risk',
  'informational',
];

const List<String> _blastRadiusOptions = <String>[
  'single-service',
  'multi-service',
  'regional',
  'global',
];

String _stringOptionOrFallback(
  dynamic value,
  List<String> options,
  String fallback,
) {
  final candidate = (value ?? '').toString();
  return options.contains(candidate) ? candidate : fallback;
}

String _incidentTypeText(BuildContext context, String value) {
  return switch (value) {
    'service' => _t(context, 'incident_type_service'),
    'security' => _t(context, 'incident_type_security'),
    'infra' => _t(context, 'incident_type_infra'),
    'product' => _t(context, 'incident_type_product'),
    'support' => _t(context, 'incident_type_support'),
    'other' => _t(context, 'incident_type_other'),
    _ => value.replaceAll('_', ' '),
  };
}

String _escalationPolicyText(BuildContext context, String value) {
  return switch (value) {
    'standard' => _t(context, 'escalation_policy_standard'),
    'sev1' => _t(context, 'escalation_policy_sev1'),
    'sev2' => _t(context, 'escalation_policy_sev2'),
    'watch' => _t(context, 'escalation_policy_watch'),
    _ => value.replaceAll('_', ' '),
  };
}

String _escalationStateText(BuildContext context, String value) {
  return switch (value) {
    'normal' => _t(context, 'escalation_state_normal'),
    'escalated' => _t(context, 'escalation_state_escalated'),
    'bridge_open' => _t(context, 'escalation_state_bridge_open'),
    'handoff' => _t(context, 'escalation_state_handoff'),
    _ => value.replaceAll('_', ' '),
  };
}

String _impactLevelText(BuildContext context, String value) {
  return switch (value) {
    'outage' => _t(context, 'impact_level_outage'),
    'degraded' => _t(context, 'impact_level_degraded'),
    'risk' => _t(context, 'impact_level_risk'),
    'informational' => _t(context, 'impact_level_informational'),
    _ => value.replaceAll('_', ' '),
  };
}

String _blastRadiusText(BuildContext context, String value) {
  return switch (value) {
    'single-service' => _t(context, 'blast_radius_single_service'),
    'multi-service' => _t(context, 'blast_radius_multi_service'),
    'regional' => _t(context, 'blast_radius_regional'),
    'global' => _t(context, 'blast_radius_global'),
    _ => value.replaceAll('_', ' '),
  };
}

Future<void> _copyText(
  BuildContext context,
  String text,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    Directionality.of(context),
  );
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String _formatDate(String? value) {
  if (value == null || value.trim().isEmpty) return '—';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = parsed.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

String _formatDateTime(String? value) {
  if (value == null || value.trim().isEmpty) return '—';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = parsed.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _docLink(String spaceId, String slug) {
  final uri = Uri(path: '/spaces/$spaceId', queryParameters: {'docSlug': slug});
  return Uri.base.resolveUri(uri).toString();
}

String _docIdLink(String spaceId, String docId) {
  final uri = Uri(path: '/spaces/$spaceId', queryParameters: {'docId': docId});
  return Uri.base.resolveUri(uri).toString();
}

String _spaceIncidentLink(String spaceId, String incidentId) {
  final uri = Uri(
    path: '/spaces/$spaceId',
    queryParameters: {'incidentId': incidentId},
  );
  return Uri.base.resolveUri(uri).toString();
}

List<JsonMap> _asJsonList(dynamic data) {
  if (data is List) {
    return data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
  return const [];
}

List<String> _asStringList(dynamic data) {
  if (data is! List) return const [];
  return data
      .map((e) => e?.toString().trim() ?? '')
      .where((e) => e.isNotEmpty)
      .toList();
}

JsonMap _asJsonMap(dynamic data) {
  if (data is Map) return data.cast<String, dynamic>();
  return <String, dynamic>{};
}

String _slugify(String raw) {
  final lower = raw.trim().toLowerCase();
  final cleaned = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
}

String _richPreviewText(String raw) {
  final withoutTags = raw
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return withoutTags;
}

String _errorText(Object error) {
  return requestErrorMessage(error);
}
