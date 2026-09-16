import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'data/adapters/firebase_crashlytics_adapter.dart';
import 'data/adapters/firebase_crashlytics_client.dart';
import 'data/adapters/log_error_redactor.dart';
import 'data/adapters/logger_adapter.dart';
import 'data/log_data_source.dart';
import 'data/log_repository_impl.dart';
import 'domain/log_repository.dart';
import 'domain/log_sink.dart';

/// The whole public surface of this package.
///
/// Every level below is a silent no-op until something is registered — see
/// [init] for the startup contract, and [LogSink] for the seam a host app
/// implements when it wants its own destination, or wants its own tests to
/// see that a fault was logged.
///
/// **An instance exists to be registered, not to be called.** [LogSystem.withSink]
/// builds one and [register] installs it; the call surface is the statics
/// below. That is not a style preference — a static and an instance member
/// cannot share a name in Dart, so `LogSystem.error` being the static one is
/// what lets every existing call site keep working unchanged. An app wanting
/// an injectable logger injects its own [LogSink], not this.
///
/// **This package ships no fake sink.** A test double belongs to the suite
/// that asserts on it: shipping one would put its shape — what it records,
/// how a matcher reads it — in this package's public API, where changing it
/// becomes a breaking change for every consumer. The [LogSink] doc has the
/// four-line implementation to copy.
class LogSystem {
  LogSystem._(this._repository);

  /// An instance that forwards every level to [sink] and to nothing else —
  /// no console, no crash reporter. Install it with [register].
  ///
  /// This is the shape a test wants. [init] is the production path and is
  /// wrong for a test whatever it is passed: it reads the Firebase registry,
  /// reassigns `PlatformDispatcher.instance.onError` (a process-wide global,
  /// from a `setUp`), and logs a warning of its own. None of that is what a
  /// suite asking "was this failure logged?" wants standing behind it.
  ///
  /// An app wanting its own backend *alongside* the console and the reporter
  /// passes `sink:` to [init] instead.
  factory LogSystem.withSink(LogSink sink) =>
      LogSystem._(LogRepositoryImpl(sink: sink));

  final LogRepository _repository;

  void _debug(String message, {Object? error, StackTrace? stackTrace}) =>
      _repository.debug(message, error: error, stackTrace: stackTrace);

  void _info(String message) => _repository.info(message);

  void _warning(String message, {Object? error, StackTrace? stackTrace}) =>
      _repository.warning(message, error: error, stackTrace: stackTrace);

  void _error(String message, {Object? error, StackTrace? stackTrace}) =>
      _repository.error(message, error: error, stackTrace: stackTrace);

  void _fatal(String message, {Object? error, StackTrace? stackTrace}) =>
      _repository.fatal(message, error: error, stackTrace: stackTrace);

  void _event(String name, {Map<String, Object>? parameters}) =>
      _repository.event(name, parameters: parameters);

  /// Static members

  /// The graph [init] builds, once, at startup.
  ///
  /// The layers below ([LogRepository], the sinks, the redactor) are a clean
  /// architecture graph, and the instance methods on that repository are its
  /// entry point. But a log line is called from everywhere, and threading an
  /// instance to every call site buys nothing — so the graph is built once by
  /// [init] and reached through the statics below instead.
  static LogSystem? _instance;

