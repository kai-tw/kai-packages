import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Not exported: the crash-reporter egress is package-internal, and this is
// the single highest-value file to test directly — everything that leaves
// the device does so from here.
import 'package:log_system/src/data/adapters/firebase_crashlytics_adapter.dart';
import 'package:log_system/src/data/adapters/firebase_crashlytics_client.dart';

/// Records every call, in order, plus each call's argument content.
///
/// A hand-written fake against [FirebaseCrashlyticsClient] rather than a
/// `mocktail` mock against `FirebaseCrashlytics`, which is the whole point of
/// that split: this adapter's own behaviour — the enabled gate, message
/// formatting, which level maps to which call — is tested here with plain
/// list/map assertions and no mocking-library ceremony at all. The one
/// mocked test against the real SDK type lives in
/// `firebase_crashlytics_client_test.dart`, confined to the thin wrapper
/// that actually touches it.
class _RecordingCrashlyticsClient implements FirebaseCrashlyticsClient {
  /// One entry per call, in order — the same convention
  /// `log_system_test.dart`'s `_RecordingSink` uses, so "nothing else
  /// happened" is `expect(calls, hasLength(1))`, not a mocking-library
  /// `verifyNoMoreInteractions`.
  final List<String> calls = <String>[];

  final Map<String, Object> customKeys = <String, Object>{};

  final List<_RecordedErrorReport> recordedErrors = <_RecordedErrorReport>[];

  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) async {
    calls.add('setCrashlyticsCollectionEnabled:$enabled');
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    calls.add('setCustomKey:$key');
    customKeys[key] = value;
  }

  @override
  Future<void> log(String message) async {
    calls.add('log:$message');
  }

  @override
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    required String? reason,
    required bool printDetails,
    required bool fatal,
  }) async {
    calls.add('recordError:$reason');
    recordedErrors.add(
      _RecordedErrorReport(
        exception: exception,
        stackTrace: stackTrace,
        reason: reason,
        printDetails: printDetails,
        fatal: fatal,
      ),
    );
  }
}

class _RecordedErrorReport {
  const _RecordedErrorReport({
    required this.exception,
    required this.stackTrace,
    required this.reason,
    required this.printDetails,
    required this.fatal,
  });

  final Object exception;
  final StackTrace? stackTrace;
  final String? reason;
  final bool printDetails;
  final bool fatal;
}

