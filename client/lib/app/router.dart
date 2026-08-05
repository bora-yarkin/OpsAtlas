// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// Central route table, auth redirects, and page transition policy.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/auth_store.dart';
import '../core/api/server_config.dart';
import '../core/theme/theme.dart';
import '../features/account/account_screen.dart';
import '../features/admin/backups/backups_screen.dart';
import '../features/admin/backups/snapshot_browser_screen.dart';
import '../features/admin/media/admin_media_screen.dart';
import '../features/admin/organization/admin_organization_screen.dart';
import '../features/analytics/analytics_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/server_connect_screen.dart';
import '../features/spaces/space_workspace_screen.dart';
import '../features/spaces/spaces_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/tasks/tasks_screen.dart';
import 'shell.dart';

/// Applies subtle desktop route transitions while keeping mobile shell swaps simple.
Page<void> _buildShellPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  final isDesktop = (MediaQuery.maybeSizeOf(context)?.width ?? 0) >= 980;
  if (!isDesktop) {
    return NoTransitionPage<void>(key: state.pageKey, child: child);
  }
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: AppMotion.standard,
    reverseTransitionDuration: AppMotion.fast,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.018),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Central route table that enforces auth redirects and role-based access.
final appRouterProvider = Provider<GoRouter>((ref) {
  final auth = ref.read(authStoreProvider);
  final serverConfig = ref.read(serverConfigProvider);

  String? sanitizeReturnTo(String? raw) {
    final candidate = (raw ?? '').trim();
    if (candidate.isEmpty) {
      return null;
    }
    Uri parsed;
    try {
      parsed = Uri.parse(candidate);
    } catch (_) {
      return null;
    }
    if (parsed.hasScheme || parsed.hasAuthority) {
      return null;
    }
    final path = parsed.path;
    if (!path.startsWith('/')) {
      return null;
    }
    if (path.startsWith('/login')) {
      return null;
    }
    return parsed.toString();
  }

  String loginLocationWithReturnTo(Uri currentUri) {
    final returnTo = sanitizeReturnTo(currentUri.toString());
    if (returnTo == null) {
      return '/login';
    }
    return Uri(
      path: '/login',
      queryParameters: <String, String>{'return_to': returnTo},
    ).toString();
  }

  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: Listenable.merge(<Listenable>[auth, serverConfig]),
    redirect: (context, state) {
      final goingConnect = state.matchedLocation == '/connect';
      final requiresServerSetup =
          serverConfig.supportsUserManagedBaseUrl &&
          serverConfig.loaded &&
          (serverConfig.effectiveBaseUrl == null ||
              serverConfig.effectiveBaseUrl!.trim().isEmpty);
      if (requiresServerSetup && !goingConnect) {
        return '/connect';
      }
      final loggedIn = auth.isLoggedIn;
      final goingLogin = state.matchedLocation == '/login';
      if (!loggedIn && !goingLogin && !goingConnect) {
        return loginLocationWithReturnTo(state.uri);
      }
      if (loggedIn && goingLogin) {
        final returnTo = sanitizeReturnTo(
          state.uri.queryParameters['return_to'],
        );
        return returnTo ?? '/dashboard';
      }
      final path = state.matchedLocation;
      if (loggedIn) {
        if (path.startsWith('/analytics') && !auth.canViewAnalytics) {
          return '/dashboard';
        }
        if (path.startsWith('/organization/backups') && !auth.isAdminLike) {
          return '/dashboard';
        }
        if (path.startsWith('/organization/media') && !auth.isAdmin) {
          final scopedSpaceId = state.uri.queryParameters['spaceId']?.trim();
          if (!(auth.isAdminLike &&
              scopedSpaceId != null &&
              scopedSpaceId.isNotEmpty)) {
            return '/spaces';
          }
        }
        final isOrganizationCore =
            path == '/organization' ||
            (path.startsWith('/organization/') &&
                !path.startsWith('/organization/media') &&
                !path.startsWith('/organization/backups'));
        if (isOrganizationCore && !auth.isAdmin) {
          return '/dashboard';
        }
      }
      return null;
    },
    routes: [
      GoRoute(path: '/connect', builder: (_, _) => const ServerConnectScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      ShellRoute(
        builder: (_, _, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            pageBuilder: (context, s) =>
                _buildShellPage(context, s, const DashboardScreen()),
          ),
          GoRoute(
            path: '/account',
            pageBuilder: (context, s) =>
                _buildShellPage(context, s, const AccountScreen()),
          ),
          GoRoute(
            path: '/spaces',
            pageBuilder: (context, s) => _buildShellPage(
              context,
              s,
              SpacesScreen(initialSearchQuery: s.uri.queryParameters['search']),
            ),
          ),
          GoRoute(
            path: '/tasks',
            pageBuilder: (context, s) => _buildShellPage(
              context,
              s,
              TasksScreen(
                initialSearchQuery: s.uri.queryParameters['search'],
                initialSpaceId: s.uri.queryParameters['spaceId'],
                autoOpenCreateDialog: s.uri.queryParameters['create'] == 'task',
              ),
            ),
          ),
          GoRoute(
            path: '/spaces/:spaceId',
            pageBuilder: (_, s) => CupertinoPage<void>(
              key: s.pageKey,
              child: SpaceWorkspaceScreen(
                spaceId: s.pathParameters['spaceId']!,
                initialSection: s.uri.queryParameters['tab'] ?? 'kb',
                initialSearchQuery: s.uri.queryParameters['search'],
                openDocId: s.uri.queryParameters['docId'],
                openDocSlug: s.uri.queryParameters['docSlug'],
                openSopId: s.uri.queryParameters['sopId'],
                openSopSlug: s.uri.queryParameters['sopSlug'],
                openSopStepId: s.uri.queryParameters['sopStepId'],
                openSopRunId: s.uri.queryParameters['sopRunId'],
                openIncidentId: s.uri.queryParameters['incidentId'],
                openTimelineId: s.uri.queryParameters['timelineId'],
                openActionItemId: s.uri.queryParameters['actionItemId'],
                openTaskId: s.uri.queryParameters['taskId'],
                createAction: s.uri.queryParameters['create'],
              ),
            ),
          ),
          GoRoute(
            path: '/analytics',
            pageBuilder: (context, s) =>
                _buildShellPage(context, s, const AnalyticsScreen()),
          ),
          GoRoute(
            path: '/organization',
            pageBuilder: (context, s) => _buildShellPage(
              context,
              s,
              AdminOrganizationScreen(
                initialSearchQuery: s.uri.queryParameters['search'],
              ),
            ),
          ),
          GoRoute(
            path: '/organization/media',
            builder: (_, s) => AdminMediaScreen(
              initialSpaceId: s.uri.queryParameters['spaceId'],
              initialSearchQuery: s.uri.queryParameters['search'],
            ),
          ),
          GoRoute(
            path: '/organization/backups',
            builder: (_, s) => BackupsScreen(
              initialSearchQuery: s.uri.queryParameters['search'],
            ),
          ),
          GoRoute(
            path: '/organization/backups/:snapshotId',
            builder: (_, s) => SnapshotBrowserScreen(
              snapshotId: s.pathParameters['snapshotId']!,
              initialPath: s.uri.queryParameters['path'],
            ),
          ),
        ],
      ),
    ],
  );
});