  /// Builds the graph and wires it. Call once, during startup, before
  /// anything logs.
  ///
  /// The version this was extracted from resolved `sl<LogSystem>()` on every
  /// call, which inside one app is fine and in a package is impossible: it
  /// would make `get_it` a dependency of every consumer and hard-code one
  /// app's locator. Here the app supplies flags instead, and the wiring is
  /// this file's business.
  ///
  /// **Logging before this runs is a silent no-op, on purpose.** Unit tests
  /// that construct production types directly never stand up the app's
  /// wiring, and a log line must not be the reason one of them throws. Do not
  /// "fix" it by asserting initialisation.
  ///
  /// **Calling this again replaces the wiring** rather than throwing, which is
  /// a deliberate departure from what `init` usually implies: an integration
  /// harness re-inits to swap the real reporter out.
  ///
  /// **When Firebase is absent** — `Firebase.initializeApp()` has not run, as
  /// in an integration harness booting the real graph against no backend —
  /// this wires the console alone and says so through the console, rather
  /// than touching `FirebaseCrashlytics`, which setting the collection flag
  /// would otherwise require.
  ///
  /// Neither of the obvious alternatives works there. **Throwing** would let
  /// a logging library stop an app from starting, a worse failure than the
  /// one it guards against, and it would break the harness this case exists
  /// for. **Asserting** is the same thing wearing a debug badge — it aborts
  /// the rest of `init`, so the harness gets an exception *and* no logging at
  /// all. **Degrading silently** would let an app that simply forgot
  /// `initializeApp()` get no crash reporting and no complaint. A warning
  /// through the sink that is definitely wired costs nothing in release,
  /// appears where a developer is already looking in debug, and leaves
  /// everything working either way.
  static void init({
    /// Off keeps every level device-local **and switches Crashlytics
    /// collection off at the SDK**. Gating what this package sends does
    /// nothing about the native crash capture, which runs with no Dart code
    /// involved, so the switch has to be thrown either way — collection is
    /// set on every call to this method, to whatever `reportCrashes &&
    /// kReleaseMode` comes to, and is never left at the SDK's default, which
    /// is on.
    ///
    /// ⚠️ `false` is **not** the "no Firebase" case — that one is detected
    /// automatically, and handled separately. This means Firebase *is* there
    /// and must be told to stay quiet: a beta build, a harness that stands
    /// Firebase up. Conflating the two is how this parameter first shipped,
    /// and it made the configuration that most needed to avoid Firebase the
    /// one that crashed on startup.
    bool reportCrashes = true,

    /// Assigns `FlutterError.onError` and
    /// `PlatformDispatcher.instance.onError`. On by default, because leaving
    /// it to each app is how two of them ended up disagreeing about which
    /// uncaught errors count as crashes. Pass false only if the app installs
    /// its own — doing so reassigns two global handlers, a side effect worth
    /// knowing about.
    bool installErrorHandlers = true,

    /// Stamped on the crash reporter as-is and **bypass redaction
    /// entirely**, so only provably non-identifying values belong here — a
    /// commit sha, a release channel.
    Map<String, String> customKeys = const <String, String>{},

    /// For a custom key that needs a platform round-trip; it lands a moment
    /// after launch, so a crash in the first frames may miss it.
    Future<Map<String, String>> Function()? deferredCustomKeys,

    /// Keeps one structural field from an error type this package cannot
    /// name — the built-in arms cover `dart:io` and `package:flutter` only,
    /// because an arm for an HTTP client's exception would make that client a
    /// dependency of every consumer. Return the **field only**; the type name
    /// is prepended, so a describer cannot break crash-report grouping. An
    /// app's own exceptions should extend `LoggableException` instead of
    /// going through here.
    String? Function(Object error)? describeExtra,

    /// The app's own destination, wired **alongside** the console and the
    /// crash reporter rather than instead of them, and receiving every level
    /// — including `debug` and `event`, which the reporter never sees. It is
    /// handed values that have already crossed the redaction boundary; see
    /// [LogSink].
    LogSink? sink,
  }) {
    LogErrorRedactor.describeExtra = describeExtra;

    // A registry read, not an app lookup, so it is safe before
    // `initializeApp()` — it answers with an empty list rather than throwing.
    final bool hasFirebase = Firebase.apps.isNotEmpty;

    _instance = LogSystem._(
      LogRepositoryImpl(
        console: LoggerAdapter(),
        sink: sink,
        // Built even when it will send nothing, because building it is what
        // switches collection **off** at the SDK. Skipping it on
        // `reportCrashes: false` would leave the SDK default — on — and the
        // native layer captures a crash with no Dart code involved, so the
        // build that most wanted silence would be the one still reporting.
        report: buildCrashlyticsReportForTest(
          hasFirebase: hasFirebase,
          reportCrashes: reportCrashes,
          customKeys: customKeys,
          deferredCustomKeys: deferredCustomKeys,
          clientFactory: realCrashlyticsClientForTest,
        ),
      ),
    );

    if (installErrorHandlers) {
      _installErrorHandlers();
    }

    // After the wiring, deliberately — this is the one message that has to go
    // out through the sink it is complaining about.
    if (!hasFirebase) {
      warning(
        'log: no Firebase app, so nothing will be reported — console only',
      );
    }
  }

