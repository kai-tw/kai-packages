import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:design_mockups/design_mockups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 64×64 solid red square, declared as an asset of this package so the
/// provider under test is the one a consuming app actually paints: an
/// `AssetImage`, read through the test bundle and decoded on the real event
/// loop.
const String _asset = 'test/fixtures/red.png';
const int _red = 0xFFFF0000;

/// A 1×1 transparent GIF, so the `FadeInImage` case has a placeholder that
/// needs no second asset and paints nothing over the photo.
const List<int> _transparentGif = <int>[
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, //
  0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
  0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
  0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
  0x01, 0x00, 0x3B,
];

void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('design_mockups_images');
  });
  tearDownAll(() {
    dir.deleteSync(recursive: true);
  });

  // One case per way an app puts a photo on screen. The decoration cases are
  // the ones that bite: a photo behind a scrim is a `DecorationImage`, and a
  // harness that names images by looking for `Image` widgets finds none of
  // them. `Container` and `FadeInImage` are here as the other half of that
  // claim — they compose from the shapes above, so they must come out right
  // WITHOUT the scan naming their types.
  final Map<String, Widget Function()> cases = <String, Widget Function()>{
    'an Image widget': () =>
        const Image(image: AssetImage(_asset), fit: BoxFit.cover),
    'a BoxDecoration image': () => const DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(image: AssetImage(_asset), fit: BoxFit.cover),
      ),
      child: SizedBox.expand(),
    ),
    'a ShapeDecoration image': () => const DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedRectangleBorder(),
        image: DecorationImage(image: AssetImage(_asset), fit: BoxFit.cover),
      ),
      child: SizedBox.expand(),
    ),
    'an Ink decoration': () => Material(
      child: Ink(
        decoration: const BoxDecoration(
          image: DecorationImage(image: AssetImage(_asset), fit: BoxFit.cover),
        ),
        child: const SizedBox.expand(),
      ),
    ),
    'a DecoratedSliver': () => CustomScrollView(
      slivers: <Widget>[
        const DecoratedSliver(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage(_asset),
              fit: BoxFit.cover,
            ),
          ),
          sliver: SliverToBoxAdapter(child: SizedBox(height: 400.0)),
        ),
      ],
    ),
    'a TableRow decoration': () => Table(
      children: <TableRow>[
        const TableRow(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage(_asset),
              fit: BoxFit.cover,
            ),
          ),
          children: <Widget>[SizedBox(height: 400.0)],
        ),
      ],
    ),
    'a Container decoration': () => Container(
      decoration: const BoxDecoration(
        image: DecorationImage(image: AssetImage(_asset), fit: BoxFit.cover),
      ),
    ),
    'a FadeInImage': () => FadeInImage(
      placeholder: MemoryImage(Uint8List.fromList(_transparentGif)),
      image: const AssetImage(_asset),
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 1),
    ),
  };

  cases.forEach((String name, Widget Function() build) {
    testWidgets('$name is decoded before the frame is captured', (
      WidgetTester tester,
    ) async {
      // An empty cache, or this test cannot fail: the image cache is
      // process-wide and `flutter_test` does not clear it between tests, so
      // every render of an asset after the first one paints it correctly
      // whatever the harness does. A missing precache is visible only on an
      // asset's first use.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      final String out = '${dir.path}/${name.replaceAll(' ', '_')}.png';
      await renderMockupToPng(
        tester,
        home: build(),
        logicalSize: const Size(100.0, 100.0),
        devicePixelRatio: 1.0,
        theme: ThemeData.light(),
        locale: const Locale('en', 'US'),
        outputPath: out,
      );

      int centre = 0;
      await tester.runAsync(() async {
        centre = await _centrePixel(out);
      });
      expect(
        centre,
        _red,
        reason:
            'the centre of the capture should be the asset, not the empty '
            'space left where it failed to decode',
      );
    });
  });
}

/// The captured PNG's centre pixel, as 0xAARRGGBB.
Future<int> _centrePixel(String path) async {
  final ui.Codec codec = await ui.instantiateImageCodec(
    await File(path).readAsBytes(),
  );
  final ui.Image image = (await codec.getNextFrame()).image;
  try {
    final ByteData rgba = (await image.toByteData())!;
    final int offset =
        ((image.height ~/ 2) * image.width + (image.width ~/ 2)) * 4;
    return (rgba.getUint8(offset + 3) << 24) |
        (rgba.getUint8(offset) << 16) |
        (rgba.getUint8(offset + 1) << 8) |
        rgba.getUint8(offset + 2);
  } finally {
    image.dispose();
  }
}
