// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:opsatlas_client/app/router.dart';
import 'package:opsatlas_client/core/api/auth_store.dart';
import 'package:opsatlas_client/core/api/server_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app router exposes the expected product route contract', () {
    final auth = AuthStore()..loaded = true;
    final serverConfig = ServerConfigController(
      compiledBaseUrl: fallbackLocalApiBaseUrl,
    )..loaded = true;
    final container = ProviderContainer(
      overrides: [
        authStoreProvider.overrideWith((ref) => auth),
        serverConfigProvider.overrideWith((ref) => serverConfig),
      ],
    );
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    addTearDown(router.dispose);

    expect(
      _routePaths(router.configuration.routes),
      containsAll(<String>{
        '/connect',
        '/login',
        '/dashboard',
        '/account',
        '/spaces',
        '/tasks',
        '/spaces/:spaceId',
        '/analytics',
        '/organization',
        '/organization/media',
        '/organization/backups',
        '/organization/backups/:snapshotId',
      }),
    );
  });
}

Set<String> _routePaths(List<RouteBase> routes) {
  final paths = <String>{};
  for (final route in routes) {
    if (route is GoRoute) {
      paths.add(route.path);
      paths.addAll(_routePaths(route.routes));
    } else if (route is ShellRoute) {
      paths.addAll(_routePaths(route.routes));
    }
  }
  return paths;
}