  /// The decision [init] makes for the crash-reporter destination —
  /// extracted for the same reason [handleFrameworkErrorForTest] is: so this
  /// package's own tests can reach it directly, with [clientFactory] standing
  /// in for the one call [init] cannot make under `flutter test`.
  ///
  /// This is not the `LogRepository` seam this package's `CLAUDE.md` refuses
  /// to open. That refusal is about exposing *which internal destination a
  /// level reached* — the graph a caller could wire wrong. This exposes
  /// *whether and how the report destination gets built* for one already-
  /// public constructor ([FirebaseCrashlyticsAdapter]) — the same shape as
  /// injecting a collaborator, not as widening what a level can reach.
  ///
  /// Splitting the seam here, at [clientFactory], rather than one level up at
  /// `report:` itself, is deliberate: `hasFirebase`, `reportCrashes &&
  /// kReleaseMode`, and forwarding `customKeys`/`deferredCustomKeys` are this
  /// method's own logic, not the SDK's, and a test exercising them should not
  /// have to stand up a fake `FirebaseCrashlyticsPlatform` to do it — [init]
  /// passes a fake [FirebaseCrashlyticsClient] instead, no different from how
  /// `firebase_crashlytics_adapter_test.dart` tests
  /// [FirebaseCrashlyticsAdapter] itself.
  ///
  /// What stays genuinely out of reach is narrower than it looks: not
  /// "anything Firebase", just the one thing [clientFactory] wraps at its own
  /// call site in [init] — a *method call* on the real
  /// `FirebaseCrashlytics.instance`. Reading `Firebase.apps` (what
  /// `hasFirebase` is) is a plain, swappable object graph and is exercised
  /// for real below with a fake `FirebasePlatform`; even
  /// `FirebaseCrashlytics.instance` itself resolves safely against that same
  /// fake, since the getter only wraps a `FirebaseApp` reference. The wall is
  /// one field deeper: `FirebaseCrashlyticsPlatform.instanceFor` — reached the
  /// moment any method is called on that client — asserts
  /// `pluginConstants['isCrashlyticsCollectionEnabled'] != null`, and
  /// `pluginConstants` reads a `static` field private to
  /// `firebase_core_platform_interface` that only the real native
  /// `Firebase#initializeCore` channel response ever populates. No object
  /// substitution reaches a private field in a package this one does not
  /// own; only re-implementing that plugin's own native handshake would, and
  /// that is testing the SDK, not this package.
  ///
  /// [init] passes [realCrashlyticsClientForTest] as the factory, which a test
  /// can call on its own: resolving `FirebaseCrashlytics.instance` and wrapping
  /// it calls no method on it, so it runs against a mocked `FirebasePlatform`.
  @visibleForTesting
  static LogDataSource? buildCrashlyticsReportForTest({
    required bool hasFirebase,
    required bool reportCrashes,
    required Map<String, String> customKeys,
    required Future<Map<String, String>> Function()? deferredCustomKeys,
    required FirebaseCrashlyticsClient Function() clientFactory,
  }) {
    if (!hasFirebase) {
      return null;
    }
    return FirebaseCrashlyticsAdapter(
      clientFactory(),
      enabled: reportCrashes && kReleaseMode,
      customKeys: customKeys,
      deferredCustomKeys: deferredCustomKeys,
    );
  }

