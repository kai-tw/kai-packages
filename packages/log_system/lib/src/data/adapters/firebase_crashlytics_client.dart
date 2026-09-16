import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// The narrow slice of the Crashlytics SDK [FirebaseCrashlyticsAdapter]
/// actually calls.
///
/// Every other data source in this package — [LogRepository], [LogSink] —
/// is a contract this package owns rather than a third-party type reached
/// directly; this is that same shape applied to the one place it was
/// missing. `FirebaseCrashlytics` itself has a dozen-plus members (`crash()`,
/// `checkForUnsentReports()`, `setUserIdentifier()`, …) the adapter never
/// touches, has a private constructor a hand-written fake cannot `extends`,
/// and its `recordError` takes enough named parameters that mocking it
/// directly means either stubbing members with no bearing on this adapter's
/// behaviour or reasoning about a mocking library's undocumented multi-value
/// capture order. None of that is *wrong*, but all of it is friction this
/// package's own tests should not have to pay for logic that has nothing to
/// do with it.
///
/// Production wires the real SDK through [FirebaseCrashlyticsClient.wrapping];
/// a test hands [FirebaseCrashlyticsAdapter] a four-method hand-written fake
/// instead. [wrapping]'s own delegation is thin enough (one line per method,
/// no branches) that it is the one place in this pairing still worth a mock
/// against the real SDK type — see `firebase_crashlytics_client_test.dart`.
abstract class FirebaseCrashlyticsClient {
  /// Wraps a real [FirebaseCrashlytics] instance. The only call site is
  /// `LogSystem.realCrashlyticsClientForTest`, the factory `LogSystem.init`
  /// passes along.
  factory FirebaseCrashlyticsClient.wrapping(FirebaseCrashlytics instance) =
      _RealFirebaseCrashlyticsClient;

  Future<void> setCrashlyticsCollectionEnabled(bool enabled);

  Future<void> setCustomKey(String key, Object value);

  Future<void> log(String message);

  /// Mirrors [FirebaseCrashlytics.recordError]'s shape, narrowed to exactly
  /// the parameters [FirebaseCrashlyticsAdapter] passes — every call site
  /// supplies all three, so `required` here says so rather than leaving
  /// each implementer to reconstruct the SDK's own defaults.
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    required String? reason,
    required bool printDetails,
    required bool fatal,
  });
}

class _RealFirebaseCrashlyticsClient implements FirebaseCrashlyticsClient {
  _RealFirebaseCrashlyticsClient(this._instance);

  final FirebaseCrashlytics _instance;

  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) =>
      _instance.setCrashlyticsCollectionEnabled(enabled);

  @override
  Future<void> setCustomKey(String key, Object value) =>
      _instance.setCustomKey(key, value);

  @override
  Future<void> log(String message) => _instance.log(message);

  @override
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    required String? reason,
    required bool printDetails,
    required bool fatal,
  }) => _instance.recordError(
    exception,
    stackTrace,
    reason: reason,
    printDetails: printDetails,
    fatal: fatal,
  );
}
