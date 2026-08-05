// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Persisted recent-query and saved-view state for structured-search screens.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'query_ast.dart';

class SearchSavedView {
  final String id;
  final String name;
  final String query;
  final DateTime createdAt;
  final DateTime lastUsedAt;

  const SearchSavedView({
    required this.id,
    required this.name,
    required this.query,
    required this.createdAt,
    required this.lastUsedAt,
  });

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'query': query,
    'created_at': createdAt.toIso8601String(),
    'last_used_at': lastUsedAt.toIso8601String(),
  };

  SearchSavedView copyWith({
    String? id,
    String? name,
    String? query,
    DateTime? createdAt,
    DateTime? lastUsedAt,
  }) {
    return SearchSavedView(
      id: id ?? this.id,
      name: name ?? this.name,
      query: query ?? this.query,
      createdAt: createdAt ?? this.createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  static SearchSavedView? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final row = raw.cast<Object?, Object?>();
    final id = (row['id'] ?? '').toString().trim();
    final name = (row['name'] ?? '').toString().trim();
    final query = normalizeSearchInput((row['query'] ?? '').toString());
    final createdAtRaw = (row['created_at'] ?? '').toString().trim();
    final lastUsedAtRaw = (row['last_used_at'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty || query.isEmpty) {
      return null;
    }
    final createdAt = DateTime.tryParse(createdAtRaw) ?? DateTime.now().toUtc();
    final lastUsedAt =
        DateTime.tryParse(lastUsedAtRaw) ?? DateTime.now().toUtc();
    return SearchSavedView(
      id: id,
      name: name,
      query: query,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
    );
  }
}

class SearchStateStore {
  static String _recentKey(String surfaceId) =>
      'search_recent_queries_${surfaceId.trim().toLowerCase()}_v1';

  static String _savedViewsKey(String surfaceId) =>
      'search_saved_views_${surfaceId.trim().toLowerCase()}_v1';

  static Future<List<String>> loadRecentQueries(
    String surfaceId, {
    int limit = 12,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(_recentKey(surfaceId)) ?? const <String>[];
    return rows
        .map(normalizeSearchInput)
        .where((query) => query.isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }

  static Future<void> rememberQuery(
    String surfaceId,
    String rawQuery, {
    int limit = 12,
  }) async {
    final query = normalizeSearchInput(rawQuery);
    if (query.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _recentKey(surfaceId);
    final existing = prefs.getStringList(key) ?? const <String>[];
    final next = <String>[
      query,
      ...existing.where((row) => row != query),
    ].take(limit).toList(growable: false);
    await prefs.setStringList(key, next);
  }

  static Future<List<SearchSavedView>> loadSavedViews(String surfaceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString(_savedViewsKey(surfaceId)) ?? '').trim();
    if (raw.isEmpty) return const <SearchSavedView>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <SearchSavedView>[];
      }
      final views = decoded
          .map(SearchSavedView.fromJson)
          .whereType<SearchSavedView>()
          .toList(growable: false);
      return views;
    } catch (_) {
      return const <SearchSavedView>[];
    }
  }

  static Future<void> saveView(
    String surfaceId, {
    required String name,
    required String query,
  }) async {
    final cleanName = name.trim();
    final cleanQuery = normalizeSearchInput(query);
    if (cleanName.isEmpty || cleanQuery.isEmpty) return;

    final now = DateTime.now().toUtc();
    final existing = await loadSavedViews(surfaceId);
    final matchIndex = existing.indexWhere(
      (view) => view.name.toLowerCase() == cleanName.toLowerCase(),
    );

    final mutable = existing.toList(growable: true);
    if (matchIndex >= 0) {
      final current = mutable[matchIndex];
      mutable[matchIndex] = current.copyWith(
        name: cleanName,
        query: cleanQuery,
        lastUsedAt: now,
      );
    } else {
      mutable.insert(
        0,
        SearchSavedView(
          id: _nextId(surfaceId),
          name: cleanName,
          query: cleanQuery,
          createdAt: now,
          lastUsedAt: now,
        ),
      );
    }

    await _persistSavedViews(
      surfaceId,
      mutable.take(24).toList(growable: false),
    );
  }

  static Future<void> touchView(String surfaceId, String viewId) async {
    final existing = await loadSavedViews(surfaceId);
    final now = DateTime.now().toUtc();
    final next = existing
        .map(
          (view) => view.id == viewId ? view.copyWith(lastUsedAt: now) : view,
        )
        .toList(growable: false);
    await _persistSavedViews(surfaceId, next);
  }

  static Future<void> deleteView(String surfaceId, String viewId) async {
    final existing = await loadSavedViews(surfaceId);
    final next = existing
        .where((view) => view.id != viewId)
        .toList(growable: false);
    await _persistSavedViews(surfaceId, next);
  }

  static Future<void> _persistSavedViews(
    String surfaceId,
    List<SearchSavedView> views,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _savedViewsKey(surfaceId),
      jsonEncode(views.map((view) => view.toJson()).toList(growable: false)),
    );
  }

  static String _nextId(String surfaceId) {
    final millis = DateTime.now().microsecondsSinceEpoch;
    return '${surfaceId.trim().toLowerCase()}-$millis';
  }
}

