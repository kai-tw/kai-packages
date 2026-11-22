// Runs on a device or simulator against the real platform key store, through
// the plugin that GeneratedPluginRegistrant wires in. A missing registration
// shows up here as KeychainPlatformFailureException, which the package's own
// unit tests (a mocked channel) cannot catch.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keychain/keychain.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String keyId = 'demo.token';

  testWidgets('a key goes through create, read, refuse, delete and absence', (
    WidgetTester tester,
  ) async {
    final KeychainRepository keychain = KeychainRepository();
    // A key left by an earlier, interrupted run; absent already counts as
    // deleted.
    await keychain.delete(keyId);

    expect(await keychain.isAvailable(), isTrue);

    await keychain.create(keyId);
    expect(await keychain.exists(keyId), isTrue);
    final KeychainKeyEntity first = await keychain.read(keyId);
    expect(first.keyId, keyId);
    expect(first.material, hasLength(32));

    await expectLater(
      keychain.create(keyId),
      throwsA(isA<KeychainKeyAlreadyExistsException>()),
    );
    expect(await keychain.read(keyId), first);

    await keychain.delete(keyId);
    expect(await keychain.exists(keyId), isFalse);
    await expectLater(
      keychain.read(keyId),
      throwsA(isA<KeychainKeyNotFoundException>()),
    );

    await expectLater(
      keychain.read('not-an-id'),
      throwsA(isA<KeychainInvalidKeyIdException>()),
    );
  });
}
