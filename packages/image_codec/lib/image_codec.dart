/// Reads facts out of image bytes, and turns image bytes into other image
/// bytes — behind one exception type.
///
/// The engine's header reader, `package:image` and `flutter_image_compress`
/// fail in three different shapes across two type hierarchies. This package
/// owns all three so a consumer catches [ImageCodecException] and nothing else.
library;

/// `EngineImageBoundary` is exported for its `@visibleForTesting` factory
/// seams only — a consumer never calls it, and the analyzer will flag any
/// non-test use of those members.
export 'src/engine_image_boundary.dart' show EngineImageBoundary;
export 'src/image_codec.dart' show ImageCodec;
export 'src/image_codec_exception.dart'
    show
        ImageCodecException,
        ImageCodecDecodeException,
        ImageCodecEncodeException;
export 'src/image_size.dart' show ImageSize;
export 'src/webp_encoder.dart' show WebpEncoder;
