// End-to-end widget smoke sweep for the main desktop and mobile UI routes.

import 'dart:convert';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:opsatlas_client/app/app.dart';
import 'package:opsatlas_client/app/router.dart';
import 'package:opsatlas_client/core/api/api_client.dart';
import 'package:opsatlas_client/core/api/auth_store.dart';
import 'package:opsatlas_client/core/api/branding.dart';
import 'package:opsatlas_client/core/api/server_config.dart';
import 'package:opsatlas_client/core/i18n/app_localizations.dart';
import 'package:opsatlas_client/core/widgets/rich_content.dart';

String _spaceRoute(
  String spaceId, {
  String? search,
  String? create,
  String? docId,
  String? sopId,
  String? incidentId,
  String? actionItemId,
  String? taskId,
}) {
  return Uri(
    path: '/spaces/$spaceId',
    queryParameters: <String, String>{
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      if (create != null && create.trim().isNotEmpty) 'create': create.trim(),
      if (docId != null && docId.trim().isNotEmpty) 'docId': docId.trim(),
      if (sopId != null && sopId.trim().isNotEmpty) 'sopId': sopId.trim(),
      if (incidentId != null && incidentId.trim().isNotEmpty)
        'incidentId': incidentId.trim(),
      if (actionItemId != null && actionItemId.trim().isNotEmpty)
        'actionItemId': actionItemId.trim(),
      if (taskId != null && taskId.trim().isNotEmpty) 'taskId': taskId.trim(),
    },
  ).toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UI smoke sweep', () {
    testWidgets('desktop routes and panels build without runtime UI errors', (
      tester,
    ) async {
      final harness = await _UiSmokeHarness.pump(
        tester,
        logicalSize: const Size(1440, 1024),
      );
      addTearDown(harness.dispose);

      await harness.expectOnScreen(
        find.text(_UiSmokeApi.spaceName),
        label: 'desktop shell boot',
      );
      await harness.openDesktopNotifications();
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'desktop notifications panel',
      );
      await harness.closeNotifications();
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.taskPrimaryTitle),
        label: 'dashboard content',
      );

      await harness.go('/analytics');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'analytics dashboard',
      );

      await harness.go('/organization');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.orgUnitName),
        label: 'organization tree',
      );

      await harness.go('/organization/media');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('access_mode')),
        label: 'media manager',
      );

      await harness.go('/organization/backups');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('snapshot_label')),
        label: 'backups list',
      );

      await harness.go('/organization/backups/${_UiSmokeApi.backupSnapshotId}');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.snapshotManifestName),
        label: 'snapshot browser',
      );

      await harness.go('/spaces');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.spaceName),
        label: 'spaces list',
      );

      await harness.go('/tasks');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.taskPrimaryTitle),
        label: 'tasks list',
      );

      await harness.go('/tasks?create=task');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('task_title')),
        label: 'task create screen',
      );
      await harness.popRoute(label: 'close task create screen');

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId));
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'workspace root',
      );

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, docId: _UiSmokeApi.kbDocPrimaryId),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'kb doc detail',
      );

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, search: '@type:kb @stale:true'),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'needs review search',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'doc'));
      await harness.expectOnScreen(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'kb doc create screen',
      );
      await harness.popRoute(label: 'close kb doc create screen');

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, search: '@type:sop'));
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.sopTitle),
        label: 'sop list',
      );

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, sopId: _UiSmokeApi.sopId),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.sopTitle),
        label: 'sop detail',
      );

      await harness.go(
        '/tasks?spaceId=${_UiSmokeApi.spaceId}&search=%40source%3Asop_run',
      );
      await harness.expectOnScreen(
        find.textContaining(_UiSmokeApi.taskSopRunTitle),
        label: 'sop tracker',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'sop'));
      await harness.expectOnScreen(
        find.text(harness.l10n.text('create_sop')),
        label: 'sop create screen',
      );
      await harness.popRoute(label: 'close sop create screen');

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, search: '@type:incident'),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.incidentTitle),
        label: 'incident list',
      );

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, incidentId: _UiSmokeApi.incidentId),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.incidentTitle),
        label: 'incident detail',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'incident'));
      await harness.expectOnScreen(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'incident create screen editor',
      );
      await harness.popRoute(label: 'close incident create screen');

      await harness.go('/account');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.userEmail),
        label: 'account email',
      );
      await harness.expectOnScreen(
        find.text(harness.l10n.text('account')),
        label: 'account title',
      );

      harness.expectNoErrors();
    });

    testWidgets('workspace search accepts spaces in typed text', (
      tester,
    ) async {
      final harness = await _UiSmokeHarness.pump(
        tester,
        logicalSize: const Size(1440, 1024),
      );
      addTearDown(harness.dispose);

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId));
      final searchField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            (widget.decoration?.hintText ?? '').contains('Search this space'),
        description: 'workspace search field',
      );

      await harness.expectOnScreen(
        searchField,
        label: 'workspace search field',
      );
      await tester.enterText(searchField, 'refund day');
      await harness.pumpUntilIdle(label: 'workspace search with spaces');

      expect(
        tester.widget<TextField>(searchField).controller?.text,
        'refund day',
      );
      expect(harness.currentUri.queryParameters['search'], 'refund day');

      harness.expectNoErrors();
    });

    testWidgets('mobile routes, drawer, and back navigation stay stable', (
      tester,
    ) async {
      final harness = await _UiSmokeHarness.pump(
        tester,
        logicalSize: const Size(390, 844),
      );
      addTearDown(harness.dispose);

      await harness.expectOnScreen(
        find.text(harness.l10n.text('dashboard')),
        label: 'mobile dashboard',
      );
      await harness.openMobileNotifications();
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'mobile notifications panel',
      );
      await harness.closeNotifications();
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.taskPrimaryTitle),
        label: 'mobile dashboard content',
      );

      await harness.go('/analytics');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'mobile analytics dashboard',
      );

      await harness.go('/organization');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.orgUnitName),
        label: 'mobile organization tree',
      );

      await harness.go('/organization/media');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('media_manager')),
        label: 'mobile media manager',
      );

      await harness.go('/organization/backups');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('backups')),
        label: 'mobile backups list',
      );

      await harness.go('/organization/backups/${_UiSmokeApi.backupSnapshotId}');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.snapshotManifestName),
        label: 'mobile snapshot browser',
      );

      await harness.go('/spaces');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.spaceName),
        label: 'mobile spaces list',
      );
      harness.checkpointNoErrors(label: 'mobile spaces list');

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId));
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'mobile workspace root',
      );
      harness.checkpointNoErrors(label: 'mobile workspace root');
      await harness.tap(find.byIcon(Icons.arrow_back).first);
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.spaceName),
        label: 'mobile back to spaces',
      );
      harness.checkpointNoErrors(label: 'mobile back to spaces');

      await harness.go('/tasks');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.taskPrimaryTitle),
        label: 'mobile tasks list',
      );
      harness.checkpointNoErrors(label: 'mobile tasks list');

      await harness.go('/tasks?create=task');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('task_title')),
        label: 'mobile task create screen',
      );
      await harness.popRoute(label: 'close mobile task create screen');

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, docId: _UiSmokeApi.kbDocSecondaryId),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocSecondaryTitle),
        label: 'mobile kb doc detail',
      );
      harness.checkpointNoErrors(label: 'mobile kb doc detail');
      await harness.tap(
        find.byIcon(Icons.arrow_back).first,
        label: 'mobile close kb doc detail',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'doc'));
      await harness.reveal(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'mobile kb doc create editor',
      );
      await harness.expectOnScreen(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'mobile kb doc create screen',
      );
      await harness.popRoute(label: 'close mobile kb doc create screen');

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, sopId: _UiSmokeApi.sopId),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.sopTitle),
        label: 'mobile sop detail',
      );
      harness.checkpointNoErrors(label: 'mobile sop detail');
      await harness.tap(
        find.byIcon(Icons.arrow_back).first,
        label: 'mobile close sop detail',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'sop'));
      await harness.expectOnScreen(
        find.text(harness.l10n.text('create_sop')),
        label: 'mobile sop create screen',
      );
      await harness.popRoute(label: 'close mobile sop create screen');

      await harness.go(
        _spaceRoute(_UiSmokeApi.spaceId, incidentId: _UiSmokeApi.incidentId),
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.incidentTitle),
        label: 'mobile incident detail',
      );
      harness.checkpointNoErrors(label: 'mobile incident detail');
      await harness.tap(
        find.byIcon(Icons.arrow_back).first,
        label: 'mobile close incident detail',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'incident'));
      await harness.reveal(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'mobile incident create editor',
      );
      await harness.expectOnScreen(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'mobile incident create screen',
      );
      await harness.popRoute(label: 'close mobile incident create screen');

      await harness.go('/account');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.userEmail),
        label: 'mobile account email',
      );

      harness.expectNoErrors();
    });

    testWidgets('compact desktop editors and account actions stay stable', (
      tester,
    ) async {
      final harness = await _UiSmokeHarness.pump(
        tester,
        logicalSize: const Size(1100, 780),
      );
      addTearDown(harness.dispose);

      await harness.go('/analytics');
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'compact desktop analytics',
      );

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'doc'));
      await harness.reveal(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'compact desktop kb editor reveal',
      );
      await harness.expectOnScreen(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'compact desktop kb editor',
      );
      await harness.popRoute(label: 'close compact desktop kb editor');

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'sop'));
      await harness.expectOnScreen(
        find.text(harness.l10n.text('create_sop')),
        label: 'compact desktop sop editor',
      );
      await harness.popRoute(label: 'close compact desktop sop editor');

      await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'incident'));
      await harness.reveal(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'compact desktop incident editor reveal',
      );
      await harness.expectOnScreen(
        find.byKey(_UiSmokeHarness.richEditorKey),
        label: 'compact desktop incident editor',
      );
      await harness.popRoute(label: 'close compact desktop incident editor');

      await harness.go('/account');
      await harness.expectOnScreen(
        find.text(harness.l10n.text('sessions_title')),
        label: 'compact desktop sessions card',
      );
      await harness.expectOnScreen(
        find.text(harness.l10n.text('revoke_other_sessions')).first,
        label: 'revoke other sessions action visible',
      );
      await harness.expectOnScreen(
        find.textContaining(harness.l10n.text('revoked_sessions')).first,
        label: 'revoked sessions action visible',
      );

      harness.expectNoErrors();
    });

    testWidgets('dashboard activity feed stays human readable', (tester) async {
      final harness = await _UiSmokeHarness.pump(
        tester,
        logicalSize: const Size(1280, 900),
      );
      addTearDown(harness.dispose);

      await harness.expectOnScreen(
        find.text(_UiSmokeApi.kbDocPrimaryTitle),
        label: 'dashboard feed document title',
      );
      await harness.expectOnScreen(
        find.text(_UiSmokeApi.taskPrimaryTitle),
        label: 'dashboard task title',
      );
      expect(find.textContaining('/spaces/'), findsNothing);
      expect(find.textContaining('?tab='), findsNothing);
      expect(find.textContaining(_UiSmokeApi.spaceId), findsNothing);
      expect(find.textContaining(_UiSmokeApi.kbDocPrimaryId), findsNothing);

      harness.expectNoErrors();
    });

    testWidgets(
      'anonymous users are redirected to login with a safe return URL',
      (tester) async {
        final harness = await _UiSmokeHarness.pump(
          tester,
          logicalSize: const Size(1280, 900),
          auth: _buildLoggedOutAuthStore(),
        );
        addTearDown(harness.dispose);

        final destination = _spaceRoute(
          _UiSmokeApi.spaceId,
          incidentId: _UiSmokeApi.incidentId,
        );
        await harness.go(destination);

        expect(harness.currentUri.path, '/login');
        expect(harness.currentUri.queryParameters['return_to'], destination);
        await harness.expectOnScreen(
          find.text(harness.l10n.text('login')),
          label: 'redirected login screen',
        );

        harness.expectNoErrors();
      },
    );

    testWidgets(
      'member role is redirected away from restricted admin surfaces',
      (tester) async {
        final harness = await _UiSmokeHarness.pump(
          tester,
          logicalSize: const Size(1280, 900),
          auth: _buildAuthenticatedAuthStore(
            role: 'member',
            mfaVerified: false,
          ),
        );
        addTearDown(harness.dispose);

        await harness.go('/analytics');
        expect(harness.currentUri.path, '/dashboard');
        await harness.expectOnScreen(
          find.text(harness.l10n.text('dashboard')),
          label: 'member redirected from analytics',
        );

        await harness.go('/organization');
        expect(harness.currentUri.path, '/dashboard');

        await harness.go('/organization/media');
        expect(harness.currentUri.path, '/spaces');
        await harness.expectOnScreen(
          find.text(_UiSmokeApi.spaceName),
          label: 'member redirected from media manager',
        );

        await harness.go('/organization/backups');
        expect(harness.currentUri.path, '/dashboard');

        harness.expectNoErrors();
      },
    );

    testWidgets(
      'login return_to handling rejects external targets and preserves internal ones',
      (tester) async {
        final loggedOutHarness = await _UiSmokeHarness.pump(
          tester,
          logicalSize: const Size(1280, 900),
          auth: _buildLoggedOutAuthStore(),
        );
        addTearDown(loggedOutHarness.dispose);

        await loggedOutHarness.go(
          '/login?return_to=https://evil.example.com/phish',
        );
        await loggedOutHarness.expectOnScreen(
          find.text(loggedOutHarness.l10n.text('login')),
          label: 'login screen for unsafe return_to',
        );
        expect(
          loggedOutHarness.currentUri.queryParameters['return_to'],
          'https://evil.example.com/phish',
        );

        final loggedInHarness = await _UiSmokeHarness.pump(
          tester,
          logicalSize: const Size(1280, 900),
        );
        addTearDown(loggedInHarness.dispose);

        await loggedInHarness.go(
          '/login?return_to=https://evil.example.com/phish',
        );
        expect(loggedInHarness.currentUri.path, '/dashboard');

        await loggedInHarness.go('/login?return_to=/tasks');
        expect(loggedInHarness.currentUri.path, '/tasks');
        await loggedInHarness.expectOnScreen(
          find.text(_UiSmokeApi.taskPrimaryTitle),
          label: 'safe internal return_to redirected to tasks',
        );

        loggedOutHarness.expectNoErrors();
        loggedInHarness.expectNoErrors();
      },
    );

    testWidgets(
      'moderator media-manager access requires scoped space and keeps backup restrictions',
      (tester) async {
        final harness = await _UiSmokeHarness.pump(
          tester,
          logicalSize: const Size(1280, 900),
          auth: _buildAuthenticatedAuthStore(role: 'moderator'),
        );
        addTearDown(harness.dispose);

        await harness.go('/organization/media');
        expect(harness.currentUri.path, '/spaces');

        await harness.go('/organization/media?spaceId=${_UiSmokeApi.spaceId}');
        expect(harness.currentUri.path, '/organization/media');
        await harness.expectAnyOnScreen(<Finder>[
          find.text(harness.l10n.text('media_manager')),
          find.textContaining('total assets'),
        ], label: 'moderator scoped media manager');

        await harness.go('/organization/backups');
        expect(harness.currentUri.path, '/organization/backups');
        await harness.expectAnyOnScreen(<Finder>[
          find.text(harness.l10n.text('backups')),
          find.textContaining('Backups'),
        ], label: 'moderator backups allowed');

        harness.expectNoErrors();
      },
    );

    testWidgets('login route builds without runtime UI errors', (tester) async {
      final harness = await _UiSmokeHarness.pump(
        tester,
        logicalSize: const Size(1280, 900),
        auth: _buildLoggedOutAuthStore(),
      );
      addTearDown(harness.dispose);

      await harness.expectOnScreen(
        find.text(harness.l10n.text('email')),
        label: 'login email field',
      );
      await harness.expectOnScreen(
        find.text(harness.l10n.text('password')),
        label: 'login password field',
      );
      await harness.expectOnScreen(
        find.text(harness.l10n.text('login')),
        label: 'login button',
      );

      harness.expectNoErrors();
    });

    testWidgets(
      'responsive stress sweep catches overflows, layout faults, and framework errors',
      (tester) async {
        final scenarios =
            <({String name, Size size, bool desktopShell, bool collapsedRail})>[
              (
                name: 'tight desktop',
                size: const Size(980, 700),
                desktopShell: true,
                collapsedRail: true,
              ),
              (
                name: 'compact tablet',
                size: const Size(820, 720),
                desktopShell: false,
                collapsedRail: false,
              ),
              (
                name: 'small mobile',
                size: const Size(360, 640),
                desktopShell: false,
                collapsedRail: false,
              ),
            ];

        for (final scenario in scenarios) {
          final harness = await _UiSmokeHarness.pump(
            tester,
            logicalSize: scenario.size,
          );
          try {
            await harness.expectOnScreen(
              find.text(
                scenario.desktopShell
                    ? _UiSmokeApi.spaceName
                    : harness.l10n.text('dashboard'),
              ),
              label: '${scenario.name} boot',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} dashboard',
            );
            harness.checkpointNoErrors(label: '${scenario.name} dashboard');

            if (scenario.desktopShell) {
              if (scenario.collapsedRail) {
                await harness.collapseDesktopSidebar();
              }
              await harness.openDesktopNotifications();
            } else {
              await harness.openMobileNotifications();
            }
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.kbDocPrimaryTitle),
              label: '${scenario.name} notifications panel',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} notifications',
            );
            await harness.closeNotifications();

            await harness.go('/analytics');
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.kbDocPrimaryTitle),
              label: '${scenario.name} analytics',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} analytics',
            );
            harness.checkpointNoErrors(label: '${scenario.name} analytics');

            await harness.go('/organization');
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.orgUnitName),
              label: '${scenario.name} organization',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} organization',
            );
            harness.checkpointNoErrors(label: '${scenario.name} organization');

            await harness.go('/organization/media');
            await harness.expectAnyOnScreen(<Finder>[
              find.text(harness.l10n.text('media_manager')),
              find.text(harness.l10n.text('access_mode')),
              find.textContaining('total assets'),
              find.textContaining('expired assets'),
            ], label: '${scenario.name} media manager');
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} media manager',
            );
            harness.checkpointNoErrors(label: '${scenario.name} media manager');

            await harness.go('/organization/backups');
            await harness.expectAnyOnScreen(<Finder>[
              find.text(harness.l10n.text('backups')),
              find.text(harness.l10n.text('snapshot_label')),
              find.textContaining('Backups'),
              find.textContaining('incremental'),
            ], label: '${scenario.name} backups');
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} backups',
            );
            harness.checkpointNoErrors(label: '${scenario.name} backups');

            await harness.go(
              '/organization/backups/${_UiSmokeApi.backupSnapshotId}',
            );
            await harness.expectAnyOnScreen(<Finder>[
              find.text(_UiSmokeApi.snapshotManifestName),
              find.text('Snapshot Browser'),
              find.text('Tree'),
            ], label: '${scenario.name} snapshot browser');
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} snapshot browser',
            );
            harness.checkpointNoErrors(
              label: '${scenario.name} snapshot browser',
            );

            await harness.go('/spaces');
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.spaceName),
              label: '${scenario.name} spaces',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} spaces',
            );
            harness.checkpointNoErrors(label: '${scenario.name} spaces');

            await harness.go('/tasks');
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.taskPrimaryTitle),
              label: '${scenario.name} tasks',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} tasks',
            );
            harness.checkpointNoErrors(label: '${scenario.name} tasks');

            await harness.go('/tasks?create=task');
            await harness.expectOnScreen(
              find.text(harness.l10n.text('task_title')),
              label: '${scenario.name} task create',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} task create',
            );
            harness.checkpointNoErrors(label: '${scenario.name} task create');
            await harness.popRoute(label: '${scenario.name} close task create');

            await harness.go(_spaceRoute(_UiSmokeApi.spaceId));
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.kbDocPrimaryTitle),
              label: '${scenario.name} workspace',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} workspace',
            );
            harness.checkpointNoErrors(label: '${scenario.name} workspace');

            await harness.go(
              _spaceRoute(
                _UiSmokeApi.spaceId,
                docId: _UiSmokeApi.kbDocPrimaryId,
              ),
            );
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.kbDocPrimaryTitle),
              label: '${scenario.name} kb detail',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} kb detail',
            );
            harness.checkpointNoErrors(label: '${scenario.name} kb detail');

            await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'doc'));
            await harness.reveal(
              find.byKey(_UiSmokeHarness.richEditorKey),
              label: '${scenario.name} kb create reveal',
            );
            await harness.expectOnScreen(
              find.byKey(_UiSmokeHarness.richEditorKey),
              label: '${scenario.name} kb create',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} kb create',
            );
            harness.checkpointNoErrors(label: '${scenario.name} kb create');
            await harness.popRoute(label: '${scenario.name} close kb create');

            await harness.go(
              _spaceRoute(_UiSmokeApi.spaceId, sopId: _UiSmokeApi.sopId),
            );
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.sopTitle),
              label: '${scenario.name} sop detail',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} sop detail',
            );
            harness.checkpointNoErrors(label: '${scenario.name} sop detail');

            await harness.go(_spaceRoute(_UiSmokeApi.spaceId, create: 'sop'));
            await harness.expectOnScreen(
              find.text(harness.l10n.text('create_sop')),
              label: '${scenario.name} sop create',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} sop create',
            );
            harness.checkpointNoErrors(label: '${scenario.name} sop create');
            await harness.popRoute(label: '${scenario.name} close sop create');

            await harness.go(
              _spaceRoute(
                _UiSmokeApi.spaceId,
                incidentId: _UiSmokeApi.incidentId,
              ),
            );
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.incidentTitle),
              label: '${scenario.name} incident detail',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} incident detail',
            );
            harness.checkpointNoErrors(
              label: '${scenario.name} incident detail',
            );

            await harness.go(
              _spaceRoute(_UiSmokeApi.spaceId, create: 'incident'),
            );
            await harness.reveal(
              find.byKey(_UiSmokeHarness.richEditorKey),
              label: '${scenario.name} incident create reveal',
            );
            await harness.expectAnyOnScreen(<Finder>[
              find.byKey(_UiSmokeHarness.richEditorKey),
              find.text('Create Incident'),
              find.text(harness.l10n.text('title')),
            ], label: '${scenario.name} incident create');
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} incident create',
            );
            harness.checkpointNoErrors(
              label: '${scenario.name} incident create',
            );
            await harness.popRoute(
              label: '${scenario.name} close incident create',
            );

            await harness.go('/account');
            await harness.expectOnScreen(
              find.text(_UiSmokeApi.userEmail),
              label: '${scenario.name} account',
            );
            await harness.exerciseVisibleScrollables(
              label: '${scenario.name} account',
            );
            harness.checkpointNoErrors(label: '${scenario.name} account');

            harness.expectNoErrors();
          } finally {
            harness.dispose();
          }
        }
      },
    );
  });
}

