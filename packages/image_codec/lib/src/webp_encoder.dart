import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

import 'image_codec.dart';
import 'image_codec_exception.dart';

/// Re-encodes image bytes as WebP.
///
/// Split from [ImageCodec] rather than sharing its class, because the two are
/// unrelated jobs that happen to take the same input. Reading facts out of
/// bytes and turning bytes into other bytes have different dependencies
/// (`dart:ui` versus `package:image` + a native plugin), different failure
/// modes, and — decisively — different testability: every read is exercised by
/// the unit suite, while nothing here runs under `flutter test` at all,
/// because no platform compressor is registered in that environment.
///
/// Keeping them in one file made that second fact invisible. Mutation testing
/// scored the combined file at 41%, which reads as "under-tested" when it
/// actually meant "one well-tested half averaged with one unreachable half".
/// Separated, each number says something true: the read half is measurable and
/// high, this file is honestly zero until an `integration_test/` runs on a real
/// device.
abstract final class WebpEncoder {
  /// Re-encodes [bytes] as WebP.
  ///
  /// **Android and iOS only.** `flutter_image_compress` hard-gates WebP to
  /// those two platforms and throws `UnsupportedError` everywhere else, and
  /// when no platform implementation is registered at all — which is the state
  /// of every plain `flutter test` run — its default stub throws
  /// `UnimplementedError`. Both are `Error` subtypes, so neither can be caught
  /// without violating this repo's own `avoid_catching_error`. This method
  /// therefore **checks the platform before calling** rather than catching
  /// afterwards: prevention converts a whole class of uncatchable `Error` into
  /// this package's own [ImageCodecEncodeException] without a catch clause anywhere.
  ///
  /// **Silently resizes when the source is large.** The compressor's
  /// [minWidth]/[minHeight] are a FLOOR on the result, not a ceiling, and the
  /// name is upstream's because the name is correct. The image is scaled DOWN
  /// by the smallest factor that brings one axis to its limit, and the other
  /// axis then lands above its own:
  ///
  ///     scale  = max(1.0, min(srcW / minWidth, srcH / minHeight))
  ///     result = src / scale
  ///
  /// So 4032x3024 at the defaults comes back **1920x1440** — width exactly at
  /// the limit, height 360px above it. Both axes end up >= their minimum,
  /// which is what "min" means here. Passing `minHeight: 2000` does NOT cap
  /// the height at 2000; it guarantees the result is at least 2000 tall.
  ///
  /// Nothing is ever scaled up: `max(1.0, …)` clamps the factor, so a source
  /// already smaller than both limits passes through untouched.
  ///
  /// They are passed explicitly rather than defaulted so the transform is a
  /// decision the caller can see. `readImageSize` before and after will differ
  /// whenever the source exceeds them — that is the contract, not a bug.
  ///
  /// The passthrough hands the source bytes straight to the native compressor,
  /// skipping a decode and a PNG re-encode when the platform already reads that
  /// format. Its result is verified by reading the dimensions back, because the
  /// Dart layer cannot tell us whether a *native* decoder accepted odd input
  /// and produced a wrong image. That check catches "not an image at all"; it
  /// cannot catch correct-sized-but-wrong-pixels, which would need a real
  /// device to establish.
  ///
  /// Throws [ImageCodecEncodeException] on an unsupported platform, on empty or
  /// undecodable bytes, and when neither encode path produces output.
  static Future<Uint8List> encodeWebp(
    Uint8List bytes, {
    int quality = 85,
    int minWidth = 1920,
    int minHeight = 1080,
  }) async {
    if (bytes.isEmpty) {
      throw const ImageCodecEncodeException('cannot encode empty bytes');
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw ImageCodecEncodeException(
        'WebP encoding is available on Android and iOS only; this is '
        '${Platform.operatingSystem}',
      );
    }
    final Uint8List? direct = await _compressOrNull(
      bytes,
      quality,
      minWidth,
      minHeight,
    );
    if (direct != null && await ImageCodec.readImageSize(direct) != null) {
      return direct;
    }
    return _reEncodeViaPng(bytes, quality, minWidth, minHeight);
  }

