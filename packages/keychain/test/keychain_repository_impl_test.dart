import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keychain/src/data/keychain_data_source.dart';
import 'package:keychain/src/data/keychain_repository_impl.dart';
import 'package:keychain/src/domain/keychain_exception.dart';
import 'package:keychain/src/domain/keychain_key_entity.dart';

/// An in-memory native store: add-if-absent is one step, as the platform's
/// create is. [failure], when set, is what every call throws instead.
/// [gate], when set, holds every create before it touches the store, so a
/// test can line several up at once.
class _FakeKeychainDataSource implements KeychainDataSource {
  final Map<String, int> keys = <String, int>{};
  final Set<String> invalidated = <String>{};
  final List<String> calls = <String>[];
  final StreamController<bool> availability =
      StreamController<bool>.broadcast();
  bool available = true;
  KeychainException? failure;
  Completer<void>? gate;
  int _generation = 0;

  void _record(String method, String keyId) {
    calls.add('$method:$keyId');
    final KeychainException? pending = failure;
    if (pending != null) {
      throw pending;
    }
  }

  @override
  Future<void> create(String keyId) async {
    _record('create', keyId);
    await gate?.future;
    if (keys.containsKey(keyId)) {
      throw const KeychainKeyAlreadyExistsException();
    }
    _generation += 1;
    keys[keyId] = _generation;
  }

  @override
  Future<Uint8List> read(String keyId) async {
    _record('read', keyId);
    final int? generation = keys[keyId];
    if (generation == null) {
      throw const KeychainKeyNotFoundException();
    }
    if (invalidated.contains(keyId)) {
      throw const KeychainKeyInvalidatedException();
    }
    return Uint8List(32)..[0] = generation;
  }

  @override
  Future<bool> get isAvailable async {
    final KeychainException? pending = failure;
    if (pending != null) {
      throw pending;
    }
    return available;
  }

  @override
  Stream<bool> get availabilityChanges => availability.stream;

  @override
  Future<bool> exists(String keyId) async {
    _record('exists', keyId);
    return keys.containsKey(keyId);
  }

  @override
  Future<void> delete(String keyId) async {
    _record('delete', keyId);
    keys.remove(keyId);
  }
}

/// How [call] ended: `null` when it completed, otherwise the "already
/// exists" refusal — the only failure a concurrent create may meet.
Future<KeychainKeyAlreadyExistsException?> _outcome(Future<void> call) async {
  try {
    await call;
    return null;
  } on KeychainKeyAlreadyExistsException catch (e) {
    return e;
  }
}

