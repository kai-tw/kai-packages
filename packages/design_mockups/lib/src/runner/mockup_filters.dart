import 'package:flutter/material.dart';

/// The `--dart-define` knobs the `render-mockups` CLI passes through.
///
/// Compile-time defines rather than OS environment variables: they are scoped
/// to the one run, and `flutter test` has no other way to hand a value to the
/// code under test.
///
/// An **empty** filter selects everything. An absent filter is not an empty
/// one, and conflating the two is how a narrowing flag silently renders zero
/// screens.
class MockupFilters {
  const MockupFilters({
    required this.spec,
    required this.locales,
    required this.themes,
    required this.sizes,
    required this.states,
    required this.screens,
  });

  /// Reads the defines. Const-folded, so a define changes what is compiled.
  factory MockupFilters.fromEnvironment() => MockupFilters(
    spec: const String.fromEnvironment('MOCKUP_SPEC', defaultValue: 'smoke'),
    locales: _csv(const String.fromEnvironment('MOCKUP_LOCALES')),
    themes: _csv(const String.fromEnvironment('MOCKUP_THEMES')),
    sizes: _csv(const String.fromEnvironment('MOCKUP_SIZES')),
    states: _csv(const String.fromEnvironment('MOCKUP_STATES')),
    screens: _csv(const String.fromEnvironment('MOCKUP_SCREENS')),
  );

  final String spec;
  final Set<String> locales;
  final Set<String> themes;
  final Set<String> sizes;
  final Set<String> states;
  final Set<String> screens;

  bool wantsSize(String name) => _wants(sizes, name);
  bool wantsState(String name) => _wants(states, name);
  bool wantsScreen(String name) => _wants(screens, name);

  /// The language tags to render, resolved against what the app supports.
  ///
  /// Fails on an unknown tag rather than falling back, because a silent
  /// fallback renders a different locale than the one asked for and nothing
  /// in the output says so.
  List<Locale> resolveLocales(
    List<Locale> supported,
    List<String> fallbackTags,
  ) {
    final Iterable<String> tags = locales.isEmpty ? fallbackTags : locales;
    return <Locale>[
      for (final String tag in tags)
        supported.firstWhere(
          (Locale l) => l.toLanguageTag().toLowerCase() == tag.toLowerCase(),
          orElse: () => throw ArgumentError(
            'design_mockups: locale "$tag" is not in the app\'s supported '
            'locales (${supported.map((Locale l) => l.toLanguageTag()).join(", ")}).',
          ),
        ),
    ];
  }

  /// The brightnesses to render.
  List<Brightness> resolveBrightnesses(List<Brightness> fallback) {
    if (themes.isEmpty) {
      return fallback;
    }
    return <Brightness>[
      for (final String name in themes)
        switch (name) {
          'light' => Brightness.light,
          'dark' => Brightness.dark,
          _ => throw ArgumentError(
            'design_mockups: theme "$name" must be "light" or "dark".',
          ),
        },
    ];
  }

  static bool _wants(Set<String> filter, String name) =>
      filter.isEmpty || filter.contains(name);

  static Set<String> _csv(String raw) => raw
      .split(',')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toSet();
}
