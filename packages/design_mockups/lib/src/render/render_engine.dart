import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'mockup_settle.dart';

/// Renders [home] headless and writes a PNG to [outputPath].
///
/// Returns the produced image's physical pixel size
/// (`logicalSize * devicePixelRatio`).
///
/// The caller supplies the viewport, the theme and the localization; this
/// function owns only the capture recipe, whose non-obvious parts are each
/// commented below because every one of them fails silently or misleadingly.
Future<Size> renderMockupToPng(
  WidgetTester tester, {
  required Widget home,
  required Size logicalSize,
  required double devicePixelRatio,
  required ThemeData theme,
  required Locale locale,
  required String outputPath,
  Iterable<LocalizationsDelegate<dynamic>> localizationsDelegates =
      const <LocalizationsDelegate<dynamic>>[],
  Iterable<Locale> supportedLocales = const <Locale>[Locale('en', 'US')],
  double textScale = 1.0,
  MockupSettle settle = const MockupSettle(),
  double screenCornerRadius = 0.0,
  EdgeInsets safeArea = EdgeInsets.zero,
  TransitionBuilder? builder,
}) async {
  // The view, not an ambient `MediaQuery`: `MaterialApp` builds its own from
  // the view, so an override wrapped around it is simply discarded. Text scale
  // goes the same way, through the platform rather than through a `MediaQuery`
  // injected below the app — that is both closer to the truth (the scale is a
  // device setting, and this is how the device reports it) and the reason
  // there is no `builder:` needed for it.
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = Size(
    logicalSize.width * devicePixelRatio,
    logicalSize.height * devicePixelRatio,
  );
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  // `flutter_test` defaults `debugDisableShadows` to true, which paints every
  // elevation shadow as a SOLID silhouette — a hard dark ring around the FAB,
  // a hard edge under the nav bar. Real soft shadows need it off, but it must
  // be restored before the test-body invariant check, which runs before any
  // `addTearDown`; hence the `finally` rather than a tear-down.
  debugDisableShadows = false;
  try {
    final GlobalKey boundaryKey = GlobalKey();

    // A real device's screen: clip to rounded corners and inject a safe-area
    // inset so the chrome sits away from the corners, and the rounding clips
    // only background. Skipped at radius 0, which is every design mockup —
    // this is here for the store-asset harness that shares this engine.
    Widget framed = home;
    if (screenCornerRadius > 0.0) {
      framed = MediaQuery(
        data: MediaQueryData.fromView(
          tester.view,
        ).copyWith(padding: safeArea, viewPadding: safeArea),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(screenCornerRadius),
          child: home,
        ),
      );
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          locale: locale,
          localizationsDelegates: localizationsDelegates,
          supportedLocales: supportedLocales,
          builder: builder,
          home: framed,
        ),
      ),
    );

    await _settle(tester, settle, outputPath);

    final RenderRepaintBoundary boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;

    // `runAsync`, or this hangs until the test times out. A widget test runs
    // inside a fake-async zone where nothing real completes on its own;
    // rasterising a layer and encoding a PNG are both real engine work, so
    // awaiting them directly parks forever and the failure reads as "did not
    // complete", which names the symptom and not this.
    final Size? produced = await tester.runAsync<Size>(() async {
      final ui.Image image = await boundary.toImage(
        pixelRatio: devicePixelRatio,
      );
      try {
        final ByteData? pngBytes = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (pngBytes == null) {
          throw StateError('toByteData returned no PNG bytes for $outputPath.');
        }
        final File file = File(outputPath)..createSync(recursive: true);
        await file.writeAsBytes(pngBytes.buffer.asUint8List());
        return Size(image.width.toDouble(), image.height.toDouble());
      } finally {
        image.dispose();
      }
    });

    if (produced == null) {
      throw StateError(
        'Render capture did not run (runAsync returned null) for $outputPath.',
      );
    }
    return produced;
  } finally {
    debugDisableShadows = true;
  }
}

Future<void> _settle(
  WidgetTester tester,
  MockupSettle settle,
  String outputPath,
) async {
  for (int round = 0; round < settle.precacheRounds; round++) {
    await tester.pump(settle.roundDuration);
    await tester.runAsync(() async {
      for (final Element element in find.byType(Image).evaluate()) {
        final Image widget = element.widget as Image;
        await precacheImage(widget.image, element);
      }
    });
  }

  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      settle.timeout,
    );
  } on FlutterError {
    if (settle.policy == MockupSettlePolicy.fail) {
      rethrow;
    }
    // Still animating after the bound. Advance one more frame so the
    // photograph is of a definite moment rather than mid-pump, and say which
    // file it applies to — otherwise the warning is unattributable in a run of
    // sixty renders.
    await tester.pump(const Duration(milliseconds: 400));
    stderr.writeln(
      'design_mockups: ${p.basename(outputPath)} never settled within '
      '${settle.timeout.inSeconds}s — captured mid-animation. Expected for a '
      'loading state; a surprise anywhere else.',
    );
  }
}
