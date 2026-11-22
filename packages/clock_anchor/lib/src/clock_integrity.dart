import 'clock_integrity_report.dart';
import 'time_anchor.dart';
import 'time_source_trust.dart';
import 'watermark_store.dart';

/// Rollback detection for the device's wall clock, using a persisted
/// high-water mark.
///
/// **This never feeds a timestamp.** It answers one question — has this
/// device's clock been moved backwards — and that answer goes to consumers
/// whose safe response is to refuse and retry. It is deliberately kept out of
/// the path that produces time, because a watermark used as a floor under
/// emitted timestamps poisons every later write for as long as the bogus
/// value stands, which is a worse failure than the one it prevents.
///
/// The watermark is not permanent either: [reconcile] lets a sufficiently
/// trusted anchor pull it back down. Without that, one careless clock change
/// would leave the device fail-closed until real time caught up.
class ClockIntegrity {
  /// [tolerance] absorbs the ordinary jitter of reading a clock; only moves
  /// larger than it are reported. [persistGranularity] keeps a rising
  /// watermark from writing to storage on every observation.
  ClockIntegrity({
    required WatermarkStore store,
    Duration tolerance = const Duration(seconds: 5),
    Duration persistGranularity = const Duration(minutes: 5),
  }) : _store = store,
       _tolerance = tolerance,
       _persistGranularity = persistGranularity;

  final WatermarkStore _store;
  final Duration _tolerance;
  final Duration _persistGranularity;

  DateTime? _watermark;
  DateTime? _persisted;
  bool _rolledBack = false;

  /// The watermark currently in force, if one has been established.
  DateTime? get watermark => _watermark;

  /// Whether the clock has been caught going backwards and not yet vindicated.
  ///
  /// Sticky on purpose: a device that rolled back its clock once is suspect
  /// until a trusted source says otherwise, and clearing the flag merely
  /// because the next reading looked fine would let an attacker clear it by
  /// waiting.
  bool get isRolledBack => _rolledBack;

  /// Loads the persisted watermark. Call once, before the first observation.
  Future<void> load() async {
    final DateTime? stored = await _store.read();
    if (stored != null) {
      _watermark = stored.toUtc();
      _persisted = stored.toUtc();
    }
  }

  /// Records what the device clock currently says and reports what that means.
  ///
  /// Event-driven, not per-read: call it at startup, when the app returns to
  /// the foreground, and before a decision that must fail closed. Calling it
  /// on every `now()` would turn a cheap read into a storage write.
  ///
  /// [monotonicAdvance] is how much monotonic time has passed since the
  /// previous observation, which is what makes an implausible forward jump
  /// distinguishable from time simply passing. Pass [Duration.zero] when
  /// there is no previous observation to compare against.
  Future<ClockIntegrityReport> observe(
    DateTime deviceNow, {
    Duration monotonicAdvance = Duration.zero,
  }) async {
    final DateTime now = deviceNow.toUtc();
    final DateTime? mark = _watermark;

    if (mark == null) {
      await _raise(now);
      return ClockIntegrityReport(
        verdict: ClockIntegrityVerdict.intact,
        delta: Duration.zero,
        watermark: _watermark,
      );
    }

    if (now.isBefore(mark.subtract(_tolerance))) {
      _rolledBack = true;
      return ClockIntegrityReport(
        verdict: ClockIntegrityVerdict.rolledBack,
        delta: mark.difference(now),
        watermark: mark,
      );
    }

    final Duration jump = now.difference(mark) - monotonicAdvance;
    await _raise(now);
    if (jump > _tolerance) {
      return ClockIntegrityReport(
        verdict: ClockIntegrityVerdict.advanced,
        delta: jump,
        watermark: _watermark,
      );
    }
    return ClockIntegrityReport(
      verdict: ClockIntegrityVerdict.intact,
      delta: Duration.zero,
      watermark: _watermark,
    );
  }

  /// Lets a trusted [anchor] correct a watermark that has been left in the
  /// future, and vindicate a device clock that has come back into line.
  ///
  /// This is what stops one careless clock change from leaving the device
  /// fail-closed for days: wind the clock forward, and the watermark rises
  /// with it; wind it back to the truth, and it would sit above every real
  /// instant until time caught up. A trusted source pulls it back down.
  ///
  /// Only a source at [TimeSourceTrust.transportAuthenticated] or above may
  /// do it. An unauthenticated source with this power would hand the
  /// anti-rollback floor to whoever controls the network, which is the same
  /// person who set the clock.
  ///
  /// The two effects are decided separately and on purpose. The watermark
  /// comes down whenever it is above the truth; the rollback flag clears only
  /// when [deviceNow] itself agrees with the truth, because the flag is a
  /// statement about the device clock and a corrected watermark says nothing
  /// about it.
  ///
  /// Returns whether the watermark was lowered.
  Future<bool> reconcile(
    TimeAnchor anchor,
    Duration ticksNow,
    DateTime deviceNow,
  ) async {
    if (!anchor.trust.canLowerWatermark) {
      return false;
    }
    final DateTime truth = anchor.timeAt(ticksNow);
    if (deviceNow.toUtc().difference(truth).abs() <= _tolerance) {
      _rolledBack = false;
    }
    final DateTime? mark = _watermark;
    if (mark == null || !mark.isAfter(truth.add(_tolerance))) {
      return false;
    }
    _watermark = truth;
    await _store.write(truth);
    _persisted = truth;
    return true;
  }

  Future<void> _raise(DateTime now) async {
    final DateTime? mark = _watermark;
    if (mark != null && !now.isAfter(mark)) {
      return;
    }
    _watermark = now;
    final DateTime? persisted = _persisted;
    if (persisted == null || now.difference(persisted) >= _persistGranularity) {
      await _store.write(now);
      _persisted = now;
    }
  }
}
