// Since integration tests run in a full Flutter application, they exercise
// the real native metered-probe channel, unlike the package's Dart unit
// tests (which mock the internal data-source seams). See
// https://flutter.dev/to/integration-testing.

import 'package:connectivity_status/connectivity_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the metered channel answers true, false, or MissingPluginException — '
    'never a stale wrapper exception',
    (WidgetTester tester) async {
      // ConnectivityStatusPlatform is this package's federated-plugin
      // extensibility point (the same role path_provider_platform_interface
      // plays for path_provider) — deliberately public, unlike the
      // clean-architecture data-source seams this package keeps internal.
      // On a real iOS/Android device or simulator this resolves via the
      // native handler this package ships; MissingPluginException would mean
      // GeneratedPluginRegistrant never wired ConnectivityStatusPlugin in
      // for this build.
      final bool? metered =
          await ConnectivityStatusPlatform.instance.isActiveNetworkMetered;

      expect(metered, anyOf(isTrue, isFalse, isNull));
    },
  );

  testWidgets(
    'GetConnectivityUseCase resolves a real status against the real adapters',
    (WidgetTester tester) async {
      final ConnectivityStatus status = await GetConnectivityUseCase(
        ConnectivityRepository(),
      )();

      expect(ConnectivityStatus.values, contains(status));
    },
  );
}
