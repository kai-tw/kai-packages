// Runs on a device or simulator against the real platform key store, through
// the plugin that GeneratedPluginRegistrant wires in. A missing registration
// shows up here as KeychainPlatformFailureException, which the package's own
// unit tests (a mocked channel) cannot catch.

import 'dart:typed_data';

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

    expect(await keychain.isAvailable, isTrue);

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
  testWidgets('a key made elsewhere is stored and read back unchanged', (
    WidgetTester tester,
  ) async {
    const String storedId = 'demo.stored_v1';
    final KeychainRepository keychain = KeychainRepository();
    await keychain.delete(storedId);
    final Uint8List material = Uint8List.fromList(
      List<int>.generate(32, (int i) => 255 - i),
    );

    await keychain.store(storedId, material);
    expect((await keychain.read(storedId)).material, material);

    await expectLater(
      keychain.store(storedId, Uint8List(32)),
      throwsA(isA<KeychainKeyAlreadyExistsException>()),
    );
    expect((await keychain.read(storedId)).material, material);

    await keychain.delete(storedId);
    expect(await keychain.exists(storedId), isFalse);
  });
}
