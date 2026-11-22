import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keychain/src/domain/keychain_key_entity.dart';

void main() {
  final KeychainKeyEntity key = KeychainKeyEntity(
    keyId: 'demo.token',
    material: Uint8List.fromList(List<int>.generate(32, (int i) => i)),
  );

  test('copyWith with no arguments keeps every field', () {
    expect(key.copyWith(), key);
  });

  test('copyWith replaces only the field it is given', () {
    expect(
      key.copyWith(keyId: 'demo.other'),
      KeychainKeyEntity(keyId: 'demo.other', material: key.material),
    );
    expect(
      key.copyWith(material: Uint8List(32)),
      KeychainKeyEntity(keyId: 'demo.token', material: Uint8List(32)),
    );
  });

  test('two keys with the same bytes are equal, different bytes are not', () {
    expect(
      key,
      KeychainKeyEntity(
        keyId: 'demo.token',
        material: Uint8List.fromList(key.material),
      ),
    );
    expect(key == key.copyWith(material: Uint8List(32)), isFalse);
  });

  test('toString names the key and never prints its bytes', () {
    final KeychainKeyEntity secret = KeychainKeyEntity(
      keyId: 'demo.token',
      material: Uint8List(32)..fillRange(0, 32, 0xAB),
    );
    expect(secret.toString(), 'KeychainKeyEntity(demo.token)');
    expect(secret.toString(), isNot(contains('171')));
  });
}
