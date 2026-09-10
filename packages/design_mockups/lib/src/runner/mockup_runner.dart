import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../config/mockup_harness_config.dart';
import '../model/mockup_screen.dart';
import '../model/mockup_spec.dart';
import '../model/mockup_state.dart';
import '../model/mockup_variant.dart';
import '../model/mockup_variant_scope.dart';
import '../model/mockup_viewport.dart';
import '../render/mockup_theme.dart';
import '../render/render_engine.dart';
import 'mockup_filters.dart';

/// The whole harness: pick the spec named by `MOCKUP_SPEC`, register one
/// `testWidgets` case per screen x band x state x brightness x locale, and
/// write each to a PNG.
///
/// A project's `run_mockups_test.dart` is a call to this and nothing else. It
/// is a `_test.dart` because the harness *is* a headless `flutter_test` run —
/// that is what gives it a real engine, real text layout and a real
/// `RepaintBoundary` to photograph, with no simulator and no device.
void runMockups({
  required List<MockupSpec> specs,
  required MockupHarnessConfig config,
  MockupFilters? filters,
}) {
  final MockupFilters selection = filters ?? MockupFilters.fromEnvironment();
  final MockupSpec spec = _resolveSpec(specs, selection.spec);
  final List<Locale> locales = selection.resolveLocales(
    config.supportedLocales,
    config.defaultLocales,
  );
  final List<Brightness> brightnesses = selection.resolveBrightnesses(
    config.defaultBrightnesses,
  );

  // Filled by `setUpAll` and read by every test body: which families the app
  // itself ships decides whether the theme's own font name is kept or replaced
  // (see `applyMockupFonts`). It cannot be computed earlier — reading
  // `FontManifest.json` needs the binding, which only exists inside the test.
  Set<String> bundledFamilies = const <String>{};

  setUpAll(() async {
    // Fonts first: the spec's own set-up may build widgets, and a face
    // registered afterwards does not reach text already laid out.
    bundledFamilies = (await config.fonts.load()).appBundledFamilies;
    await spec.setUp?.call();
  });
  tearDownAll(() async {
    await spec.tearDown?.call();
  });

  group('design mockups · ${spec.slug}', () {
    // Every path this run will write, so a second render claiming one is a
    // loud failure rather than a silent overwrite. Without it a collision is
    // invisible: both tests pass, both assert the file exists and is
    // non-empty, and the survivor is whichever ran last.
    final Set<String> claimed = <String>{};
    int registered = 0;
    for (final MockupScreen screen in spec.screens) {
      if (!selection.wantsScreen(screen.name)) {
        continue;
      }
      registered += _registerScreen(
        spec: spec,
        screen: screen,
        config: config,
        selection: selection,
        brightnesses: brightnesses,
        locales: locales,
        claimed: claimed,
        bundledFamilies: () => bundledFamilies,
      );
    }
    if (registered == 0) {
      // A run that renders nothing looks exactly like a run that succeeded —
      // the CLI prints "Generated 0 mockup(s)" and moves on. Fail instead, and
      // say which filter emptied the set.
      test('spec "${spec.slug}" matched at least one render', () {
        fail(
          'design_mockups: no render matched the filters '
          '(screens: ${_show(selection.screens)}, sizes: ${_show(selection.sizes)}, '
          'states: ${_show(selection.states)}). The spec declares screens: '
          '${spec.screens.map((MockupScreen s) => s.name).join(", ")}.',
        );
      });
    }
  });
}

MockupSpec _resolveSpec(List<MockupSpec> specs, String slug) {
  final Map<String, MockupSpec> bySlug = <String, MockupSpec>{};
  for (final MockupSpec spec in specs) {
    if (bySlug.containsKey(spec.slug)) {
      throw ArgumentError(
        'design_mockups: two specs share the slug "${spec.slug}". A slug names '
        'an output directory, so the second would overwrite the first.',
      );
    }
    bySlug[spec.slug] = spec;
  }
  final MockupSpec? found = bySlug[slug];
  if (found == null) {
    throw ArgumentError(
      'design_mockups: unknown spec "$slug". Registered: '
      '${bySlug.keys.join(", ")}.',
    );
  }
  return found;
}

