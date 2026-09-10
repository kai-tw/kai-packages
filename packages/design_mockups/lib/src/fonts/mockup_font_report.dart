import 'dart:io';

import 'host_font_candidates.dart';

/// What a font load actually managed to register.
class MockupFontReport {
  const MockupFontReport({
    required this.loaded,
    required this.missing,
    this.appBundledFamilies = const <String>{},
  });

  /// `family (n)`, one per registered family.
  final List<String> loaded;

  /// Families that resolved to no file at all.
  final List<String> missing;

  /// The families the app itself ships, read from `FontManifest.json`.
  ///
  /// This is what tells a real bundled face apart from a platform font name a
  /// theme happens to carry. `Roboto` is the case that matters: M3 typography
  /// names it whether or not the app ships it, it exists on a device, and it
  /// does not exist in a headless test — so keeping it as the primary family
  /// hands every glyph it "has" to `flutter_test`'s substitute and the
  /// fallback chain is never consulted for them.
  final Set<String> appBundledFamilies;

  bool get isComplete => missing.isEmpty;

  /// Says so on `stderr` when something is missing.
  ///
  /// Loud rather than silent, because the symptom — a render full of boxes —
  /// looks like a font bug in the app, and someone will go looking for it
  /// there. `stderr` rather than `print`: it is addressed to whoever just
  /// typed the command, it survives the caller piping stdout, and it needs no
  /// lint suppression.
  void warn() {
    if (isComplete) {
      return;
    }
    stderr.writeln(
      'design_mockups: no font file found for ${missing.join(", ")} — text '
      'in this render may appear as boxes. Run `dart run '
      'design_mockups:fetch_fonts` to download a pinned Noto CJK set into '
      '$kMockupFontCacheDir, or declare the faces your app ships via '
      'MockupHarnessConfig.fonts.',
    );
  }
}
