import 'dart:io';

import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_verdict.dart';
import 'package:dart_mutants/src/runner/run_journal.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Mutant _mutant(int offset) => Mutant(
  filePath: 'lib/a.dart',
  offset: offset,
  length: 1,
  line: 1,
  column: offset + 1,
  original: '<',
  replacement: '<=',
  operatorName: 'relational_operator_replacement',
  description: '< → <=',
);

void main() {
  late Directory dir;
  late String path;
  const Map<String, Object?> header = <String, Object?>{
    'testCommand': 'dart test',
    'fingerprint': 'aaaa',
  };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('run_journal_test_');
    path = p.join(dir.path, 'journal.jsonl');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('[partition] a result recorded in one run is recalled in the next', () {
    RunJournal.open(path, header).record(
      MutantResult(
        mutant: _mutant(3),
        verdict: MutantVerdict.undetected,
        uncovered: true,
      ),
    );

    final RunJournal again = RunJournal.open(path, header);
    final MutantResult? r = again.recall(_mutant(3));

    expect(again.discarded, isNull);
    expect(again.recordedCount, 1);
    expect(r?.verdict, MutantVerdict.undetected);
    expect(r?.uncovered, isTrue);
  });

  test('[partition] a mutant with no recorded result is not recalled', () {
    RunJournal.open(path, header).record(
      MutantResult(mutant: _mutant(3), verdict: MutantVerdict.detected),
    );

    expect(RunJournal.open(path, header).recall(_mutant(4)), isNull);
  });

  test(
    '[decision] a recorded timeout is never recalled — the budget decided '
    'it, and the next run may have a larger one',
    () {
      RunJournal.open(path, header).record(
        MutantResult(
          mutant: _mutant(3),
          verdict: MutantVerdict.timeout,
          timeout: const Duration(seconds: 30),
        ),
      );

      expect(RunJournal.open(path, header).recall(_mutant(3)), isNull);
    },
  );

  test(
    '[decision] a different header starts the file over and names the '
    'field that changed',
    () {
      RunJournal.open(path, header).record(
        MutantResult(mutant: _mutant(3), verdict: MutantVerdict.detected),
      );

      final RunJournal changed = RunJournal.open(path, <String, Object?>{
        ...header,
        'fingerprint': 'bbbb',
      });

      expect(changed.discarded, contains('fingerprint'));
      expect(changed.recall(_mutant(3)), isNull);
      expect(File(path).readAsLinesSync(), hasLength(1));
    },
  );

  test(
    '[boundary] a last line cut off mid-write is skipped, and the lines '
    'before it still count',
    () {
      RunJournal.open(path, header)
        ..record(
          MutantResult(mutant: _mutant(3), verdict: MutantVerdict.detected),
        )
        ..record(
          MutantResult(mutant: _mutant(5), verdict: MutantVerdict.invalid),
        );
      File(path).writeAsStringSync('{"mutant": "[', mode: FileMode.append);

      final RunJournal again = RunJournal.open(path, header);

      expect(again.discarded, isNull);
      expect(again.recall(_mutant(3))?.verdict, MutantVerdict.detected);
      expect(again.recall(_mutant(5))?.verdict, MutantVerdict.invalid);
    },
  );

  test('[error] a file that is not a journal is started over', () {
    File(path).writeAsStringSync('not json\n');

    final RunJournal opened = RunJournal.open(path, header);

    expect(opened.discarded, 'it is not a journal this version can read');
    expect(opened.recordedCount, 0);
  });

  group('the fingerprint', () {
    late Directory pkg;

    setUp(() {
      pkg = Directory(p.join(dir.path, 'pkg'))..createSync();
      File(p.join(pkg.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
      Directory(p.join(pkg.path, 'lib')).createSync();
      Directory(p.join(pkg.path, 'test')).createSync();
      File(p.join(pkg.path, 'lib', 'a.dart')).writeAsStringSync('int a;\n');
      File(p.join(pkg.path, 'test', 'a_test.dart')).writeAsStringSync('//\n');
    });

    String fingerprint() => RunJournal.fingerprint(pkg.path, const <String>[]);

    test('[state] is the same for the same content', () {
      expect(fingerprint(), fingerprint());
    });

    test('[partition] changes when a test changes', () {
      final String before = fingerprint();
      File(p.join(pkg.path, 'test', 'a_test.dart')).writeAsStringSync('//x\n');
      expect(fingerprint(), isNot(before));
    });

    test('[partition] changes when a file is renamed, content unchanged', () {
      final String before = fingerprint();
      File(
        p.join(pkg.path, 'lib', 'a.dart'),
      ).renameSync(p.join(pkg.path, 'lib', 'b.dart'));
      expect(fingerprint(), isNot(before));
    });

    test('[partition] does not see a file outside lib/ and test/', () {
      final String before = fingerprint();
      File(p.join(pkg.path, 'README.md')).writeAsStringSync('changed\n');
      expect(fingerprint(), before);
    });
  });
}
