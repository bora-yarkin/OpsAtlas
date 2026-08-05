import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:opsatlas_client/app/app.dart';
import 'package:opsatlas_client/core/api/branding.dart';
import 'package:opsatlas_client/core/api/server_config.dart';

void main() {
  testWidgets('app bootstraps', (WidgetTester tester) async {
    final serverConfig = ServerConfigController(
      compiledBaseUrl: fallbackLocalApiBaseUrl,
    )..loaded = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith((ref) => serverConfig),
          brandingProvider.overrideWith(
            (ref) async => const BrandingConfig(
              resolvedAppTitle: 'OpsAtlas',
              resolvedApplicationShortName: 'OpsAtlas',
              resolvedWebDescription: defaultBrandingWebDescription,
              resolvedAppleWebAppTitle: 'OpsAtlas',
              resolvedThemeColorHex: '#0F67E8',
              resolvedInstallBackgroundHex: '#0A0D12',
            ),
          ),
        ],
        child: const App(),
      ),
    );

    expect(find.byType(ProviderScope), findsOneWidget);
  });
}
