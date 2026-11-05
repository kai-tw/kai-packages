import 'dart:io';

import 'package:dart_mutants/src/review/diff_scope.dart';
import 'package:dart_mutants/src/runner/worker_sandbox.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A real git repository holding a package under `pkg/`, because what is
/// under test is how the change is read out of git: the merge base, commits
/// on the branch, and uncommitted edits.
late Directory _repo;
late String _pkg;

void _git(List<String> args) {
  final ProcessResult r = Process.runSync('git', <String>[
    '-c',
    'user.name=test',
    '-c',
    'user.email=test@example.com',
    '-c',
    'commit.gpgsign=false',
    ...args,
  ], workingDirectory: _repo.path);
  if (r.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${r.stderr}');
  }
}

void _write(String path, String content) =>
    (File(p.join(_pkg, path))..createSync(recursive: true)).writeAsStringSync(
      content,
    );

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('diff_scope_test_');
    _pkg = p.join(_repo.path, 'pkg');
    _git(<String>['init', '-q', '-b', 'main']);
    _write('pubspec.yaml', 'name: pkg\n');
    _write('lib/a.dart', 'int a() => 1;\nint b() => 2;\nint c() => 3;\n');
    _write('lib/deleted.dart', 'int x() => 1;\nint y() => 2;\n');
    _write('lib/untouched.dart', 'int u() => 1;\n');
    _write('lib/a.g.dart', 'int g() => 1;\n');
    _write('test/a_test.dart', 'void main() {}\n');
    _git(<String>['add', '.']);
    _git(<String>['commit', '-q', '-m', 'base']);
    _git(<String>['checkout', '-q', '-b', 'topic']);
    // Committed on the branch: line 2 of a.dart changed.
    _write('lib/a.dart', 'int a() => 1;\nint b() => 20;\nint c() => 3;\n');
    _git(<String>['commit', '-q', '-am', 'change b']);
    // Uncommitted: a line added at the end of a.dart, a line deleted from
    // deleted.dart, and a generated file and a test touched.
    _write(
      'lib/a.dart',
      'int a() => 1;\nint b() => 20;\nint c() => 3;\nint d() => 4;\n',
    );
    _write('lib/deleted.dart', 'int x() => 1;\n');
    _write('lib/a.g.dart', 'int g() => 2;\n');
    _write('test/a_test.dart', 'void main() { }\n');
  });

  tearDown(() => _repo.deleteSync(recursive: true));

  test(
    '[partition] the changed lines since the merge base, committed and '
    'uncommitted alike, of every touched hand-written file under lib/',
    () async {
      final DiffScope scope = await DiffScope.of('main', packageRoot: _pkg);

      expect(scope.lines, <String, Set<int>>{
        realPath(p.join(_pkg, 'lib', 'a.dart')): <int>{2, 4},
      });
    },
  );

  test(
    '[decision] given files are the scope, and the ref still sets their '
    'lines — a given file with no added line is left out',
    () async {
      final DiffScope scope = await DiffScope.of(
        'main',
        packageRoot: _pkg,
        files: <String>[
          p.join(_pkg, 'lib', 'a.dart'),
          p.join(_pkg, 'lib', 'untouched.dart'),
        ],
      );

      expect(scope.files, <String>[realPath(p.join(_pkg, 'lib', 'a.dart'))]);
    },
  );

  test('[error] a ref that does not resolve says so', () async {
    await expectLater(
      DiffScope.of('no-such-ref', packageRoot: _pkg),
      throwsA(
        isA<DiffScopeException>().having(
          (DiffScopeException e) => e.message,
          'message',
          contains('no-such-ref'),
        ),
      ),
    );
  });

  group('parseAddedLines', () {
    test('[partition] a hunk with a count adds that many lines', () {
      expect(parseAddedLines('@@ -3,0 +4,2 @@ x\n'), <int>{4, 5});
    });

    test('[partition] a hunk with no count adds one line', () {
      expect(parseAddedLines('@@ -3 +3 @@\n'), <int>{3});
    });

    test('[boundary] a hunk that only deletes adds none', () {
      expect(parseAddedLines('@@ -2,1 +1,0 @@\n'), isEmpty);
    });
  });
}
