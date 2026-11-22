import 'package:clock_anchor/clock_anchor.dart';
import 'package:test/test.dart';

import 'support/fake_monotonic_ticks.dart';
import 'support/mutable_wall_clock.dart';

/// `HttpDateTimeSource` — the three date forms RFC 9110 requires a recipient
/// to accept, everything it must refuse, and the resolution arithmetic.
void main() {
  final DateTime expected = DateTime.utc(1994, 11, 6, 8, 49, 37);

  late FakeMonotonicTicks ticks;
  late MutableWallClock device;

  setUp(() {
    ticks = FakeMonotonicTicks(const Duration(minutes: 7));
    device = MutableWallClock(DateTime.utc(2026, 9, 1));
  });

  group('parsing', () {
    test('IMF-fixdate, the form every modern server sends', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sun, 06 Nov 1994 08:49:37 GMT'),
        expected,
      );
    });

    test('the obsolete RFC 850 form', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sunday, 06-Nov-94 08:49:37 GMT'),
        expected,
      );
    });

    test('the obsolete asctime form, including its space-padded day', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sun Nov  6 08:49:37 1994'),
        expected,
      );
      expect(
        HttpDateTimeSource.parseHttpDate('Sun Nov 16 08:49:37 1994'),
        DateTime.utc(1994, 11, 16, 8, 49, 37),
      );
    });

    test('two-digit years split at 70', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sunday, 06-Nov-69 08:49:37 GMT'),
        DateTime.utc(2069, 11, 6, 8, 49, 37),
      );
      expect(
        HttpDateTimeSource.parseHttpDate('Sunday, 06-Nov-70 08:49:37 GMT'),
        DateTime.utc(1970, 11, 6, 8, 49, 37),
      );
    });

    test('surrounding whitespace is tolerated', () {
      expect(
        HttpDateTimeSource.parseHttpDate('  Sun, 06 Nov 1994 08:49:37 GMT '),
        expected,
      );
    });

    test('a day that does not exist is malformed, not three days later', () {
      // `DateTime.utc` rolls Feb 31 into Mar 3 without complaining, so a
      // header naming an impossible day would otherwise parse as a real
      // instant that is simply wrong.
      expect(
        HttpDateTimeSource.parseHttpDate('Mon, 31 Feb 2026 08:49:37 GMT'),
        isNull,
      );
      expect(
        HttpDateTimeSource.parseHttpDate('Mon, 29 Feb 2026 08:49:37 GMT'),
        isNull,
      );
      expect(
        HttpDateTimeSource.parseHttpDate('Thu, 29 Feb 2024 08:49:37 GMT'),
        DateTime.utc(2024, 2, 29, 8, 49, 37),
      );
    });

    test('a leap second rolls into the next minute', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sun, 31 Dec 2016 23:59:60 GMT'),
        DateTime.utc(2017),
      );
    });

    test('out-of-range and unparsable values are null, never a throw', () {
      for (final String malformed in <String>[
        '',
        'not a date at all',
        'Sun, 06 Nov 1994 08:49:37',
        'Sun, 06 Xxx 1994 08:49:37 GMT',
        'Sun, 06 Nov 1994 25:49:37 GMT',
        'Sun, 06 Nov 1994 08:61:37 GMT',
        'Sun, 06 Nov 1994 08:49:61 GMT',
        'Sun, 00 Nov 1994 08:49:37 GMT',
        'Sun, 06 Nov 1994 08:49:37 UTC',
      ]) {
        expect(
          HttpDateTimeSource.parseHttpDate(malformed),
          isNull,
          reason: 'input of length ${malformed.length}',
        );
      }
    });
  });

  group('sampling', () {
    HttpDateTimeSource buildSource(
      Future<String?> Function(Uri uri) probe,
    ) => HttpDateTimeSource(
      id: 'cdn',
      uri: Uri.parse('https://example.test/'),
      ticks: ticks,
      probe: probe,
      deviceClock: device.clock,
    );

    test(
      'the one-second resolution shows up in estimate and uncertainty',
      () async {
        final HttpDateTimeSource source = buildSource((Uri uri) async {
          ticks.advance(const Duration(milliseconds: 200));
          return 'Sun, 06 Nov 1994 08:49:37 GMT';
        });

        final TimeSample sample = await source.sample();

        // Half the round trip (100 ms) plus half a resolution step (500 ms),
        // both as offset and as error bar: the header could have been generated
        // anywhere inside that second.
        expect(
          sample.remoteUtc,
          expected.add(const Duration(milliseconds: 600)),
        );
        expect(sample.uncertainty, const Duration(milliseconds: 600));
        expect(sample.trust, TimeSourceTrust.transportAuthenticated);
      },
    );

    test('a TLS-carried source is allowed to lower the watermark', () {
      expect(
        TimeSourceTrust.transportAuthenticated.canLowerWatermark,
        isTrue,
      );
    });

    test('a missing header is a declared failure', () async {
      await expectLater(
        buildSource((Uri uri) async => null).sample(),
        throwsA(isA<HttpDateException>()),
      );
    });

    test(
      'an unparsable header is a declared failure carrying no bytes',
      () async {
        try {
          await buildSource((Uri uri) async => 'Yesterday afternoon').sample();
          fail('expected a rejection');
        } on HttpDateException catch (error) {
          expect(error.reason, isNot(contains('Yesterday')));
          expect(error.reason, contains('length 19'));
        }
      },
    );
  });

  group('field bounds', () {
    test('the low end of every field is accepted', () {
      // Zero is a legal second and a legal minute; rejecting it would be an
      // off-by-one in the guard rather than in the format.
      expect(
        HttpDateTimeSource.parseHttpDate('Thu, 01 Jan 2026 00:00:00 GMT'),
        DateTime.utc(2026),
      );
    });

    test('the high end of every field is accepted', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Thu, 31 Dec 2026 23:59:59 GMT'),
        DateTime.utc(2026, 12, 31, 23, 59, 59),
      );
    });

    test('a zero year or a zero day is malformed', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sun, 06 Nov 0000 08:49:37 GMT'),
        isNull,
      );
      expect(
        HttpDateTimeSource.parseHttpDate('Sun, 00 Nov 2026 08:49:37 GMT'),
        isNull,
      );
    });
  });

  group('year bounds', () {
    test('the two-digit year 00 is 2000, not a rejection', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Sunday, 06-Nov-00 08:49:37 GMT'),
        DateTime.utc(2000, 11, 6, 8, 49, 37),
      );
    });

    test('the first and last years DateTime can express are accepted', () {
      expect(
        HttpDateTimeSource.parseHttpDate('Mon, 06 Nov 0001 08:49:37 GMT'),
        DateTime.utc(1, 11, 6, 8, 49, 37),
      );
      expect(
        HttpDateTimeSource.parseHttpDate('Mon, 06 Nov 9999 08:49:37 GMT'),
        DateTime.utc(9999, 11, 6, 8, 49, 37),
      );
    });
  });
}