/// [KeychainRepositoryImpl]: one group per outcome or error of its contract.
///
/// Techniques: state transition (absent → created → deleted → re-created),
/// decision table (each failure variant through each method), and
/// concurrency (creates held at a gate, then released together).
void main() {
  late _FakeKeychainDataSource dataSource;
  late KeychainRepositoryImpl repository;

  setUp(() {
    dataSource = _FakeKeychainDataSource();
    repository = KeychainRepositoryImpl(dataSource);
  });

  group('create / generate', () {
    test('create stores a key under the fixed name', () async {
      await repository.create('demo.token');
      expect(dataSource.keys.keys, <String>['demo.token']);
    });

    test('generate stores a key under the dynamic id', () async {
      const String id = 'demo.0f8fad5b-d9cb-469f-a165-70867728950e';
      await repository.generate(id);
      expect(await repository.exists(id), isTrue);
    });

    test(
      'a second create of one name is refused and keeps the first key',
      () async {
        await repository.create('demo.token');
        await expectLater(
          repository.create('demo.token'),
          throwsA(isA<KeychainKeyAlreadyExistsException>()),
        );
        expect(dataSource.keys['demo.token'], 1);
      },
    );

    test('create and generate share one name space', () async {
      await repository.generate('demo.token');
      await expectLater(
        repository.create('demo.token'),
        throwsA(isA<KeychainKeyAlreadyExistsException>()),
      );
      expect(dataSource.keys['demo.token'], 1);
    });

    test('neither checks existence first: the store alone decides', () async {
      await repository.create('demo.token');
      await repository.generate('demo.other');
      expect(dataSource.calls, <String>[
        'create:demo.token',
        'create:demo.other',
      ]);
    });

    test('concurrent creates of one name: exactly one key, the first, '
        'is kept', () async {
      dataSource.gate = Completer<void>();
      final List<Future<Object?>> pending = <Future<Object?>>[
        for (int i = 0; i < 6; i++)
          _outcome(
            i.isEven
                ? repository.create('demo.token')
                : repository.generate('demo.token'),
          ),
      ];
      // Every call is now parked at the gate, past validation.
      await Future<void>.delayed(Duration.zero);
      expect(dataSource.calls, hasLength(6));
      dataSource.gate?.complete();

      final List<Object?> outcomes = await Future.wait(pending);

      expect(outcomes.where((Object? o) => o == null), hasLength(1));
      expect(
        outcomes.whereType<KeychainKeyAlreadyExistsException>(),
        hasLength(5),
      );
      expect(dataSource.keys, <String, int>{'demo.token': 1});
    });

    test('after a delete, the same fixed name is created again', () async {
      await repository.create('demo.token');
      await repository.delete('demo.token');
      await repository.create('demo.token');
      expect(dataSource.keys['demo.token'], 2);
    });
  });

  group('read', () {
    test('returns the usable key stored under the id', () async {
      await repository.create('demo.token');
      expect(
        await repository.read('demo.token'),
        KeychainKeyEntity(
          keyId: 'demo.token',
          material: Uint8List(32)..[0] = 1,
        ),
      );
    });

    test('a missing key is not found, and read creates nothing', () async {
      await expectLater(
        repository.read('demo.token'),
        throwsA(isA<KeychainKeyNotFoundException>()),
      );
      expect(await repository.exists('demo.token'), isFalse);
    });

    test('an unusable key is invalidated, and is left in place', () async {
      await repository.create('demo.token');
      dataSource.invalidated.add('demo.token');
      await expectLater(
        repository.read('demo.token'),
        throwsA(isA<KeychainKeyInvalidatedException>()),
      );
      expect(await repository.exists('demo.token'), isTrue);
    });
  });

  group('exists', () {
    test('true for a stored key, false for an absent one', () async {
      await repository.create('demo.token');
      expect(await repository.exists('demo.token'), isTrue);
      expect(await repository.exists('demo.other'), isFalse);
    });

    test(
      'existence is not usability: an invalidated key still exists',
      () async {
        await repository.create('demo.token');
        dataSource.invalidated.add('demo.token');
        expect(await repository.exists('demo.token'), isTrue);
      },
    );
  });

  group('delete', () {
    test('removes a stored key', () async {
      await repository.create('demo.token');
      await repository.delete('demo.token');
      expect(await repository.exists('demo.token'), isFalse);
    });

    test('a key that is already gone counts as deleted', () async {
      await repository.delete('demo.token');
      expect(dataSource.calls, <String>['delete:demo.token']);
    });
  });

  group('availability', () {
    tearDown(() => dataSource.availability.close());

    test('isAvailable answers what the platform says', () async {
      dataSource.available = false;
      expect(await repository.isAvailable, isFalse);
      dataSource.available = true;
      expect(await repository.isAvailable, isTrue);
    });

    test('a locked device leaves every key in place', () async {
      await repository.create('demo.token');
      dataSource.failure = const KeychainTemporarilyUnavailableException();
      await expectLater(
        repository.read('demo.token'),
        throwsA(isA<KeychainTemporarilyUnavailableException>()),
      );
      dataSource.failure = null;
      expect(dataSource.keys, <String, int>{'demo.token': 1});
    });

    test('changes pass through as the platform sends them', () async {
      final Future<List<bool>> seen = repository.availabilityChanges
          .take(2)
          .toList();
      dataSource.availability
        ..add(false)
        ..add(true);
      expect(await seen, <bool>[false, true]);
    });
  });

  group('platform failures pass through unchanged, never as absence', () {
    final List<KeychainException> failures = <KeychainException>[
      const KeychainTemporarilyUnavailableException(),
      const KeychainUnsupportedException(),
      const KeychainPlatformFailureException(),
    ];
    final Map<String, Future<Object?> Function(KeychainRepositoryImpl)>
    methods = <String, Future<Object?> Function(KeychainRepositoryImpl)>{
      'create': (KeychainRepositoryImpl r) => r.create('demo.token'),
      'generate': (KeychainRepositoryImpl r) => r.generate('demo.token'),
      'read': (KeychainRepositoryImpl r) => r.read('demo.token'),
      'exists': (KeychainRepositoryImpl r) => r.exists('demo.token'),
      'delete': (KeychainRepositoryImpl r) => r.delete('demo.token'),
    };

    for (final KeychainException failure in failures) {
      for (final MapEntry<
            String,
            Future<Object?> Function(KeychainRepositoryImpl)
          >
          method
          in methods.entries) {
        test('${method.key}: ${failure.runtimeType}', () async {
          await repository.create('demo.token');
          dataSource.failure = failure;
          await expectLater(method.value(repository), throwsA(same(failure)));
          dataSource.failure = null;
          expect(dataSource.keys['demo.token'], 1);
        });
      }
    }
  });

  group('invalid ids are refused before the store is touched', () {
    final Map<String, Future<Object?> Function(String)> methods =
        <String, Future<Object?> Function(String)>{
          'create': (String id) => repository.create(id),
          'generate': (String id) => repository.generate(id),
          'read': (String id) => repository.read(id),
          'exists': (String id) => repository.exists(id),
          'delete': (String id) => repository.delete(id),
        };

    for (final MapEntry<String, Future<Object?> Function(String)> method
        in methods.entries) {
      for (final String id in <String>['token', 'demo.a.b', '']) {
        test('${method.key}("$id")', () async {
          await expectLater(
            method.value(id),
            throwsA(isA<KeychainInvalidKeyIdException>()),
          );
          expect(dataSource.calls, isEmpty);
        });
      }
    }
  });
}