  /// The factory [init] hands [buildCrashlyticsReportForTest]: the real SDK
  /// singleton, wrapped. Named rather than a closure so a test can run it.
  @visibleForTesting
  static FirebaseCrashlyticsClient realCrashlyticsClientForTest() =>
      FirebaseCrashlyticsClient.wrapping(FirebaseCrashlytics.instance);

  /// The two handlers every uncaught throw arrives at, wired once here so two
  /// apps cannot drift apart on the judgements they involve. They did.
  ///
  /// Both handler bodies are extracted to [handleFrameworkErrorForTest] and
  /// [handleAsyncErrorForTest] rather than written inline, and the reason is
  /// the release gate below: `kReleaseMode` is a compile-time constant,
  /// always false in a `flutter test` binary, so a test cannot flip it.
  /// Extracted as ordinary static methods, this package's own tests can call
  /// the logic directly. The gate itself is a parameter of
  /// [installErrorHandlersForTest] for the same reason — so the release-only
  /// assignment is exercised too, not just the handler it installs.
  static void _installErrorHandlers() =>
      installErrorHandlersForTest(releaseMode: kReleaseMode);

  /// [_installErrorHandlers] with the release gate passed in; production
  /// always passes `kReleaseMode`.
  @visibleForTesting
  static void installErrorHandlersForTest({required bool releaseMode}) {
    // Release only. In debug `FlutterError.onError` already defaults to
    // `FlutterError.presentError`, so overriding it there reimplements the
    // default — and presenting *and* logging prints the same error twice while
    // the reporter is disabled and there is nothing to report.
    //
    // It also keeps `presentError` out of release structurally. There
    // `dumpErrorToConsole` takes the `debugPrintStack(label:
    // exception.toString())` branch, and `debugPrint` is not assert-gated, so
    // it would put the raw exception on logcat / oslog — the object the
    // redaction exists to stop, reaching a different sink.
    if (releaseMode) {
      FlutterError.onError = handleFrameworkErrorForTest;
    }

    // Unconditional, because Flutter installs nothing here by default.
    PlatformDispatcher.instance.onError = handleAsyncErrorForTest;
  }

  /// The logic `FlutterError.onError` runs in release builds — see
  /// [_installErrorHandlers] for why it lives here as an ordinary method
  /// instead of a closure inline in that gate.
  ///
  /// Not a test seam grafted on afterwards: this **is** the production
  /// handler, reached in a release build through the tear-off
  /// `_installErrorHandlers` assigns. `ForTest` in the name is honest about
  /// the *reason* it is a named method and not a closure — a closure could
  /// not be reached from outside its own release-only assignment — while
  /// [visibleForTesting] says the same about who besides this package's own
  /// tests should ever call it directly: nobody. It is not exported from the
  /// public barrel.
  ///
  /// `details.silent` is the framework's own fatal/non-fatal signal, set at
  /// the throw site: "errors that could be triggered by environmental
  /// conditions (as opposed to logic errors)". The HTTP library sets it so a
  /// 404 on flaky wifi does not read like a bug, and the framework honours it
  /// in `dumpErrorToConsole`. FlutterFire's `recordFlutterError` never looks
  /// at it, which is how its documented pattern files every one of them as a
  /// crash — and `fatal: true` feeds crash-free users, the number a release
  /// is judged by.
  ///
  /// `details.exception` rather than `details` is also what drops `context`
  /// and `informationCollector`, both `DiagnosticsNode`s that can carry
  /// widget-tree property values.
  @visibleForTesting
  static void handleFrameworkErrorForTest(FlutterErrorDetails details) {
    if (details.silent) {
      error(
        'flutter: environmental framework error',
        error: details.exception,
        stackTrace: details.stack,
      );
      return;
    }
    fatal(
      'flutter: uncaught framework error',
      error: details.exception,
      stackTrace: details.stack,
    );
  }

