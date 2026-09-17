import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image_codec/image_codec.dart';

/// Encodes a real PNG through the engine at test time.
///
/// Deliberately not a hand-written byte array. The implementation this package
/// replaces parsed PNG/JPEG headers itself, so a hand-built 24-byte stub was a
/// valid input for it — it is not a valid input for a real decoder, and pinning
/// this contract against one would assert against a file no image library would
/// accept.
Future<Uint8List> _encodePng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  image.dispose();
  return bytes.buffer.asUint8List();
}

void main() {
  // Every test here is a plain `test()`, never `testWidgets`. Measured on the
  // source implementation: `testWidgets` rewrites a throw in its body into a
  // generic framework failure, and awaiting real engine work inside its guarded
  // zone deadlocks against `pumpWidget`'s async guard — surfacing as a
  // ten-minute timeout rather than a failed assertion.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('readImageSize reads the header without decoding pixels', () {
    test('[partition] a valid image reports its encoded dimensions', () async {
      final Uint8List bytes = await _encodePng(800, 1200);

      final ImageSize? size = await ImageCodec.readImageSize(bytes);

      expect(size, isNotNull);
      expect(size!.width, 800);
      expect(size.height, 1200);
    });

    test(
      '[boundary] an image whose pixel data is truncated STILL reports its '
      'dimensions — this is what separates a header read from a full decode',
      () async {
        // A decoder that materialises the bitmap fails on these bytes; a header
        // read does not care that the pixel stream stops early. Asserting the
        // happy path alone would pass under either implementation, so it would
        // not pin the property this package exists to deliver.
        final Uint8List whole = await _encodePng(800, 1200);
        final Uint8List truncated = whole.sublist(0, whole.length ~/ 2);

        final ImageSize? size = await ImageCodec.readImageSize(truncated);

        expect(size, isNotNull);
        expect(size!.width, 800);
        expect(size.height, 1200);
      },
    );
  });

  group('unreadable bytes yield null, never a throw', () {
    // "These bytes are not an image" is an ordinary answer for a cover a user
    // picked or an image pulled out of an EPUB. Callers branch on null; a throw
    // would escape into paths that never expected one.
    test('[partition] bytes that are not an image return null', () async {
      final Uint8List garbage = Uint8List.fromList(
        List<int>.generate(64, (int i) => i),
      );

      expect(await ImageCodec.readImageSize(garbage), isNull);
    });

    test('[boundary] empty bytes return null', () async {
      expect(await ImageCodec.readImageSize(Uint8List(0)), isNull);
    });

    test(
      '[boundary] a valid signature with nothing after it returns null',
      () async {
        // A PNG signature alone — enough to look like an image to a signature
        // sniffer, not enough for a decoder to read a size from.
        final Uint8List signatureOnly = Uint8List.fromList(
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        );

        expect(await ImageCodec.readImageSize(signatureOnly), isNull);
      },
    );
  });

  group('isPixelDataComplete is a different question from readImageSize', () {
    test('[partition] a whole image has complete pixel data', () async {
      expect(
        await ImageCodec.isPixelDataComplete(await _encodePng(40, 60)),
        isTrue,
      );
    });

    test(
      '[boundary] a truncated image does NOT — and this is the exact case '
      'readImageSize reports success for, which is why both exist',
      () async {
        final Uint8List whole = await _encodePng(800, 1200);
        final Uint8List truncated = whole.sublist(0, whole.length ~/ 2);

        expect(await ImageCodec.readImageSize(truncated), isNotNull);
        expect(await ImageCodec.isPixelDataComplete(truncated), isFalse);
      },
    );

    test('[partition] non-empty garbage is not complete either', () async {
      // Deliberately NOT `Uint8List(0)` — empty is its own boundary, already
      // covered above, and feeding it here would have left the whole
      // "not an image" equivalence class untested while the test name claimed
      // otherwise.
      final Uint8List garbage = Uint8List.fromList(
        List<int>.generate(64, (int i) => i * 3),
      );

      expect(await ImageCodec.isPixelDataComplete(garbage), isFalse);
      expect(await ImageCodec.isPixelDataComplete(Uint8List(0)), isFalse);
    });
  });

  group('engine resources are released', () {
    // Mutation testing found all four `dispose()` calls in
    // engine_image_boundary.dart alive: delete any one and every other test
    // still passed, because nothing asserted release. These are not equivalent
    // mutants — an undisposed engine handle leaks native memory the Dart heap
    // cannot see, so it is invisible to everything except a leak report from a
    // real device.
    //
    // Three of the four are pinned here, by two different devices, because
    // `dart:ui` exposes disposal three different ways:
    //
    //   ui.Image           a static `onDispose` hook — no seam needed
    //   ui.ImageDescriptor `abstract class`, so a test can implement it
    //   ui.Codec           `abstract class`, same
    //   ui.ImmutableBuffer `base class` — the language forbids implementing it
    //                      outside its library, so this one stays unpinnable
    //
    // The last is named in the README rather than left to read as an untested
    // oversight. Reaching the middle two needed the factory seam on
    // EngineImageBoundary; the reasoning for paying that cost is on the seam
    // itself.
    test(
      '[partition] the 1x1 decode disposes the frame image it allocates',
      () async {
        // Encoded BEFORE the hook is installed: `_encodePng` disposes an image
        // of its own, and counting that one would make this pass even if the
        // boundary released nothing.
        final Uint8List bytes = await _encodePng(20, 20);

        int disposed = 0;
        ui.Image.onDispose = (ui.Image _) => disposed++;
        addTearDown(() => ui.Image.onDispose = null);

        await ImageCodec.isPixelDataComplete(bytes);

        expect(
          disposed,
          1,
          reason:
              'isPixelDataComplete allocates exactly one frame image and '
              'must release it; deleting `frame.image.dispose()` makes this 0',
        );
      },
    );

    test(
      '[partition] the header read disposes the descriptor it opens',
      () async {
        // `ui.ImageDescriptor` is an `abstract class`, so a test CAN implement
        // it — which is the only reason this call is observable at all.
        // `ImmutableBuffer` is a `base class`, so its `dispose()` stays
        // unpinnable and is named as such in the README.
        final _RecordingDescriptor fake = _RecordingDescriptor(1024, 768);
        EngineImageBoundary.descriptorFactory = (ui.ImmutableBuffer _) async =>
            fake;
        addTearDown(EngineImageBoundary.resetFactories);

        final ImageSize? size = await ImageCodec.readImageSize(
          await _encodePng(10, 10),
        );

        expect(
          size,
          const ImageSize(width: 1024, height: 768),
          reason:
              'the fake must actually be the one consulted, or the '
              'disposal assertion below is vacuous',
        );
        expect(fake.disposeCount, 1);
      },
    );

    test(
      '[boundary] the descriptor is disposed even when reading it throws',
      () async {
        // The `finally` is the whole point: a descriptor opened and then failed
        // on still has to be released. Deleting `descriptor.dispose()` makes
        // this 0 while the method still returns null, so the null-on-failure
        // contract alone cannot catch the leak.
        final _RecordingDescriptor fake = _RecordingDescriptor.throwing();
        EngineImageBoundary.descriptorFactory = (ui.ImmutableBuffer _) async =>
            fake;
        addTearDown(EngineImageBoundary.resetFactories);

        expect(
          await ImageCodec.readImageSize(await _encodePng(10, 10)),
          isNull,
        );
        expect(fake.disposeCount, 1);
      },
    );

    test('[boundary] resetFactories puts BOTH factories back', () async {
      // A hole the seam itself introduced, found by mutation testing: deleting
      // the `codecFactory = ...` line inside `resetFactories` left every test
      // green, because each one overrode only the factory it cared about and
      // nothing ever checked the reset was complete. A half-working reset
      // leaks a fake into whatever test runs next — the worst kind of failure,
      // since it lands somewhere other than the code that caused it.
      final _RecordingDescriptor descriptor = _RecordingDescriptor(1, 1);
      final _RecordingCodec codec = _RecordingCodec();
      EngineImageBoundary.descriptorFactory = (ui.ImmutableBuffer _) async =>
          descriptor;
      EngineImageBoundary.codecFactory =
          (Uint8List _, {int? targetWidth, int? targetHeight}) async => codec;

      EngineImageBoundary.resetFactories();

      // Asserted through behaviour, not identity: a real read now reports the
      // real dimensions rather than the fake's 1x1, and a real decode of a
      // whole image succeeds rather than hitting the fake's throw.
      final Uint8List bytes = await _encodePng(64, 48);
      expect(
        await ImageCodec.readImageSize(bytes),
        const ImageSize(width: 64, height: 48),
        reason: 'descriptorFactory was not restored',
      );
      expect(
        await ImageCodec.isPixelDataComplete(bytes),
        isTrue,
        reason: 'codecFactory was not restored',
      );
      expect(descriptor.disposeCount, 0);
      expect(codec.disposeCount, 0);
    });

    test('[partition] the 1x1 decode disposes the codec it opens', () async {
      final _RecordingCodec fake = _RecordingCodec();
      EngineImageBoundary.codecFactory =
          (Uint8List _, {int? targetWidth, int? targetHeight}) async => fake;
      addTearDown(EngineImageBoundary.resetFactories);

      await ImageCodec.isPixelDataComplete(await _encodePng(10, 10));

      expect(fake.disposeCount, 1);
    });

    test(
      '[boundary] a failed decode allocates no frame image to leak',
      () async {
        // The throwing path. `getNextFrame` never returns, so there is no image
        // to dispose — and the `finally` that disposes the codec must still run.
        // Asserting zero here is what stops the test above from being satisfied
        // by a dispose that fires on every call regardless of the path taken.
        int disposed = 0;
        ui.Image.onDispose = (ui.Image _) => disposed++;
        addTearDown(() => ui.Image.onDispose = null);

        expect(await ImageCodec.isPixelDataComplete(Uint8List(0)), isFalse);
        expect(disposed, 0);
      },
    );
  });

  group('decodeImageSizes omits what it cannot read', () {
    test(
      '[partition] readable entries resolve, unreadable ones are omitted',
      () async {
        final Uint8List good = await _encodePng(40, 60);
        final Uint8List bad = Uint8List.fromList(
          List<int>.generate(32, (int i) => 255 - i),
        );

        final Map<String, ImageSize> sizes = await ImageCodec.decodeImageSizes(
          <String, Uint8List>{'good': good, 'bad': bad},
        );

        expect(sizes.keys, <String>['good']);
        expect(sizes['good']!.width, 40);
        expect(sizes['good']!.height, 60);
      },
    );

    test('[boundary] an empty input map resolves to an empty result', () async {
      expect(
        await ImageCodec.decodeImageSizes(<String, Uint8List>{}),
        isEmpty,
      );
    });
  });

  group('encodeWebp reports failure as this package\'s own type', () {
    test('[boundary] empty bytes are rejected BEFORE the platform check', () {
      // The message is the assertion, not the type. On a host that is neither
      // Android nor iOS the platform guard also throws ImageCodecEncodeException,
      // so `throwsA(isA<ImageCodecEncodeException>())` alone cannot tell the two
      // guards apart: delete the empty-bytes check entirely and a type-only
      // assertion still passes here. Naming the message is what makes this
      // test able to go red for its own reason.
      expect(
        () => WebpEncoder.encodeWebp(Uint8List(0)),
        throwsA(
          isA<ImageCodecEncodeException>().having(
            (ImageCodecEncodeException e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('[partition] the thrown type is an Exception, not an Error', () {
      // flutter_image_compress throws `CompressError extends Error`. Letting
      // that shape reach a caller would hand them an Error for an input they
      // do not control, and `on Error` is not something a consumer should have
      // to write.
      expect(const ImageCodecEncodeException('x'), isA<Exception>());
      expect(const ImageCodecEncodeException('x'), isNot(isA<Error>()));
      expect(const ImageCodecDecodeException('x'), isA<ImageCodecException>());
    });

    test('[partition] cause survives the type collapse', () async {
      // The whole justification for `cause` is on the exception class:
      // "collapsing the type must not also destroy the evidence". Nothing
      // asserted it, so the field could have been dropped — or never
      // populated, which is what a review found it actually was — without a
      // single test noticing.
      final ArgumentError original = ArgumentError('the underlying failure');
      const String message = 'could not encode';
      final ImageCodecEncodeException wrapped = ImageCodecEncodeException(
        message,
        cause: original,
      );

      expect(wrapped.cause, same(original));
      expect(wrapped.toString(), contains(message));
      expect(
        wrapped.toString(),
        contains('the underlying failure'),
        reason:
            'toString must surface the cause, or the evidence is only '
            'reachable by a caller who already knows to look for it',
      );
    });

    test('[boundary] toString without a cause omits the empty parentheses', () {
      // The other arm of the ternary. Both were dark.
      const ImageCodecEncodeException bare = ImageCodecEncodeException(
        'no cause here',
      );

      expect(bare.toString(), contains('no cause here'));
      expect(bare.toString(), isNot(contains('(')));
    });
  });
}

/// An [ui.ImageDescriptor] that records whether it was released.
///
/// Possible only because `ImageDescriptor` is an `abstract class`. Its sibling
/// `ImmutableBuffer` is a `base class`, which the language refuses to let a
/// test implement — that is the whole reason one of the boundary's four
/// `dispose()` calls stays unpinnable.
class _RecordingDescriptor implements ui.ImageDescriptor {
  _RecordingDescriptor(this._width, this._height) : _throws = false;
  _RecordingDescriptor.throwing() : _width = 0, _height = 0, _throws = true;

  final int _width;
  final int _height;
  final bool _throws;
  int disposeCount = 0;

  @override
  int get width => _throws
      ? throw const _SimulatedEngineException('cannot read width')
      : _width;

  @override
  int get height => _height;

  @override
  int get bytesPerPixel => 4;

  @override
  void dispose() => disposeCount++;

  @override
  Future<ui.Codec> instantiateCodec({
    int? targetWidth,
    int? targetHeight,
    ui.TargetPixelFormat targetFormat = ui.TargetPixelFormat.dontCare,
  }) => throw UnimplementedError();
}

/// A [ui.Codec] that records whether it was released.
class _RecordingCodec implements ui.Codec {
  int disposeCount = 0;

  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() =>
      throw const _SimulatedEngineException('decode failed');

  @override
  void dispose() => disposeCount++;
}

/// Stands in for the engine's own failure.
///
/// The real thing is a bare `Exception` — `dart:ui` has no typed hierarchy —
/// but a named subtype exercises the identical path, because the boundary
/// catches `on Exception` and every subtype is caught by it. If someone ever
/// narrows that catch, the real engine's bare throw and this one BOTH stop
/// being caught, so the fidelity that matters is preserved while the house
/// rule against throwing a generic Exception stays satisfied.
class _SimulatedEngineException implements Exception {
  const _SimulatedEngineException(this.message);
  final String message;
  @override
  String toString() => 'SimulatedEngineException: $message';
}
