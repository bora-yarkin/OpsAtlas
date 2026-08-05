// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Analytics event tracking provider and helpers for frontend user actions.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';

const Set<String> trackedAnalyticsEventTypes = <String>{
  'view',
  'open',
  'search_query_issued',
  'search_results_shown',
  'search_no_result',
  'search_suggestion_accepted',
};

String _analyticsSessionId =
    'app-${DateTime.now().microsecondsSinceEpoch.toString()}';

class _RouteAnalyticsTarget {
  final String surface;
  final String? spaceId;
  final String? entityType;
  final String? entityId;
  final Map<String, Object?> extraMeta;

  const _RouteAnalyticsTarget({
    required this.surface,
    required this.spaceId,
    required this.entityType,
    required this.entityId,
    this.extraMeta = const <String, Object?>{},
  });
}

Future<void> trackAnalyticsEvent(
  WidgetRef ref, {
  required String eventType,
  String? path,
  String? entityType,
  String? entityId,
  String? spaceId,
  Map<String, Object?> meta = const <String, Object?>{},
}) async {
  if (!trackedAnalyticsEventTypes.contains(eventType)) {
    return;
  }

  final api = ref.read(apiClientProvider);
  final payload = <String, Object?>{
    'session_id': _analyticsSessionId,
    'event_type': eventType,
    'space_id': spaceId,
    'entity_type': entityType,
    'entity_id': entityId,
    'path': path,
    'meta': <String, Object?>{'producer': 'client', ...meta},
  };

  try {
    await api.dio.post('/analytics/events', data: payload);
  } on DioException {
    // Best-effort telemetry only.
  } catch (_) {
    // Best-effort telemetry only.
  }
}

Future<void> trackEntityView(
  WidgetRef ref, {
  required String entityType,
  required String entityId,
  required String path,
  required String surface,
  String? spaceId,
  Map<String, Object?> meta = const <String, Object?>{},
}) {
  return trackAnalyticsEvent(
    ref,
    eventType: 'view',
    path: path,
    entityType: entityType,
    entityId: entityId,
    spaceId: spaceId,
    meta: <String, Object?>{'surface': surface, ...meta},
  );
}

Future<void> trackEntityOpen(
  WidgetRef ref, {
  required String entityType,
  required String entityId,
  required String path,
  required String surface,
  String? spaceId,
  Map<String, Object?> meta = const <String, Object?>{},
}) {
  return trackAnalyticsEvent(
    ref,
    eventType: 'open',
    path: path,
    entityType: entityType,
    entityId: entityId,
    spaceId: spaceId,
    meta: <String, Object?>{'surface': surface, ...meta},
  );
}

Future<void> trackRouteView(WidgetRef ref, {required Uri uri}) {
  final target = _routeAnalyticsTargetForUri(uri);
  if (target == null) {
    return Future<void>.value();
  }
  return trackAnalyticsEvent(
    ref,
    eventType: 'view',
    path: uri.toString(),
    entityType: target.entityType,
    entityId: target.entityId,
    spaceId: target.spaceId,
    meta: <String, Object?>{'surface': target.surface, ...target.extraMeta},
  );
}

void resetAnalyticsSession() {
  _analyticsSessionId =
      'app-${DateTime.now().microsecondsSinceEpoch.toString()}';
}

_RouteAnalyticsTarget? _routeAnalyticsTargetForUri(Uri uri) {
  final path = uri.path;
  if (path.isEmpty || path == '/login') {
    return null;
  }
  if (path == '/dashboard') {
    return const _RouteAnalyticsTarget(
      surface: 'dashboard',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'dashboard',
    );
  }
  if (path == '/spaces') {
    return const _RouteAnalyticsTarget(
      surface: 'spaces',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'spaces',
    );
  }
  if (path == '/tasks') {
    return const _RouteAnalyticsTarget(
      surface: 'tasks',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'tasks',
    );
  }
  if (path == '/analytics') {
    return const _RouteAnalyticsTarget(
      surface: 'analytics',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'analytics',
    );
  }
  if (path == '/organization') {
    return const _RouteAnalyticsTarget(
      surface: 'organization',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'organization',
    );
  }
  if (path == '/organization/media') {
    return const _RouteAnalyticsTarget(
      surface: 'organization_media',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'organization_media',
    );
  }
  if (path == '/organization/backups' ||
      path.startsWith('/organization/backups/')) {
    return const _RouteAnalyticsTarget(
      surface: 'organization_backups',
      spaceId: null,
      entityType: 'admin_surface',
      entityId: 'organization_backups',
    );
  }
  final segments = uri.pathSegments;
  if (segments.length >= 2 && segments.first == 'spaces') {
    final spaceId = segments[1].trim();
    if (spaceId.isEmpty) {
      return null;
    }
    final entityType = switch (true) {
      _
          when uri.queryParameters.containsKey('docId') ||
              uri.queryParameters.containsKey('docSlug') =>
        'doc',
      _
          when uri.queryParameters.containsKey('sopId') ||
              uri.queryParameters.containsKey('sopSlug') ||
              uri.queryParameters.containsKey('sopRunId') =>
        'sop',
      _
          when uri.queryParameters.containsKey('incidentId') ||
              uri.queryParameters.containsKey('timelineId') ||
              uri.queryParameters.containsKey('actionItemId') =>
        'incident',
      _ when uri.queryParameters.containsKey('taskId') => 'task',
      _ => 'workspace',
    };
    return _RouteAnalyticsTarget(
      surface: 'space_workspace',
      spaceId: spaceId,
      entityType: null,
      entityId: null,
      extraMeta: <String, Object?>{'entity_type': entityType},
    );
  }
  return null;
}
