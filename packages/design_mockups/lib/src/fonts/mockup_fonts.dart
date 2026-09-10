import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'host_font_candidates.dart';
import 'mockup_font_face.dart';
import 'mockup_font_family.dart';
import 'mockup_font_report.dart';

/// Which faces a render registers, and what a text style should reach for when
/// its primary face has no glyph for a character.
///
/// **This is the tofu fix.** `flutter test` disables asset fonts and ships Ahem,
/// which draws every glyph as a filled box, so a headless render with nothing
/// loaded is worthless for a CJK app. Loading one broad face is the obvious
/// half-fix and the one that leaves the residual defect: any character that
/// face happens to lack still renders as a box, and it looks exactly like a
/// bug in the app. What removes the class is a **chain** — several faces
/// registered as a CHAIN of families walked per character — plus a theme
/// that actually puts that family on every text style, which
/// `applyMockupFonts` does.
class MockupFonts {
  const MockupFonts({
    this.primary,
    this.fallback,
    this.extra = const <MockupFontFamily>[],
    this.loadMaterialIcons = true,
    this.loadAppFontManifest = true,
  });

  /// Registers nothing of its own and takes the app's bundled fonts as they
  /// are. For an app that already ships every face it renders in.
  const MockupFonts.appBundledOnly()
    : primary = null,
      fallback = null,
      extra = const <MockupFontFamily>[],
      loadMaterialIcons = true,
      loadAppFontManifest = true;

  /// The family the harness theme applies as each text style's primary face.
  /// Null leaves the app theme's own choice alone — right for an app that
  /// bundles its brand font, since that font *is* what should be photographed.
  final MockupFontFamily? primary;

  /// The chain every text style falls through to, in order. Null means
  /// [defaultFallbackFamilies] — one family per broad-coverage face the host
  /// has. A LIST, because per-glyph fallback is what `fontFamilyFallback`
  /// does and it walks family NAMES; several files under one family name are
  /// weight alternates, not a chain.
  final List<MockupFontFamily>? fallback;

  /// Further families to register but not wire into the theme, for a fixture
  /// that names one on a specific `TextStyle`.
  final List<MockupFontFamily> extra;

  /// Load the SDK's `MaterialIcons`. Without it every `Icon` is a tofu box.
  final bool loadMaterialIcons;

  /// Load everything in the test bundle's `FontManifest.json` under its real
  /// family — the app's own bundled faces and icon fonts.
  final bool loadAppFontManifest;

  /// The family name text styles should ask for, or null to leave the theme's.
  String? get primaryFamily => primary?.family;

  /// The fallback family names, in order, for `TextStyle.fontFamilyFallback`.
  List<String> get fallbackFamilies => (fallback ?? defaultFallbackFamilies())
      .map((MockupFontFamily family) => family.family)
      .toList();

  /// Registers every declared family and reports what actually resolved.
  ///
  /// Call once, in `setUpAll`.
  Future<MockupFontReport> load() async {
    // An empty chain is the CI case, and it would otherwise sail through: no
    // family is declared, so no family is "missing", and every render comes
    // out a page of boxes with a green exit code.
    if (fallbackFamilies.isEmpty) {
      throw StateError(
        'design_mockups: no broad-coverage font was found on this machine, so '
        'every glyph would render as a box. Run `dart run '
        'design_mockups:fetch_fonts` to cache a pinned Noto CJK set into '
        '$kMockupFontCacheDir, or declare the faces your app ships via '
        'MockupHarnessConfig.fonts.',
      );
    }

    final List<MockupFontFamily> families = _families();

    final List<String> loaded = <String>[];
    final List<String> missing = <String>[];
    final List<String> missingRequired = <String>[];
    for (final MockupFontFamily family in families) {
      final int count = await _loadFamily(family);
      if (count == 0) {
        missing.add(family.family);
        if (family.required) {
          missingRequired.add(family.family);
        }
      } else {
        loaded.add('${family.family} ($count)');
      }
    }

    final Set<String> bundled = loadAppFontManifest
        ? await _loadDeclaredAppFonts()
        : const <String>{};

    final MockupFontReport report = MockupFontReport(
      loaded: loaded,
      missing: missing,
      appBundledFamilies: bundled,
    );
    report.warn();
    // Every family is collected before this throws, so one run names all of
    // them — resolving them one exception at a time is several minutes of
    // rebuild each.
    //
    // It throws rather than warning because a required family resolving to
    // nothing is the exact failure this package exists to remove: the render
    // still completes, the PNGs are the right size, the run exits 0, and every
    // glyph in them is a box. A warning on stderr loses that race against
    // sixty lines of test output. An OPTIONAL family missing is a different
    // thing — a fallback link only some hosts have — and only warns.
    if (missingRequired.isNotEmpty) {
      throw StateError(
        'design_mockups: no font file resolved for required '
        '${missingRequired.length == 1 ? "family" : "families"} '
        '${missingRequired.join(", ")}. Every glyph would render as a box. '
        'Run `dart run design_mockups:fetch_fonts` to cache a pinned Noto CJK '
        'set, or declare the faces your app ships via '
        'MockupHarnessConfig.fonts.',
      );
    }
    return report;
  }

