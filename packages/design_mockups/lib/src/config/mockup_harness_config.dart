import 'package:flutter/material.dart';

import '../fonts/mockup_fonts.dart';
import '../model/mockup_viewport.dart';
import '../render/mockup_settle.dart';

/// Builds the theme for one render.
typedef MockupThemeBuilder =
    ThemeData Function(Locale locale, Brightness brightness);

/// Everything about a render that belongs to the **app** rather than to a
/// spec: its themes, its locales, its fonts, its breakpoints.
///
/// This is the whole of what the harness needs from its host, and it is
/// deliberately data rather than an interface to implement — a project's
/// `run_mockups_test.dart` is then one `const` value and a list of specs, with
/// no logic to get wrong.
class MockupHarnessConfig {
  const MockupHarnessConfig({
    required this.theme,
    required this.supportedLocales,
    this.localizationsDelegates = const <LocalizationsDelegate<dynamic>>[],
    this.defaultLocales = const <String>['en'],
    this.defaultBrightnesses = const <Brightness>[
      Brightness.light,
      Brightness.dark,
    ],
    this.fonts = const MockupFonts(),
    this.viewports = kDefaultMockupViewports,
    this.devicePixelRatio = 2.0,
    this.outputRoot = 'build/design-mockups',
    this.settle = const MockupSettle(),
    this.applyFontsToTheme = true,
    this.builder,
  });

  /// The app's real `ThemeData` for a locale and brightness. The whole point
  /// of the render is that every pixel comes from here.
  final MockupThemeBuilder theme;

  /// Everything the app ships. A `--locales` tag outside this list is refused
  /// rather than rendered, because a locale the app does not support falls
  /// back to another one and the result reads as a copy bug.
  final List<Locale> supportedLocales;

  final List<LocalizationsDelegate<dynamic>> localizationsDelegates;

  /// Language tags rendered when `--locales` is not passed. For a
  /// single-locale app this is that one locale; for a multi-locale app it is
  /// the one whose text is longest or whose script is least forgiving, since
  /// that is the render worth having by default.
  final List<String> defaultLocales;

  /// Brightnesses rendered when `--themes` is not passed. Both, because dark
  /// mode is co-equal and the defect it hides is invisible in light.
  final List<Brightness> defaultBrightnesses;

  final MockupFonts fonts;

  /// The band id -> surface matrix a screen's `sizes` set is resolved against.
  final Map<String, MockupViewport> viewports;

  /// Two, not three: enough that CJK strokes are legible when the reviewer
  /// zooms, without a multi-megabyte PNG per screen.
  final double devicePixelRatio;

  /// PNGs land in `<outputRoot>/<slug>/`.
  final String outputRoot;

  final MockupSettle settle;

  /// Whether the harness rewrites the app theme's text styles onto its own
  /// font chain. Turn it off only for an app that bundles every face it
  /// renders in and has verified there is no tofu without it.
  final bool applyFontsToTheme;

  /// Wraps every rendered app, for a project whose real entry point installs
  /// something above the navigator that the design depends on.
  final TransitionBuilder? builder;
}