/// Boots the app with mocked backend responses and captures framework errors.
class _UiSmokeHarness {
  static const richEditorKey = ValueKey<String>(
    'rich-editor-plain-text-fallback',
  );

  final ProviderContainer container;
  final GoRouter router;
  final _UiSmokeApi api;
  final _UiErrorCollector errors;
  final WidgetTester tester;
  final AppLocalizations l10n;
  final List<String> failures = <String>[];

  _UiSmokeHarness._({
    required this.container,
    required this.router,
    required this.api,
    required this.errors,
    required this.tester,
    required this.l10n,
  });

  static Future<_UiSmokeHarness> pump(
    WidgetTester tester, {
    required Size logicalSize,
    AuthStore? auth,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = logicalSize;

    final errors = _UiErrorCollector()..install();
    final effectiveAuth = auth ?? _buildAuthenticatedAuthStore();
    final serverConfig = ServerConfigController(
      compiledBaseUrl: fallbackLocalApiBaseUrl,
    )..loaded = true;
    final api = _UiSmokeApi(effectiveAuth);

    final container = ProviderContainer(
      overrides: [
        serverConfigProvider.overrideWith((ref) => serverConfig),
        authStoreProvider.overrideWith((ref) => effectiveAuth),
        apiClientProvider.overrideWith((ref) => api.client),
        brandingProvider.overrideWith(
          (ref) async => const BrandingConfig(
            companyName: 'OpsAtlas',
            applicationTitle: 'OpsAtlas',
            applicationShortName: 'OpsAtlas',
            webDescription: defaultBrandingWebDescription,
            appleWebAppTitle: 'OpsAtlas',
            resolvedAppTitle: 'OpsAtlas',
            resolvedApplicationShortName: 'OpsAtlas',
            resolvedWebDescription: defaultBrandingWebDescription,
            resolvedAppleWebAppTitle: 'OpsAtlas',
            resolvedThemeColorHex: '#0F67E8',
            resolvedInstallBackgroundHex: '#0A0D12',
          ),
        ),
        richEditorRenderModeProvider.overrideWith(
          (ref) => RichEditorRenderMode.plainTextFallback,
        ),
      ],
    );

    final harness = _UiSmokeHarness._(
      container: container,
      router: container.read(appRouterProvider),
      api: api,
      errors: errors,
      tester: tester,
      l10n: AppLocalizations(const Locale('en')),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const App()),
    );
    await harness.pumpUntilIdle(label: 'app bootstrap');

    return harness;
  }

