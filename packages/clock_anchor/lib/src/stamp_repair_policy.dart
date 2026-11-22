import 'stamp_repair_decision.dart';
import 'time_reading.dart';

/// Decides which locally-written timestamps were produced while the device
/// clock was wrong, and are therefore sitting in the future.
///
/// This is the cleanup half of the package. Anchoring stops *new* stamps from
/// being poisoned by a moved clock, but it cannot retract the ones written
/// before an anchor existed — offline, on a first run, or in the window
/// between a clock change and the next successful sample. Those records win
/// every comparison until real time catches up, and on the far side of a sync
/// they are rejected outright by any peer enforcing a future ceiling.
///
/// Nothing is repaired unless the reading is `TimeConfidence.anchored`.
/// Repairing against a device clock would be the same mistake in the other
/// direction: a device that is merely *behind* would rewrite every correct
/// stamp it owns. The two preconditions this class cannot check for itself
/// are on [plan], which is where records are handed over.
class StampRepairPolicy {
  /// [tolerance] is the slack allowed before a stamp counts as implausible.
  /// It absorbs the ordinary case of a stamp issued a moment ago on a clock
  /// running a little fast, which is not worth rewriting.
  const StampRepairPolicy({this.tolerance = const Duration(minutes: 5)});

  /// How far ahead of the trusted reading a stamp may sit unrepaired.
  final Duration tolerance;

  /// Judges one stamp.
  ///
  /// The threshold is built from [TimeReading.latest], not from the point
  /// estimate: when the reading itself is uncertain, the benefit of the doubt
  /// goes to leaving the stamp alone.
  StampRepairDecision inspect({
    required DateTime stamp,
    required TimeReading now,
  }) {
    if (!now.isTrustworthy) {
      return const StampRepairDecision.defer();
    }
    final DateTime threshold = now.latest.add(tolerance);
    final DateTime candidate = stamp.toUtc();
    if (!candidate.isAfter(threshold)) {
      return const StampRepairDecision.keep();
    }
    return StampRepairDecision.repair(
      repairedTo: now.utc,
      excess: candidate.difference(now.utc),
    );
  }

  /// Applies [inspect] across [records], returning only those that need
  /// re-issuing, in the order given.
  ///
  /// Generic over the record type and blind to storage: the caller keeps its
  /// own entities and hands over a way to read the stamp off one. An
  /// untrustworthy reading yields an empty plan, never a partial one.
  ///
  /// Two things about [records] cannot be checked here and are the caller's
  /// to guarantee. Only stamps **this device produced** may be passed — a
  /// stamp from another device is that device's business, and re-issuing it
  /// would overwrite a peer's ordering with this one's; with hybrid logical
  /// clocks the filter is the node id. And only records **no peer has
  /// accepted yet**, because repair lowers a stamp: a peer that already took
  /// the high one will rank it above the repaired value, so repairing an
  /// already-uploaded record buys nothing and costs a write. The
  /// pending-upload set is the right input.
  List<T> plan<T>(
    Iterable<T> records, {
    required DateTime Function(T record) stampOf,
    required TimeReading now,
  }) {
    if (!now.isTrustworthy) {
      return <T>[];
    }
    final List<T> planned = <T>[];
    for (final T record in records) {
      if (inspect(stamp: stampOf(record), now: now).isRepairNeeded) {
        planned.add(record);
      }
    }
    return planned;
  }
}
