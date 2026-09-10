/// Declares that the annotated top-level function produces one design-mockup
/// render, and says which cell of the grid it fills.
///
/// Put it on a function beside the widget it previews — that is the whole
/// point of the annotation. The sample data a state needs lives in the file
/// that owns the widget, where a reader looking at the widget can see what
/// its states actually look like, and no separate fixture file or registry
/// entry has to be kept in step.
///
/// The function must be top-level (not a method, not nested) and return a
/// `Widget`. Either signature is accepted:
///
/// ```dart
/// @MockupPreview(spec: 'account', screen: 'account_card', state: 'ready')
/// Widget accountCardReady() => AccountCard(state: const AccountReady());
///
/// @MockupPreview(spec: 'account', screen: 'account_card', state: 'failed')
/// Widget accountCardFailed(BuildContext context) => ...;
/// ```
///
/// What it returns is the **real insertion point** — the page as the app
/// builds it, chrome included — not a fragment in a borrowed `Scaffold`.
class MockupPreview {
  const MockupPreview({
    required this.spec,
    required this.screen,
    this.state = 'default',
    this.sizes = const <String>['compact'],
    this.textScale = 1.0,
  });

  /// The spec this render belongs to — the `render-mockups <slug>` argument
  /// and the output subdirectory. Previews sharing a slug are rendered
  /// together.
  final String spec;

  /// The screen name, verbatim in the filename. Several states of one screen
  /// share it.
  final String screen;

  /// The condition being shown, verbatim in the filename: `default`, `empty`,
  /// `loading`, `error`, `offline`.
  final String state;

  /// The `WindowSize` bands this screen **restructures** at. A screen that
  /// only reflows lists `compact` and the one band that proves it — five
  /// near-identical PNGs are noise that hides the ones that differ.
  final List<String> sizes;

  /// Register a second preview at 1.5 rather than adding a state: text scale
  /// changes the *layout*, not the condition being shown.
  final double textScale;
}