  Future<void> pumpUntilIdle({
    String label = 'pump',
    int maxTicks = 40,
    Duration step = const Duration(milliseconds: 80),
  }) async {
    for (var i = 0; i < maxTicks; i++) {
      await tester.pump(step);
      errors.drain(tester, context: label);
      if (!tester.binding.hasScheduledFrame) {
        break;
      }
    }
    errors.drain(tester, context: label);
  }

  Future<void> go(String route) async {
    router.go(route);
    await pumpUntilIdle(label: route);
  }

  Uri get currentUri => router.routeInformationProvider.value.uri;

  Future<void> popRoute({String label = 'pop route'}) async {
    await pumpUntilIdle(label: 'pre-$label');
    if (!router.canPop()) {
      failures.add('Cannot pop route during $label');
      return;
    }
    router.pop();
    await pumpUntilIdle(label: label);
  }

  Future<void> tap(Finder finder, {String label = 'tap'}) async {
    await pumpUntilIdle(label: 'pre-$label');
    if (!_hasMatch(finder, action: label)) {
      failures.add('Missing tappable widget during $label');
      return;
    }
    try {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
    } catch (error) {
      failures.add('Failed to tap during $label: $error');
      return;
    }
    await pumpUntilIdle(label: label);
  }

  Future<void> expectOnScreen(Finder finder, {String? label}) async {
    await pumpUntilIdle(label: 'settle before expect');
    if (!_hasMatch(finder, action: 'expect')) {
      failures.add(
        'Missing expected widget${label == null ? '' : ' ($label)'} on ${router.routeInformationProvider.value.uri}\n'
        'Visible text sample: ${_visibleTextSnapshot()}',
      );
    }
  }

