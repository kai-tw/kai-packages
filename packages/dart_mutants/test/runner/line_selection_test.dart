import 'package:dart_mutants/src/runner/line_selection.dart';
import 'package:test/test.dart';

void main() {
  test('[partition] reads single lines and ranges', () {
    final LineSelection selection = LineSelection.parse('lib/a.dart:3-5,9');

    expect(selection.file, 'lib/a.dart');
    expect(selection.lines, <int>{3, 4, 5, 9});
  });

  for (final String bad in <String>[
    'lib/a.dart',
    'lib/a.dart:',
    'lib/a.dart:5-3',
    'lib/a.dart:0',
    'lib/a.dart:1-2-3',
    'lib/a.dart:x',
  ]) {
    test('[error] refuses "$bad"', () {
      expect(() => LineSelection.parse(bad), throwsFormatException);
    });
  }
}