String encodeSearchAstParamFromRawQuery(String rawQuery) {
  final ast = parseSearchQueryAst(rawQuery);
  final payload = <String, Object?>{
    'raw': normalizeSearchInput(ast.raw),
    'field_tokens': ast.fieldTokens
        .map(
          (token) => <String, Object?>{
            'source': token.source,
            'field': token.field,
            'normalized_field': token.normalizedField,
            'value': token.value,
            'normalized_value': token.normalizedValue,
            'has_value_separator': token.hasValueSeparator,
            'is_negated': token.isNegated,
            'start': token.start,
            'end': token.end,
          },
        )
        .toList(growable: false),
    'text_tokens': ast.textTokens
        .map(
          (token) => <String, Object?>{
            'source': token.source,
            'value': token.value,
            'normalized_value': token.normalizedValue,
            'is_negated': token.isNegated,
            'start': token.start,
            'end': token.end,
          },
        )
        .toList(growable: false),
    'expression': _encodeExpressionNode(ast.expression),
    'diagnostics': ast.diagnostics
        .map(
          (diagnostic) => <String, Object?>{
            'code': diagnostic.code,
            'message': diagnostic.message,
            'start': diagnostic.start,
            'end': diagnostic.end,
          },
        )
        .toList(growable: false),
  };
  return base64UrlEncode(utf8.encode(jsonEncode(payload)));
}

Map<String, dynamic>? decodeSearchAstParam(String raw) {
  final payload = raw.trim();
  if (payload.isEmpty) return null;
  try {
    final decoded = utf8.decode(base64Url.decode(base64.normalize(payload)));
    final parsed = jsonDecode(decoded);
    if (parsed is! Map) return null;
    return parsed.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

Object? _encodeExpressionNode(SearchExpressionNode? node) {
  if (node == null) return null;
  return switch (node) {
    SearchExpressionGroup(:final operator, :final children) =>
      <String, Object?>{
        'kind': 'group',
        'operator': operator.name,
        'children': children
            .map<Object?>((child) => _encodeExpressionNode(child))
            .toList(growable: false),
      },
    SearchExpressionNot(:final child) => <String, Object?>{
      'kind': 'not',
      'child': _encodeExpressionNode(child),
    },
    SearchExpressionAtom(fieldToken: final field?) => <String, Object?>{
      'kind': 'field',
      'token': <String, Object?>{
        'normalized_field': field.normalizedField,
        'normalized_value': field.normalizedValue,
        'is_negated': field.isNegated,
      },
    },
    SearchExpressionAtom(textToken: final text?) => <String, Object?>{
      'kind': 'text',
      'token': <String, Object?>{
        'normalized_value': text.normalizedValue,
        'is_negated': text.isNegated,
      },
    },
    _ => null,
  };
}