  Future<void> expectAnyOnScreen(List<Finder> finders, {String? label}) async {
    await pumpUntilIdle(label: 'settle before expect any');
    for (final finder in finders) {
      if (_hasMatch(finder, action: 'expect any')) {
        return;
      }
    }
    failures.add(
      'Missing expected widget set${label == null ? '' : ' ($label)'} on ${router.routeInformationProvider.value.uri}\n'
      'Visible text sample: ${_visibleTextSnapshot()}',
    );
  }

  Future<void> reveal(Finder finder, {String label = 'reveal'}) async {
    await pumpUntilIdle(label: 'pre-$label');
    if (_hasMatch(finder, action: label)) {
      return;
    }
    final scrollableCount = find.byType(Scrollable).evaluate().length;
    for (var i = 0; i < scrollableCount; i++) {
      final scrollable = find.byType(Scrollable).at(i);
      if (!_hasMatch(scrollable, action: '$label scrollable $i')) {
        continue;
      }
      try {
        await tester.scrollUntilVisible(
          finder,
          220,
          scrollable: scrollable,
          maxScrolls: 8,
        );
        await pumpUntilIdle(label: '$label scrollable $i');
        if (_hasMatch(finder, action: '$label post-scroll $i')) {
          return;
        }
      } catch (_) {
        // Keep trying other scroll containers until we find the target.
      }
    }
  }

  Future<void> exerciseVisibleScrollables({
    required String label,
    int maxScrollables = 8,
  }) async {
    await pumpUntilIdle(label: 'pre-$label');
    final scrollableCount = find.byType(Scrollable).evaluate().length;
    final limit = scrollableCount < maxScrollables
        ? scrollableCount
        : maxScrollables;
    for (var i = 0; i < limit; i++) {
      final finder = find.byType(Scrollable).at(i);
      if (!_hasMatch(finder, action: '$label scrollable $i')) {
        continue;
      }
      try {
        final state = tester.state<ScrollableState>(finder);
        final position = state.position;
        if (!position.hasContentDimensions || position.maxScrollExtent <= 0) {
          continue;
        }
        position.jumpTo(position.maxScrollExtent);
        await pumpUntilIdle(label: '$label scrollable $i max');
        position.jumpTo(0);
        await pumpUntilIdle(label: '$label scrollable $i reset');
      } catch (error) {
        failures.add('Failed to sweep scrollable $i during $label: $error');
      }
    }
  }

  Future<void> openDesktopNotifications() async {
    await tap(
      find.byTooltip(l10n.text('notifications')).first,
      label: 'open desktop notifications',
    );
    await expectOnScreen(find.text(l10n.text('notifications')));
  }

  Future<void> openMobileNotifications() async {
    await tap(
      find.byTooltip(l10n.text('more')).first,
      label: 'open mobile drawer',
    );
    await tap(
      find.text(l10n.text('notifications')).last,
      label: 'open mobile notifications',
    );
    await expectOnScreen(find.text(l10n.text('notifications')));
  }

  Future<void> closeNotifications() async {
    await tap(
      find.byIcon(Icons.arrow_back).first,
      label: 'close notifications',
    );
  }

  Future<void> collapseDesktopSidebar() async {
    await tap(
      find.byIcon(Icons.keyboard_double_arrow_left).first,
      label: 'collapse desktop sidebar',
    );
    await expectOnScreen(
      find.byIcon(Icons.keyboard_double_arrow_right).first,
      label: 'desktop sidebar collapsed',
    );
  }

  bool _hasMatch(Finder finder, {required String action}) {
    try {
      return finder.evaluate().isNotEmpty;
    } catch (error) {
      failures.add('Finder evaluation failed during $action: $error');
      return false;
    }
  }

  String _visibleTextSnapshot({int limit = 20}) {
    final seen = <String>{};
    final visible = <String>[];
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final data = text.data?.trim();
      if (data == null || data.isEmpty || !seen.add(data)) {
        continue;
      }
      visible.add(data);
      if (visible.length >= limit) {
        break;
      }
    }
    return visible.isEmpty ? '<none>' : visible.join(' | ');
  }

  void expectNoErrors() {
    errors.drain(tester, context: 'final drain');
    errors.restore();
    final failures = <String>[
      ...this.failures,
      ...errors.messages,
      ...api.unhandledRequests.map((request) => 'Unhandled request: $request'),
    ];
    expect(
      failures,
      isEmpty,
      reason: failures.isEmpty ? null : failures.join('\n\n'),
    );
  }

  void checkpointNoErrors({required String label}) {
    errors.drain(tester, context: label);
    final failures = <String>[
      ...this.failures,
      ...errors.messages,
      ...api.unhandledRequests.map((request) => 'Unhandled request: $request'),
    ];
    errors.restore();
    expect(
      failures,
      isEmpty,
      reason: failures.isEmpty ? null : '$label\n\n${failures.join('\n\n')}',
    );
    errors.install();
    this.failures.clear();
    errors.messages.clear();
    errors._dedupedMessages.clear();
    api.unhandledRequests.clear();
  }

  void dispose() {
    container.dispose();
    errors.restore();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

class _UiErrorCollector {
  final List<String> messages = <String>[];
  final Set<String> _dedupedMessages = <String>{};
  bool Function(Object, StackTrace)? _previousPlatformHandler;
  void Function(FlutterErrorDetails)? _previousFlutterErrorHandler;
  bool _installed = false;

  void install() {
    if (_installed) {
      return;
    }
    _installed = true;
    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _record(_describeFlutterErrorDetails(details));
    };
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      _record(_describeError(error));
      return true;
    };
  }

  void drain(WidgetTester tester, {required String context}) {
    Object? error;
    while ((error = tester.takeException()) != null) {
      _record('[$context] ${_describeError(error!)}');
    }
  }

  void restore() {
    if (!_installed) {
      return;
    }
    _installed = false;
    PlatformDispatcher.instance.onError = _previousPlatformHandler;
    FlutterError.onError = _previousFlutterErrorHandler;
  }

  String _describeError(Object error) {
    if (error is FlutterError) {
      return error.toStringDeep();
    }
    return error.toString();
  }

  String _describeFlutterErrorDetails(FlutterErrorDetails details) {
    return details.toString();
  }

  void _record(String message) {
    if (_dedupedMessages.add(message)) {
      messages.add(message);
    }
  }
}

AuthStore _buildAuthenticatedAuthStore({
  String role = 'admin',
  bool mfaVerified = true,
  String sessionId = 'session-current',
}) {
  final auth = AuthStore();
  auth
    ..token = _jwtFor(
      role: role,
      mfaVerified: mfaVerified,
      sessionId: sessionId,
    )
    ..refreshToken = 'refresh-token'
    ..sessionId = sessionId
    ..role = role
    ..mfaVerified = mfaVerified
    ..loaded = true;
  return auth;
}

AuthStore _buildLoggedOutAuthStore() {
  final auth = AuthStore();
  auth
    ..token = null
    ..refreshToken = null
    ..sessionId = null
    ..role = null
    ..mfaVerified = false
    ..loaded = true;
  return auth;
}

String _jwtFor({
  required String role,
  required bool mfaVerified,
  required String sessionId,
}) {
  final header = base64Url
      .encode(utf8.encode('{"alg":"none","typ":"JWT"}'))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode(<String, Object>{
            'sub': _UiSmokeApi.userId,
            'role': role,
            'mfa': mfaVerified,
            'sid': sessionId,
            'exp':
                DateTime.now()
                    .add(const Duration(days: 30))
                    .millisecondsSinceEpoch ~/
                1000,
          }),
        ),
      )
      .replaceAll('=', '');
  return '$header.$payload.signature';
}

