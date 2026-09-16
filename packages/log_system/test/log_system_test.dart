import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_system/log_system.dart';
// Not exported. A host app configures via flags on `LogSystem.init`; these are
// the internals those flags assemble, reachable from inside the package only.
import 'package:log_system/src/data/adapters/firebase_crashlytics_adapter.dart';
import 'package:log_system/src/data/adapters/firebase_crashlytics_client.dart';
import 'package:log_system/src/data/adapters/log_error_redactor.dart';
import 'package:log_system/src/data/log_data_source.dart';
import 'package:log_system/src/data/log_repository_impl.dart';

/// The four-line `LogSink` the docs tell a host app to copy — needed here
/// only to read back the content of `init`'s own no-Firebase warning, which
/// is emitted through the wiring `init` just built rather than through a
/// fake the test controls.
final class _RecordingLogSink implements LogSink {
  final List<LogEntry> entries = <LogEntry>[];

  @override
  void emit(LogEntry entry) => entries.add(entry);
}

/// Stands in for the real SDK in `buildCrashlyticsReportForTest` tests. Every
/// method just resolves — `FirebaseCrashlyticsAdapter`'s own behaviour against
/// a client is `firebase_crashlytics_adapter_test.dart`'s job; this file only
/// needs proof that *a* client reaches the adapter's constructor, not that its
/// calls are recorded correctly.
class _StubFirebaseCrashlyticsClient implements FirebaseCrashlyticsClient {
  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) async {}

  @override
  Future<void> setCustomKey(String key, Object value) async {}

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    required String? reason,
    required bool printDetails,
    required bool fatal,
  }) async {}
}

/// Records what each level was asked to do, without touching a real sink.
class _RecordingSink extends LogDataSource {
  final List<String> calls = <String>[];
  final List<Object?> errors = <Object?>[];

  @override
  Future<void> debug(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    calls.add('debug:$message');
    errors.add(error);
  }

  @override
  Future<void> info(String message) async => calls.add('info:$message');

  @override
  Future<void> warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    calls.add('warning:$message');
    errors.add(error);
  }

  @override
  Future<void> error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    calls.add('error:$message');
    errors.add(error);
  }

  @override
  Future<void> fatal(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    calls.add('fatal:$message');
    errors.add(error);
  }

  @override
  Future<void> event(String name, {Map<String, Object>? parameters}) async {
    calls.add('event:$name');
  }
}

