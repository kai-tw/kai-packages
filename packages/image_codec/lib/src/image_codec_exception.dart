/// The one failure type this package throws.
///
/// It exists because the three libraries underneath fail in three different
/// shapes, and every consumer was otherwise obliged to know all three:
///
/// - the Flutter engine throws a bare `Exception` with no subtype at all —
///   every `dart:ui` native call routes failure through one generic bridge
///   (`_futurize`) that hardcodes `throw Exception('operation failed')`, so
///   there is no narrower type to catch and no predicate to ask first;
/// - `package:image` throws `ImageException`, which does implement
///   `Exception`;
/// - `flutter_image_compress` throws `CompressError`, which extends **`Error`**
///   — the other side of Dart's exception/error split, for failures that are
///   plainly runtime conditions ("the image is empty", "compress returned no
///   data") rather than programming mistakes. That is the package mislabelling
///   its own failures, and a consumer cannot fix it from outside.
///
/// Collapsing those into one `Exception` subtype is the actual product of
/// putting decode, encode and convert in one package: a caller writes
/// `on ImageCodecException` and is done, instead of catching three unrelated
/// types across two type hierarchies and hoping it has them all.
///
/// [cause] keeps the original for diagnosis — collapsing the type must not
/// also destroy the evidence.
sealed class ImageCodecException implements Exception {
  const ImageCodecException(this.message, {this.cause});

  final String message;

  /// The underlying failure this was converted from, when there was one.
  final Object? cause;

  @override
  String toString() => cause == null
      ? '$runtimeType: $message'
      : '$runtimeType: $message ($cause)';
}

/// The bytes could not be read as an image.
///
/// Note the read APIs on this package do NOT throw this — they return `null`
/// or omit the entry, because "these bytes are not an image" is an ordinary,
/// expected answer for a cover picked by a user or extracted from an EPUB.
/// This is thrown only where a caller asked for a result that cannot exist
/// without a successful decode.
final class ImageCodecDecodeException extends ImageCodecException {
  const ImageCodecDecodeException(super.message, {super.cause});
}

/// The image could not be re-encoded into the requested format.
final class ImageCodecEncodeException extends ImageCodecException {
  const ImageCodecEncodeException(super.message, {super.cause});
}
