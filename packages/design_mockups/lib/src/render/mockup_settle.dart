/// What to do when a screen never stops animating.
enum MockupSettlePolicy {
  /// Take the frame anyway and warn. A render is a photograph, not a proof
  /// that the screen is idle — an indeterminate spinner is exactly the state
  /// a `loading` render is *for*, and it never settles by construction.
  captureAnyway,

  /// Fail the render. For a harness where a never-settling widget is a defect
  /// rather than a subject — a store screenshot, which ships.
  fail,
}

/// How long the engine waits for a screen to stop moving before photographing
/// it.
class MockupSettle {
  const MockupSettle({
    this.precacheRounds = 4,
    this.roundDuration = const Duration(milliseconds: 50),
    this.timeout = const Duration(seconds: 15),
    this.policy = MockupSettlePolicy.captureAnyway,
  });

  /// Rounds of "pump, then precache every image in the tree under `runAsync`".
  ///
  /// Each round drains microtasks so a `FutureBuilder` resolves and whatever
  /// paints the image appears, then decodes what appeared — decoding needs the
  /// real engine loop, which only `runAsync` provides. A few rounds cover
  /// future → widget → decode → paint. Zero skips the whole step, for a
  /// fixture with no async images.
  ///
  /// "Every image" means every provider the tree will paint, not every `Image`
  /// widget: a photo behind a scrim is usually a `BoxDecoration(image:)`, and
  /// an un-precached one is photographed as empty space the first time an
  /// asset is used in a run. See `_imagesInTree` in `render_engine.dart`.
  final int precacheRounds;

  final Duration roundDuration;

  /// Bounded, so a never-settling widget resolves in seconds instead of
  /// hanging for `flutter test`'s ten-minute default.
  final Duration timeout;

  final MockupSettlePolicy policy;
}