void main() {
  late _RecordingSink console;
  late _RecordingSink report;

  setUp(() {
    console = _RecordingSink();
    report = _RecordingSink();
    LogSystem.initWithRepositoryForTest(
      LogRepositoryImpl(console: console, report: report),
    );
  });

  tearDown(LogSystem.reset);

  group('severity routing — the reason the repository layer exists', () {
    test('debug reaches the console and never the reporter', () {
      LogSystem.debug('local only');
      expect(console.calls, <String>['debug:local only']);
      expect(report.calls, isEmpty);
    });

    test('event reaches the console and never the reporter', () {
      // It is not a fault and not a breadcrumb; it is the seat an analytics
      // backend may take later, and dripping into crash reports meanwhile
      // would make that wiring look like it had already happened.
      LogSystem.event('opened');
      expect(console.calls, <String>['event:opened']);
      expect(report.calls, isEmpty);
    });

    test('info, warning, error and fatal reach both', () {
      LogSystem.info('i');
      LogSystem.warning('w');
      LogSystem.error('e');
      LogSystem.fatal('f');
      const List<String> expected = <String>[
        'info:i',
        'warning:w',
        'error:e',
        'fatal:f',
      ];
      expect(console.calls, expected);
      expect(report.calls, expected);
    });
  });

  group('initialisation', () {
    test('logging before init is a silent no-op, not a throw', () {
      // A unit test that constructs production types directly never stands up
      // the app's wiring, and a log line must not be why it fails.
      LogSystem.reset();
      expect(() => LogSystem.error('nothing is listening'), returnsNormally);
    });

    test('init again replaces the existing repository', () {
      // What an integration harness does to keep a test build off the real
      // crash reporter.
      final _RecordingSink replacement = _RecordingSink();
      LogSystem.initWithRepositoryForTest(
        LogRepositoryImpl(console: replacement),
      );
      LogSystem.error('e');
      expect(replacement.calls, <String>['error:e']);
      expect(console.calls, isEmpty);
    });

    test('init without Firebase wires the console instead of throwing', () {
      // The integration-harness case: the real graph is booted against no
      // backend, so `Firebase.initializeApp()` was never called and
      // `FirebaseCrashlytics.instance` would throw synchronously. This test
      // runs with no Firebase either, so reaching it would fail here — which
      // is the assertion.
      //
      // It must not throw and must not assert: both abort the rest of `init`,
      // leaving the harness with no logging at all — the opposite of the point.
      LogSystem.reset();
      expect(LogSystem.init, returnsNormally);
      expect(() => LogSystem.fatal('still logs'), returnsNormally);
    });

    test('a repository with no reporter keeps every level device-local', () {
      LogSystem.initWithRepositoryForTest(LogRepositoryImpl(console: console));
      LogSystem.info('i');
      LogSystem.fatal('f');
      expect(console.calls, <String>['info:i', 'fatal:f']);
      expect(report.calls, isEmpty);
    });
  });

  test('the error object is passed through, not stringified by the facade', () {
    // Reduction happens at the egress sink, not here — the console sink is
    // entitled to the real object.
    const FormatException error = FormatException('raw');
    LogSystem.error('e', error: error);
    expect(console.errors.last, same(error));
  });

  group('the two uncaught-error handlers, extracted for direct testing', () {
    // `kReleaseMode` is a compile-time constant, always false under `flutter
    // test`, so `_installErrorHandlers`'s `if (kReleaseMode) { FlutterError.
    // onError = ... }` assignment can never run here — there is no way to
    // flip the constant from a test. `handleFrameworkErrorForTest` and
    // `handleAsyncErrorForTest` are the production handler bodies themselves
    // (see their doc comments on `LogSystem`), reachable directly because
    // they are ordinary static methods rather than closures sealed inside
    // that dead branch.
    setUp(() {
      LogSystem.initWithRepositoryForTest(
        LogRepositoryImpl(console: console, report: report),
      );
    });

    test('a silent framework error is logged as error, not fatal', () {
      // `details.silent` is the framework's own environmental/logic-error
      // signal; FlutterFire's recordFlutterError ignores it and would file
      // this as a crash regardless, which is exactly what this package
      // exists to not do.
      final FlutterErrorDetails details = FlutterErrorDetails(
        exception: StateError('flaky wifi'),
        stack: StackTrace.current,
        silent: true,
      );

      LogSystem.handleFrameworkErrorForTest(details);

      expect(console.calls, <String>[
        'error:flutter: environmental framework error',
      ]);
      expect(console.errors.single, same(details.exception));
    });

    test('a non-silent framework error is logged as fatal', () {
      final FlutterErrorDetails details = FlutterErrorDetails(
        exception: StateError('real bug'),
        stack: StackTrace.current,
      );

      LogSystem.handleFrameworkErrorForTest(details);

      expect(console.calls, <String>[
        'fatal:flutter: uncaught framework error',
      ]);
      expect(console.errors.single, same(details.exception));
    });

    test('an async error is logged as error and marked handled', () {
      // `return true` is the framework's "the app dealt with it, keep
      // running" signal — filing this path as `fatal` instead would
      // contradict that in the same breath.
      final StackTrace stack = StackTrace.current;
      final StateError thrown = StateError('uncaught');

      final bool handled = LogSystem.handleAsyncErrorForTest(thrown, stack);

      expect(handled, isTrue);
      expect(console.calls, <String>['error:uncaught async error']);
      expect(console.errors.single, same(thrown));
    });
  });

  group('_installErrorHandlers wiring, via init()', () {
    tearDown(() => PlatformDispatcher.instance.onError = null);

    test('installs the extracted async handler by default', () {
      LogSystem.init();
      expect(
        PlatformDispatcher.instance.onError,
        same(LogSystem.handleAsyncErrorForTest),
      );
    });

    test(
      '[partition] the release gate installs the framework handler, and only '
      'when open',
      () {
        final FlutterExceptionHandler? original = FlutterError.onError;
        try {
          LogSystem.installErrorHandlersForTest(releaseMode: false);
          expect(FlutterError.onError, same(original));

          LogSystem.installErrorHandlersForTest(releaseMode: true);
          expect(
            FlutterError.onError,
            same(LogSystem.handleFrameworkErrorForTest),
          );
        } finally {
          FlutterError.onError = original;
        }
      },
    );

    test('installErrorHandlers: false leaves it untouched', () {
      PlatformDispatcher.instance.onError = null;
      LogSystem.init(installErrorHandlers: false);
      expect(PlatformDispatcher.instance.onError, isNull);
    });

    test(
      'the installed handler is genuinely live — invoking it through '
      'PlatformDispatcher reaches this package\'s logging',
      () {
        // Not just "the same tear-off": calling it through the exact global
        // the framework calls, and observing the effect arrive at whatever
        // is currently registered — proving the wiring, not just the
        // extraction.
        LogSystem.init();
        LogSystem.initWithRepositoryForTest(
          LogRepositoryImpl(console: console, report: report),
        );

        final bool? handled = PlatformDispatcher.instance.onError?.call(
          StateError('async'),
          StackTrace.current,
        );

        expect(handled, isTrue);
        expect(console.calls, <String>['error:uncaught async error']);
      },
    );
  });

  group('init wires describeExtra through to the redactor', () {
    test('a host describer set via init is what redact() actually uses', () {
      // Not a check on `init`'s parameter list — a check that the value
      // reaches `LogErrorRedactor`, the object every crash-reporter-bound
      // error is actually reduced through.
      LogSystem.init(
        installErrorHandlers: false,
        describeExtra: (Object error) => error is StateError ? 'known' : null,
      );

      expect(
        LogErrorRedactor.redact(StateError('x')).toString(),
        'StateError known',
      );
    });

    test('reset() clears it, same as it clears the instance', () {
      LogSystem.init(
        installErrorHandlers: false,
        describeExtra: (Object error) => 'known',
      );

      LogSystem.reset();

      expect(LogErrorRedactor.describeExtra, isNull);
    });
  });

  group('init without Firebase — the warning\'s own content', () {
    // 'init without Firebase wires the console instead of throwing' above
    // proves logging keeps working; this proves the SPECIFIC message a
    // developer needs actually goes out, through the wiring `init` just
    // built, and only when there really is no Firebase app registered.
    test('the exact warning reaches a registered sink', () {
      final _RecordingLogSink sink = _RecordingLogSink();

      LogSystem.init(installErrorHandlers: false, sink: sink);

      expect(sink.entries, hasLength(1));
      final LogEntry entry = sink.entries.single;
      expect(entry.level, LogLevel.warning);
      expect(
        entry.message,
        'log: no Firebase app, so nothing will be reported — console only',
      );
    });
  });

  group(
    'buildCrashlyticsReportForTest — the decision init makes for the '
    'report destination',
    () {
      test('no Firebase: null, and the client factory is never called', () {
        int factoryCalls = 0;

        final LogDataSource? result = LogSystem.buildCrashlyticsReportForTest(
          hasFirebase: false,
          reportCrashes: true,
          customKeys: const <String, String>{},
          deferredCustomKeys: null,
          clientFactory: () {
            factoryCalls++;
            return _StubFirebaseCrashlyticsClient();
          },
        );

        expect(result, isNull);
        expect(
          factoryCalls,
          0,
          reason:
              'no Firebase app means nothing should ever touch the real SDK',
        );
      });

      test(
        'Firebase present: builds a real FirebaseCrashlyticsAdapter, calling '
        'the factory exactly once',
        () {
          int factoryCalls = 0;

          final LogDataSource? result = LogSystem.buildCrashlyticsReportForTest(
            hasFirebase: true,
            reportCrashes: true,
            customKeys: const <String, String>{},
            deferredCustomKeys: null,
            clientFactory: () {
              factoryCalls++;
              return _StubFirebaseCrashlyticsClient();
            },
          );

          expect(result, isA<FirebaseCrashlyticsAdapter>());
          expect(factoryCalls, 1);
        },
      );

      test(
        'enabled is reportCrashes && kReleaseMode, not reportCrashes || '
        'kReleaseMode — both read false under flutter test, so only && '
        'agrees with reportCrashes: true',
        () {
          final FirebaseCrashlyticsAdapter result =
              LogSystem.buildCrashlyticsReportForTest(
                    hasFirebase: true,
                    reportCrashes: true,
                    customKeys: const <String, String>{},
                    deferredCustomKeys: null,
                    clientFactory: _StubFirebaseCrashlyticsClient.new,
                  )
                  as FirebaseCrashlyticsAdapter;

          expect(result.enabled, isFalse);
        },
      );

      test('reportCrashes: false also switches collection off', () {
        final FirebaseCrashlyticsAdapter result =
            LogSystem.buildCrashlyticsReportForTest(
                  hasFirebase: true,
                  reportCrashes: false,
                  customKeys: const <String, String>{},
                  deferredCustomKeys: null,
                  clientFactory: _StubFirebaseCrashlyticsClient.new,
                )
                as FirebaseCrashlyticsAdapter;

        expect(result.enabled, isFalse);
      });
    },
  );
}
