import '../domain/log_entry.dart';
import '../domain/log_repository.dart';
import '../domain/log_sink.dart';
import 'adapters/log_error_redactor.dart';
import 'log_data_source.dart';

/// Sends each severity to the sinks that severity is allowed to reach.
///
/// The routing is the whole reason this layer exists, and flattening it is how
/// a local debug line ends up in a 90-day retained sink:
///
/// | level | console | crash reporter | host sink |
/// |---|---|---|---|
/// | `debug` | yes (never in release) | never | yes |
/// | `info` | yes | breadcrumb, if the sink forwards it | yes |
/// | `warning` | yes | breadcrumb — never a fault entry | yes |
/// | `error` / `fatal` | yes | `recordError`, non-fatal / fatal | yes |
/// | `event` | yes | never | yes |
///
/// The host sink's column is uniform on purpose. It is not a third egress
/// with its own policy — it is the app observing its own logging, and an app
/// that cannot see the levels it emits most (`debug`, and `event`, neither of
/// which the reporter ever receives) can observe the half of its logging that
/// was never in question. What it receives is bounded by redaction instead of
/// by level.
///
/// A failing sink rejects the combined future rather than being swallowed:
/// logging that silently stops working is worse than logging that throws
/// somewhere a zone handler can see it.
class LogRepositoryImpl extends LogRepository {
  LogRepositoryImpl({
    LogDataSource? console,
    LogDataSource? report,
    LogSink? sink,
  }) : _console = console,
       _report = report,
       _sink = sink;

  /// Null when the host has taken logging over entirely — `LogSystem.withSink`
  /// builds one of these. Every other configuration wires the console, which
  /// costs nothing in release (`logger`'s filter drops the lot) and is the
  /// only destination that always exists.
  final LogDataSource? _console;

  /// Null in a build with no crash reporter at all — a test harness, or an
  /// app that has not wired one yet. Every level then stays device-local.
  final LogDataSource? _report;

  /// The host app's own destination, if it registered one.
  final LogSink? _sink;

  /// Fans one log line out to every destination it is allowed to reach.
  ///
  /// [entry] is a builder rather than a value because constructing it runs the
  /// redactor, and an app with no sink registered — most of them — should not
  /// pay for a reduction nobody will read on every log line.
  Future<void> _fanOut(
    LogEntry Function() entry, {
    required bool toReport,
    required Future<void> Function(LogDataSource destination) call,
  }) {
    final LogDataSource? console = _console;
    final LogDataSource? report = _report;
    final LogSink? sink = _sink;
    return Future.wait(<Future<void>>[
      if (console != null) call(console),
      if (toReport && report != null) call(report),
      if (sink != null) _emit(sink, entry()),
    ]);
  }

  /// `async` deliberately, so a host sink that throws synchronously rejects
  /// this future instead of propagating out of the `LogSystem` static that
  /// started the call. A sink is app code this package does not control, and
  /// a log line must never be why the line after it does not run.
  Future<void> _emit(LogSink sink, LogEntry entry) async => sink.emit(entry);

  /// The **second** call site of the redactor, and it has to be: the first
  /// lives inside `FirebaseCrashlyticsAdapter`, which guards its own egress
  /// and is the reason no caller can opt out of reduction on the way to
  /// Crashlytics. A host sink does not pass through that adapter, so without
  /// this it would receive the raw object — a door around the boundary,
  /// opened by the feature meant to make logging observable.
  ///
  /// Keeping both sites is defence in depth rather than duplication: each
  /// reduces once, for one destination, and **neither ever receives the
  /// other's output.** Chaining them would reduce a `_RedactedErrorSurrogate` to the
  /// string `_RedactedErrorSurrogate`, losing the type name that keeps crash-report
  /// grouping apart.
  static String? _redact(Object? error) =>
      error == null ? null : LogErrorRedactor.redact(error).toString();

  @override
  Future<void> debug(String message, {Object? error, StackTrace? stackTrace}) {
    // Console only, by routing rather than by the sink's discretion.
    return _fanOut(
      () => LogEntry(
        level: LogLevel.debug,
        message: message,
        redactedError: _redact(error),
        stackTrace: stackTrace,
      ),
      toReport: false,
      call: (LogDataSource destination) =>
          destination.debug(message, error: error, stackTrace: stackTrace),
    );
  }

  @override
  Future<void> info(String message) {
    return _fanOut(
      () => LogEntry(level: LogLevel.info, message: message),
      toReport: true,
      call: (LogDataSource destination) => destination.info(message),
    );
  }

  @override
  Future<void> warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    return _fanOut(
      () => LogEntry(
        level: LogLevel.warning,
        message: message,
        redactedError: _redact(error),
        stackTrace: stackTrace,
      ),
      toReport: true,
      call: (LogDataSource destination) =>
          destination.warning(message, error: error, stackTrace: stackTrace),
    );
  }

  @override
  Future<void> error(String message, {Object? error, StackTrace? stackTrace}) {
    return _fanOut(
      () => LogEntry(
        level: LogLevel.error,
        message: message,
        redactedError: _redact(error),
        stackTrace: stackTrace,
      ),
      toReport: true,
      call: (LogDataSource destination) =>
          destination.error(message, error: error, stackTrace: stackTrace),
    );
  }

  @override
  Future<void> fatal(String message, {Object? error, StackTrace? stackTrace}) {
    return _fanOut(
      () => LogEntry(
        level: LogLevel.fatal,
        message: message,
        redactedError: _redact(error),
        stackTrace: stackTrace,
      ),
      toReport: true,
      call: (LogDataSource destination) =>
          destination.fatal(message, error: error, stackTrace: stackTrace),
    );
  }

  @override
  Future<void> event(String name, {Map<String, Object>? parameters}) {
    // Console only. Routing an event to the crash reporter is how a log level
    // quietly becomes analytics.
    return _fanOut(
      () => LogEntry(
        level: LogLevel.event,
        message: name,
        parameters: parameters,
      ),
      toReport: false,
      call: (LogDataSource destination) =>
          destination.event(name, parameters: parameters),
    );
  }
}
