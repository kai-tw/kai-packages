import 'dart:ui';

import 'package:design_mockups_annotations/design_mockups_annotations.dart';

/// A render viewport for one Material 3 `WindowSize` band.
///
/// [logicalSize] drives layout; the captured PNG is
/// `logicalSize * devicePixelRatio` physical pixels. The width is what selects
/// the band, so it is chosen to sit well inside one rather than near its edge —
/// a band boundary moving by a pixel must not silently reclassify a render.
/// The height only has to be plausible for the shape of device that reports
/// that width.
class MockupViewport {
  const MockupViewport({
    required this.id,
    required this.logicalSize,
    this.devicePixelRatio,
  });

  /// The band id. Appears in the output filename and is what a screen's
  /// `sizes` set names.
  final String id;

  /// Logical layout size (physical pixels / DPR).
  final Size logicalSize;

  /// Overrides the harness-wide DPR for this band. Null means "use the
  /// harness's". A band rarely needs its own; a very large desktop surface is
  /// the case that does, where 2.0 produces a file nobody wants to open.
  final double? devicePixelRatio;

  /// Output PNG dimensions at [dpr].
  Size pixelSizeAt(double dpr) =>
      Size(logicalSize.width * dpr, logicalSize.height * dpr);
}

/// One representative surface per Material 3 `WindowSize` band:
/// compact < 600, medium 600-840, expanded 840-1280, large 1280-1600,
/// extraLarge >= 1600.
///
/// An app overrides this wholesale through `MockupHarnessConfig.viewports` when
/// its own breakpoints differ.
const Map<String, MockupViewport> kDefaultMockupViewports =
    <String, MockupViewport>{
      MockupSizes.compact: MockupViewport(
        id: MockupSizes.compact,
        logicalSize: Size(402.0, 874.0), // a large phone, portrait
      ),
      MockupSizes.medium: MockupViewport(
        id: MockupSizes.medium,
        logicalSize: Size(744.0, 1133.0), // a small tablet, portrait
      ),
      MockupSizes.expanded: MockupViewport(
        id: MockupSizes.expanded,
        logicalSize: Size(1133.0, 744.0), // a tablet, landscape
      ),
      MockupSizes.large: MockupViewport(
        id: MockupSizes.large,
        logicalSize: Size(1366.0, 1024.0), // a desktop window
      ),
      MockupSizes.extraLarge: MockupViewport(
        id: MockupSizes.extraLarge,
        logicalSize: Size(1728.0, 1117.0), // a full-screen desktop window
      ),
    };
