import 'package:flutter_test/flutter_test.dart';
import 'package:keychain/src/domain/keychain_key_id_entity.dart';

/// The `<feature>.<key-id>` format, as a decision table of accepted and
/// refused spellings, plus the length boundary.
void main() {
  group('accepted ids', () {
    for (final String id in <String>[
      'demo.token',
      'some_feature.token',
      'demo.0f8fad5b-d9cb-469f-a165-70867728950e',
      'demo.12345',
      'a1.B',
      'notes.item_42',
    ]) {
      test('"$id" is valid', () {
        expect(KeychainKeyIdEntity(id).isValid, isTrue);
      });
    }
  });

  group('refused ids', () {
    for (final String id in <String>[
      '',
      'demo',
      'demo.',
      '.token',
      'demo..token',
      'demo.token.extra',
      'Demo.token',
      '1demo.token',
      '_demo.token',
      'de-mo.token',
      'demo._token',
      'demo.-token',
      'demo.to ken',
      'demo.token ',
      ' demo.token',
      'demo.token\n',
      'demo.stör',
      'demo/token',
    ]) {
      test('"${id.replaceAll('\n', r'\n')}" is invalid', () {
        expect(KeychainKeyIdEntity(id).isValid, isFalse);
      });
    }
  });

  group('length boundary', () {
    String idOfLength(int length) => 'demo.${'a' * (length - 'demo.'.length)}';

    test('exactly maxLength is valid', () {
      expect(
        KeychainKeyIdEntity(idOfLength(KeychainKeyIdEntity.maxLength)).isValid,
        isTrue,
      );
    });

    test('maxLength + 1 is invalid', () {
      expect(
        KeychainKeyIdEntity(
          idOfLength(KeychainKeyIdEntity.maxLength + 1),
        ).isValid,
        isFalse,
      );
    });
  });

  test('equality and copyWith follow the value', () {
    const KeychainKeyIdEntity id = KeychainKeyIdEntity('demo.token');
    expect(id, const KeychainKeyIdEntity('demo.token'));
    expect(id.copyWith(), id);
    expect(
      id.copyWith(value: 'demo.other'),
      const KeychainKeyIdEntity('demo.other'),
    );
  });
}
