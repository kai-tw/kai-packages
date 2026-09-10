/// The Material 3 `WindowSize` band ids the default render matrix defines.
///
/// Constants rather than an enum because the matrix is configurable: an app
/// may add a band its own layout code recognises, and an enum would close that
/// set. Specs and previews still read as names rather than string literals.
///
/// They live in the annotation package so a widget in `lib/` can name a band
/// in its own `@MockupPreview` without importing the harness.
abstract final class MockupSizes {
  /// 0-600. A large phone, portrait.
  static const String compact = 'compact';

  /// 600-840. A small tablet, portrait.
  static const String medium = 'medium';

  /// 840-1280. A tablet, landscape.
  static const String expanded = 'expanded';

  /// 1280-1600. A desktop window.
  static const String large = 'large';

  /// 1600+. A full-screen desktop window.
  static const String extraLarge = 'extraLarge';

  /// Every id in the default matrix, in ascending width order.
  static const List<String> all = <String>[
    compact,
    medium,
    expanded,
    large,
    extraLarge,
  ];
}
