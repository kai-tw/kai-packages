import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keychain/src/data/keychain_data_source_impl.dart';
import 'package:keychain/src/data/keychain_repository_impl.dart';
import 'package:keychain/src/domain/keychain_exception.dart';

/// [KeychainDataSourceImpl] against a mocked native side, through the
/// official binary-messenger hook.
///
/// Techniques: decision table (native error code → exception variant),
/// equivalence partitioning (supported vs unsupported platform), contract
/// (method name + arguments sent), and a stateful native stand-in that models
/// the native create's atomic add-if-absent, to drive concurrent creates
/// through the real channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('net.kaiwu.keychain');

  void handle(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    handle(null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('supported platforms send the call', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test(
        '${platform.name}: each method sends its name and the key id',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          final List<MethodCall> calls = <MethodCall>[];
          handle((MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'read':
                return Uint8List(32);
              case 'isAvailable':
                return true;
              case 'exists':
                return true;
              default:
                return null;
            }
          });
          final KeychainDataSourceImpl dataSource = KeychainDataSourceImpl();

          await dataSource.create('demo.token');
          expect(await dataSource.read('demo.token'), Uint8List(32));
          expect(await dataSource.exists('demo.token'), isTrue);
          await dataSource.delete('demo.token');
          expect(await dataSource.isAvailable(), isTrue);

          expect(calls.map((MethodCall c) => c.method), <String>[
            'create',
            'read',
            'exists',
            'delete',
            'isAvailable',
          ]);
          expect(calls.last.arguments, isNull);
          for (final MethodCall call in calls.take(4)) {
            expect(call.arguments, <String, String>{
              'keyId': 'demo.token',
            });
          }
        },
      );
    }
  });

  test('web reports unsupported without calling, whatever host OS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    int calls = 0;
    handle((MethodCall call) async {
      calls += 1;
      return null;
    });
    final KeychainDataSourceImpl dataSource = KeychainDataSourceImpl(
      isWeb: true,
    );

    await expectLater(
      dataSource.exists('demo.token'),
      throwsA(isA<KeychainUnsupportedException>()),
    );
    expect(calls, 0);
  });

  group('unsupported platforms report unsupported without calling', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.fuchsia,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      test(platform.name, () async {
        debugDefaultTargetPlatformOverride = platform;
        int calls = 0;
        handle((MethodCall call) async {
          calls += 1;
          return null;
        });
        final KeychainDataSourceImpl dataSource = KeychainDataSourceImpl();

        await expectLater(
          dataSource.create('demo.token'),
          throwsA(isA<KeychainUnsupportedException>()),
        );
        await expectLater(
          dataSource.read('demo.token'),
          throwsA(isA<KeychainUnsupportedException>()),
        );
        await expectLater(
          dataSource.exists('demo.token'),
          throwsA(isA<KeychainUnsupportedException>()),
        );
        await expectLater(
          dataSource.delete('demo.token'),
          throwsA(isA<KeychainUnsupportedException>()),
        );
        await expectLater(
          dataSource.isAvailable(),
          throwsA(isA<KeychainUnsupportedException>()),
        );
        expect(calls, 0);
      });
    }
  });

  group('exists answers', () {
    test('false is a conclusive absence', () async {
      handle((MethodCall call) async => false);
      expect(await KeychainDataSourceImpl().exists('demo.token'), isFalse);
    });

    test('null is contract drift, not absence', () async {
      handle((MethodCall call) async => null);
      await expectLater(
        KeychainDataSourceImpl().exists('demo.token'),
        throwsA(isA<KeychainPlatformFailureException>()),
      );
    });
  });

  test('read answering null is contract drift', () async {
    handle((MethodCall call) async => null);
    await expectLater(
      KeychainDataSourceImpl().read('demo.token'),
      throwsA(isA<KeychainPlatformFailureException>()),
    );
  });

  group('native error codes', () {
    final Map<String, TypeMatcher<KeychainException>> table =
        <String, TypeMatcher<KeychainException>>{
          'alreadyExists': isA<KeychainKeyAlreadyExistsException>(),
          'notFound': isA<KeychainKeyNotFoundException>(),
          'invalidated': isA<KeychainKeyInvalidatedException>(),
          'temporarilyUnavailable':
              isA<KeychainTemporarilyUnavailableException>(),
          'unsupported': isA<KeychainUnsupportedException>(),
          'failed': isA<KeychainPlatformFailureException>(),
          'badArgs': isA<KeychainPlatformFailureException>(),
        };

    for (final MapEntry<String, TypeMatcher<KeychainException>> row
        in table.entries) {
      test('"${row.key}" becomes ${row.value}', () async {
        handle(
          (MethodCall call) async => throw PlatformException(code: row.key),
        );
        await expectLater(
          KeychainDataSourceImpl().read('demo.token'),
          throwsA(row.value),
        );
      });
    }

    test('a code outside the vocabulary is an unidentified failure', () async {
      handle((MethodCall call) async => throw PlatformException(code: 'boom'));
      await expectLater(
        KeychainDataSourceImpl().read('demo.token'),
        throwsA(isA<KeychainPlatformFailureException>()),
      );
    });

    test('an integer status crosses as the diagnostic code', () async {
      for (final String code in <String>[
        'temporarilyUnavailable',
        'unsupported',
        'failed',
      ]) {
        handle(
          (MethodCall call) async =>
              throw PlatformException(code: code, details: -25308),
        );
        await expectLater(
          KeychainDataSourceImpl().exists('demo.token'),
          throwsA(
            isA<KeychainException>().having(
              (KeychainException e) => e.diagnosticCode,
              'diagnosticCode',
              -25308,
            ),
          ),
        );
      }
    });

    test('non-integer details are dropped, never forwarded', () async {
      handle(
        (MethodCall call) async =>
            throw PlatformException(code: 'failed', details: 'demo.token'),
      );
      await expectLater(
        KeychainDataSourceImpl().exists('demo.token'),
        throwsA(
          isA<KeychainPlatformFailureException>().having(
            (KeychainPlatformFailureException e) => e.diagnosticCode,
            'diagnosticCode',
            isNull,
          ),
        ),
      );
    });
  });

  test('a missing native handler is a platform failure', () async {
    handle(null);
    await expectLater(
      KeychainDataSourceImpl().create('demo.token'),
      throwsA(isA<KeychainPlatformFailureException>()),
    );
  });

  test('a hung native handler times out as a platform failure', () {
    fakeAsync((FakeAsync async) {
      handle((MethodCall call) => Completer<Object?>().future);
      Object? error;
      KeychainDataSourceImpl()
          .create('demo.token')
          .then<void>((_) {}, onError: (Object e) => error = e);

      async.elapse(const Duration(seconds: 14));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error, isA<KeychainPlatformFailureException>());
    });
  });

  test('read answering a key of the wrong size is contract drift', () async {
    handle((MethodCall call) async => Uint8List(16));
    await expectLater(
      KeychainDataSourceImpl().read('demo.token'),
      throwsA(isA<KeychainPlatformFailureException>()),
    );
  });

  group('isAvailable', () {
    test('passes the native answer through', () async {
      handle((MethodCall call) async => false);
      expect(await KeychainDataSourceImpl().isAvailable(), isFalse);
    });

    test('null is contract drift, not "unavailable"', () async {
      handle((MethodCall call) async => null);
      await expectLater(
        KeychainDataSourceImpl().isAvailable(),
        throwsA(isA<KeychainPlatformFailureException>()),
      );
    });
  });

  group('availabilityChanges', () {
    const EventChannel events = EventChannel(
      'net.kaiwu.keychain/availability',
    );
    late MockStreamHandlerEventSink? sink;
    late int listens;
    late int cancels;

    setUp(() {
      sink = null;
      listens = 0;
      cancels = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            events,
            MockStreamHandler.inline(
              onListen: (Object? arguments, MockStreamHandlerEventSink s) {
                listens += 1;
                sink = s;
              },
              onCancel: (Object? arguments) => cancels += 1,
            ),
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(events, null);
    });

    /// Lets the channel round trips (listen, isAvailable) land.
    Future<void> settle() => pumpEventQueue();

    test(
      'emits the current state, then each change, without repeats',
      () async {
        handle((MethodCall call) async => false);
        final List<bool> seen = <bool>[];
        final StreamSubscription<bool> subscription = KeychainDataSourceImpl()
            .availabilityChanges
            .listen(seen.add);
        await settle();
        sink?.success(false);
        sink?.success(true);
        sink?.success(true);
        sink?.success(false);
        await settle();
        await subscription.cancel();

        expect(seen, <bool>[false, true, false]);
      },
    );

    test('a change that lands before the state query wins over it', () async {
      final Completer<Object?> answer = Completer<Object?>();
      handle((MethodCall call) => answer.future);
      final List<bool> seen = <bool>[];
      final StreamSubscription<bool> subscription = KeychainDataSourceImpl()
          .availabilityChanges
          .listen(seen.add);
      await settle();
      sink?.success(true);
      await settle();
      answer.complete(false);
      await settle();
      await subscription.cancel();

      expect(seen, <bool>[true]);
    });

    test('listeners share one native subscription, released on the last '
        'cancel', () async {
      handle((MethodCall call) async => true);
      final KeychainDataSourceImpl dataSource = KeychainDataSourceImpl();
      final List<bool> first = <bool>[];
      final List<bool> second = <bool>[];
      final StreamSubscription<bool> a = dataSource.availabilityChanges.listen(
        first.add,
      );
      final StreamSubscription<bool> b = dataSource.availabilityChanges.listen(
        second.add,
      );
      await settle();
      sink?.success(false);
      await settle();

      expect(listens, 1);
      expect(first, <bool>[true, false]);
      expect(second, <bool>[true, false]);

      await a.cancel();
      await settle();
      expect(cancels, 0);
      await b.cancel();
      await settle();
      expect(cancels, 1);
    });

    test('a native error event becomes its keychain exception', () async {
      handle((MethodCall call) async => true);
      final List<Object> errors = <Object>[];
      final StreamSubscription<bool> subscription = KeychainDataSourceImpl()
          .availabilityChanges
          .listen((_) {}, onError: errors.add);
      await settle();
      sink?.error(code: 'temporarilyUnavailable');
      await settle();
      await subscription.cancel();

      expect(errors.single, isA<KeychainTemporarilyUnavailableException>());
    });

    test('an event that is not a bool is contract drift', () async {
      handle((MethodCall call) async => true);
      final List<Object> errors = <Object>[];
      final StreamSubscription<bool> subscription = KeychainDataSourceImpl()
          .availabilityChanges
          .listen((_) {}, onError: errors.add);
      await settle();
      sink?.success('unlocked');
      await settle();
      await subscription.cancel();

      expect(errors.single, isA<KeychainPlatformFailureException>());
    });

    test('a failed state query after a change is dropped too', () async {
      final Completer<Object?> answer = Completer<Object?>();
      handle((MethodCall call) => answer.future);
      final List<bool> seen = <bool>[];
      final List<Object> errors = <Object>[];
      final StreamSubscription<bool> subscription = KeychainDataSourceImpl()
          .availabilityChanges
          .listen(seen.add, onError: errors.add);
      await settle();
      sink?.success(true);
      await settle();
      answer.completeError(PlatformException(code: 'failed'));
      await settle();
      await subscription.cancel();

      expect(seen, <bool>[true]);
      expect(errors, isEmpty);
    });

    test('a failed state query reaches the listener as an error', () async {
      handle(
        (MethodCall call) async => throw PlatformException(code: 'unsupported'),
      );
      final List<Object> errors = <Object>[];
      final StreamSubscription<bool> subscription = KeychainDataSourceImpl()
          .availabilityChanges
          .listen((_) {}, onError: errors.add);
      await settle();
      await subscription.cancel();

      expect(errors.single, isA<KeychainUnsupportedException>());
    });

    test('an unsupported platform emits nothing and never listens', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final List<bool> seen = await KeychainDataSourceImpl().availabilityChanges
          .toList();

      expect(seen, isEmpty);
      expect(listens, 0);
    });
  });

  group('through the repository, over a native store', () {
    /// keyId → which create made it. Add-if-absent is one step, as
    /// `SecItemAdd` and the Android module's single executor make it.
    late Map<String, int> store;
    late int creates;

    setUp(() {
      store = <String, int>{};
      creates = 0;
      handle((MethodCall call) async {
        final String keyId =
            (call.arguments as Map<Object?, Object?>)['keyId']! as String;
        switch (call.method) {
          case 'create':
            creates += 1;
            if (store.containsKey(keyId)) {
              throw PlatformException(code: 'alreadyExists');
            }
            store[keyId] = creates;
            return null;
          case 'read':
            if (!store.containsKey(keyId)) {
              throw PlatformException(code: 'notFound');
            }
            final int? generation = store[keyId];
            if (generation == null) {
              throw PlatformException(code: 'notFound');
            }
            return Uint8List(32)..[0] = generation;
          case 'exists':
            return store.containsKey(keyId);
          case 'delete':
            store.remove(keyId);
            return null;
        }
        return null;
      });
    });

    test('concurrent creates of one name: one wins, the rest are refused, '
        'the winner\'s key is kept', () async {
      final KeychainRepositoryImpl repository = KeychainRepositoryImpl(
        KeychainDataSourceImpl(),
      );

      final List<Object?> outcomes = await Future.wait(<Future<Object?>>[
        for (int i = 0; i < 4; i++)
          (i.isEven
                  ? repository.create('demo.token')
                  : repository.generate('demo.token'))
              .then<Object?>((_) => null, onError: (Object e) => e),
      ]);

      expect(
        outcomes.whereType<KeychainKeyAlreadyExistsException>(),
        hasLength(3),
      );
      expect(outcomes.where((Object? o) => o == null), hasLength(1));
      expect(store, <String, int>{'demo.token': 1});
      expect((await repository.read('demo.token')).material[0], 1);
    });
  });
}