class _UiSmokeApi {
  static const String userId = 'user-admin';
  static const String reviewerId = 'user-reviewer';
  static const String userEmail = 'alice@opsatlas.test';
  static const String spaceId = '4196320b-00d8-547f-ad67-479843a9feae';
  static const String spaceName = 'Operations HQ';
  static const String taskPrimaryId = 'task-follow-up-1';
  static const String taskPrimaryTitle = 'Write incident follow-up';
  static const String taskSecondaryId = 'task-refund-1';
  static const String taskSopRunTitle = 'Complete refund escalation run';
  static const String kbFolderPrimaryId =
      'ee77b29d-9a45-5e38-98f7-07ac31c8b1b9';
  static const String kbFolderSecondaryId =
      '986f2101-4fc3-58c4-a077-15a81d71b893';
  static const String kbDocPrimaryId = '806f43cf-b021-5528-9353-948b17a12643';
  static const String kbDocSecondaryId = '10226477-f16d-5122-ae4f-cbc1fe2d221e';
  static const String kbDocPrimaryTitle = 'Refund Eligibility Matrix';
  static const String kbDocSecondaryTitle = 'Routing Escalation SOP Notes';
  static const String sopId = 'ee837010-2ef9-55ac-a1ed-5752c7a81840';
  static const String sopRunId = 'e5994ae3-cc46-4331-9a04-ffabc112c6e0';
  static const String sopStepId = '5f07b68b-c186-44f2-8fbf-5b02ce41cb6f';
  static const String sopTitle = 'Refund Escalation Runbook';
  static const String incidentId = '9766052a-60f8-56e4-8fe4-5b73d7a16975';
  static const String incidentTimelineId = 'timeline-1';
  static const String incidentActionItemId = 'action-item-1';
  static const String incidentTitle = 'Payments API latency spike';
  static const String incidentTemplateId = 'template-payments-major';
  static const String orgUnitId = 'department-ops';
  static const String orgUnitName = 'Operations Region';
  static const String mediaAssetId = 'asset-brand-mark';
  static const String mediaAssetName = 'brand-mark.png';
  static const String backupSnapshotId = 'snapshot-2026-06-18-full';
  static const String backupSnapshotIncrementalId =
      'snapshot-2026-06-17-incremental';
  static const String snapshotManifestPath = '/exports/manifest.json';
  static const String snapshotManifestName = 'manifest.json';

  final AuthStore auth;
  final ApiClient client;
  final List<String> unhandledRequests = <String>[];
  final Map<String, dynamic> _dashboardPrefs = <String, dynamic>{
    'selected_space_id': spaceId,
    'widget_order': <String>[
      'profile_actions',
      'my_tasks',
      'incident_queue',
      'due_runs',
      'mentions',
      'activity_feed',
      'spaces_overview',
    ],
    'hidden_widgets': <String>[],
  };
  final Map<String, dynamic> _notificationPrefs = <String, dynamic>{
    'include_view': false,
    'include_search': false,
    'include_publish': true,
    'include_task': true,
    'digest_mode': 'realtime',
    'digest_hour': 9,
    'digest_minute': 0,
  };
  late final List<Map<String, dynamic>> _activeSessions;
  late final List<Map<String, dynamic>> _revokedSessions;

