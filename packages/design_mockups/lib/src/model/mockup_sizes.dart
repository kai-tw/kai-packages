/// The Material 3 `WindowSize` band ids the default render matrix defines.
///
/// Constants rather than an enum because the matrix is configurable: an app may
/// add a band its own layout code recognises, and an enum would close that set.
/// Specs still read as names rather than as string literals.
///
/// **`design_mockups_annotations` declares the same five constants**, and that
/// is deliberate rather than an oversight. This package cannot depend on that
/// one: a consuming app pins both by git tag, and pub identifies a dependency
/// by its source DESCRIPTION, so a path dep reached through a git checkout
/// (`git at <sha> in packages/…`) never unifies with the app's own tag pin,
/// and version solving fails outright. Nor can the repo paper over it with a
/// `dependency_overrides`, which pub refuses for a workspace member.
///
/// Duplicating them costs nothing here because the API is `Set<String>`: the
/// constants are spelling aids, not a type, so a band named through either
/// package is the same value and the two are interchangeable at every call
/// site. Each package spells them for its own users — this one for a `tool/`
/// fixture, the annotation one for a `lib/` widget that cannot import a
/// `flutter_test`-dependent harness.
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
