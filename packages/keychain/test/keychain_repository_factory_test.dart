import 'package:flutter_test/flutter_test.dart';
import 'package:keychain/keychain.dart';
import 'package:keychain/src/data/keychain_repository_impl.dart';

/// The public entry points: [KeychainRepository]'s factory and the exception
/// family's shape.
void main() {
  group('KeychainRepository()', () {
    test('is backed by the internal impl', () {
      // The one place this package's own suite pins the concrete class, to
      // prove the factory returns a working object; no consumer test should.
      expect(KeychainRepository(), isA<KeychainRepositoryImpl>());
    });

    test('each call builds an independent instance', () {
      expect(identical(KeychainRepository(), KeychainRepository()), isFalse);
    });
  });

  group('KeychainException', () {
    const List<KeychainException> family = <KeychainException>[
      KeychainInvalidKeyIdException(),
      KeychainKeyAlreadyExistsException(),
      KeychainKeyNotFoundException(),
      KeychainKeyInvalidatedException(),
      KeychainTemporarilyUnavailableException(diagnosticCode: -25308),
      KeychainUnsupportedException(),
      KeychainPlatformFailureException(),
    ];

    for (final KeychainException exception in family) {
      test('${exception.runtimeType} is an Exception with fixed text', () {
        expect(exception, isA<Exception>());
        expect(
          exception.toString(),
          '${exception.runtimeType}: ${exception.message}',
        );
      });
    }

    test('only a platform-reported variant carries a diagnostic code', () {
      expect(
        const KeychainTemporarilyUnavailableException(
          diagnosticCode: -25308,
        ).diagnosticCode,
        -25308,
      );
      expect(const KeychainKeyNotFoundException().diagnosticCode, isNull);
    });
  });
}
