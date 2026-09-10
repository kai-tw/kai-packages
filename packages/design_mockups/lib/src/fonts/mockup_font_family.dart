import 'mockup_font_face.dart';

/// How a family's declared sources are turned into loaded faces.
enum MockupFontLoadMode {
  /// Load **every** source, and fail if one is missing.
  ///
  /// For a family the app ships itself: the files are in the repo, several
  /// weights belong to one family, and a missing one is a broken checkout
  /// rather than a difference between machines. Loading all weights is what
  /// lets a bold label render a real bold face instead of a synthesized one.
  all,

  /// Load the **first** source that exists and stop; missing sources are
  /// normal.
  ///
  /// For a family resolved from the host — the same face lives at a different
  /// path on macOS, on Linux and in CI, so the list is alternatives rather
  /// than parts.
  firstAvailable,
}

/// A family to register, and where its bytes come from.
class MockupFontFamily {
  const MockupFontFamily({
    required this.family,
    required this.faces,
    this.mode = MockupFontLoadMode.firstAvailable,
    this.required = false,
  });

  /// Every weight of one app-shipped family. All files must exist.
  const MockupFontFamily.bundled({
    required this.family,
    required this.faces,
    this.required = true,
  }) : mode = MockupFontLoadMode.all;

  /// The engine family name to register under. Independent of the font file's
  /// own internal name: it is what a `TextStyle.fontFamily` has to say to get
  /// these bytes.
  final String family;

  final List<MockupFontFace> faces;

  final MockupFontLoadMode mode;

  /// Whether a render without this family is worthless. A required family that
  /// resolves to nothing throws; an optional one warns and carries on — which
  /// is right for a fallback link that only some hosts have.
  final bool required;
}
