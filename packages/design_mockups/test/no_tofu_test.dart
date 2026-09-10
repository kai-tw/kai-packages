/// The regression test for the defect this package was extracted to fix: a
/// headless render whose text comes out as filled boxes.
///
/// It is worth a test rather than an eyeball because tofu passes every check a
/// render harness normally makes. The PNG exists, its dimensions are right, its
/// byte length is non-zero, and no exception was thrown — the file is simply
/// unreadable, and the only thing that notices is a person opening it.
///
/// The measurement: Ahem, which `flutter test` substitutes when a family has no
/// bytes, draws every glyph as a **solid filled rectangle**. A real typeface
/// does not — a 測 or a 永 leaves background showing inside its own bounding
/// box. So render dark text on a light ground, crop to where the text is, and
/// look at how much of that area is ink. Solid boxes sit near 100%; real
/// glyphs, even dense Han ones, sit far below it.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:design_mockups/design_mockups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Characters chosen to span the scripts a single host face most often fails
/// to cover all of at once — **plus the ones the substitute font itself has**.
///
/// The digits and `一` are here because of a real escape: measured over a whole
/// sentence, three boxes among forty glyphs moved the average by almost
/// nothing, and a render shipped with `1`, `4` and `一` as rectangles and
/// everything around them perfect. So each character is measured **alone**;
/// that is the only framing in which one bad glyph is a failure rather than a
/// rounding error.
const List<String> _samples = <String>[
  '繁', '體', '灣', '歡', '經', '亂', // Traditional-only shapes
  '简', '书', '汉', // Simplified-only shapes
  'ひ', 'ら', 'ゲ', // Japanese kana
  '一', '二', '十', // The simple shapes a box hides in plain sight
  '0', '1', '4', '7', // ASCII digits — the substitute font has these
  'A', 'g', // Latin
];

void main() {
  const String outDir = 'build/design-mockups/_self_test';

  setUpAll(() async {
    final MockupFontReport report = await const MockupFonts().load();
    // The report is the diagnostic a consuming project reads when its render
    // is full of boxes, so it has to be true here first.
    expect(
      report.missing,
      isNot(contains(kMaterialIconsFamily)),
      reason:
          'MaterialIcons ships with the SDK. If it is missing, FLUTTER_ROOT is '
          'unset and every Icon in every render is a box.',
    );
  });

  // Both weights, because a heading is bold and the chain resolves per weight:
  // a face carrying a character at 400 but not at 700 drops it out of the
  // title alone, which is how a render can look right everywhere a reader
  // checks and be wrong in the largest text on the screen.
  for (final FontWeight weight in <FontWeight>[
    FontWeight.normal,
    FontWeight.bold,
  ]) {
    for (final String sample in _samples) {
      _glyphTest(sample: sample, weight: weight, outDir: outDir);
    }
  }
}

