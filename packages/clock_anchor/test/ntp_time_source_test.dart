import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock_anchor/clock_anchor.dart';
import 'package:clock_anchor/clock_anchor_ntp.dart';
import 'package:test/test.dart';

import 'support/fake_monotonic_ticks.dart';
import 'support/mutable_wall_clock.dart';
import 'support/scripted_ntp_exchange.dart';

/// `NtpTimeSource` — every way a reply can be unusable, and the one way it is
/// usable.
///
/// The rejections matter more than the happy path. This source is
/// unauthenticated by construction, so the only thing standing between a
/// hostile or broken reply and the app's notion of time is this list.
void main() {
  final DateTime serverTime = DateTime.utc(2026, 9, 3, 12);

  late FakeMonotonicTicks ticks;
  late MutableWallClock device;

  setUp(() {
    ticks = FakeMonotonicTicks(const Duration(minutes: 7));
    device = MutableWallClock(DateTime.utc(2026, 9, 1));
  });

  void writeUint32(Uint8List bytes, int offset, int value) {
    bytes[offset] = (value >> 24) & 0xFF;
    bytes[offset + 1] = (value >> 16) & 0xFF;
    bytes[offset + 2] = (value >> 8) & 0xFF;
    bytes[offset + 3] = value & 0xFF;
  }

  int readUint32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  int ntpSecondsFor(DateTime instant) {
    final int unix = instant.millisecondsSinceEpoch ~/ 1000;
    final int era0 = unix + NtpPacket.ntpToUnixSeconds;
    return era0 > 0xFFFFFFFF ? era0 - 0x100000000 : era0;
  }

  /// A well-formed reply that echoes [request]'s nonce, adjustable per test.
  Uint8List replyTo(
    Uint8List request, {
    int leapIndicator = 0,
    int mode = 4,
    int stratum = 2,
    DateTime? transmit,
    bool echoNonce = true,
    bool zeroTransmit = false,
    String kiss = '',
  }) {
    final Uint8List bytes = Uint8List(NtpPacket.packetLength);
    bytes[0] = (leapIndicator << 6) | (4 << 3) | mode;
    bytes[1] = stratum;
    for (int index = 0; index < kiss.length && index < 4; index += 1) {
      bytes[12 + index] = kiss.codeUnitAt(index);
    }
    if (echoNonce) {
      writeUint32(
        bytes,
        NtpPacket.originateOffset,
        readUint32(request, NtpPacket.transmitOffset),
      );
      writeUint32(
        bytes,
        NtpPacket.originateOffset + 4,
        readUint32(request, NtpPacket.transmitOffset + 4),
      );
    }
    if (!zeroTransmit) {
      writeUint32(
        bytes,
        NtpPacket.transmitOffset,
        ntpSecondsFor(transmit ?? serverTime),
      );
    }
    return bytes;
  }

  NtpTimeSource buildSource(
    Uint8List Function(Uint8List request) handler, {
    DateTime? plausibleFrom,
    DateTime? plausibleUntil,
  }) => NtpTimeSource(
    ticks: ticks,
    exchange: ScriptedNtpExchange(handler),
    deviceClock: device.clock,
    plausibleFrom: plausibleFrom,
    plausibleUntil: plausibleUntil,
  );

  test('is unauthenticated, and therefore may not lower the watermark', () {
    expect(
      buildSource(replyTo).trust,
      TimeSourceTrust.unauthenticated,
    );
    expect(TimeSourceTrust.unauthenticated.canLowerWatermark, isFalse);
  });

  group('a usable reply', () {
    test(
      'folds half the round trip into both estimate and uncertainty',
      () async {
        final NtpTimeSource source = buildSource((Uint8List request) {
          // The round trip is 80 ms of monotonic time.
          ticks.advance(const Duration(milliseconds: 80));
          return replyTo(request);
        });

        final TimeSample sample = await source.sample();

        expect(
          sample.remoteUtc,
          serverTime.add(const Duration(milliseconds: 40)),
        );
        expect(sample.uncertainty, const Duration(milliseconds: 40));
        expect(
          sample.ticksAtReceipt,
          const Duration(minutes: 7, milliseconds: 80),
        );
        expect(sample.trust, TimeSourceTrust.unauthenticated);
      },
    );

    test(
      'measures the round trip monotonically, not on the device clock',
      () async {
        final NtpTimeSource source = buildSource((Uint8List request) {
          ticks.advance(const Duration(milliseconds: 80));
          // The user moves the phone's clock while the request is in flight.
          // RFC 4330's offset formula reads the device clock on both sides and
          // would produce nonsense here; this one never reads it.
          device.now = DateTime.utc(2031);
          return replyTo(request);
        });

        final TimeSample sample = await source.sample();

        expect(sample.uncertainty, const Duration(milliseconds: 40));
        expect(
          sample.remoteUtc,
          serverTime.add(const Duration(milliseconds: 40)),
        );
      },
    );
  });

  group('rejections', () {
    Future<void> expectRejected(
      Uint8List Function(Uint8List request) handler,
      String fragment,
    ) async {
      await expectLater(
        buildSource(handler).sample(),
        throwsA(
          isA<NtpQueryException>().having(
            (NtpQueryException error) => error.reason,
            'reason',
            contains(fragment),
          ),
        ),
      );
    }

    test('a reply shorter than an SNTP message', () async {
      await expectRejected(
        (Uint8List request) => Uint8List(20),
        'shorter than an SNTP message',
      );
    });

    test('a reply that is not in server mode', () async {
      await expectRejected(
        (Uint8List request) => replyTo(request, mode: 3),
        'is not server',
      );
    });

    test('a server declaring itself unsynchronized', () async {
      await expectRejected(
        (Uint8List request) => replyTo(request, leapIndicator: 3),
        'unsynchronized',
      );
    });

    test('a kiss-o-death, with its code preserved for diagnostics', () async {
      await expectRejected(
        (Uint8List request) => replyTo(request, stratum: 0, kiss: 'DENY'),
        'kiss-o-death (DENY)',
      );
    });

    test('an unusable stratum', () async {
      await expectRejected(
        (Uint8List request) => replyTo(request, stratum: 16),
        'stratum 16',
      );
    });

    test('a reply that does not echo the nonce', () async {
      // A blind off-path spoofer cannot see the request, so it cannot echo
      // the nonce. This does not stop an on-path attacker, and the trust
      // level says so.
      await expectRejected(
        (Uint8List request) => replyTo(request, echoNonce: false),
        'does not echo request',
      );
    });

    test('a zero transmit timestamp', () async {
      await expectRejected(
        (Uint8List request) => replyTo(request, zeroTransmit: true),
        'transmit timestamp is zero',
      );
    });

    test('a timestamp outside the plausible window', () async {
      await expectRejected(
        (Uint8List request) =>
            replyTo(request, transmit: DateTime.utc(1971, 2, 3)),
        'outside plausible range',
      );
    });
  });

  group('transport failures become declared exceptions', () {
    test('a socket failure', () async {
      await expectLater(
        buildSource((Uint8List request) {
          throw const SocketException('unreachable');
        }).sample(),
        throwsA(isA<NtpQueryException>()),
      );
    });

    test('a timeout', () async {
      await expectLater(
        buildSource((Uint8List request) {
          throw TimeoutException('no reply', const Duration(seconds: 5));
        }).sample(),
        throwsA(
          isA<NtpQueryException>().having(
            (NtpQueryException error) => error.reason,
            'reason',
            contains('no reply within'),
          ),
        ),
      );
    });

    test('the exception carries no bytes from the reply', () async {
      // The message reaches a log, and on both consuming apps a log message
      // travels verbatim to a crash reporter.
      try {
        await buildSource(
          (Uint8List request) => replyTo(request, stratum: 16),
        ).sample();
        fail('expected a rejection');
      } on NtpQueryException catch (error) {
        expect(error.toString(), isNot(contains('[')));
        expect(error.reason, 'stratum 16 is unusable');
      }
    });
  });

  group('constructor defaults are defaults, not hard-coded values', () {
    test('an injected random is what produces the nonce', () async {
      // Not decoration: the nonce is the anti-spoofing echo, and a source
      // that ignored its injected generator would be untestable for it.
      final Random seeded = Random(20260903);
      final int firstNonce = seeded.nextInt(0x100000000);
      final int secondNonce = seeded.nextInt(0x100000000);

      final ScriptedNtpExchange exchange = ScriptedNtpExchange(replyTo);
      await NtpTimeSource(
        ticks: ticks,
        exchange: exchange,
        deviceClock: device.clock,
        random: Random(20260903),
      ).sample();

      final NtpPacket? sent = NtpPacket.parse(
        exchange.lastRequest ?? Uint8List(0),
      );
      expect(sent?.transmitSeconds, firstNonce);
      expect(sent?.transmitFraction, secondNonce);
    });

    test('an injected plausible window overrides the default', () async {
      // 2021 is inside the default window and outside this one, so only a
      // source that actually reads the injected value rejects it.
      await expectLater(
        buildSource(
          (Uint8List request) =>
              replyTo(request, transmit: DateTime.utc(2021, 5, 5)),
          plausibleFrom: DateTime.utc(2026),
        ).sample(),
        throwsA(isA<NtpQueryException>()),
      );

      await expectLater(
        buildSource(
          (Uint8List request) =>
              replyTo(request, transmit: DateTime.utc(2030, 5, 5)),
          plausibleUntil: DateTime.utc(2027),
        ).sample(),
        throwsA(isA<NtpQueryException>()),
      );
    });

    test('with no window given, the defaults still bound the reply', () async {
      await expectLater(
        NtpTimeSource(
          ticks: ticks,
          exchange: ScriptedNtpExchange(
            (Uint8List request) =>
                replyTo(request, transmit: DateTime.utc(1971, 2, 3)),
          ),
          deviceClock: device.clock,
        ).sample(),
        throwsA(isA<NtpQueryException>()),
      );

      final TimeSample sample = await NtpTimeSource(
        ticks: ticks,
        exchange: ScriptedNtpExchange(replyTo),
        deviceClock: device.clock,
      ).sample();
      expect(sample.remoteUtc, serverTime);
    });
  });
}
