import 'dart:io';

import 'package:dart_mutants/src/runner/compile_check.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_progress.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/run_plan.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_pubspec.dart';

/// A real package: the journal's promise — a second start runs nothing the
/// first one finished — is about which `dart test` runs happen, so it is
/// checked against real ones. `pick.dart` has one ternary its test pins both
/// ways (detected); `unused.dart` has one no test calls (undetected).
Future<Directory> _fixture() async {
  final Directory dir = Directory.systemTemp.createTempSync(
    'journal_run_test_',
  );
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: fixture
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
$dartMutantsDevDependency''');
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'pick.dart')).writeAsStringSync(
    "String pick(bool a) => a ? 'yes' : 'no';\n",
  );
  File(p.join(dir.path, 'lib', 'unused.dart')).writeAsStringSync(
    "String unused(bool a) => a ? 'yes' : 'no';\n",
  );
  File(p.join(dir.path, 'test', 'pick_test.dart')).writeAsStringSync('''
import 'package:fixture/pick.dart';
import 'package:test/test.dart';

void main() {
  test('yes', () => expect(pick(true), 'yes'));
  test('no', () => expect(pick(false), 'no'));
}
''');
  final ProcessResult pubGet = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError('dart pub get failed:\n${pubGet.stderr}');
  }
  return dir;
}

/// One start of a run over the fixture with a journal, and what it said.
class _Start {
  RunPlan? plan;
  final List<MutantProgress> ran = <MutantProgress>[];
  String? discarded;
  late MutationRunReport report;

  FileMutationReport file(String name) => report.files.singleWhere(
    (FileMutationReport f) => p.basename(f.filePath) == name,
  );
}

Future<_Start> _start(
  Directory dir,
  String journal, {
  bool selectByCoverage = false,
}) async {
  final InProcessAnalyzerCheck check = InProcessAnalyzerCheck(<String>[
    dir.path,
  ]);
  addTearDown(check.close);
  final _Start start = _Start();
  start.report =
      await MutationTestRunner(
        testCommand: ProcessCommand('dart', <String>[
          'test',
        ], workingDirectory: dir.path),
        compileCheck: check,
        mutantTimeout: const Duration(seconds: 20),
        baselineFactor: 0,
        selectByCoverage: selectByCoverage,
        journalPath: journal,
        onPlan: (RunPlan plan) => start.plan = plan,
        onProgress: start.ran.add,
        onJournalDiscarded: (String reason) => start.discarded = reason,
      ).run(<String>[
        p.join(dir.path, 'lib', 'pick.dart'),
        p.join(dir.path, 'lib', 'unused.dart'),
      ]);
  return start;
}

/// A real package whose only statement is a call to a marked method, so the
/// mutants of `work.dart` that touch it are diagnostic ones.
Future<Directory> _diagnosticFixture() async {
  final Directory dir = Directory.systemTemp.createTempSync(
    'journal_run_test_',
  );
  File(
    p.join(dir.path, 'pubspec.yaml'),
  ).writeAsStringSync(dartFixturePubspec('fixture'));
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'work.dart')).writeAsStringSync('''
class Sink {
  @pragma('dart_mutants:diagnostic')
  static void info(String message) {}
}

void work() {
  Sink.info('x');
}
''');
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
    throw StateError('dart pub get failed:\n${pubGet.stderr}');
  }
  return dir;
}

void main() {
  late Directory dir;
  late String journal;

  setUp(() async {
    dir = await _fixture();
    journal = p.join(dir.path, '.journal', 'run.jsonl');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test(
    '[state] a second start with the same journal runs no mutant and scores '
    'the same',
    () async {
      final _Start first = await _start(dir, journal);
      final _Start second = await _start(dir, journal);

      expect(first.ran, hasLength(2));
      expect(first.report.reusedMutants, 0);
      expect(second.plan?.mutantCount, 0);
      expect(second.plan?.reused, 2);
      expect(second.ran, isEmpty);
      expect(second.report.reusedMutants, 2);
      expect(second.file('pick.dart').detected, 1);
      expect(second.file('unused.dart').undetected, 1);
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );

  test(
    '[state] a second start reads the baseline from the journal instead of '
    'running it again',
    () async {
      final _Start first = await _start(dir, journal);
      File(journal).writeAsStringSync(
        '${File(journal).readAsLinesSync().take(2).join('\n')}\n',
      );
      final _Start second = await _start(dir, journal);

      expect(first.plan?.baselineReused, isFalse);
      expect(second.plan?.baselineReused, isTrue);
      expect(
        second.plan?.baseline?.inMilliseconds,
        first.plan?.baseline?.inMilliseconds,
      );
      expect(second.ran, hasLength(2));
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );

  test(
    '[state] under the selection, a second start scores the same without a '
    'baseline, and reuses every result',
    () async {
      final _Start first = await _start(dir, journal, selectByCoverage: true);
      final _Start second = await _start(dir, journal, selectByCoverage: true);

      expect(first.plan?.baseline, isNull);
      expect(second.plan?.baseline, isNull);
      expect(second.ran, isEmpty);
      expect(second.report.selectedByCoverage, isTrue);
      expect(second.file('pick.dart').detected, 1);
      expect(second.file('unused.dart').undetected, 1);
      expect(second.file('unused.dart').uncovered, 1);
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );

  test(
    '[partition] a recorded verdict is used as recorded, not asked again',
    () async {
      await _start(dir, journal);
      final File file = File(journal);
      file.writeAsStringSync(
        file.readAsStringSync().replaceAll(
          '"verdict":"detected"',
          '"verdict":"undetected"',
        ),
      );

      final _Start second = await _start(dir, journal);

      expect(second.ran, isEmpty);
      expect(second.file('pick.dart').undetected, 1);
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );

  test(
    '[decision] after a test changes, the journal is started over and '
    'every mutant runs',
    () async {
      await _start(dir, journal);
      File(
        p.join(dir.path, 'test', 'pick_test.dart'),
      ).writeAsStringSync('// edited\n', mode: FileMode.append);

      final _Start second = await _start(dir, journal);

      expect(second.discarded, contains('fingerprint'));
      expect(second.ran, hasLength(2));
      expect(second.report.reusedMutants, 0);
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );

  test(
    '[journal] a diagnostic result is recorded, and a second start takes it '
    'back as it was: not asked again, no test run',
    () async {
      final Directory fixture = await _diagnosticFixture();
      addTearDown(() => fixture.deleteSync(recursive: true));
      final String diagnosticJournal = p.join(
        fixture.path,
        '.journal',
        'run.jsonl',
      );

      Future<_Start> start(CompileCheck check) async {
        addTearDown(check.close);
        final _Start s = _Start();
        s.report = await MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: fixture.path),
          compileCheck: check,
          mutantTimeout: const Duration(seconds: 20),
          baselineFactor: 0,
          journalPath: diagnosticJournal,
          onPlan: (RunPlan plan) => s.plan = plan,
          onProgress: s.ran.add,
        ).run(<String>[p.join(fixture.path, 'lib', 'work.dart')]);
        return s;
      }

      final _Start first = await start(
        InProcessAnalyzerCheck(<String>[fixture.path]),
      );
      final _Start second = await start(
        InProcessAnalyzerCheck(<String>[fixture.path]),
      );

      final FileMutationReport before = first.file('work.dart');
      final FileMutationReport after = second.file('work.dart');
      expect(before.diagnostic, greaterThan(0));
      expect(first.ran, isNotEmpty);
      expect(second.ran, isEmpty);
      expect(second.plan?.mutantCount, 0);
      expect(second.plan?.reused, first.ran.length);
      expect(after.diagnostic, before.diagnostic);
      expect(after.undetected, before.undetected);
      expect(after.detected, before.detected);
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );
}
