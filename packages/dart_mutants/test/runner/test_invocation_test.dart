import 'dart:io';

import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/test_invocation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('test_invocation_test_');
    for (final String file in <String>[
      'test/a_test.dart',
      'test/deep/b_test.dart',
      'test/helper.dart',
      'integration/c_test.dart',
    ]) {
      File(p.join(root.path, file)).createSync(recursive: true);
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  TestInvocation? parse(String executable, List<String> args) =>
      TestInvocation.parse(
        ProcessCommand(executable, args, workingDirectory: root.path),
      );

  group('parse', () {
    test('[partition] recognises dart test and flutter test', () {
      expect(parse('dart', <String>['test'])!.runner, TestRunner.dart);
      expect(parse('flutter', <String>['test'])!.runner, TestRunner.flutter);
      expect(
        parse('/opt/flutter/bin/flutter', <String>['test'])!.runner,
        TestRunner.flutter,
      );
    });

    test(
      '[partition] leaves anything else alone — the caller then runs it as '
      'given',
      () {
        expect(parse('dart', <String>['analyze']), isNull);
        expect(parse('fvm', <String>['flutter', 'test']), isNull);
        expect(parse('./run_tests.sh', <String>['test']), isNull);
        expect(parse('dart', <String>[]), isNull);
      },
    );

    test('[partition] separates existing paths from flags, keeping order', () {
      final TestInvocation inv = parse('dart', <String>[
        'test',
        '--fail-fast',
        'test/a_test.dart',
        '-j',
        '1',
        'integration',
      ])!;

      expect(inv.paths, <String>['test/a_test.dart', 'integration']);
      expect(inv.flags, <String>['--fail-fast', '-j', '1']);
    });

    test(
      '[boundary] the value of an option that takes one is a flag even when '
      'it names an existing path',
      () {
        // `test` is a directory here, and also a plausible tag name.
        final TestInvocation inv = parse('dart', <String>[
          'test',
          '--tags',
          'test',
          '--name=integration',
        ])!;

        expect(inv.paths, isEmpty);
        expect(inv.flags, <String>['--tags', 'test', '--name=integration']);
      },
    );
  });

  test(
    '[partition] a command that collects coverage itself, or ends its '
    'options with --, is flagged so the caller can refuse it',
    () {
      expect(parse('dart', <String>['test'])!.setsCoverage, isFalse);
      expect(
        parse('dart', <String>['test', '--coverage=out'])!.setsCoverage,
        isTrue,
      );
      expect(
        parse('flutter', <String>['test', '--coverage'])!.setsCoverage,
        isTrue,
      );
      expect(
        parse('dart', <String>['test', '--', 'test'])!.hasOptionTerminator,
        isTrue,
      );
    },
  );

  test(
    '[boundary] a value option left out of the known list would swallow the '
    'first selected file — --packages is on the list',
    () {
      File(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      ).createSync(recursive: true);

      final TestInvocation inv = parse('dart', <String>[
        'test',
        '--packages',
        '.dart_tool/package_config.json',
      ])!;

      expect(inv.paths, isEmpty);
    },
  );

  group('testFiles', () {
    test('[boundary] an absolute test file comes back relative', () {
      expect(
        parse('dart', <String>[
          'test',
          p.join(root.path, 'test', 'a_test.dart'),
        ])!.testFiles(),
        <String>['test/a_test.dart'],
      );
    });

    test(
      '[partition] no paths means test/, walked recursively, *_test.dart '
      'only, sorted',
      () {
        expect(parse('dart', <String>['test'])!.testFiles(), <String>[
          'test/a_test.dart',
          'test/deep/b_test.dart',
        ]);
      },
    );

    test('[partition] given files and directories are expanded and merged', () {
      expect(
        parse('dart', <String>[
          'test',
          'integration',
          'test/a_test.dart',
        ])!.testFiles(),
        <String>['integration/c_test.dart', 'test/a_test.dart'],
      );
    });
  });

  test(
    '[partition] withTestFiles keeps the flags, adds the extras, and swaps '
    'in the given files',
    () {
      final ProcessCommand command =
          parse('flutter', <String>[
            'test',
            '--no-pub',
            'test',
          ])!.withTestFiles(
            <String>['test/a_test.dart'],
            extra: <String>['--coverage'],
          );

      expect(command.executable, 'flutter');
      expect(command.arguments, <String>[
        'test',
        '--no-pub',
        '--coverage',
        'test/a_test.dart',
      ]);
      expect(command.workingDirectory, root.path);
    },
  );
}
