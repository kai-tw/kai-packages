import 'dart:io';

import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_progress.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/run_plan.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
''');
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

Future<_Start> _start(Directory dir, String journal) async {
  final InProcessAnalyzerGate gate = InProcessAnalyzerGate(<String>[dir.path]);
  addTearDown(gate.close);
  final _Start start = _Start();
  start.report =
      await MutationTestRunner(
        testCommand: ProcessCommand('dart', <String>[
          'test',
        ], workingDirectory: dir.path),
        compileSafetyGate: gate,
        mutantTimeout: const Duration(seconds: 20),
        baselineFactor: 0,
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
}
