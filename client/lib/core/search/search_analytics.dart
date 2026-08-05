// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Search telemetry helpers shared by structured-search surfaces.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics_tracker.dart';
import 'query_ast.dart';

class _SearchTelemetryState {
  String searchSessionId;
  String lastQuery;
  int refinementDepth;
  DateTime updatedAt;

  _SearchTelemetryState({
    required this.searchSessionId,
    required this.lastQuery,
    required this.refinementDepth,
    required this.updatedAt,
  });
}

const _searchTelemetryIdleWindow = Duration(minutes: 20);
final Map<String, _SearchTelemetryState> _searchTelemetryBySurface =
    <String, _SearchTelemetryState>{};

Future<void> trackSearchEvent(
  WidgetRef ref, {
  required String eventType,
  required String surface,
  required String query,
  String? path,
  String? entityType,
  String? entityId,
  String? spaceId,
  int? results,
  Map<String, Object?> extraMeta = const <String, Object?>{},
}) async {
  final normalizedQuery = normalizeSearchInput(query);
  if (normalizedQuery.isEmpty) {
    return;
  }

  final telemetryState = _resolveSearchTelemetryState(
    surface: surface,
    spaceId: spaceId,
    normalizedQuery: normalizedQuery,
    eventType: eventType,
  );
  final diagnosticsCount = _diagnosticsCount(extraMeta);
  final resultsMeta = results == null
      ? null
      : <String, Object?>{'results': results};
  final meta = <String, Object?>{
    'surface': surface,
    'query': normalizedQuery,
    'search_session_id': telemetryState.searchSessionId,
    'refinement_depth': telemetryState.refinementDepth,
    'diagnostics_count': diagnosticsCount,
    'has_diagnostics': diagnosticsCount > 0,
    ...?resultsMeta,
    ...extraMeta,
  };
  await trackAnalyticsEvent(
    ref,
    eventType: eventType,
    path: path,
    entityType: entityType,
    entityId: entityId,
    spaceId: spaceId,
    meta: meta,
  );
}

Future<void> trackSearchSuggestionAccepted(
  WidgetRef ref, {
  required String surface,
  required String query,
  required String nextQuery,
  String? suggestionToken,
  String? suggestionLabel,
  String? path,
  String? entityType,
  String? entityId,
  String? spaceId,
  Map<String, Object?> extraMeta = const <String, Object?>{},
}) {
  final normalizedQuery = normalizeSearchInput(query);
  final normalizedNextQuery = normalizeSearchInput(nextQuery);
  if (normalizedQuery.isEmpty || normalizedNextQuery.isEmpty) {
    return Future<void>.value();
  }
  return trackSearchEvent(
    ref,
    eventType: 'search_suggestion_accepted',
    surface: surface,
    query: normalizedQuery,
    path: path,
    entityType: entityType,
    entityId: entityId,
    spaceId: spaceId,
    extraMeta: <String, Object?>{
      'next_query': normalizedNextQuery,
      if (suggestionToken != null && suggestionToken.trim().isNotEmpty)
        'suggestion_token': suggestionToken.trim(),
      if (suggestionLabel != null && suggestionLabel.trim().isNotEmpty)
        'suggestion_label': suggestionLabel.trim(),
      ...extraMeta,
    },
  );
}

Future<void> trackSearchResultOpened(
  WidgetRef ref, {
  required String surface,
  required String query,
  String? path,
  String? entityType,
  String? entityId,
  String? spaceId,
  Map<String, Object?> extraMeta = const <String, Object?>{},
}) {
  final normalizedQuery = normalizeSearchInput(query);
  if (normalizedQuery.isEmpty) {
    return Future<void>.value();
  }
  return trackSearchEvent(
    ref,
    eventType: 'open',
    surface: surface,
    query: normalizedQuery,
    path: path,
    entityType: entityType,
    entityId: entityId,
    spaceId: spaceId,
    extraMeta: <String, Object?>{'positive_search_outcome': true, ...extraMeta},
  );
}

void resetSearchAnalyticsSession({String? surface, String? spaceId}) {
  if (surface == null) {
    _searchTelemetryBySurface.clear();
    return;
  }
  _searchTelemetryBySurface.remove(_searchTelemetryKey(surface, spaceId));
}

int _diagnosticsCount(Map<String, Object?> extraMeta) {
  final explicit = extraMeta['diagnostics_count'];
  if (explicit is num) {
    return explicit.toInt();
  }
  final diagnostics = extraMeta['diagnostic_codes'];
  if (diagnostics is Iterable) {
    return diagnostics.length;
  }
  return 0;
}

_SearchTelemetryState _resolveSearchTelemetryState({
  required String surface,
  required String? spaceId,
  required String normalizedQuery,
  required String eventType,
}) {
  final key = _searchTelemetryKey(surface, spaceId);
  final now = DateTime.now();
  final existing = _searchTelemetryBySurface[key];
  final state =
      existing == null ||
          now.difference(existing.updatedAt) > _searchTelemetryIdleWindow
      ? _newSearchTelemetryState(normalizedQuery, now)
      : existing;

  if (eventType == 'search_query_issued') {
    if (state.lastQuery.isEmpty) {
      state.lastQuery = normalizedQuery;
      state.refinementDepth = 0;
    } else if (state.lastQuery == normalizedQuery) {
      // Preserve the current refinement depth for repeated submissions.
    } else if (_sameSearchJourney(state.lastQuery, normalizedQuery)) {
      state.lastQuery = normalizedQuery;
      state.refinementDepth += 1;
    } else {
      final replacement = _newSearchTelemetryState(normalizedQuery, now);
      _searchTelemetryBySurface[key] = replacement;
      return replacement;
    }
  } else if (state.lastQuery.isEmpty) {
    state.lastQuery = normalizedQuery;
  }

  state.updatedAt = now;
  _searchTelemetryBySurface[key] = state;
  return state;
}

_SearchTelemetryState _newSearchTelemetryState(
  String normalizedQuery,
  DateTime now,
) {
  return _SearchTelemetryState(
    searchSessionId:
        'search-${DateTime.now().microsecondsSinceEpoch.toString()}',
    lastQuery: normalizedQuery,
    refinementDepth: 0,
    updatedAt: now,
  );
}

String _searchTelemetryKey(String surface, String? spaceId) {
  return '$surface|${spaceId ?? ''}';
}

bool _sameSearchJourney(String previousQuery, String nextQuery) {
  if (previousQuery == nextQuery) {
    return true;
  }
  if (previousQuery.isEmpty || nextQuery.isEmpty) {
    return false;
  }
  if (previousQuery.contains(nextQuery) || nextQuery.contains(previousQuery)) {
    return true;
  }
  final previousTokens = _queryTokens(previousQuery);
  final nextTokens = _queryTokens(nextQuery);
  if (previousTokens.isEmpty || nextTokens.isEmpty) {
    return false;
  }
  return previousTokens.intersection(nextTokens).isNotEmpty;
}

Set<String> _queryTokens(String query) {
  return query
      .split(RegExp(r'\s+'))
      .map((token) => token.trim().toLowerCase())
      .where((token) => token.isNotEmpty && !token.startsWith('@'))
      .toSet();
}