void main() {
  late _RecordingCrashlyticsClient client;

  setUp(() {
    client = _RecordingCrashlyticsClient();
  });

  group('the collection switch is thrown on every construction', () {
    test('enabled: true switches collection on', () {
      FirebaseCrashlyticsAdapter(client, enabled: true);
      expect(client.calls, <String>['setCrashlyticsCollectionEnabled:true']);
    });

    test('enabled: false switches collection off', () {
      FirebaseCrashlyticsAdapter(client, enabled: false);
      expect(client.calls, <String>['setCrashlyticsCollectionEnabled:false']);
    });

    test(
      'omitting enabled falls back to kReleaseMode — false under flutter '
      'test',
      () {
        // The adapter's own default, not this test's: `enabled: enabled ??
        // kReleaseMode`. Asserted because a caller relying on the default
        // getting flipped silently by a refactor would ship every debug
        // build reporting to production Crashlytics.
        FirebaseCrashlyticsAdapter(client);
        expect(client.calls, <String>[
          'setCrashlyticsCollectionEnabled:false',
        ]);
      },
    );
  });

  group('custom keys are gated by enabled, not sent unconditionally', () {
    test(
      'disabled: no custom key reaches the reporter, deferred or not',
      () async {
        FirebaseCrashlyticsAdapter(
          client,
          enabled: false,
          customKeys: const <String, String>{'channel': 'beta'},
          deferredCustomKeys: () async => <String, String>{'late': 'value'},
        );
        await Future<void>.delayed(Duration.zero);
        expect(client.customKeys, isEmpty);
      },
    );

    test('enabled: every entry in customKeys is stamped', () {
      FirebaseCrashlyticsAdapter(
        client,
        enabled: true,
        customKeys: const <String, String>{
          'channel': 'beta',
          'sha': 'abc123',
        },
      );
      expect(client.customKeys, <String, Object>{
        'channel': 'beta',
        'sha': 'abc123',
      });
    });

    test('enabled with no customKeys: nothing is stamped', () {
      FirebaseCrashlyticsAdapter(client, enabled: true);
      expect(client.customKeys, isEmpty);
    });

    test(
      'deferredCustomKeys lands once its future resolves, after construction '
      'returns',
      () async {
        FirebaseCrashlyticsAdapter(
          client,
          enabled: true,
          deferredCustomKeys: () async => <String, String>{
            'install_id': 'xyz',
          },
        );
        // Not yet — the constructor does not await it, on purpose: it needs a
        // platform round-trip and must not stall startup on it.
        expect(client.customKeys, isEmpty);

        await Future<void>.delayed(Duration.zero);
        expect(client.customKeys, <String, Object>{'install_id': 'xyz'});
      },
    );

    test('no deferredCustomKeys: nothing pending, nothing stamped', () async {
      FirebaseCrashlyticsAdapter(client, enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(client.customKeys, isEmpty);
    });
  });

  group('debug and event never reach the reporter, whatever enabled is', () {
    for (final bool enabled in <bool>[true, false]) {
      test('debug — enabled: $enabled', () async {
        final FirebaseCrashlyticsAdapter adapter = FirebaseCrashlyticsAdapter(
          client,
          enabled: enabled,
        );
        await adapter.debug('local only', error: StateError('x'));
        // Only the constructor's own collection-switch call — debug() added
        // nothing.
        expect(client.calls, <String>[
          'setCrashlyticsCollectionEnabled:$enabled',
        ]);
      });

      test('event — enabled: $enabled', () async {
        final FirebaseCrashlyticsAdapter adapter = FirebaseCrashlyticsAdapter(
          client,
          enabled: enabled,
        );
        await adapter.event(
          'opened',
          parameters: <String, Object>{
            'count': 3,
          },
        );
        expect(client.calls, <String>[
          'setCrashlyticsCollectionEnabled:$enabled',
        ]);
      });
    }
  });

  group('info, warning, error, fatal are no-ops while disabled', () {
    late FirebaseCrashlyticsAdapter adapter;

    setUp(() {
      adapter = FirebaseCrashlyticsAdapter(client, enabled: false);
    });

    test('info', () async {
      await adapter.info('i');
      expect(client.calls, <String>['setCrashlyticsCollectionEnabled:false']);
    });

    test('warning', () async {
      await adapter.warning('w', error: StateError('x'));
      expect(client.calls, <String>['setCrashlyticsCollectionEnabled:false']);
    });

    test('error does not record a fault entry', () async {
      await adapter.error('e', error: StateError('x'));
      expect(client.recordedErrors, isEmpty);
    });

    test('fatal does not record a fault entry', () async {
      await adapter.fatal('f', error: StateError('x'));
      expect(client.recordedErrors, isEmpty);
    });
  });

  group('while enabled', () {
    late FirebaseCrashlyticsAdapter adapter;

    setUp(() {
      adapter = FirebaseCrashlyticsAdapter(client, enabled: true);
    });

    test('info is logged as a plain breadcrumb, message verbatim', () async {
      await adapter.info('sync finished');
      expect(client.calls.last, 'log:Info: sync finished');
    });

    test(
      'warning is a breadcrumb, never recordError — a warning is not a '
      'fault',
      () async {
        await adapter.warning('retrying', error: StateError('x'));
        expect(client.recordedErrors, isEmpty);
      },
    );

    test('a warning with no error is just the message', () async {
      await adapter.warning('nothing went wrong yet');
      expect(client.calls.last, 'log:Warning: nothing went wrong yet');
    });

    test('a warning\'s error arrives REDACTED, not raw', () async {
      const FileSystemException error = FileSystemException(
        'could not read',
        '/Users/someone/Library/private-book.epub',
      );
      await adapter.warning('load failed', error: error);

      expect(
        client.calls.last,
        'log:Warning: load failed — FileSystemException errno=-',
      );
      expect(client.calls.last, isNot(contains('private-book')));
      expect(client.calls.last, isNot(contains('/Users')));
    });

    test(
      'a warning\'s stack trace is appended after the redacted error',
      () async {
        final StackTrace stack = StackTrace.current;
        await adapter.warning('w', error: StateError('x'), stackTrace: stack);
        expect(client.calls.last, 'log:Warning: w — StateError\n$stack');
      },
    );

    test(
      'error records a non-fatal fault entry with the redacted error',
      () async {
        const FileSystemException error = FileSystemException(
          'could not read',
          '/Users/someone/Library/private-book.epub',
        );
        final StackTrace stack = StackTrace.current;

        await adapter.error('load failed', error: error, stackTrace: stack);

        final _RecordedErrorReport recorded = client.recordedErrors.single;
        expect(recorded.exception.toString(), 'FileSystemException errno=-');
        expect(recorded.exception.toString(), isNot(contains('private-book')));
        expect(recorded.stackTrace, same(stack));
        expect(recorded.reason, 'load failed');
        expect(
          recorded.printDetails,
          isFalse,
          reason:
              'the console sink already printed at full fidelity; the plugin '
              'printing the redacted surrogate underneath would read like the '
              'error lost its detail',
        );
        expect(recorded.fatal, isFalse);
      },
    );

    test('fatal records the SAME shape, with fatal: true', () async {
      await adapter.fatal('f', error: StateError('x'));

      final _RecordedErrorReport recorded = client.recordedErrors.single;
      expect(recorded.reason, 'f');
      expect(recorded.printDetails, isFalse);
      expect(recorded.fatal, isTrue);
    });

    test('no error object on error() still records — reason carries the '
        'message', () async {
      await adapter.error('message only');

      final _RecordedErrorReport recorded = client.recordedErrors.single;
      expect(recorded.exception.toString(), '<no error object>');
      expect(recorded.stackTrace, isNull);
    });
  });
}
