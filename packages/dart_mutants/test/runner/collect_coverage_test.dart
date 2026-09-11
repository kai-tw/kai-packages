import 'dart:io';

import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/test_invocation.dart';
import 'package:dart_mutants/src/runner/test_selection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A package with two test files and no toolchain behind it. Refusals are
/// decided before any process starts, so they need nothing else; the
/// report-reading cases run a fake `dart` or `flutter` that writes what
/// each case needs.
Directory _package() {
  final Directory root = Directory.systemTemp.createTempSync(
    'collect_coverage_test_',
  );
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: pkg\n');
  for (final String file in <String>['test/a_test.dart', 'test/b_test.dart']) {
    File(p.join(root.path, file))
      ..createSync(recursive: true)
      ..writeAsStringSync("import 'package:pkg/pkg.dart';\n");
  }
  File(p.join(root.path, 'lib', 'pkg.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('int f() => 1;\n');
  return root;
}

/// A fake runner named [name] in its own directory, running [body] as a
/// shell script with the real arguments in `$@`.
String _fake(String name, String body) {
  final Directory bin = Directory.systemTemp.createTempSync('fake_runner_');
  addTearDown(() => bin.deleteSync(recursive: true));
  final File file = File(p.join(bin.path, name))
    ..writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
  return file.path;
}

Future<(TestSelection?, List<String>)> _collect(
  Directory root,
  String executable,
  List<String> args,
) async {
  final List<String> reasons = <String>[];
  final TestSelection? selection = await collectCoverage(
    TestInvocation.parse(
      ProcessCommand(executable, args, workingDirectory: root.path),
    )!,
    timeout: const Duration(seconds: 30),
    onFailure: reasons.add,
  );
  return (selection, reasons);
}

void main() {
  late Directory root;

  setUp(() => root = _package());
  tearDown(() => root.deleteSync(recursive: true));

  group('refuses, before running anything, a command it cannot mirror', () {
    // The fake runner fails any run it is asked to do. Had the command not
    // been refused, the one reason would be that failure — "exited 1".
    final Map<String, (List<String>, String)> cases =
        <String, (List<String>, String)>{
          '`--`': (<String>['test', '--', 'test'], ''),
          'its own coverage': (<String>['test', '--coverage=out'], ''),
          'a platform off the VM': (
            <String>['test', '-p', 'vm,chrome'],
            '',
          ),
          'an argument it cannot place': (
            <String>['test', 'test/a_test.dart?name=x'],
            '',
          ),
          'dart_test.yaml paths, with no paths given': (
            <String>['test'],
            'paths: [test]\n',
          ),
          'dart_test.yaml filename, even with paths given': (
            <String>['test', 'test'],
            'filename: "*_spec.dart"\n',
          ),
          'dart_test.yaml platforms': (
            <String>['test', 'test'],
            'platforms: [chrome]\n',
          ),
        };

    for (final MapEntry<String, (List<String>, String)> c in cases.entries) {
      test('[error] ${c.key}', () async {
        final String config = c.value.$2;
        if (config.isNotEmpty) {
          File(p.join(root.path, 'dart_test.yaml')).writeAsStringSync(config);
        }

        final (TestSelection? selection, List<String> reasons) = await _collect(
          root,
          _fake('dart', 'exit 1'),
          c.value.$1,
        );

        expect(selection, isNull);
        expect(reasons.single, isNot(contains('exited')));
      });
    }

    test(
      '[error] under flutter test, a test that imports lib/ by relative '
      'path — its coverage drops that copy of the file',
      () async {
        File(
          p.join(root.path, 'test', 'a_test.dart'),
        ).writeAsStringSync("import '../lib/pkg.dart';\n");

        final (TestSelection? selection, List<String> reasons) = await _collect(
          root,
          _fake('flutter', 'exit 1'),
          <String>['test'],
        );

        expect(selection, isNull);
        expect(reasons.single, contains('relative path'));
      },
    );
  });

  group('reading what the runner wrote', () {
    // Writes [report] where `dart test --coverage=<dir>` writes each suite's
    // report, for every test file named on the command line.
    String dartWriting(String report, {String onScoped = ''}) => _fake(
      'dart',
      '''
dir=""; files=""
for a in "\$@"; do
  case "\$a" in
    --coverage=*) dir="\${a#--coverage=}" ;;
    --coverage-package=*) $onScoped ;;
    test/*) files="\$files \$a" ;;
  esac
done
for f in \$files; do
  mkdir -p "\$dir/\$(dirname "\$f")"
  printf '%s' '$report' > "\$dir/\$f.vm.json"
done
exit 0
''',
    );

    const String good =
        '{"type":"CodeCoverage","coverage":[{"source":"package:pkg/pkg.dart",'
        '"hits":[1,1]}]}';

    test('[partition] a well-formed report builds a selection', () async {
      final (TestSelection? selection, List<String> reasons) = await _collect(
        root,
        dartWriting(good),
        <String>['test'],
      );

      expect(reasons, isEmpty);
      expect(selection!.map.testsFor('lib/pkg.dart', 1, 1), <String>{
        'test/a_test.dart',
        'test/b_test.dart',
      });
    });

    test(
      '[error] a report in an unexpected shape falls back instead of '
      'crashing the run after its baseline',
      () async {
        final (TestSelection? selection, List<String> reasons) = await _collect(
          root,
          dartWriting('{"coverage":7}'),
          <String>[
            'test',
          ],
        );

        expect(selection, isNull);
        expect(reasons.single, contains('could not be read'));
      },
    );

    test(
      '[error] no reports at all falls back, rather than claim a selection '
      'that selects nothing',
      () async {
        final (TestSelection? selection, List<String> reasons) = await _collect(
          root,
          _fake('dart', 'exit 0'),
          <String>['test'],
        );

        expect(selection, isNull);
        expect(reasons.single, contains('no coverage reports'));
      },
    );

    test(
      '[partition] a package:test too old for --coverage-package is retried '
      'without it',
      () async {
        final (TestSelection? selection, List<String> reasons) = await _collect(
          root,
          dartWriting(good, onScoped: 'exit 64'),
          <String>[
            'test',
          ],
        );

        expect(reasons, isEmpty);
        expect(selection, isNotNull);
      },
    );

    test(
      '[partition] flutter test: one lcov per file, and a file that runs no '
      'test contributes nothing rather than failing the pass',
      () async {
        final String flutter = _fake('flutter', r'''
out=""; file=""
for a in "$@"; do
  case "$a" in
    --coverage-path=*) out="${a#--coverage-path=}" ;;
    test/*) file="$a" ;;
  esac
done
[ "$file" = "test/b_test.dart" ] && exit 79
printf 'SF:lib/pkg.dart\nDA:1,3\nend_of_record\n' > "$out"
exit 0
''');

        final (TestSelection? selection, List<String> reasons) = await _collect(
          root,
          flutter,
          <String>['test'],
        );

        expect(reasons, isEmpty);
        expect(selection!.map.testsFor('lib/pkg.dart', 1, 1), <String>{
          'test/a_test.dart',
        });
      },
    );
  });

  test(
    '[boundary] under flutter test, a file with coverage:ignore comments is '
    'not spoken for — they can delete a function\'s entry from the report',
    () async {
      final String flutter = _fake('flutter', r'''
for a in "$@"; do case "$a" in --coverage-path=*) out="${a#--coverage-path=}";; esac; done
printf 'SF:lib/pkg.dart\nDA:1,1\nend_of_record\n' > "$out"
''');
      final (TestSelection? selection, _) = await _collect(
        root,
        flutter,
        <String>['test'],
      );

      expect(selection!.speaksFor('int f() => 1;\n'), isTrue);
      expect(
        selection.speaksFor('// coverage:ignore-line\nint f() => 1;\n'),
        isFalse,
      );
    },
  );
}
