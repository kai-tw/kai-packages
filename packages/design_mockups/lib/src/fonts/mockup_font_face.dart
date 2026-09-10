/// One font file to register under a family.
class MockupFontFace {
  const MockupFontFace(this.path, {this.weight});

  /// Absolute, or relative to the process working directory — which for
  /// `flutter test` is always the project root.
  final String path;

  /// Only meaningful when every declared face is loaded; documentation for the
  /// reader, since the engine reads the weight from the font's own metadata.
  final int? weight;
}
