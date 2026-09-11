import 'dart:io';

import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/coverage_map.dart';
import 'package:dart_mutants/src/runner/line_range.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/test_invocation.dart';
import 'package:dart_mutants/src/runner/test_selection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Mutant _mutantIn(String filePath) => Mutant(
  filePath: filePath,
  offset: 0,
  length: 1,
  line: 2,
  column: 1,
  original: 'a',
  replacement: 'b',
  operatorName: 'op',
  description: 'a -> b',
);

void main() {
  late Directory root;
  late ProcessCommand full;
  late TestSelection selection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('test_selection_test_');
    for (final String file in <String>[
      'lib/foo.dart',
      'test/a_test.dart',
      'test/b_test.dart',
      'test/c_test.dart',
    ]) {
      File(p.join(root.path, file)).createSync(recursive: true);
    }
    full = ProcessCommand('dart', <String>[
      'test',
      '--fail-fast',
    ], workingDirectory: root.path);
    final CoverageMapBuilder builder = CoverageMapBuilder(root.path)
      // foo.dart: lines 1-3 are function `f`, entered by b and a; lines 5-6
      // are function `g`, entered by nobody.
      ..add('test/b_test.dart', 'lib/foo.dart', 1, 1)
      ..add('test/a_test.dart', 'lib/foo.dart', 3, 2)
      ..add('test/c_test.dart', 'lib/foo.dart', 1, 0)
      ..add('test/a_test.dart', 'lib/foo.dart', 5, 0)
      ..add('test/b_test.dart', 'lib/foo.dart', 5, 0);
    selection = TestSelection(TestInvocation.parse(full)!, builder.build());
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    '[partition] a scope some tests entered runs exactly those, sorted, '
    'with the command\'s own flags kept',
    () {
      final ProcessCommand command = selection.commandFor(
        _mutantIn(p.join(root.path, 'lib', 'foo.dart')),
        const LineRange(1, 3),
        full,
      )!;

      expect(command.arguments, <String>[
        'test',
        '--fail-fast',
        'test/a_test.dart',
        'test/b_test.dart',
      ]);
      expect(command.workingDirectory, root.path);
    },
  );

  test('[partition] a scope nobody entered needs no run — null', () {
    expect(
      selection.commandFor(
        _mutantIn(p.join(root.path, 'lib', 'foo.dart')),
        const LineRange(5, 6),
        full,
      ),
      isNull,
    );
  });

  test(
    '[boundary] no scope, or a scope nothing reported, runs the full command',
    () {
      final Mutant mutant = _mutantIn(p.join(root.path, 'lib', 'foo.dart'));

      expect(selection.commandFor(mutant, null, full), same(full));
      expect(
        selection.commandFor(mutant, const LineRange(20, 30), full),
        same(full),
      );
      expect(
        selection.commandFor(
          _mutantIn(p.join(root.path, 'lib', 'other.dart')),
          const LineRange(1, 3),
          full,
        ),
        same(full),
      );
    },
  );

  test(
    '[partition] a relative mutant path resolves against the current '
    'directory the same as an absolute one',
    () {
      final String original = Directory.current.path;
      addTearDown(() => Directory.current = original);
      Directory.current = root.path;

      expect(
        selection
            .commandFor(
              _mutantIn(p.join('lib', 'foo.dart')),
              const LineRange(1, 3),
              full,
            )!
            .arguments
            .last,
        'test/b_test.dart',
      );
    },
  );

  test(
    '[boundary] a mutant reached through a symlinked path still finds its '
    'key — /tmp against /private/tmp would otherwise miss every one, and '
    'every mutant would silently run in full',
    () {
      final Directory links = Directory.systemTemp.createTempSync(
        'test_selection_link_',
      );
      addTearDown(() => links.deleteSync(recursive: true));
      final Link link = Link(p.join(links.path, 'pkg'))..createSync(root.path);

      final ProcessCommand? command = selection.commandFor(
        _mutantIn(p.join(link.path, 'lib', 'foo.dart')),
        const LineRange(1, 3),
        full,
      );

      expect(command, isNot(same(full)));
      expect(command, isNotNull);
    },
  );
}
