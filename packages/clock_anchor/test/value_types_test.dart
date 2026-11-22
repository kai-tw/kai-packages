import 'package:clock_anchor/clock_anchor.dart';
import 'package:test/test.dart';

import 'support/fake_monotonic_ticks.dart';
import 'support/mutable_wall_clock.dart';

/// The small surfaces — derived getters, the ordering extensions, the
/// in-memory store, and every `toString`.
///
/// `toString` is here because these objects are what a diagnostic log line
/// carries, and the one thing they must never carry is a remote payload. A
/// format that silently started interpolating one would be invisible without
/// an assertion on the string itself.
void main() {
  final DateTime instant = DateTime.utc(2026, 9, 3, 12);

  group('TimeReading', () {
    TimeReading reading({
      TimeConfidence confidence = TimeConfidence.anchored,
      Duration uncertainty = const Duration(minutes: 5),
    }) => TimeReading(
      utc: instant,
      confidence: confidence,
      uncertainty: uncertainty,
    );

    test('earliest and latest bracket the estimate', () {
      expect(reading().earliest, instant.subtract(const Duration(minutes: 5)));
      expect(reading().latest, instant.add(const Duration(minutes: 5)));
    });

    test('only a fresh anchor is trustworthy', () {
      expect(reading().isTrustworthy, isTrue);
      for (final TimeConfidence weaker in <TimeConfidence>[
        TimeConfidence.unknown,
        TimeConfidence.deviceOnly,
        TimeConfidence.staleAnchor,
      ]) {
        expect(reading(confidence: weaker).isTrustworthy, isFalse);
      }
    });

    test('a local DateTime is normalised on the way in', () {
      final TimeReading local = TimeReading(
        utc: instant.toLocal(),
        confidence: TimeConfidence.anchored,
        uncertainty: Duration.zero,
      );

      expect(local.utc.isUtc, isTrue);
      expect(local.utc, instant);
    });

    test('describes itself without inventing precision', () {
      expect(
        reading().toString(),
        'TimeReading($instant, anchored, +/-0:05:00.000000)',
      );
    });
  });

  group('ordering extensions', () {
    test('TimeConfidence compares by strength', () {
      expect(
        TimeConfidence.anchored.isAtLeast(TimeConfidence.staleAnchor),
        isTrue,
      );
      expect(
        TimeConfidence.deviceOnly.isAtLeast(TimeConfidence.anchored),
        isFalse,
      );
      expect(
        TimeConfidence.unknown.isAtLeast(TimeConfidence.unknown),
        isTrue,
      );
    });

    test('TimeSourceTrust compares by strength', () {
      expect(
        TimeSourceTrust.serverAttested.isAtLeast(
          TimeSourceTrust.transportAuthenticated,
        ),
        isTrue,
      );
      expect(
        TimeSourceTrust.unauthenticated.isAtLeast(
          TimeSourceTrust.transportAuthenticated,
        ),
        isFalse,
      );
    });

    test('only an authenticated source may lower the watermark', () {
      expect(TimeSourceTrust.unauthenticated.canLowerWatermark, isFalse);
      expect(
        TimeSourceTrust.transportAuthenticated.canLowerWatermark,
        isTrue,
      );
      expect(TimeSourceTrust.serverAttested.canLowerWatermark, isTrue);
    });
  });

  group('TimeSample', () {
    TimeSample sample() => TimeSample(
      remoteUtc: instant,
      ticksAtReceipt: const Duration(seconds: 3),
      deviceWallAtReceipt: instant.subtract(const Duration(minutes: 90)),
      uncertainty: const Duration(milliseconds: 40),
      trust: TimeSourceTrust.serverAttested,
      sourceId: 'firestore',
    );

    test('reports the device clock error at the moment of sampling', () {
      expect(sample().deviceOffset, const Duration(minutes: 90));
    });

    test('describes itself with no remote payload', () {
      expect(
        sample().toString(),
        'TimeSample(firestore, serverAttested, '
        'remoteUtc=$instant, uncertainty=0:00:00.040000)',
      );
    });
  });

  group('TimeAnchor', () {
    test('describes itself', () {
      final TimeAnchor anchor = TimeAnchor(
        referenceUtc: instant,
        ticksAtReference: Duration.zero,
        deviceWallAtReference: instant,
        uncertainty: Duration.zero,
        trust: TimeSourceTrust.transportAuthenticated,
        sourceId: 'cdn',
      );

      expect(
        anchor.toString(),
        'TimeAnchor(cdn, transportAuthenticated, referenceUtc=$instant)',
      );
    });
  });

  group('ClockIntegrityReport', () {
    test('isRolledBack is true only for the rollback verdict', () {
      for (final ClockIntegrityVerdict verdict
          in ClockIntegrityVerdict.values) {
        final ClockIntegrityReport report = ClockIntegrityReport(
          verdict: verdict,
          delta: Duration.zero,
          watermark: instant,
        );

        expect(
          report.isRolledBack,
          verdict == ClockIntegrityVerdict.rolledBack,
          reason: verdict.name,
        );
      }
    });

    test('describes itself', () {
      expect(
        const ClockIntegrityReport(
          verdict: ClockIntegrityVerdict.advanced,
          delta: Duration(hours: 2),
          watermark: null,
        ).toString(),
        'ClockIntegrityReport(advanced, delta=2:00:00.000000)',
      );
    });
  });

  group('StampRepairDecision', () {
    test('isRepairNeeded is true only for the repair action', () {
      expect(const StampRepairDecision.keep().isRepairNeeded, isFalse);
      expect(const StampRepairDecision.defer().isRepairNeeded, isFalse);
      expect(
        StampRepairDecision.repair(
          repairedTo: instant,
          excess: const Duration(days: 3),
        ).isRepairNeeded,
        isTrue,
      );
    });

    test('describes itself', () {
      expect(
        StampRepairDecision.repair(
          repairedTo: instant,
          excess: const Duration(minutes: 90),
        ).toString(),
        'StampRepairDecision(repair, excess=1:30:00.000000)',
      );
    });
  });

  group('InMemoryWatermarkStore', () {
    test(
      'starts empty unless seeded, and reads back what it is given',
      () async {
        final InMemoryWatermarkStore empty = InMemoryWatermarkStore();
        expect(await empty.read(), isNull);

        await empty.write(instant.toLocal());
        final DateTime? stored = await empty.read();
        expect(stored, instant);
        expect(stored?.isUtc, isTrue);

        final InMemoryWatermarkStore seeded = InMemoryWatermarkStore(instant);
        expect(await seeded.read(), instant);
      },
    );
  });

  group('StopwatchMonotonicTicks', () {
    test('starts on construction and never decreases', () async {
      final StopwatchMonotonicTicks ticks = StopwatchMonotonicTicks();

      final Duration first = ticks.elapsed;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final Duration second = ticks.elapsed;

      expect(first, greaterThanOrEqualTo(Duration.zero));
      expect(second, greaterThan(first));
    });
  });

  group('FakeMonotonicTicks', () {
    test('refuses to go backwards, because a monotonic source cannot', () {
      final FakeMonotonicTicks ticks = FakeMonotonicTicks();

      expect(
        () => ticks.advance(const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('ClockAnchorService', () {
    test('exposes the integrity state without an observation', () {
      final ClockIntegrity integrity = ClockIntegrity(
        store: InMemoryWatermarkStore(),
      );
      final ClockAnchorService service = ClockAnchorService(
        ticks: FakeMonotonicTicks(),
        integrity: integrity,
        deviceClock: MutableWallClock(instant).clock,
      );

      // A pure read, unlike `checkIntegrity()`, which also raises the
      // watermark — a caller that only wants to render the state should not
      // have to write to storage to learn it.
      expect(service.integrity, same(integrity));
      expect(service.integrity.isRolledBack, isFalse);
    });
  });
}
