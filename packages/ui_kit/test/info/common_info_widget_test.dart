import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

/// Long enough to wrap at every container width these tests use, which is what
/// makes `getSize(find.text(…)).width` report the *constraint* rather than the
/// glyph run: a wrapped `Text` measures on `TextWidthBasis.parent`, a
/// single-line one measures its own line.
const String _longCaption =
    'It will be handled automatically once you are back online, so there is '
    'nothing further you need to do here and no reason to try the same action '
    'again in the meantime.';

/// Character-wrapped rather than space-wrapped — CJK breaks between glyphs, so
/// it exercises a different line-breaking path against the same cap.
const String _longCaptionJa =
    'オンラインに戻ると自動的に処理されますので、ここで何か操作をしていただく必要は'
    'ありませんし、もう一度同じ操作をお試しいただく必要もございません。';

const Key _hostKey = Key('host');

/// Pumps [child] inside a [width]-wide host with a **zero-padding**
/// `MediaQuery`.
///
/// The zero padding is load-bearing: the default variant wraps in a
/// `SafeArea`, so on a device with a horizontal inset (a notched phone in
/// landscape) it contributes on top of the 24px padding and the exact
/// arithmetic below would not hold. These tests pin the widget's own
/// contribution, not the device's.
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required Widget child,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: _hostKey,
            width: width,
            height: 2000.0,
            child: child,
          ),
        ),
      ),
    ),
  );
}

double _captionWidth(WidgetTester tester, [String caption = _longCaption]) =>
    tester.getSize(find.text(caption)).width;

void main() {
  group('CommonInfoWidget content cap', () {
    testWidgets('caps the content at the default measure on a wide host', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: const CommonInfoWidget(title: 'Offline', caption: _longCaption),
      );

      expect(_captionWidth(tester), CommonInfoWidget.defaultMaxContentWidth);
    });

    testWidgets('honours an explicit maxContentWidth', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: const CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          maxContentWidth: 600.0,
        ),
      );

      expect(_captionWidth(tester), 600.0);
    });

    testWidgets('a null maxContentWidth falls back to the default', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: const CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          maxContentWidth: null,
        ),
      );

      expect(_captionWidth(tester), CommonInfoWidget.defaultMaxContentWidth);
    });

    testWidgets('caps the actions row, not just the text', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          actions: <Widget>[
            FilledButton(onPressed: () {}, child: const Text('Retry')),
          ],
        ),
      );

      expect(
        tester.getSize(find.byType(Wrap)).width,
        lessThanOrEqualTo(CommonInfoWidget.defaultMaxContentWidth),
      );
    });

    testWidgets('caps CJK captions on the same measure', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: const CommonInfoWidget(title: 'オフライン', caption: _longCaptionJa),
      );

      expect(
        _captionWidth(tester, _longCaptionJa),
        CommonInfoWidget.defaultMaxContentWidth,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('CommonInfoWidget density arithmetic', () {
    // The three regimes of `min(cap, W - 48)` vs `min(cap, W - 32)`. The middle
    // one is the trap: it is neither "equal" nor "16 apart", and a test that
    // only samples the outer two reads the invariant as unbounded.
    testWidgets('both variants converge on the cap once the host is wide', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: const CommonInfoWidget(title: 'Offline', caption: _longCaption),
      );
      final double defaultWidth = _captionWidth(tester);

      await _pump(
        tester,
        width: 1000.0,
        child: const CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          dense: true,
        ),
      );

      expect(_captionWidth(tester), defaultWidth);
      expect(defaultWidth, CommonInfoWidget.defaultMaxContentWidth);
    });

    testWidgets('below the cap, dense is exactly 16 wider', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 400.0,
        child: const CommonInfoWidget(title: 'Offline', caption: _longCaption),
      );
      final double defaultWidth = _captionWidth(tester);

      await _pump(
        tester,
        width: 400.0,
        child: const CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          dense: true,
        ),
      );

      expect(_captionWidth(tester) - defaultWidth, 16.0);
    });

    testWidgets('in the transition band the gap is neither 16 nor 0', (
      WidgetTester tester,
    ) async {
      // 520: dense has already saturated at 480, the default has not (472).
      await _pump(
        tester,
        width: 520.0,
        child: const CommonInfoWidget(title: 'Offline', caption: _longCaption),
      );
      final double defaultWidth = _captionWidth(tester);

      await _pump(
        tester,
        width: 520.0,
        child: const CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          dense: true,
        ),
      );

      expect(defaultWidth, 472.0);
      expect(_captionWidth(tester), CommonInfoWidget.defaultMaxContentWidth);
      expect(_captionWidth(tester) - defaultWidth, 8.0);
    });

    testWidgets('dense never renders flush against its host', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 400.0,
        child: const CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          dense: true,
        ),
      );

      final double hostLeft = tester.getTopLeft(find.byKey(_hostKey)).dx;
      final double captionLeft = tester.getTopLeft(find.text(_longCaption)).dx;

      expect(captionLeft - hostLeft, 16.0);
    });
  });

  group('CommonInfoWidget action sizing', () {
    testWidgets('does not scale the actions it is given', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: Center(
          child: FilledButton(onPressed: () {}, child: const Text('Retry')),
        ),
      );
      final double bareHeight = tester
          .getSize(find.byType(FilledButton))
          .height;

      await _pump(
        tester,
        width: 1000.0,
        child: CommonInfoWidget(
          title: 'Offline',
          caption: _longCaption,
          actions: <Widget>[
            FilledButton(onPressed: () {}, child: const Text('Retry')),
          ],
        ),
      );

      expect(tester.getSize(find.byType(FilledButton)).height, bareHeight);
    });
  });

  group('composed widgets inherit the cap', () {
    // Both compose or extend CommonInfoWidget with `dense: false` by default
    // (the sliver has no `dense` at all), so they inherit the cap.
    testWidgets('CommonErrorWidget is capped', (WidgetTester tester) async {
      await _pump(
        tester,
        width: 1000.0,
        child: const CommonErrorWidget(
          content: 'Something went wrong',
          caption: _longCaption,
        ),
      );

      expect(_captionWidth(tester), CommonInfoWidget.defaultMaxContentWidth);
    });

    testWidgets('CommonErrorSliverWidget is capped inside a CustomScrollView', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 1000.0,
        child: CustomScrollView(
          slivers: const <Widget>[
            CommonErrorSliverWidget(
              content: 'Something went wrong',
              caption: _longCaption,
            ),
          ],
        ),
      );

      expect(_captionWidth(tester), CommonInfoWidget.defaultMaxContentWidth);
      expect(tester.takeException(), isNull);
    });
  });

  group('CommonErrorWidget dense', () {
    testWidgets('passes dense through: small error-tinted icon, no SafeArea', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 400.0,
        child: const CommonErrorWidget(
          content: 'Something went wrong',
          dense: true,
        ),
      );

      final Icon icon = tester.widget<Icon>(find.byType(Icon));
      final BuildContext context = tester.element(find.byType(Icon));
      expect(icon.size, 20.0);
      expect(icon.color, Theme.of(context).colorScheme.error);
      expect(find.byType(SafeArea), findsNothing);
    });

    testWidgets('defaults to the full-screen variant', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: 400.0,
        child: const CommonErrorWidget(content: 'Something went wrong'),
      );

      expect(tester.widget<Icon>(find.byType(Icon)).size, 48.0);
      expect(find.byType(SafeArea), findsOneWidget);
    });
  });
}
