import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_system/log_system.dart';
// Not exported; see log_system_test.dart.
import 'package:log_system/src/data/adapters/firebase_crashlytics_client.dart';

/// Its own file because it initialises a (mocked) Firebase app, and
/// `log_system_test.dart` depends on there being none.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  test(
    '[partition] the factory init passes wraps the SDK singleton without '
    'calling a method on it',
    () {
      // A method call would reach `FirebaseCrashlyticsPlatform.instanceFor`,
      // which the core mock does not satisfy; resolving and wrapping does not.
      expect(
        LogSystem.realCrashlyticsClientForTest(),
        isA<FirebaseCrashlyticsClient>(),
      );
    },
  );
}