  _UiSmokeApi(this.auth) : client = ApiClient(auth) {
    final currentSessionId = (auth.sessionId ?? '').trim().isEmpty
        ? 'session-current'
        : auth.sessionId!.trim();
    _activeSessions = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': currentSessionId,
        'label': 'Current MacBook',
        'created_at': '2026-06-17T08:30:00Z',
        'last_seen_at': '2026-06-18T08:30:00Z',
        'current': true,
        'ip_address': '203.0.113.11',
        'user_agent': 'Chrome',
      },
      <String, dynamic>{
        'id': 'session-tablet',
        'label': 'iPad Safari',
        'created_at': '2026-06-15T08:30:00Z',
        'last_seen_at': '2026-06-18T07:00:00Z',
        'current': false,
        'ip_address': '203.0.113.12',
        'user_agent': 'Safari',
      },
    ];
    _revokedSessions = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'session-revoked',
        'label': 'Old Safari on iPhone',
        'created_at': '2026-06-01T08:30:00Z',
        'revoked_at': '2026-06-10T08:30:00Z',
        'current': false,
        'ip_address': '203.0.113.10',
        'user_agent': 'Safari',
      },
    ];
    client.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final data = _resolve(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
  }

  Object? _resolve(RequestOptions options) {
    final method = options.method.toUpperCase();
    final path = options.uri.path;
    final query = options.queryParameters;

    if (path == '/analytics/events' && method == 'POST') {
      return const <String, dynamic>{'ok': true};
    }
    if (path == '/auth/logout' && method == 'POST') {
      final currentSessionId = (auth.sessionId ?? '').trim();
      final revoked = currentSessionId.isNotEmpty
          ? _revokeSession(currentSessionId, reason: 'logout')
          : false;
      return <String, dynamic>{'ok': true, 'revoked': revoked};
    }
    if (path == '/auth/session/policy' && method == 'GET') {
      return <String, dynamic>{
        'allow_remember_device': true,
        'default_profile': 'this_browser',
        'this_browser_days': 1,
        'remember_device_days': 14,
        'warning_minutes': 15,
        'available_profiles': const <String>['this_browser', 'remember_device'],
      };
    }
    if (path == '/auth/me' && method == 'GET') {
      return <String, dynamic>{
        'id': userId,
        'name': 'Alice Admin',
        'email': userEmail,
        'global_role': auth.role ?? 'admin',
      };
    }
    if (path == '/auth/me/dashboard-preferences') {
      if (method == 'PATCH' && options.data is Map) {
        _dashboardPrefs.addAll((options.data as Map).cast<String, dynamic>());
      }
      return _dashboardPrefs;
    }
    if (path == '/auth/me/notification-preferences') {
      if (method == 'PATCH' && options.data is Map) {
        _notificationPrefs.addAll(
          (options.data as Map).cast<String, dynamic>(),
        );
      }
      return Map<String, dynamic>.from(_notificationPrefs);
    }
    if (path == '/auth/me/session-status' && method == 'GET') {
      return <String, dynamic>{
        'warning_active': false,
        'session_profile': 'this_browser',
        'expires_in_seconds': 3600,
      };
    }
    if (path == '/auth/me/mfa/status' && method == 'GET') {
      return <String, dynamic>{
        'enabled': true,
        'verified': true,
        'recovery_codes_remaining': 6,
      };
    }
    if (path == '/auth/me/sessions' && method == 'GET') {
      final scope = (query['scope'] ?? 'active').toString();
      if (scope == 'revoked') {
        return _copySessions(_revokedSessions);
      }
      return _copySessions(_activeSessions);
    }
    if (path == '/auth/me/sessions/revoke-others' && method == 'POST') {
      final currentSessionId = (auth.sessionId ?? '').trim();
      final idsToRevoke = _activeSessions
          .where((session) => session['id'] != currentSessionId)
          .map((session) => session['id'].toString())
          .toList(growable: false);
      for (final sessionId in idsToRevoke) {
        _revokeSession(sessionId, reason: 'manual_revoke_others');
      }
      return <String, dynamic>{
        'ok': true,
        'revoked_count': idsToRevoke.length,
        'current_session_id': currentSessionId,
      };
    }
    final revokeSessionMatch = RegExp(
      r'^/auth/me/sessions/([^/]+)/revoke$',
    ).firstMatch(path);
    if (revokeSessionMatch != null && method == 'POST') {
      final sessionId = revokeSessionMatch.group(1) ?? '';
      final revoked = _revokeSession(sessionId, reason: 'manual_revoke');
      return <String, dynamic>{
        'ok': true,
        'revoked': revoked,
        'session_id': sessionId,
      };
    }
    if (path == '/localization/runtime' && method == 'GET') {
      return <String, dynamic>{
        'catalog': <String, dynamic>{
          'default_language_code': 'en',
          'organization_fallback_order': <String>['en'],
          'languages': <Map<String, dynamic>>[
            <String, dynamic>{
              'code': 'en',
              'name': 'English',
              'enabled': true,
              'is_default': true,
              'is_rtl': false,
              'fallback_order': <String>['en'],
              'bundle_version': 1,
            },
          ],
        },
        'user_preference': <String, dynamic>{
          'language_code': 'en',
          'use_org_default': false,
        },
        'bundles': const <String, dynamic>{},
      };
    }
    if (path == '/spaces' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': spaceId,
          'name': spaceName,
          'slug': 'operations-hq',
          'member_count': 12,
          'open_task_count': 7,
          'open_incident_count': 1,
        },
        <String, dynamic>{
          'id': 'space-archive',
          'name': 'Archive',
          'slug': 'archive',
          'member_count': 3,
          'open_task_count': 0,
          'open_incident_count': 0,
        },
      ];
    }
    if (path == '/tasks/my' && method == 'GET') {
      return _tasks();
    }
    if (path == '/tasks/spaces/$spaceId' && method == 'GET') {
      return _tasks();
    }
    if (path == '/analytics/feed' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'feed-1',
          'event_type': 'view',
          'entity_type': 'doc',
          'entity_id': kbDocPrimaryId,
          'entity_title': kbDocPrimaryTitle,
          'space_id': spaceId,
          'path': _spaceRoute(spaceId, docId: kbDocPrimaryId),
          'created_at': '2026-06-18T09:00:00Z',
          'ts': '2026-06-18T09:00:00Z',
          'meta': <String, dynamic>{
            'title': kbDocPrimaryTitle,
            'space_name': spaceName,
          },
        },
        <String, dynamic>{
          'id': 'feed-2',
          'event_type': 'incident_action_reminder',
          'entity_type': 'incident_action_item',
          'entity_id': incidentActionItemId,
          'space_id': spaceId,
          'created_at': '2026-06-18T08:30:00Z',
          'ts': '2026-06-18T08:30:00Z',
          'meta': <String, dynamic>{
            'incident_id': incidentId,
            'incident_title': incidentTitle,
            'message': 'Review the delayed refunds queue.',
            'space_id': spaceId,
          },
        },
      ];
    }
    if (path == '/analytics/spaces/$spaceId/top/doc' && method == 'GET') {
      return _analyticsTopDocs();
    }
    if (path == '/analytics/spaces/$spaceId/top/sop' && method == 'GET') {
      return _analyticsTopSops();
    }
    if (path == '/analytics/spaces/$spaceId/top/incident' && method == 'GET') {
      return _analyticsTopIncidents();
    }
    if (path == '/analytics/spaces/$spaceId/top/task' && method == 'GET') {
      return _analyticsTopTasks();
    }
    if (path == '/analytics/spaces/$spaceId/search-quality' &&
        method == 'GET') {
      return <String, dynamic>{
        'query_count': 84,
        'parse_diagnostic_rate': 0.08,
        'suggestion_acceptance_rate': 0.23,
        'zero_result_recovery_rate': 0.67,
        'average_refinement_depth': 1.4,
      };
    }
    if (path == '/analytics/spaces/$spaceId/trends' && method == 'GET') {
      final eventTypes = (query['event_types'] ?? '').toString();
      if (eventTypes.contains('search_query_issued')) {
        return _analyticsSearchTrend();
      }
      return _analyticsUsageTrend();
    }
    if (path == '/kb/spaces/$spaceId/mentions' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'mention-1',
          'space_id': spaceId,
          'doc_id': kbDocPrimaryId,
          'doc_title': kbDocPrimaryTitle,
          'comment_excerpt': 'Need legal sign-off on duplicate charge policy.',
          'created_at': '2026-06-18T07:45:00Z',
        },
      ];
    }
    if (path == '/kb/spaces/$spaceId/folders' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': kbFolderPrimaryId,
          'name': 'Refunds',
          'path': 'Refunds',
          'parent_id': null,
        },
        <String, dynamic>{
          'id': kbFolderSecondaryId,
          'name': 'Escalations',
          'path': 'Refunds / Escalations',
          'parent_id': kbFolderPrimaryId,
        },
      ];
    }
    if (path == '/kb/spaces/$spaceId/docs' && method == 'GET') {
      final folderId = (query['folder_id'] ?? '').toString().trim();
      if (folderId == kbFolderPrimaryId) {
        return <Map<String, dynamic>>[_kbDocPrimary()];
      }
      if (folderId == kbFolderSecondaryId) {
        return <Map<String, dynamic>>[_kbDocSecondary()];
      }
      return <Map<String, dynamic>>[_kbDocPrimary(), _kbDocSecondary()];
    }
    if (path == '/kb/spaces/$spaceId/tags' && method == 'GET') {
      return <String, dynamic>{
        'tags': <String>['billing', 'refunds', 'routing', 'triage'],
      };
    }
    if (path == '/kb/spaces/$spaceId/review-summary' && method == 'GET') {
      return <String, dynamic>{
        'total_docs': 2,
        'stale_docs': 1,
        'trashed_docs': 0,
        'docs_due_for_review': 1,
      };
    }
    if (path == '/kb/spaces/$spaceId/search-suggestions' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'query': 'refund window',
          'source': 'popular',
          'language_code': 'en',
        },
        <String, dynamic>{
          'query': 'charge dispute',
          'source': 'synonym',
          'language_code': 'en',
        },
      ];
    }
    if (path == '/kb/spaces/$spaceId/reviewer-suggestions' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': reviewerId,
          'name': 'Mina Moderator',
          'open_reviews': 2,
        },
      ];
    }
    if (path == '/kb/docs/$kbDocPrimaryId/detail' && method == 'GET') {
      return _kbDocPrimary();
    }
    if (path == '/kb/docs/$kbDocSecondaryId/detail' && method == 'GET') {
      return _kbDocSecondary();
    }
    if (path == '/kb/docs/$kbDocPrimaryId/versions' && method == 'GET') {
      return _kbVersions();
    }
    if (path == '/kb/docs/$kbDocSecondaryId/versions' && method == 'GET') {
      return _kbVersions();
    }
    if (path == '/kb/docs/$kbDocPrimaryId/comments' && method == 'GET') {
      return _kbComments();
    }
    if (path == '/kb/docs/$kbDocSecondaryId/comments' && method == 'GET') {
      return _kbComments();
    }
    if (path == '/kb/docs/$kbDocPrimaryId/diff' && method == 'GET') {
      return _kbDiff();
    }
    if (path == '/kb/docs/$kbDocSecondaryId/diff' && method == 'GET') {
      return _kbDiff();
    }
    if (path == '/sop/spaces/$spaceId/due-runs' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'due-run-1',
          'sop_id': sopId,
          'title': sopTitle,
          'slug': 'refund-escalation-runbook',
          'next_due_at': '2026-06-19T09:00:00Z',
          'operator_name': 'Mina Moderator',
          'overdue': false,
        },
      ];
    }
    if (path == '/sop/spaces/$spaceId/sops' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': sopId,
          'title': sopTitle,
          'slug': 'refund-escalation-runbook',
          'status': 'draft',
          'reviewer_name': 'Alice Admin',
          'pending_approval': true,
          'updated_at': '2026-06-18T08:00:00Z',
          'linked_task_count': 1,
        },
      ];
    }
    if (path == '/sop/sops/$sopId/detail' && method == 'GET') {
      return _sopDetail();
    }
    if (path == '/incidents/spaces/$spaceId' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': incidentId,
          'space_id': spaceId,
          'title': incidentTitle,
          'summary': 'Payment API timed out for checkout traffic.',
          'status': 'monitoring',
          'severity': 2,
          'on_call_user_name': 'Alice Admin',
          'open_action_items': 1,
          'linked_task_count': 1,
          'created_at': '2026-06-18T06:15:00Z',
          'updated_at': '2026-06-18T08:20:00Z',
          'archived': false,
        },
      ];
    }
    if (path == '/incidents/spaces/$spaceId/analytics' && method == 'GET') {
      return <String, dynamic>{
        'open_incidents': 0,
        'monitoring_incidents': 1,
        'resolved_incidents': 3,
        'total_incidents': 4,
        'avg_mttr_minutes': 47,
      };
    }
    if (path == '/incidents/spaces/$spaceId/templates' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'id': incidentTemplateId,
          'name': 'Payments major incident',
          'severity': 2,
          'incident_type': 'service',
          'title_template': 'Major payments incident',
          'active': true,
        },
      ];
    }
    if (path == '/incidents/$incidentId' && method == 'GET') {
      return _incidentDetail();
    }
    if (path == '/spaces/$spaceId/members/detailed' && method == 'GET') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': userId,
          'name': 'Alice Admin',
          'email': userEmail,
          'role': 'admin',
        },
        <String, dynamic>{
          'user_id': reviewerId,
          'name': 'Mina Moderator',
          'email': 'mina@opsatlas.test',
          'role': 'moderator',
        },
      ];
    }
    if (path == '/admin/customization' && method == 'GET') {
      return <String, dynamic>{
        'published': <String, dynamic>{
          'company_name': 'OpsAtlas',
          'browser_theme_hex': '#0F67E8',
        },
        'draft': <String, dynamic>{
          'company_name': 'OpsAtlas',
          'browser_theme_hex': '#0F67E8',
        },
        'history': const <Map<String, dynamic>>[],
        'has_unpublished_changes': false,
      };
    }
    if (path == '/admin/org/items' && method == 'GET') {
      return _organizationItems();
    }
    if (path == '/admin/org/item-links' && method == 'GET') {
      return _organizationItemLinks();
    }
    if (path == '/admin/backups/snapshots' && method == 'GET') {
      return <String, dynamic>{'snapshots': _backupSnapshots()};
    }
    if (path == '/admin/backups/snapshots/$backupSnapshotId/tree' &&
        method == 'GET') {
      return <String, dynamic>{
        'path': (query['path'] ?? '/').toString(),
        'children': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'file',
            'name': snapshotManifestName,
            'path': snapshotManifestPath,
          },
          <String, dynamic>{
            'type': 'folder',
            'name': 'logs',
            'path': '/exports/logs',
          },
        ],
      };
    }
    if (path == '/admin/backups/snapshots/$backupSnapshotId/node' &&
        method == 'GET') {
      return <String, dynamic>{
        'content': '{"snapshot":"$backupSnapshotId","space":"$spaceName"}',
      };
    }
    if (path == '/media/summary' && method == 'GET') {
      return <String, dynamic>{
        'folders': <Map<String, dynamic>>[
          <String, dynamic>{'folder_path': '/branding'},
          <String, dynamic>{'folder_path': '/incident-reports'},
        ],
        'tags': <Map<String, dynamic>>[
          <String, dynamic>{'tag': 'branding'},
          <String, dynamic>{'tag': 'incident'},
        ],
        'expired_assets': 1,
        'total_assets': 2,
      };
    }
    if (path == '/media/page' && method == 'GET') {
      return <String, dynamic>{
        'items': _mediaAssets(),
        'total': 2,
        'has_more': false,
      };
    }
    if (path == '/media/policy' && method == 'GET') {
      return <String, dynamic>{
        'max_upload_mb': 25,
        'allowed_extensions': <String>['png', 'jpg', 'jpeg', 'pdf', 'md'],
        'allowed_mime_types': <String>[
          'image/png',
          'image/jpeg',
          'application/pdf',
          'text/markdown',
        ],
      };
    }
    if (path == '/media/attachments' && method == 'GET') {
      return const <Map<String, dynamic>>[];
    }

    if (method == 'POST' ||
        method == 'PUT' ||
        method == 'PATCH' ||
        method == 'DELETE') {
      return const <String, dynamic>{'ok': true};
    }

    unhandledRequests.add('$method $path ${jsonEncode(query)}');
    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _copySessions(List<Map<String, dynamic>> source) {
    return source
        .map((session) => Map<String, dynamic>.from(session))
        .toList(growable: false);
  }

  bool _revokeSession(String sessionId, {required String reason}) {
    final index = _activeSessions.indexWhere(
      (session) => session['id'] == sessionId,
    );
    if (index == -1) {
      return false;
    }
    final session = Map<String, dynamic>.from(_activeSessions.removeAt(index));
    session
      ..remove('last_seen_at')
      ..['current'] = false
      ..['revoked_at'] = '2026-06-18T10:30:00Z'
      ..['revoke_reason'] = reason;
    _revokedSessions.insert(0, session);
    return true;
  }

  List<Map<String, dynamic>> _tasks() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': taskPrimaryId,
        'space_id': spaceId,
        'space_name': spaceName,
        'title': taskPrimaryTitle,
        'description': 'Turn the incident timeline into follow-up work.',
        'status': 'in_progress',
        'priority': 'high',
        'assignee_user_id': userId,
        'assignee_name': 'Alice Admin',
        'due_at': '2026-06-19T09:00:00Z',
        'source_kind': 'incident_action_item',
        'source_id': incidentId,
        'source_step_id': incidentActionItemId,
      },
      <String, dynamic>{
        'id': taskSecondaryId,
        'space_id': spaceId,
        'space_name': spaceName,
        'title': taskSopRunTitle,
        'description':
            'Continue the refund escalation SOP run from the tracker.',
        'status': 'todo',
        'priority': 'medium',
        'assignee_user_id': reviewerId,
        'assignee_name': 'Mina Moderator',
        'due_at': '2026-06-21T09:00:00Z',
        'source_kind': 'sop_run',
        'source_id': sopId,
        'source_step_id': sopStepId,
      },
    ];
  }

  List<Map<String, dynamic>> _analyticsTopDocs() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'entity_id': kbDocPrimaryId,
        'title': kbDocPrimaryTitle,
        'views': 34,
        'path': _spaceRoute(spaceId, docId: kbDocPrimaryId),
      },
      <String, dynamic>{
        'entity_id': kbDocSecondaryId,
        'title': kbDocSecondaryTitle,
        'views': 18,
        'path': _spaceRoute(spaceId, docId: kbDocSecondaryId),
      },
    ];
  }

  List<Map<String, dynamic>> _analyticsTopSops() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'entity_id': sopId,
        'title': sopTitle,
        'views': 21,
        'path': _spaceRoute(spaceId, sopId: sopId),
      },
    ];
  }

  List<Map<String, dynamic>> _analyticsTopIncidents() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'entity_id': incidentId,
        'title': incidentTitle,
        'views': 9,
        'path': _spaceRoute(spaceId, incidentId: incidentId),
      },
    ];
  }

  List<Map<String, dynamic>> _analyticsTopTasks() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'entity_id': taskPrimaryId,
        'title': taskPrimaryTitle,
        'views': 14,
        'path': '/tasks',
      },
    ];
  }

  List<Map<String, dynamic>> _analyticsUsageTrend() {
    return <Map<String, dynamic>>[
      <String, dynamic>{'bucket_label': 'Jun 14', 'count': 8},
      <String, dynamic>{'bucket_label': 'Jun 15', 'count': 12},
      <String, dynamic>{'bucket_label': 'Jun 16', 'count': 10},
      <String, dynamic>{'bucket_label': 'Jun 17', 'count': 16},
      <String, dynamic>{'bucket_label': 'Jun 18', 'count': 19},
    ];
  }

  List<Map<String, dynamic>> _analyticsSearchTrend() {
    return <Map<String, dynamic>>[
      <String, dynamic>{'bucket_label': 'Jun 14', 'count': 5},
      <String, dynamic>{'bucket_label': 'Jun 15', 'count': 7},
      <String, dynamic>{'bucket_label': 'Jun 16', 'count': 9},
      <String, dynamic>{'bucket_label': 'Jun 17', 'count': 11},
      <String, dynamic>{'bucket_label': 'Jun 18', 'count': 13},
    ];
  }

  List<Map<String, dynamic>> _organizationItems() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'department',
        'details': <String, dynamic>{
          'id': orgUnitId,
          'name': orgUnitName,
          'code': 'OPS',
          'active': true,
          'meta': <String, dynamic>{'default_language_code': 'en'},
        },
      },
      <String, dynamic>{
        'kind': 'space',
        'details': <String, dynamic>{
          'id': spaceId,
          'name': spaceName,
          'slug': 'operations-hq',
          'active': true,
        },
      },
      <String, dynamic>{
        'kind': 'user',
        'details': <String, dynamic>{
          'id': userId,
          'name': 'Alice Admin',
          'email': userEmail,
          'active': true,
        },
      },
      <String, dynamic>{
        'kind': 'user',
        'details': <String, dynamic>{
          'id': reviewerId,
          'name': 'Mina Moderator',
          'email': 'mina@opsatlas.test',
          'active': true,
        },
      },
    ];
  }

  List<Map<String, dynamic>> _organizationItemLinks() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'parent_kind': 'department',
        'parent_id': orgUnitId,
        'child_kind': 'space',
        'child_id': spaceId,
        'active': true,
        'inherit_to_descendants': true,
      },
      <String, dynamic>{
        'parent_kind': 'department',
        'parent_id': orgUnitId,
        'child_kind': 'user',
        'child_id': userId,
        'active': true,
      },
      <String, dynamic>{
        'parent_kind': 'department',
        'parent_id': orgUnitId,
        'child_kind': 'user',
        'child_id': reviewerId,
        'active': true,
      },
      <String, dynamic>{
        'parent_kind': 'role',
        'parent_id': 'admin',
        'child_kind': 'user',
        'child_id': userId,
        'active': true,
      },
      <String, dynamic>{
        'parent_kind': 'role',
        'parent_id': 'moderator',
        'child_kind': 'user',
        'child_id': reviewerId,
        'active': true,
      },
    ];
  }

  List<Map<String, dynamic>> _backupSnapshots() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': backupSnapshotId,
        'mode': 'full',
        'created_at_ms': 1718697600000,
      },
      <String, dynamic>{
        'id': backupSnapshotIncrementalId,
        'mode': 'incremental',
        'created_at_ms': 1718611200000,
      },
    ];
  }

  List<Map<String, dynamic>> _mediaAssets() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': mediaAssetId,
        'name': mediaAssetName,
        'folder_path': '/branding',
        'tags': <String>['branding'],
        'access_mode': 'space_members',
        'expires_at': null,
        'space_id': spaceId,
        'space_name': spaceName,
        'content_type': 'image/png',
        'usage': 'branding',
      },
      <String, dynamic>{
        'id': 'asset-incident-report',
        'name': 'incident-timeline.pdf',
        'folder_path': '/incident-reports',
        'tags': <String>['incident'],
        'access_mode': 'owner_only',
        'expires_at': '2026-06-30T09:00:00Z',
        'space_id': spaceId,
        'space_name': spaceName,
        'content_type': 'application/pdf',
        'usage': 'attachment',
      },
    ];
  }

  Map<String, dynamic> _kbDocPrimary() {
    return <String, dynamic>{
      'id': kbDocPrimaryId,
      'title': kbDocPrimaryTitle,
      'slug': 'refund-eligibility-matrix',
      'folder_id': kbFolderPrimaryId,
      'status': 'published',
      'content_md':
          '# Refund Eligibility Matrix\n\n| Scenario | Window | Approval | Notes |\n| --- | --- | --- | --- |\n| Duplicate charge | 30 days | Tier-1 | Verify processor settlement IDs |\n| Damaged item | 14 days | Tier-1 | Photo required for shipped orders |\n| Subscription renewal dispute | 7 days | Billing lead | Check cancellation timestamp |\n| Fraud claim | N/A | Payments team | Escalate immediately |',
      'tags': <String>['refunds', 'billing'],
      'review_due_at': '2026-06-28T09:00:00Z',
      'review_reminder_days': 3,
      'reviewer_user_id': reviewerId,
      'reviewer_name': 'Mina Moderator',
      'is_stale': false,
      'mentions': 1,
      'created_at': '2026-06-01T08:00:00Z',
      'updated_at': '2026-06-18T07:30:00Z',
      'deleted_at': null,
      'trash_expires_at': null,
    };
  }

  Map<String, dynamic> _kbDocSecondary() {
    return <String, dynamic>{
      'id': kbDocSecondaryId,
      'title': kbDocSecondaryTitle,
      'slug': 'routing-escalation-notes',
      'folder_id': kbFolderSecondaryId,
      'status': 'draft',
      'content_md':
          '## Routing notes\n\nUse the billing lead when cancellation timestamps conflict with processor settlement windows.',
      'tags': <String>['routing', 'triage'],
      'review_due_at': '2026-06-25T09:00:00Z',
      'review_reminder_days': 7,
      'reviewer_user_id': userId,
      'reviewer_name': 'Alice Admin',
      'is_stale': true,
      'mentions': 0,
      'created_at': '2026-06-03T08:00:00Z',
      'updated_at': '2026-06-17T12:00:00Z',
      'deleted_at': null,
      'trash_expires_at': null,
    };
  }

  List<Map<String, dynamic>> _kbVersions() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'version-2',
        'name': 'v2',
        'author_name': 'Alice Admin',
        'created_at': '2026-06-18T07:30:00Z',
      },
      <String, dynamic>{
        'id': 'version-1',
        'name': 'v1',
        'author_name': 'Mina Moderator',
        'created_at': '2026-06-10T10:00:00Z',
      },
    ];
  }

  List<Map<String, dynamic>> _kbComments() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'comment-1',
        'author_name': 'Mina Moderator',
        'body_md': 'Please add a note about processor settlement mismatches.',
        'created_at': '2026-06-18T07:45:00Z',
      },
    ];
  }

  Map<String, dynamic> _kbDiff() {
    return <String, dynamic>{
      'from_label': 'v1',
      'to_label': 'v2',
      'diff_html': '<p>Updated approval path for subscription disputes.</p>',
      'rows': <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'replace',
          'left_line_no': 4,
          'right_line_no': 4,
          'left_text': 'Tier-1',
          'right_text': 'Billing lead',
        },
      ],
    };
  }

  Map<String, dynamic> _sopDetail() {
    return <String, dynamic>{
      'id': sopId,
      'title': sopTitle,
      'slug': 'refund-escalation-runbook',
      'status': 'draft',
      'overview_md':
          '## Overview\n\nUse this runbook when refund disputes need cross-team triage.',
      'review_due_at': '2026-06-29T09:00:00Z',
      'reviewer_name': 'Alice Admin',
      'reviewer_user_id': userId,
      'requires_approval': true,
      'pending_approval': true,
      'approval_stages': <Map<String, dynamic>>[
        <String, dynamic>{
          'stage_order': 1,
          'label': 'Ops approval',
          'approver_name': 'Alice Admin',
          'effective_approver_name': 'Alice Admin',
          'approved_at': null,
          'approved_by_name': null,
          'approved_by': null,
          'delegate_approver_name': null,
        },
      ],
      'run_schedules': <Map<String, dynamic>>[
        <String, dynamic>{
          'enabled': true,
          'cadence_days': 7,
          'next_due_at': '2026-06-19T09:00:00Z',
          'operator_name': 'Mina Moderator',
          'operator_user_id': reviewerId,
          'recent_dispatches': const <dynamic>[],
        },
      ],
      'steps': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': sopStepId,
          'step_order': 1,
          'title': 'Confirm processor settlement',
          'body_md': 'Cross-check settlement IDs against the payment gateway.',
          'requires_evidence': true,
          'evidence_required': true,
          'evidence_min_files': 1,
          'evidence_allowed_extensions': <String>['png', 'pdf'],
          'follow_up_task_id': taskPrimaryId,
          'follow_up_incident_id': incidentId,
        },
        <String, dynamic>{
          'id': 'sop-step-2',
          'step_order': 2,
          'title': 'Notify billing lead',
          'body_md': 'Escalate to billing when cancellation timing is unclear.',
          'requires_evidence': false,
          'evidence_required': false,
          'evidence_min_files': 0,
          'evidence_allowed_extensions': <String>[],
        },
      ],
      'runs': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': sopRunId,
          'status': 'active',
          'created_at': '2026-06-18T06:40:00Z',
          'started_at': '2026-06-18T06:45:00Z',
          'completed_at': null,
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': sopStepId,
              'step_id': sopStepId,
              'title': 'Confirm processor settlement',
              'completed': false,
              'evidence_note': '',
              'requires_evidence': true,
              'evidence_required': true,
              'evidence_min_files': 1,
              'evidence_allowed_extensions': <String>['png', 'pdf'],
              'follow_up_task_id': taskPrimaryId,
            },
          ],
          'sign_off_history': const <dynamic>[],
        },
      ],
      'archived_at': null,
    };
  }

  Map<String, dynamic> _incidentDetail() {
    return <String, dynamic>{
      'id': incidentId,
      'space_id': spaceId,
      'slug': 'payments-api-latency-spike',
      'title': incidentTitle,
      'status': 'monitoring',
      'severity': 2,
      'incident_type': 'service',
      'summary_md':
          '## Summary\n\nA brief database saturation event caused elevated latency for payment API calls.',
      'postmortem_md':
          '## Postmortem\n\nCaching thresholds were too low for the traffic spike. We increased pool size and added alerting.',
      'on_call_user_id': userId,
      'on_call_user_name': 'Alice Admin',
      'customer_facing': true,
      'public_status_enabled': true,
      'private_status_enabled': true,
      'escalation_status': 'active',
      'escalation_policy': 'Payments primary',
      'escalation_notes': 'Vendor bridge open.',
      'blast_radius': 'Checkout API',
      'blast_radius_summary': '8% of payment attempts failed.',
      'category': 'payments',
      'impacted_services': <String>['Checkout', 'Billing'],
      'analytics': <String, dynamic>{'mttr_minutes': 47},
      'action_items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': incidentActionItemId,
          'title': 'Reconcile delayed refunds',
          'owner_user_id': reviewerId,
          'owner_name': 'Mina Moderator',
          'status': 'open',
          'due_at': '2026-06-19T12:00:00Z',
          'due_at_snapshot': '2026-06-19T12:00:00Z',
          'notes_md': 'Pair with billing to verify refund backlog.',
          'task_id': taskPrimaryId,
          'linked_task_id': taskPrimaryId,
          'created_at': '2026-06-18T07:20:00Z',
        },
      ],
      'timeline': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': incidentTimelineId,
          'ts': '2026-06-18T06:18:00Z',
          'entry_md': 'Latency alert triggered for payment writes.',
          'stream_type': 'internal',
          'pinned': true,
          'created_by': userId,
          'created_by_name': 'Alice Admin',
          'created_at': '2026-06-18T06:18:00Z',
        },
      ],
      'status_history': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'status-history-1',
          'from_status': 'open',
          'to_status': 'monitoring',
          'changed_at': '2026-06-18T08:05:00Z',
          'changed_by': userId,
          'changed_by_name': 'Alice Admin',
          'note_md': 'Traffic stabilized after database pool expansion.',
        },
      ],
      'status_updates': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'status-update-1',
          'message_md': 'Mitigation is holding and error rates are back down.',
          'created_at': '2026-06-18T08:10:00Z',
          'created_by': userId,
          'created_by_name': 'Alice Admin',
        },
      ],
      'links': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'incident-link-doc',
          'target_type': 'doc',
          'target_id': kbDocPrimaryId,
          'title': kbDocPrimaryTitle,
        },
        <String, dynamic>{
          'id': 'incident-link-sop',
          'target_type': 'sop',
          'target_id': sopId,
          'title': sopTitle,
        },
      ],
      'reminders': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'reminder-1',
          'reminder_key': 'follow_up',
          'due_at': '2026-06-19T12:00:00Z',
        },
      ],
      'open_action_items': 1,
      'archived': false,
      'created_at': '2026-06-18T06:15:00Z',
    };
  }
}
