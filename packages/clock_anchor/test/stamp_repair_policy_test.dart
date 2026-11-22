import 'package:clock_anchor/clock_anchor.dart';
import 'package:test/test.dart';

/// `StampRepairPolicy` — which stamps get rewritten, and the two guards that
/// stop it rewriting the wrong ones.
void main() {
  final DateTime now = DateTime.utc(2026, 9, 3, 12);
  const StampRepairPolicy policy = StampRepairPolicy();

  TimeReading reading({
    TimeConfidence confidence = TimeConfidence.anchored,
    Duration uncertainty = Duration.zero,
  }) => TimeReading(utc: now, confidence: confidence, uncertainty: uncertainty);

  test('a stamp inside the tolerance is left alone', () {
    final StampRepairDecision decision = policy.inspect(
      stamp: now.add(const Duration(minutes: 4)),
      now: reading(),
    );

    expect(decision.action, StampRepairAction.keep);
    expect(decision.isRepairNeeded, isFalse);
  });

  test('a stamp beyond the tolerance is re-issued at the trusted instant', () {
    final StampRepairDecision decision = policy.inspect(
      stamp: now.add(const Duration(days: 3)),
      now: reading(),
    );

    expect(decision.action, StampRepairAction.repair);
    expect(decision.repairedTo, now);
    expect(decision.excess, const Duration(days: 3));
  });

  test('an untrustworthy reading defers rather than keeping', () {
    for (final TimeConfidence confidence in <TimeConfidence>[
      TimeConfidence.unknown,
      TimeConfidence.deviceOnly,
      TimeConfidence.staleAnchor,
    ]) {
      final StampRepairDecision decision = policy.inspect(
        stamp: now.add(const Duration(days: 3)),
        now: reading(confidence: confidence),
      );

      // "Ask again later" is not "this stamp is fine". A device that is
      // merely behind would otherwise rewrite every correct stamp it owns.
      expect(decision.action, StampRepairAction.defer, reason: '$confidence');
      expect(decision.isRepairNeeded, isFalse);
    }
  });

  test('the benefit of the doubt goes to leaving the stamp alone', () {
    // The threshold is built from the LATEST instant the reading could be, so a
    // wide reading accuses fewer stamps, not more.
    final StampRepairDecision decision = policy.inspect(
      stamp: now.add(const Duration(minutes: 20)),
      now: reading(uncertainty: const Duration(minutes: 30)),
    );

    expect(decision.action, StampRepairAction.keep);
  });

  test('a stamp in the past is never a repair candidate', () {
    final StampRepairDecision decision = policy.inspect(
      stamp: now.subtract(const Duration(days: 400)),
      now: reading(),
    );

    expect(decision.action, StampRepairAction.keep);
  });

  group('plan', () {
    test('selects only the implausible ones, in the order given', () {
      final List<DateTime> stamps = <DateTime>[
        now.subtract(const Duration(hours: 1)),
        now.add(const Duration(days: 3)),
        now.add(const Duration(minutes: 1)),
        now.add(const Duration(hours: 30)),
      ];

      expect(
        policy.plan<DateTime>(
          stamps,
          stampOf: (DateTime stamp) => stamp,
          now: reading(),
        ),
        <DateTime>[stamps[1], stamps[3]],
      );
    });

    test('is empty, never partial, when the reading cannot be trusted', () {
      expect(
        policy.plan<DateTime>(
          <DateTime>[now.add(const Duration(days: 3))],
          stampOf: (DateTime stamp) => stamp,
          now: reading(confidence: TimeConfidence.deviceOnly),
        ),
        isEmpty,
      );
    });
  });
}
