import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_pubspec.dart';

const String _notImplemented = 'not implemented yet';

final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

const String _sink = '''
class Sink {
  @pragma('dart_mutants:diagnostic')
  static void info(String message) {}
}
''';

/// `work()` with one marked call on line 6 and one survivor on line 7.
const String _callAndSurvivor = '''
import 'sink.dart';

int total = 0;

void work() {
  Sink.info('x');
  total++;
}
''';

/// `work()` whose only mutant is the marked call.
const String _callOnly = '''
import 'sink.dart';

void work() {
  Sink.info('x');
}
''';

/// What `lib/work.dart` is before the change the review looks at.
const String _emptyWork = '''
import 'sink.dart';

int total = 0;

void work() {}
''';

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

/// A package whose `lib/work.dart` is [work], and whose one test calls
/// `work()` and asserts nothing, so every mutant of `work.dart` that runs
/// survives.
Future<Directory> _fixture(String work) async {
  final Directory dir = Directory.systemTemp.createTempSync('dm_diagnostic_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(
    p.join(dir.path, 'pubspec.yaml'),
  ).writeAsStringSync(dartFixturePubspec('fixture'));
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'sink.dart')).writeAsStringSync(_sink);
  File(p.join(dir.path, 'lib', 'work.dart')).writeAsStringSync(work);
  File(p.join(dir.path, 'test', 'work_test.dart')).writeAsStringSync('''
import 'package:fixture/work.dart';
import 'package:test/test.dart';

void main() {
  test('work', work);
}
''');
  final ProcessResult pubGet = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError(
      'dart pub get failed:\n${pubGet.stdout}\n${pubGet.stderr}',
    );
  }
  return dir;
}

/// [_fixture] as a repository whose one commit holds [_emptyWork], then
/// `lib/work.dart` changed to [changed], uncommitted.
Future<Directory> _changedFixture(String changed) async {
  final Directory dir = await _fixture(_emptyWork);
  await _git(dir, <String>['init', '-q', '-b', 'main']);
  await _git(dir, <String>['add', '.']);
  await _git(dir, <String>['commit', '-q', '-m', 'base']);
  File(p.join(dir.path, 'lib', 'work.dart')).writeAsStringSync(changed);
  return dir;
}

Future<ProcessResult> _review(Directory dir, List<String> extra) => Process.run(
  'dart',
  <String>[
    'run',
    _binPath,
    '--test-command',
    'dart test',
    '--diff',
    'main',
    '--review',
    p.join(dir.path, 'review.json'),
    ...extra,
  ],
  workingDirectory: dir.path,
  environment: cliEnvironment,
);

List<Map<String, Object?>> _comments(Directory dir) =>
    (jsonDecode(File(p.join(dir.path, 'review.json')).readAsStringSync())
            as List<Object?>)
        .cast<Map<String, Object?>>();

/// One real run over [_callAndSurvivor] with `--output`: the CLI's result,
/// and `lib/work.dart`'s entry of the JSON report it wrote.
Future<(ProcessResult, Map<String, Object?>)> _runWithJsonFile() async {
  final Directory dir = await _fixture(_callAndSurvivor);
  final String out = p.join(dir.path, 'mutation.json');
  final ProcessResult result = await Process.run(
    'dart',
    <String>[
      'run',
      _binPath,
      '--test-command',
      'dart test',
      '--output',
      out,
      'lib/work.dart',
    ],
    workingDirectory: dir.path,
    environment: cliEnvironment,
  );
  final Map<String, Object?> json =
      jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>;
  final Map<String, Object?> file =
      (json['files']! as Map<String, Object?>)['lib/work.dart']!
          as Map<String, Object?>;
  return (result, file);
}

void main() {
  useHermeticVersionCheck();

  group('the report of a run with a diagnostic mutant', () {
    // Started by the first test that reads it, so skipped tests cost nothing.
    late final Future<(ProcessResult, Map<String, Object?>)> ran =
        _runWithJsonFile();

    test(
      '[S10] the JSON counts it apart and lists it the way invalidMutants '
      'lists invalid ones: the same entry shape, verdict diagnostic, and '
      'left out of total',
      () async {
        final Map<String, Object?> file = (await ran).$2;

        expect(file['diagnostic'], 1);
        expect(file['diagnosticMutants'], <Object?>[
          <String, Object?>{
            'filePath': 'lib/work.dart',
            'line': 6,
            'column': 3,
            'operatorName': 'statement_deletion',
            'description': "deleted 'Sink.info('x');'",
            'verdict': 'diagnostic',
          },
        ]);
        expect(file['undetected'], 1);
        expect(file['total'], 1);
        expect(file['invalid'], 0);
        expect(file['invalidMutants'], isEmpty);
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '[S10] the text report counts it in the file summary and lists it '
      'with the same weight as an invalid one, marked as not scored',
      () async {
        final ProcessResult result = (await ran).$1;
        final List<String> lines = (result.stdout as String).split('\n');

        expect(result.exitCode, 1, reason: '${result.stderr}');
        final String summary = lines.singleWhere(
          (String l) => l.startsWith('lib/work.dart: '),
        );
        expect(summary, contains('0/1 detected'));
        expect(summary, contains('1 diagnostic'));
        expect(
          lines,
          contains(
            '  diagnostic (NOT scored): statement_deletion at '
            "lib/work.dart:6:3 — deleted 'Sink.info('x');'",
          ),
        );
        expect(
          lines,
          contains(
            '  undetected: statement_deletion at lib/work.dart:7:3 — '
            "deleted 'total++;'",
          ),
        );
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '[S10] the progress line says diagnostic, like it says invalid for an '
      'invalid one',
      () async {
        expect(
          (await ran).$1.stdout,
          matches(
            RegExp(
              r'\[\d+/\d+\] diagnostic lib/work\.dart:6:3 statement_deletion',
            ),
          ),
        );
      },
      skip: _notImplemented,
    );
  });

  group('--review and --fail-on-survivors', () {
    test(
      '[S8] with only diagnostic mutants left, --fail-on-survivors exits 0',
      () async {
        final Directory dir = await _changedFixture(_callOnly);

        final ProcessResult result = await _review(dir, const <String>[
          '--fail-on-survivors',
        ]);

        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '[S8] with one undetected mutant beside the diagnostic one, '
      '--fail-on-survivors still exits 1',
      () async {
        final Directory dir = await _changedFixture(_callAndSurvivor);

        final ProcessResult result = await _review(dir, const <String>[
          '--fail-on-survivors',
        ]);

        expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '[S9] the review has a comment for the survivor and none for the '
      'diagnostic mutant',
      () async {
        final Directory dir = await _changedFixture(_callAndSurvivor);

        final ProcessResult result = await _review(dir, const <String>[]);

        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final List<Map<String, Object?>> comments = _comments(dir);
        expect(comments.map((Map<String, Object?> c) => c['line']), <int>[7]);
        expect(
          comments.map((Map<String, Object?> c) => '${c['body']}'),
          everyElement(isNot(contains('diagnostic'))),
        );
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '[S9] a change whose only mutant is diagnostic writes an empty review',
      () async {
        final Directory dir = await _changedFixture(_callOnly);

        final ProcessResult result = await _review(dir, const <String>[]);

        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        expect(_comments(dir), isEmpty);
      },
      skip: _notImplemented,
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