void _glyphTest({
  required String sample,
  required FontWeight weight,
  required String outDir,
}) {
  final String weightName = weight == FontWeight.bold ? 'bold' : 'regular';
  testWidgets(
    timeout: const Timeout(Duration(seconds: 90)),
    'renders "$sample" ($weightName) as a glyph, not as a filled box',
    (WidgetTester tester) async {
      final String path =
          '$outDir/${sample.runes.first.toRadixString(16)}_$weightName.png';
      await renderMockupToPng(
        tester,
        home: _SampleGlyph(character: sample, weight: weight),
        logicalSize: const Size(120.0, 120.0),
        devicePixelRatio: 2.0,
        // `ThemeData` fills in a family whether or not the app ships one —
        // M3 typography names `Roboto` on a device, and this names it
        // explicitly so the case is pinned rather than left to whatever a
        // bare `ThemeData()` resolves to. It is present on a device and
        // absent here. Reproducing that is the whole point: a theme with a
        // literally-null family does NOT exercise the bug, because with no
        // primary at all the fallback is consulted for every character. The
        // empty `bundledFamilies` says the app ships no such face, which is
        // what makes `applyMockupFonts` replace it rather than sit behind
        // it.
        theme: applyMockupFonts(
          ThemeData(brightness: Brightness.light, fontFamily: 'Roboto'),
          fallbackFamilies: const MockupFonts().fallbackFamilies,
        ),
        locale: const Locale('zh', 'TW'),
        outputPath: path,
        // Nothing here animates or loads an image; skipping both keeps
        // twenty renders to about a second.
        settle: const MockupSettle(precacheRounds: 0),
      );

      // `runAsync`, for the same reason the capture itself needs it: decoding
      // a PNG and reading its pixels back is real engine work, and in the
      // default fake-async test zone the await never returns. Without this
      // the test hangs for ten minutes and reports "Test timed out", which
      // names the symptom and not this.
      final double? inkRatio = await tester.runAsync(
        () => _inkRatio(File(path)),
      );
      if (inkRatio == null) {
        fail('The ink measurement did not run (runAsync returned null).');
      }

      // A filled rectangle measures ~1.0 across its own rows. Even the
      // densest Han glyph leaves a great deal of its box empty, so 0.85 is a
      // categorical divide rather than a threshold anybody has to tune.
      expect(
        inkRatio,
        lessThan(0.85),
        reason:
            '"$sample" is $inkRatio ink across its own rows, which is what a '
            'solid box looks like. No registered font has a glyph for it — '
            'see the design_mockups warning on stderr, and check that the '
            'substitute font is not winning as the primary family.',
      );
      // A dropped character is worse than a box, because nothing on the page
      // says anything is wrong — a heading simply reads one character short
      // and looks deliberate.
      expect(
        inkRatio,
        greaterThan(0.02),
        reason:
            '"$sample" ($weightName) left almost no ink — it did not render '
            'at all. A character that silently disappears usually means no '
            'face in the chain carries it at this weight.',
      );
    },
  );
}

class _SampleGlyph extends StatelessWidget {
  const _SampleGlyph({required this.character, required this.weight});

  final String character;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    // Maximum contrast, taken from the theme's extremes rather than a role:
    // the measurement counts dark pixels against a light ground, and a
    // `colorScheme` pairing chosen for readability would narrow exactly that
    // gap and turn a categorical check into a tuning exercise.
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Text(
          character,
          style: TextStyle(
            fontSize: 64.0,
            color: Colors.black,
            fontWeight: weight,
          ),
        ),
      ),
    );
  }
}

/// The fraction of dark pixels among the rows that contain any dark pixel.
///
/// Restricting to rows with ink is what makes the number comparable: the page
/// is mostly empty background, and averaging over all of it would put tofu and
/// glyphs within a rounding error of each other.
Future<double> _inkRatio(File file) async {
  final ui.Codec codec = await ui.instantiateImageCodec(
    await file.readAsBytes(),
  );
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ui.Image image = frame.image;
  final ByteData? data = await image.toByteData();
  image.dispose();
  codec.dispose();
  if (data == null) {
    throw StateError('Could not read pixels back from ${file.path}.');
  }

  final Uint8List pixels = data.buffer.asUint8List();
  int inkRows = 0;
  int ink = 0;
  for (int y = 0; y < image.height; y++) {
    int rowInk = 0;
    for (int x = 0; x < image.width; x++) {
      final int offset = (y * image.width + x) * 4;
      // Any pixel meaningfully darker than the white ground counts as ink;
      // anti-aliased edges are ink too, and including them is what keeps a
      // real glyph's measurement honest rather than flattering.
      if (pixels[offset] < 128) {
        rowInk++;
      }
    }
    if (rowInk > 0) {
      inkRows++;
      ink += rowInk;
    }
  }
  if (inkRows == 0) {
    return 0.0;
  }
  return ink / (inkRows * image.width);
}
