import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_pubspec.dart';

final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

Future<void> _git(Directory dir, List<String> args) async {
  final ProcessResult r = await Process.run('git', <String>[
    '-c',
    'user.name=test',
    '-c',
    'user.email=test@example.com',
    '-c',
    'commit.gpgsign=false',
    ...args,
  ], workingDirectory: dir.path);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

void main() {
  useHermeticVersionCheck();

  test(
    '[B2] a change that only deletes lines says there is nothing new to '
    'test, writes an empty review and exits 0',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('dm_del_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        p.join(dir.path, 'pubspec.yaml'),
      ).writeAsStringSync(dartFixturePubspec('deleted'));
      Directory(p.join(dir.path, 'lib')).createSync();
      File(p.join(dir.path, 'lib', 'a.dart')).writeAsStringSync(
        'int one() => 1;\n\nint two(bool c) => c ? 1 : 2;\n',
      );
      await _git(dir, <String>['init', '-q', '-b', 'main']);
      await _git(dir, <String>['add', '.']);
      await _git(dir, <String>['commit', '-q', '-m', 'base']);
      File(
        p.join(dir.path, 'lib', 'a.dart'),
      ).writeAsStringSync('int one() => 1;\n');

      final String review = p.join(dir.path, 'review.json');
      final ProcessResult result = await Process.run(
        'dart',
        <String>[
          'run',
          _binPath,
          '--test-command',
          'dart test',
          '--diff',
          'main',
          '--review',
          review,
        ],
        workingDirectory: dir.path,
        environment: cliEnvironment,
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('nothing new to mutate'));
      expect(jsonDecode(File(review).readAsStringSync()), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