  /// Every family this declaration asks for, in load order.
  List<MockupFontFamily> _families() => <MockupFontFamily>[
    ?primary,
    ...(fallback ?? defaultFallbackFamilies()),
    ...extra,
    if (loadMaterialIcons)
      MockupFontFamily(
        family: kMaterialIconsFamily,
        faces: materialIconFaces(),
        required: true,
      ),
  ];

  /// Returns how many faces were registered for [family].
  Future<int> _loadFamily(MockupFontFamily family) async {
    final List<Uint8List> bytes = <Uint8List>[];
    for (final MockupFontFace face in family.faces) {
      final File file = File(face.path);
      if (!file.existsSync()) {
        if (family.mode == MockupFontLoadMode.all) {
          // `all` means the declared files are PARTS of one family, not
          // alternatives: a missing one is a broken checkout, and loading the
          // rest would render a synthesized bold in place of the real face
          // while everything else looked correct. Say which path, since that
          // is the whole fix. A family whose entries are genuinely
          // alternatives declares `firstAvailable` and skips instead — which
          // is also why `defaultFallbackFamily` filters by existence before
          // declaring its faces.
          throw StateError(
            'design_mockups: font file not found for family '
            '"${family.family}": ${face.path}. `flutter test` runs at the '
            'project root, so a relative path is resolved from there.',
          );
        }
        continue;
      }
      bytes.add(file.readAsBytesSync());
      if (family.mode == MockupFontLoadMode.firstAvailable) {
        break;
      }
    }
    if (bytes.isEmpty) {
      return 0;
    }
    final FontLoader loader = FontLoader(family.family);
    for (final Uint8List data in bytes) {
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(data)));
    }
    await loader.load();
    return bytes.length;
  }

  /// Loads every font in the test bundle's `FontManifest.json` under its real
  /// family — the app's own bundled faces plus its icon fonts.
  ///
  /// Returns the families it registered, which is what tells a theme's font
  /// name apart from a platform one that does not exist here.
  Future<Set<String>> _loadDeclaredAppFonts() async {
    final String manifestJson;
    try {
      manifestJson = await rootBundle.loadString('FontManifest.json');
    } on FlutterError {
      // No FontManifest in this bundle — an app that declares no fonts of its
      // own. `FlutterError` is what the asset bundle throws for a key it has
      // no entry for, and it is the only failure here that is not a bug.
      return const <String>{};
    }

    final Set<String> families = <String>{};
    final List<dynamic> manifest = json.decode(manifestJson) as List<dynamic>;
    for (final dynamic entry in manifest) {
      final Map<String, dynamic> family = entry as Map<String, dynamic>;
      final String name = family['family'] as String;
      final FontLoader loader = FontLoader(name);
      for (final dynamic font in family['fonts'] as List<dynamic>) {
        final String asset = (font as Map<String, dynamic>)['asset'] as String;
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
      families.add(name);
    }
    return families;
  }
}
