/// The emitter builds Dart source out of strings, so what it produces is only
/// as good as what a test pins. These cover the shapes where the generated
/// file could compile-but-be-wrong, or not compile at all — the failures that
/// surface inside a generated, gitignored file at a line nobody wrote.
library;

import 'package:design_mockups/src/scan/discovered_preview.dart';
import 'package:design_mockups/src/scan/registry_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

DiscoveredPreview preview({
  String spec = 'sync',
  String screen = 'status_card',
  String state = 'default',
  List<String> sizes = const <String>['compact'],
  double textScale = 1.0,
  String functionName = 'statusCard',
  String importUri = 'package:app/widgets/status_card.dart',
  bool takesArguments = false,
}) => DiscoveredPreview(
  spec: spec,
  screen: screen,
  state: state,
  sizes: sizes,
  textScale: textScale,
  functionName: functionName,
  importUri: importUri,
  takesArguments: takesArguments,
);

void main() {
  const String outDir = '/repo/tool/design_mockups';

  group('emitRegistry', () {
    test('a zero-arg preview is called with no arguments', () {
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(),
      ], outDir: outDir);
      expect(source, contains('p0.statusCard()'));
    });

    test('a BuildContext preview is passed the context', () {
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(takesArguments: true),
      ], outDir: outDir);
      expect(source, contains('p0.statusCard(context)'));
    });

    test('a preview outside lib/ is imported relative to the registry', () {
      // An absolute path is not a valid import URI, so this is the difference
      // between a registry that compiles and one that does not.
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(importUri: '$outDir/previews/smoke_preview.dart'),
      ], outDir: outDir);
      expect(source, contains("import 'previews/smoke_preview.dart' as p0;"));
    });

    test('two previews from one library share one prefix', () {
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(state: 'default'),
        preview(state: 'empty'),
      ], outDir: outDir);
      expect('p0'.allMatches(source).length, greaterThan(1));
      expect(source, isNot(contains('p1')));
    });

    test('states of one screen are collected into one MockupScreen', () {
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(state: 'default'),
        preview(state: 'empty'),
      ], outDir: outDir);
      expect("name: 'status_card'".allMatches(source).length, 1);
      expect(source, contains("name: 'default'"));
      expect(source, contains("name: 'empty'"));
    });

    test('a state declaring fewer bands is NOT widened by its siblings', () {
      // The whole reason `sizes` is per-preview: a loading state that only
      // matters at compact must not also be rendered at expanded because a
      // sibling asked for it. Two MockupScreen entries, one per band set.
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(state: 'default', sizes: <String>['compact', 'expanded']),
        preview(state: 'loading', sizes: <String>['compact']),
      ], outDir: outDir);
      expect("name: 'status_card'".allMatches(source).length, 2);
      expect(source, contains("sizes: <String>{'compact', 'expanded'}"));
      expect(source, contains("sizes: <String>{'compact'}"));
    });

    test('a large-text pass is its own screen entry', () {
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(),
        preview(textScale: 1.5),
      ], outDir: outDir);
      expect(source, contains('textScale: 1.0'));
      expect(source, contains('textScale: 1.5'));
      expect("name: 'status_card'".allMatches(source).length, 2);
    });

    test('two specs become two MockupSpec entries', () {
      final String source = emitRegistry(<DiscoveredPreview>[
        preview(spec: 'sync'),
        preview(spec: 'onboarding'),
      ], outDir: outDir);
      expect(source, contains("slug: 'sync'"));
      expect(source, contains("slug: 'onboarding'"));
    });

    test('no previews still produces a compilable, empty registry', () {
      final String source = emitRegistry(
        const <DiscoveredPreview>[],
        outDir: outDir,
      );
      expect(
        source,
        contains('List<MockupSpec> discoveredMockupSpecs() => <MockupSpec>['),
      );
      // The list is empty rather than the function absent: a project with no
      // annotations still gets a registry its entry point can import, so the
      // harness never has to know whether the scan found anything.
      expect(source, isNot(contains('MockupSpec(')));
    });
  });
}