  /// Compresses [bytes] to WebP, or `null` when the compressor rejects them.
  ///
  /// `CompressError` is caught by name. It extends `Error`, not `Exception` —
  /// the package labelling a runtime condition ("the image is empty", "compress
  /// returned no data") as a programming mistake — so letting it propagate
  /// would hand callers an `Error` for an input they cannot control. Catching
  /// it by its own name is narrow enough that it stays legal: the lint that
  /// forbids catching errors matches a fixed list of `dart:core` error types,
  /// and this is not one of them.
  static Future<Uint8List?> _compressOrNull(
    Uint8List bytes,
    int quality,
    int minWidth,
    int minHeight,
  ) async {
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        format: CompressFormat.webp,
        quality: quality,
        // Passed through under the plugin's own names, deliberately: they are
        // a floor on the result, the plugin is right to call them `min*`, and
        // renaming them here would put a second vocabulary between a caller
        // and the FAQ that explains the behaviour. Explicit rather than
        // defaulted so the resize is visible at this call site.
        minWidth: minWidth,
        minHeight: minHeight,
      );
    } on CompressError {
      // Caught by name, and legal: `CompressError` extends `Error` but is not
      // in `avoid_catching_error`'s fixed list of `dart:core` error types. The
      // two Error shapes that ARE on that list — `UnsupportedError` and
      // `UnimplementedError` — are prevented by the platform guard in
      // [encodeWebp] rather than caught here.
      //
      // Discarded deliberately on THIS path only: a passthrough rejection is
      // the expected way to learn the format needs decoding first, and the
      // fallback is about to run. The evidence is preserved where it matters —
      // [_compressOrThrow], the call that actually gives up.
      return null;
    }
  }

  /// Compresses [bytes], converting a failure into [ImageCodecEncodeException]
  /// **with the original attached**.
  ///
  /// Separate from [_compressOrNull] because the two calls want opposite
  /// things from a failure. The passthrough wants to shrug and try the other
  /// path; this one is the end of the line, so `CompressError.code` — stable
  /// native values like `unsupported_format` / `decode_failed` / `io_failed` —
  /// has to survive into `cause`. Collapsing three failure shapes into one
  /// type must not also destroy the evidence of which one it was.
  static Future<Uint8List> _compressOrThrow(
    Uint8List bytes,
    int quality,
    int minWidth,
    int minHeight,
    String failureMessage,
  ) async {
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        format: CompressFormat.webp,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );
    } on CompressError catch (e) {
      throw ImageCodecEncodeException(failureMessage, cause: e);
    }
  }

  /// The fallback: decode with `package:image`, re-encode as PNG, compress.
  ///
  /// The decode and the PNG encode run in a `compute()` isolate — they are
  /// pure CPU over bytes and would otherwise stall the caller's event loop.
  /// The compression step must **not** join them: `FlutterImageCompress` is a
  /// native plugin and cannot be sent into a Dart isolate, so moving it there
  /// fails at runtime rather than at compile time. That split is the whole
  /// reason this is two steps.
  /// `package:image` is only ever handed bytes the engine has already
  /// confirmed decode cleanly.
  ///
  /// That gate is load-bearing, not defensive tidiness. On a truncated PNG
  /// `package:image` does not throw its own `ImageException` — it throws
  /// `TypeError` (a `!` on a null frame in `png_decoder.dart`) or `RangeError`
  /// (an unguarded buffer read when the truncation lands mid-chunk). Both are
  /// `Error`s on `avoid_catching_error`'s fixed list, both cross back out of
  /// the `compute()` isolate, and neither can be caught here. And the path is
  /// reached precisely for bytes the native compressor already rejected — the
  /// malformed ones. Asking [isPixelDataComplete] first removes the input that
  /// triggers them instead of trying to catch what cannot be caught.
  static Future<Uint8List> _reEncodeViaPng(
    Uint8List bytes,
    int quality,
    int minWidth,
    int minHeight,
  ) async {
    if (!await ImageCodec.isPixelDataComplete(bytes)) {
      throw const ImageCodecEncodeException(
        'the source pixel data is incomplete or corrupt, so it cannot be '
        're-encoded',
      );
    }
    final Uint8List? png = await compute<Uint8List, Uint8List?>(
      _decodeToPng,
      bytes,
    );
    if (png == null) {
      throw const ImageCodecEncodeException(
        'the bytes could not be decoded by any available decoder',
      );
    }
    return _compressOrThrow(
      png,
      quality,
      minWidth,
      minHeight,
      're-encoding to WebP failed even after decoding through PNG',
    );
  }

  /// Runs inside a `compute()` isolate.
  ///
  /// Returns `null` rather than throwing on a failed decode: an exception
  /// raised here has to survive being sent across the isolate boundary, and a
  /// nullable return is the shape that cannot go wrong. The caller converts it
  /// into an [ImageCodecEncodeException] on the other side.
  static Uint8List? _decodeToPng(Uint8List bytes) {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return null;
      }
      return Uint8List.fromList(img.encodePng(decoded));
    } on img.ImageException {
      return null;
    }
  }
}