  /// The logic `PlatformDispatcher.instance.onError` runs, unconditionally —
  /// see [handleFrameworkErrorForTest] for why this is a named method and
  /// what [visibleForTesting] means here.
  ///
  /// Not fatal, and there is no `silent` to consult on this path. `return
  /// true` says the app has handled the error and will keep running, so
  /// filing it as a crash would contradict [handleFrameworkErrorForTest]'s
  /// `fatal:` branch.
  @visibleForTesting
  static bool handleAsyncErrorForTest(Object err, StackTrace stack) {
    error('uncaught async error', error: err, stackTrace: stack);
    return true;
  }

  /// Wires a repository directly, for **this package's own tests**.
  ///
  /// Not a seam for host apps, and structurally cannot be: [LogRepository] is
  /// unexported, so nothing outside can name the argument. It survives
  /// alongside [register] because the two observe different things — this one
  /// reaches the routing table, which is what the tests in this package are
  /// about, while a [LogSink] deliberately cannot see which destination a
  /// level reached.
  @visibleForTesting
  static void initWithRepositoryForTest(LogRepository repository) =>
      _instance = LogSystem._(repository);

  /// Installs [system] as what every static below resolves through,
  /// replacing whatever was there.
  ///
  /// Separate from [LogSystem.withSink] because building an instance and
  /// making it global are two different acts, and only the second is the one
  /// a `tearDown` has to undo:
  ///
  /// ```dart
  /// setUp(() => LogSystem.register(LogSystem.withSink(sink)));
  /// tearDown(LogSystem.reset);
  /// ```
  ///
  /// Skipping the [reset] leaks one test's sink into every later test in the
  /// same process, where it goes on recording lines nobody is asserting on.
  static void register(LogSystem system) => _instance = system;

  /// Drops the wiring, returning every level to the silent no-op it is before
  /// anything is registered.
  ///
  /// Public because [register] made it half of a contract a host app has to
  /// hold up, rather than only this package's own test seam — which it was
  /// first, and is why it also clears the redactor's host describer.
  static void reset() {
    _instance = null;
    LogErrorRedactor.describeExtra = null;
  }

  /// Local-only, for expected non-error events — a user cancelling, an
  /// expected offline transition. Never leaves the device, and is skipped
  /// entirely in release.
  static void debug(String message, {Object? error, StackTrace? stackTrace}) {
    _instance?._debug(message, error: error, stackTrace: stackTrace);
  }

  /// Takes no error object, and that asymmetry is deliberate: `info` describes
  /// an expected condition. An exception worth keeping makes it a [warning] or
  /// an [error].
  static void info(String message) {
    _instance?._info(message);
  }

  /// Something went wrong but the app carried on. Reaches the crash reporter
  /// as a breadcrumb, never as a fault entry.
  static void warning(String message, {Object? error, StackTrace? stackTrace}) {
    _instance?._warning(message, error: error, stackTrace: stackTrace);
  }

  /// A fault worth a report. [error] is reduced to a non-identifying surrogate
  /// on the way out — pass the exception itself rather than describing it in
  /// [message], which crosses verbatim.
  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    _instance?._error(message, error: error, stackTrace: stackTrace);
  }

  /// As [error], reported fatal.
  static void fatal(String message, {Object? error, StackTrace? stackTrace}) {
    _instance?._fatal(message, error: error, stackTrace: stackTrace);
  }

  /// A named occurrence, console only.
  ///
  /// **This is not analytics dispatch.** Nothing here reaches an analytics
  /// backend — the level exists so an app has one place to route to one
  /// later, and wiring that is a consent decision rather than a plumbing
  /// change.
  static void event(String name, {Map<String, Object>? parameters}) {
    _instance?._event(name, parameters: parameters);
  }
}
