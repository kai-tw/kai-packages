import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_pubspec.dart';

const String _notImplemented = 'not implemented yet';

/// What a package that uses `log_system` writes: one call to each level, one
/// to a line. `lib/work.dart` line 4 is `debug`, 5 `info`, 6 `warning`, 7
/// `error`, 8 `fatal`, 9 `event`.
const String _work = '''
import 'package:log_system/log_system.dart';

void work() {
  LogSystem.debug('x');
  LogSystem.info('x');
  LogSystem.warning('x');
  LogSystem.error('x');
  LogSystem.fatal('x');
  LogSystem.event('x');
}
''';

/// Whether `log_system` marks a level is decided by what the tool does to a
/// consumer's deleted call, so this runs the real CLI over a real package
/// that depends on the real `log_system`, resolved by `flutter pub get`
/// because the package is a Flutter one. Its one test calls `work()` and
/// asserts nothing, so a mutant that is run survives, which is all that tells
/// "run as usual" from "never run".
Future<Map<String, Object?>> _runOverLogSystem() async {
  final Directory dir = Directory.systemTemp.createTempSync('dm_log_system_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final String logSystem = p.join(p.dirname(dartMutantsRoot), 'log_system');
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: fixture
environment:
  sdk: ^3.8.0
dependencies:
  flutter:
    sdk: flutter
  log_system:
    path: $logSystem
dev_dependencies:
  flutter_test:
    sdk: flutter
$dartMutantsDevDependency''');
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'test', 'work_test.dart')).writeAsStringSync('''
import 'package:fixture/work.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work', work);
}
''');
  Directory(p.join(dir.path, 'lib')).createSync();
  File(p.join(dir.path, 'lib', 'work.dart')).writeAsStringSync(_work);
  final ProcessResult pubGet = await Process.run('flutter', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError(
      'flutter pub get failed:\n${pubGet.stdout}\n${pubGet.stderr}',
    );
  }
  final String out = p.join(dir.path, 'mutation.json');
  final ProcessResult result = await Process.run(
    'dart',
    <String>[
      'run',
      p.join(dartMutantsRoot, 'bin', 'dart_mutants.dart'),
      '--test-command',
      'flutter test',
      '--output',
      out,
      'lib/work.dart',
    ],
    workingDirectory: dir.path,
    environment: cliEnvironment,
  );
  expect(File(out).existsSync(), isTrue, reason: '${result.stderr}');
  final Map<String, Object?> json =
      jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>;
  return (json['files']! as Map<String, Object?>)['lib/work.dart']!
      as Map<String, Object?>;
}

/// The lines of `lib/work.dart` that have a mutant in [file]'s [list].
Set<int> _lines(Map<String, Object?> file, String list) => <int>{
  for (final Object? m in file[list]! as List<Object?>)
    (m! as Map<String, Object?>)['line']! as int,
};

void main() {
  useHermeticVersionCheck();

  // Started by the first test that reads it, so skipped tests cost nothing.
  late final Future<Map<String, Object?>> ran = _runOverLogSystem();

  const Map<String, int> marked = <String, int>{
    'debug': 4,
    'info': 5,
    'warning': 6,
    'event': 9,
  };
  for (final MapEntry<String, int> level in marked.entries) {
    test(
      '[log_system] deleting a `LogSystem.${level.key}` call is diagnostic: listed, '
      'not run, not scored',
      () async {
        final Map<String, Object?> file = await ran;

        expect(_lines(file, 'diagnosticMutants'), contains(level.value));
        expect(_lines(file, 'undetectedMutants'), isNot(contains(level.value)));
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  const Map<String, int> unmarked = <String, int>{'error': 7, 'fatal': 8};
  for (final MapEntry<String, int> level in unmarked.entries) {
    test(
      '[log_system] deleting a `LogSystem.${level.key}` call runs as usual: with no '
      'test to fail, it is undetected',
      () async {
        final Map<String, Object?> file = await ran;

        expect(_lines(file, 'undetectedMutants'), contains(level.value));
        expect(
          _lines(file, 'diagnosticMutants'),
          isNot(contains(level.value)),
        );
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