/// Registers one screen's band x state x brightness x locale grid, and returns
/// how many cases that was.
int _registerScreen({
  required MockupSpec spec,
  required MockupScreen screen,
  required MockupHarnessConfig config,
  required MockupFilters selection,
  required List<Brightness> brightnesses,
  required List<Locale> locales,
  required Set<String> claimed,
  required Set<String> Function() bundledFamilies,
}) {
  int count = 0;
  for (final String sizeId in screen.sizes) {
    if (!selection.wantsSize(sizeId)) {
      continue;
    }
    final MockupViewport viewport =
        config.viewports[sizeId] ??
        (throw ArgumentError(
          'design_mockups: screen "${screen.name}" declares unknown size '
          '"$sizeId". Configured: ${config.viewports.keys.join(", ")}.',
        ));
    for (final MockupState state in screen.states) {
      if (!selection.wantsState(state.name)) {
        continue;
      }
      for (final Brightness brightness in brightnesses) {
        for (final Locale locale in locales) {
          _registerCapture(
            spec: spec,
            screen: screen,
            state: state,
            viewport: viewport,
            brightness: brightness,
            locale: locale,
            config: config,
            claimed: claimed,
            bundledFamilies: bundledFamilies,
          );
          count++;
        }
      }
    }
  }
  return count;
}

void _registerCapture({
  required MockupSpec spec,
  required MockupScreen screen,
  required MockupState state,
  required MockupViewport viewport,
  required Brightness brightness,
  required Locale locale,
  required MockupHarnessConfig config,
  required Set<String> claimed,
  // A callback, not a value: the manifest is only readable inside the test
  // binding, so this is filled by `setUpAll` AFTER registration has run.
  required Set<String> Function() bundledFamilies,
}) {
  final String fileName =
      '${screen.name}${_textScaleTag(screen.textScale)}__${viewport.id}'
      '__${state.name}__${brightness.name}__${locale.toLanguageTag()}.png';
  final String outputPath = '${config.outputRoot}/${spec.slug}/$fileName';
  final double dpr = viewport.devicePixelRatio ?? config.devicePixelRatio;

  if (!claimed.add(outputPath)) {
    throw ArgumentError(
      'design_mockups: two renders in spec "${spec.slug}" both write '
      '$fileName. A filename is screen + text scale + size + state + '
      'brightness + locale, so this means two screens share a name and a text '
      'scale, or one screen declares a state twice — rename one, or merge '
      'their states into a single screen.',
    );
  }

  testWidgets(fileName, timeout: const Timeout(Duration(seconds: 120)), (
    WidgetTester tester,
  ) async {
    final MockupVariant variant = MockupVariant(
      viewport: viewport,
      state: state.name,
      brightness: brightness,
      locale: locale,
      textScale: screen.textScale,
    );

    ThemeData theme = config.theme(locale, brightness);
    if (config.applyFontsToTheme) {
      theme = applyMockupFonts(
        theme,
        primaryFamily: config.fonts.primaryFamily,
        fallbackFamilies: config.fonts.fallbackFamilies,
        bundledFamilies: bundledFamilies(),
      );
    }

    final Size produced = await renderMockupToPng(
      tester,
      home: MockupVariantScope(
        variant: variant,
        child: Builder(builder: state.build),
      ),
      logicalSize: viewport.logicalSize,
      devicePixelRatio: dpr,
      theme: theme,
      locale: locale,
      localizationsDelegates: config.localizationsDelegates,
      supportedLocales: config.supportedLocales,
      textScale: screen.textScale,
      settle: config.settle,
      builder: config.builder,
      outputPath: outputPath,
    );

    expect(produced, viewport.pixelSizeAt(dpr));
    final File file = File(outputPath);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(0));
  });
}

String _show(Set<String> filter) => filter.isEmpty ? '(all)' : filter.join(',');

/// `__text150` for a large-text pass, and nothing at all at the default.
///
/// It is part of the filename because the large-text render is *the same
/// screen in the same state* — every other field matches, so without this the
/// two write one path and the survivor is whichever ran last. Absent at 1.0 so
/// the ordinary case keeps the shorter name it has always had.
String _textScaleTag(double textScale) =>
    textScale == 1.0 ? '' : '__text${(textScale * 100).round()}';
