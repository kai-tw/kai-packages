import 'dart:io';

import 'package:dart_mutants/src/mutation_operator.dart';
import 'package:dart_mutants/src/operators/ternary_swap.dart';
import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_verdict.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A real temp Dart package — `pubspec.yaml`, `dart pub get`, real `lib/`
/// and `test/` files — because the property under test (a mutant that
/// fails to compile must never read as "detected") only actually exists at
/// the boundary between three real things: the analyzer, a `dart test`
/// subprocess, and this package's own file-mutation logic. A mock of any one
/// of them would test that the mock behaves as scripted, not that the real
/// pipeline gets the classification right.
Future<Directory> _fixturePackage() async {
  final Directory dir = Directory.systemTemp.createTempSync(
    'mutation_test_runner_test_',
  );
  File(
    p.join(dir.path, 'pubspec.yaml'),
  ).writeAsStringSync('''
name: fixture
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
''');
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();

  // detected.dart: a ternary fully covered both ways — swapping it must
  // make at least one assertion fail.
  File(p.join(dir.path, 'lib', 'detected.dart')).writeAsStringSync(
    "String classify(bool isPositive) => isPositive ? 'positive' : 'negative';\n",
  );
  File(p.join(dir.path, 'test', 'detected_test.dart')).writeAsStringSync('''
import 'package:fixture/detected.dart';
import 'package:test/test.dart';

void main() {
  test('positive', () => expect(classify(true), 'positive'));
  test('negative', () => expect(classify(false), 'negative'));
}
''');

  // undetected.dart: a ternary no test ever calls at all — trivially, no
  // mutant on it can ever be caught.
  File(p.join(dir.path, 'lib', 'undetected.dart')).writeAsStringSync(
    "String classify(bool isPositive) => isPositive ? 'positive' : 'negative';\n",
  );
  File(p.join(dir.path, 'test', 'undetected_test.dart')).writeAsStringSync('''
void main() {}
''');

  // detected_and_undetected.dart: ONE file where detected AND undetected
  // are BOTH nonzero. Every other fixture in this suite has one side or the
  // other at zero, which means `total = detected + undetected` computes the
  // exact same number as `detected - undetected` everywhere else in this
  // file. Measured: that gap let `total`'s own `+` mutate to `-` and come
  // back completely unnoticed the first time this file's own operators were
  // run against it for real, because nothing here could tell addition from
  // subtraction. `covered`'s ternary is exercised both ways (its mutant is
  // detected); `uncovered`'s is never called at all (its mutant is not).
  File(
    p.join(dir.path, 'lib', 'detected_and_undetected.dart'),
  ).writeAsStringSync('''
String covered(bool isPositive) => isPositive ? 'positive' : 'negative';
String uncovered(bool isPositive) => isPositive ? 'positive' : 'negative';
''');
  File(
    p.join(dir.path, 'test', 'detected_and_undetected_test.dart'),
  ).writeAsStringSync('''
import 'package:fixture/detected_and_undetected.dart';
import 'package:test/test.dart';

void main() {
  test('covered', () {
    expect(covered(true), 'positive');
    expect(covered(false), 'negative');
  });
}
''');

  // invalid.dart: a `??` whose "left alone" mutant is a guaranteed compile
  // error (String? returned from an explicitly non-nullable String), and
  // whose "fallback alone" mutant compiles fine and is caught by the test.
  //
  // Deliberately an EXPRESSION body, not a block. Every fixture here is
  // built to isolate exactly one operator's mutants so the counts below
  // stay sharp assertions rather than running totals, and a block body
  // hands `statement_deletion` a mutant per statement — which is correct
  // behaviour on its part, just not what this file is measuring.
  File(p.join(dir.path, 'lib', 'invalid.dart')).writeAsStringSync(
    "String withDefault(String? a) => a ?? 'the default';\n",
  );
  File(p.join(dir.path, 'test', 'invalid_test.dart')).writeAsStringSync('''
import 'package:fixture/invalid.dart';
import 'package:test/test.dart';

void main() {
  test('uses the provided value when present', () {
    expect(withDefault('given'), 'given');
  });
}
''');

  // invalid_arithmetic.dart: a SECOND, independently verified operator that
  // can also produce an invalid mutant — `invalid.dart` above only proves
  // null_coalescing_deletion can. `+` on String is concatenation; swapping it
  // to `-` (arithmetic_operator_replacement's whole job) has no operator to
  // fall back to at all. Checked against the real analyzer via a standalone
  // probe before being written here, not assumed from the operator's own doc
  // comment.
  File(p.join(dir.path, 'lib', 'invalid_arithmetic.dart')).writeAsStringSync(
    "String greet(String name) => 'Hello, ' + name;\n",
  );
  File(
    p.join(dir.path, 'test', 'invalid_arithmetic_test.dart'),
  ).writeAsStringSync('''
import 'package:fixture/invalid_arithmetic.dart';
import 'package:test/test.dart';

void main() {
  test('greets', () => expect(greet('world'), 'Hello, world'));
}
''');

  // invalid_statement_deletion.dart: a THIRD operator that can produce an
  // invalid mutant — deleting the only statement of a value-returning
  // function's block body leaves nothing to return. A block body, not an
  // expression body: statement_deletion only proposes mutants inside a
  // Block, which is also why this needs its own file rather than folding
  // into one already using an expression body.
  File(
    p.join(dir.path, 'lib', 'invalid_statement_deletion.dart'),
  ).writeAsStringSync('''
String shout(String s) {
  return s.toUpperCase();
}
''');
  File(
    p.join(dir.path, 'test', 'invalid_statement_deletion_test.dart'),
  ).writeAsStringSync('''
import 'package:fixture/invalid_statement_deletion.dart';
import 'package:test/test.dart';

void main() {
  test('shouts', () => expect(shout('hi'), 'HI'));
}
''');

  // invalid_mixed.dart: THREE different operators each contribute an
  // invalid mutant to the SAME file — the shape of the real report that
  // motivated invalidMutants existing at all, where a bare `invalid: 27`
  // left a caller unable to tell whether they shared one cause or several.
  // `label`'s declaration is read by the `return` below it, so: `??`'s
  // left-alone mutant is a type error (a nullable value where the local's
  // declared type is not), deleting either statement is a type error (an
  // undefined read, or a missing return), and `+` on the resulting String
  // has no `-` to fall back to. `??`'s fallback-alone mutant is the file's
  // one legitimately scored candidate, and the test below exists to catch
  // it, not just to pad the fixture.
  File(p.join(dir.path, 'lib', 'invalid_mixed.dart')).writeAsStringSync('''
String greet(String? name) {
  final String label = name ?? 'stranger';
  return 'Hello, ' + label;
}
''');
  File(
    p.join(dir.path, 'test', 'invalid_mixed_test.dart'),
  ).writeAsStringSync('''
import 'package:fixture/invalid_mixed.dart';
import 'package:test/test.dart';

void main() {
  test('greets the given name', () => expect(greet('Kai'), 'Hello, Kai'));
}
''');

  // no_mutants.dart: nothing any operator here touches at all — a file
  // that is fully covered but produces zero candidates.
  File(
    p.join(dir.path, 'lib', 'no_mutants.dart'),
  ).writeAsStringSync('String shout(String s) => s.toUpperCase();\n');
  File(p.join(dir.path, 'test', 'no_mutants_test.dart')).writeAsStringSync('''
import 'package:fixture/no_mutants.dart';
import 'package:test/test.dart';

void main() {
  test('shouts', () => expect(shout('hi'), 'HI'));
}
''');

  // hangs.dart: the original always takes the safe path (a real assertion
  // covers exactly that), but swapping the ternary's branches routes into a
  // genuine, synchronous, non-yielding infinite loop — the shape no
  // event-loop-based test timeout can preempt.
  //
  // The non-terminating loop lives in its own file, which is NEVER passed
  // to the runner and so is never mutated. It has to: an infinite loop needs
  // a block body, a block body gets one `statement_deletion` mutant per
  // statement, and `while (true)` gets a `condition_negation` one — all
  // landing on this file and burying the single timing-out mutant this test
  // is about. Keeping the hang out of the mutated file leaves `hangs.dart`
  // with exactly one candidate: the ternary swap that routes into it.
  File(p.join(dir.path, 'lib', 'hangs.dart')).writeAsStringSync(
    "import 'hang_helper.dart';\n\n"
    "String process(bool takeSafePath) => takeSafePath ? 'ok' : hang();\n",
  );
  File(p.join(dir.path, 'lib', 'hang_helper.dart')).writeAsStringSync('''
String hang() {
  // ignore: literal_only_boolean_expressions
  while (true) {}
}
''');
  File(p.join(dir.path, 'test', 'hangs_test.dart')).writeAsStringSync('''
import 'package:fixture/hangs.dart';
import 'package:test/test.dart';

void main() {
  test('takes the safe path', () => expect(process(true), 'ok'));
}
''');

  // custom_operators.dart: a ternary AND a relational comparison in the same
  // expression, never exercised by its test at all — so defaultOperators()
  // would report undetected mutants from BOTH TernarySwap and
  // RelationalOperatorReplacement, while a caller-supplied list holding only
  // TernarySwap must report just the one.
  File(p.join(dir.path, 'lib', 'custom_operators.dart')).writeAsStringSync(
    "String classify(int a, int b) => a < b ? 'less' : 'not-less';\n",
  );
  File(
    p.join(dir.path, 'test', 'custom_operators_test.dart'),
  ).writeAsStringSync('void main() {}\n');

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

/// Uses the DEFAULT gate on purpose. This fixture is where "a mutant that
/// fails to compile must never read as detected" is actually proven end to
/// end, so it has to be proven against the gate a caller gets when they pass
/// nothing. The runner does not own the gate it is handed, so the test closes
/// it.
MutationTestRunner _runnerFor(Directory dir) {
  final InProcessAnalyzerGate gate = InProcessAnalyzerGate(<String>[dir.path]);
  addTearDown(gate.close);
  return _runnerWithGate(dir, gate);
}

MutationTestRunner _runnerWithGate(
  Directory dir,
  CompileSafetyGate gate,
) => MutationTestRunner(
  testCommand: ProcessCommand('dart', <String>[
    'test',
  ], workingDirectory: dir.path),
  compileSafetyGate: gate,
  // Short, but not as short as it wants to be. Every mutant in this fixture
  // except hangs.dart's finishes near-instantly, and that one is designed
  // never to finish at all, so the timeout only has to outlast a `dart test`
  // cold start.
  //
  // It was 5s, and that made this file FLAKY: run alone it passed, run inside
  // the full suite it failed with "the test command did not finish against
  // unmodified code within the timeout" — the BASELINE run, not a mutant. The
  // baseline is the cold one (nothing is warm yet) and it competes with every
  // other test file the runner is executing in parallel, so 5s of headroom is
  // a bet on machine load rather than a property of the fixture.
  //
  // Doubling costs ~5s on the one mutant that genuinely hangs. A suite that
  // measures whether OTHER suites are trustworthy cannot be the flaky one.
  mutantTimeout: const Duration(seconds: 10),
);

FileMutationReport _reportFor(MutationRunReport report, String name) =>
    report.files.singleWhere(
      (FileMutationReport f) => p.basename(f.filePath) == name,
    );

void main() {
  group('a full run against a real package', () {
    late Directory dir;
    late MutationRunReport report;

    tearDownAll(() => dir.deleteSync(recursive: true));

    setUpAll(() async {
      dir = await _fixturePackage();
      report = await _runnerFor(dir).run(<String>[
        p.join(dir.path, 'lib', 'detected.dart'),
        p.join(dir.path, 'lib', 'undetected.dart'),
        p.join(dir.path, 'lib', 'detected_and_undetected.dart'),
        p.join(dir.path, 'lib', 'invalid.dart'),
        p.join(dir.path, 'lib', 'invalid_arithmetic.dart'),
        p.join(dir.path, 'lib', 'invalid_statement_deletion.dart'),
        p.join(dir.path, 'lib', 'invalid_mixed.dart'),
        p.join(dir.path, 'lib', 'no_mutants.dart'),
        p.join(dir.path, 'lib', 'hangs.dart'),
      ]);
    });

    test('[partition] does not abort — the baseline suite was green', () {
      expect(report.aborted, isFalse);
    });

    test(
      '[partition] a fully-covered ternary swap is detected',
      () {
        final FileMutationReport f = _reportFor(report, 'detected.dart');
        expect(f.detected, 1);
        expect(f.undetected, 0);
        expect(f.invalid, 0);
      },
    );

    test(
      '[partition] a never-called ternary swap is undetected, not invalid '
      '— it compiles fine, nothing just happens to run it',
      () {
        final FileMutationReport f = _reportFor(report, 'undetected.dart');
        expect(f.detected, 0);
        expect(f.undetected, 1);
        expect(f.invalid, 0);
      },
    );

    test(
      '[boundary] total is detected PLUS undetected, not detected MINUS '
      'undetected — every other fixture in this suite has one side or the '
      'other at zero, so only a file with BOTH nonzero can tell `+` apart '
      'from `-`. Measured: this file is what caught `total`\'s own `+` '
      'mutating to `-` and coming back unnoticed the first time.',
      () {
        final FileMutationReport f = _reportFor(
          report,
          'detected_and_undetected.dart',
        );

        expect(f.detected, 1);
        expect(f.undetected, 1);
        expect(f.total, 2, reason: '1 + 1, not 1 - 1');
        expect(f.detectionRate, 0.5);
      },
    );

    test(
      '[partition] a mutant that fails to compile is invalid, and does '
      'NOT inflate detected — this is the one failure mode the whole gate '
      'exists to prevent',
      () {
        final FileMutationReport f = _reportFor(report, 'invalid.dart');
        expect(f.invalid, 1, reason: 'the String?-into-String mutant');
        expect(
          f.detected,
          1,
          reason: 'the other mutant on this file compiles and is caught',
        );
        expect(f.undetected, 0);
      },
    );

    test(
      '[boundary] a file with zero candidate mutants still appears in the '
      'report, at total 0 — "no mutants" and "not scanned" must stay '
      'distinguishable to a caller',
      () {
        final FileMutationReport f = _reportFor(report, 'no_mutants.dart');
        expect(f.total, 0);
        expect(f.detectionRate, isNull);
        expect(f.detected, 0);
        expect(f.undetected, 0);
        expect(f.invalid, 0);
        expect(f.timedOut, 0);
      },
    );

    test(
      '[boundary] a mutant that hangs the test command is timedOut, not '
      'detected — a hang is not the same evidence as an assertion actually '
      'catching the wrong output, even though both make the process exit '
      'non-zero-shaped',
      () {
        final FileMutationReport f = _reportFor(report, 'hangs.dart');
        expect(f.timedOut, 1);
        expect(f.detected, 0);
        expect(f.undetected, 0);
        expect(f.invalid, 0);
        expect(f.total, 0, reason: 'timedOut is excluded from the score');
      },
    );

    test(
      '[boundary] a timed-out mutant is reported with its IDENTITY, not just '
      'counted — a count says something went unmeasured without saying what, '
      'so nobody can go and look at it',
      () {
        final FileMutationReport f = _reportFor(report, 'hangs.dart');

        expect(f.timedOutMutants, hasLength(f.timedOut));
        final MutantResult r = f.timedOutMutants.single;
        expect(r.verdict, MutantVerdict.timeout);
        expect(r.mutant.line, greaterThan(0));
        expect(r.mutant.operatorName, 'ternary_swap');
        expect(
          r.mutant.description,
          isNotEmpty,
          reason:
              'a caller has to be able to map this back to a source line; '
              'measured, a mutant that timed out on EVERY round was therefore '
              'never scored once and stayed invisible behind the count',
        );
      },
    );

    test(
      '[boundary] an invalid mutant is reported with its IDENTITY, not just '
      'counted — a count says the gate rejected something without saying '
      'what, so nobody can tell a handful of one-off rejections from one '
      'operator consistently misfiring against this file',
      () {
        final FileMutationReport f = _reportFor(report, 'invalid.dart');

        expect(f.invalidMutants, hasLength(f.invalid));
        final MutantResult r = f.invalidMutants.single;
        expect(r.verdict, MutantVerdict.invalid);
        expect(r.mutant.line, greaterThan(0));
        expect(
          r.mutant.description,
          isNotEmpty,
          reason: 'a caller has to be able to map this back to a source line',
        );
        // Still no identity list for the good outcome — nobody needs to know
        // which mutants a test suite successfully caught, only which ones it
        // didn't or couldn't.
        expect(f.timedOutMutants, isEmpty);
      },
    );

    test(
      '[partition] arithmetic_operator_replacement on a String produces an '
      'invalid mutant too, not just null_coalescing_deletion — `+` is '
      'concatenation, and swapping to `-` has no operator to fall back to '
      'at all',
      () {
        final FileMutationReport f = _reportFor(
          report,
          'invalid_arithmetic.dart',
        );

        expect(f.invalid, 1);
        expect(f.total, 0, reason: "this file's only candidate is invalid");
        final MutantResult r = f.invalidMutants.single;
        expect(r.mutant.operatorName, 'arithmetic_operator_replacement');
        expect(r.mutant.line, 1);
      },
    );

    test(
      '[partition] statement_deletion produces an invalid mutant when the '
      'deleted statement was the only `return` in a value-returning '
      'function',
      () {
        final FileMutationReport f = _reportFor(
          report,
          'invalid_statement_deletion.dart',
        );

        expect(f.invalid, 1);
        expect(f.total, 0, reason: "this file's only candidate is invalid");
        final MutantResult r = f.invalidMutants.single;
        expect(r.mutant.operatorName, 'statement_deletion');
        expect(r.mutant.line, 2);
        expect(r.mutant.description, contains('return'));
      },
    );

    test(
      '[boundary] invalid mutants from THREE DIFFERENT operators in the '
      'same file are all captured, each with its own correct identity — '
      'not merged, dropped, or misattributed to the wrong operator or line',
      () {
        final FileMutationReport f = _reportFor(report, 'invalid_mixed.dart');

        expect(f.invalid, 4);
        expect(f.invalidMutants, hasLength(4));
        expect(
          f.invalidMutants
              .map((MutantResult r) => r.mutant.operatorName)
              .toSet(),
          <String>{
            'null_coalescing_deletion',
            'statement_deletion',
            'arithmetic_operator_replacement',
          },
          reason: 'three different operators each rejected on this one file',
        );
        expect(
          f.invalidMutants
              .map((MutantResult r) => (r.mutant.line, r.mutant.column))
              .toSet(),
          hasLength(4),
          reason:
              'four distinct mutants must map back to four distinct spots, '
              'not collapse to fewer',
        );
        // The file's one legitimately scored mutant survives being buried
        // among four invalid ones — invalid and detected are counted (and
        // listed) independently.
        expect(f.detected, 1);
        expect(f.undetected, 0);
      },
    );

    test(
      '[partition] a hung mutant still gets its file restored — the kill '
      'happens in _runOne\'s try block, and restore runs in its finally '
      'regardless',
      () {
        expect(
          File(p.join(dir.path, 'lib', 'hangs.dart')).readAsStringSync(),
          contains("takeSafePath ? 'ok' : hang()"),
        );
      },
    );

    test(
      '[partition] every mutated file ends the run back at its own original content',
      () {
        expect(
          File(p.join(dir.path, 'lib', 'detected.dart')).readAsStringSync(),
          "String classify(bool isPositive) => isPositive ? 'positive' : 'negative';\n",
        );
        expect(
          File(p.join(dir.path, 'lib', 'invalid.dart')).readAsStringSync(),
          contains("a ?? 'the default'"),
        );
      },
    );
  });

  group('the subprocess gate, end to end', () {
    test(
      '[partition] classifies every invalid-mutant fixture exactly as the '
      'default in-process gate does — the opt-in path still ships, so it '
      'still has to be proven through a real run and not only in isolation',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final List<String> files = <String>[
          p.join(dir.path, 'lib', 'invalid.dart'),
          p.join(dir.path, 'lib', 'invalid_arithmetic.dart'),
          p.join(dir.path, 'lib', 'invalid_statement_deletion.dart'),
          p.join(dir.path, 'lib', 'invalid_mixed.dart'),
        ];

        final MutationRunReport viaSubprocess = await _runnerWithGate(
          dir,
          const AnalyzerProcessGate(
            ProcessCommand('dart', <String>['analyze']),
          ),
        ).run(files);
        final MutationRunReport viaInProcess = await _runnerFor(
          dir,
        ).run(files);

        expect(viaSubprocess.aborted, isFalse);
        for (final String file in files) {
          final String name = p.basename(file);
          final FileMutationReport a = _reportFor(viaSubprocess, name);
          final FileMutationReport b = _reportFor(viaInProcess, name);
          expect(
            <int>[a.invalid, a.detected, a.undetected, a.timedOut],
            <int>[b.invalid, b.detected, b.undetected, b.timedOut],
            reason: '$name: [invalid, detected, undetected, timedOut]',
          );
          expect(
            a.invalid,
            greaterThan(0),
            reason: '$name is an invalid fixture',
          );
        }
      },
    );
  });

  group('a gate that rejects a file before it is mutated', () {
    // Stub gates, deliberately — unlike the real gates everywhere else in this
    // file. What is under test is the runner's reaction to "the gate rejects
    // a target's unmodified code", which is the runner's own policy.
    // Producing that with a real analyzer means a real version skew between an
    // analyzer package and the SDK, which would make these tests pass or fail
    // by which SDK happens to run them. Each stub wraps a real gate for every
    // file it does not reject, and records what was on disk each time it was
    // asked — which is what lets these tests see ORDER, not just outcome.

    test(
      '[decision] a file the primary rejects is judged by the fallback, and '
      'ONLY that file — the others keep the primary, every file is scored as '
      'a working gate would score it, and the fallback is announced',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final String kept = p.join(dir.path, 'lib', 'detected.dart');
        final String rejected = p.join(
          dir.path,
          'lib',
          'detected_and_undetected.dart',
        );
        final _RecordingGate primary = _RecordingGate(
          _realGate(dir),
          rejected: <String>{rejected},
        );
        final _RecordingGate fallback = _RecordingGate(_realGate(dir));
        final List<String> fellBack = <String>[];

        final MutationRunReport report = await MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: primary,
          fallbackCompileSafetyGate: fallback,
          onGateFallback: fellBack.add,
          mutantTimeout: const Duration(seconds: 10),
        ).run(<String>[kept, rejected]);

        expect(report.aborted, isFalse);
        // Scored exactly as the full-run fixture above scores them. A single
        // gate for the whole run would have sent `kept` through the fallback
        // too, or scored `rejected`'s mutants with a primary that rejects it.
        final FileMutationReport k = _reportFor(report, 'detected.dart');
        final FileMutationReport r = _reportFor(
          report,
          'detected_and_undetected.dart',
        );
        expect(<int>[k.detected, k.undetected, k.invalid], <int>[1, 0, 0]);
        expect(<int>[r.detected, r.undetected, r.invalid], <int>[1, 1, 0]);
        expect(fellBack, <String>[rejected]);
        expect(
          fallback.asked.map(((String, String) a) => a.$1).toSet(),
          <String>{rejected},
          reason: 'the fallback judges the file it was brought in for, only',
        );
        expect(
          primary.asked.where(((String, String) a) => a.$1 == rejected),
          hasLength(1),
          reason:
              'the primary is asked about the rejected file once — the '
              'unmodified check — and never about its mutants',
        );
      },
    );

    test(
      '[state] every target is put to the gate while STILL UNMODIFIED, before '
      'any file is mutated — so a rejection late in the target list aborts '
      'with nothing earlier already mutated and scored',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final String first = p.join(dir.path, 'lib', 'detected.dart');
        final String second = p.join(
          dir.path,
          'lib',
          'detected_and_undetected.dart',
        );
        final Map<String, String> original = <String, String>{
          first: File(first).readAsStringSync(),
          second: File(second).readAsStringSync(),
        };
        final _RecordingGate primary = _RecordingGate(
          _realGate(dir),
          rejected: <String>{second},
        );

        final MutationRunReport report = await MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: primary,
          mutantTimeout: const Duration(seconds: 10),
        ).run(<String>[first, second]);

        expect(report.aborted, isTrue);
        expect(report.abortKind, AbortKind.gateRejectsUnmodified);
        expect(report.abortReason, contains(second));
        // The whole point: had the check been done lazily, file by file,
        // `first`'s mutant would have been written and put to the gate before
        // `second` was ever looked at. Every content the gate saw would then
        // not all be the originals.
        for (final (String path, String content) in primary.asked) {
          expect(
            content,
            original[path],
            reason: 'the gate was shown a mutated $path before the abort',
          );
        }
        expect(File(first).readAsStringSync(), original[first]);
        expect(File(second).readAsStringSync(), original[second]);
      },
    );

    test(
      '[decision] with a fallback that rejects the file too, the run aborts '
      'the same way',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final String target = p.join(dir.path, 'lib', 'detected.dart');

        final MutationRunReport report = await MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: _RecordingGate(
            _realGate(dir),
            rejected: <String>{target},
          ),
          fallbackCompileSafetyGate: _RecordingGate(
            _realGate(dir),
            rejected: <String>{target},
          ),
          mutantTimeout: const Duration(seconds: 10),
        ).run(<String>[target]);

        expect(report.aborted, isTrue);
        expect(report.abortKind, AbortKind.gateRejectsUnmodified);
      },
    );

    test(
      '[boundary] a target with no mutants is never put to the gate, so a '
      'gate that would reject it cannot abort the run over a file with '
      'nothing to judge',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final String empty = p.join(dir.path, 'lib', 'no_mutants.dart');
        final _RecordingGate primary = _RecordingGate(
          _realGate(dir),
          rejected: <String>{empty},
        );

        final MutationRunReport report = await MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: primary,
          mutantTimeout: const Duration(seconds: 10),
        ).run(<String>[empty]);

        expect(report.aborted, isFalse);
        expect(_reportFor(report, 'no_mutants.dart').total, 0);
        expect(primary.asked, isEmpty);
      },
    );

    test(
      '[partition] a primary that accepts every file is used, and the '
      'fallback is never even asked',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final String target = p.join(dir.path, 'lib', 'detected.dart');
        final _RecordingGate fallback = _RecordingGate(_realGate(dir));

        final MutationRunReport report = await MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: _realGate(dir),
          fallbackCompileSafetyGate: fallback,
          mutantTimeout: const Duration(seconds: 10),
        ).run(<String>[target]);

        expect(report.aborted, isFalse);
        expect(fallback.asked, isEmpty);
      },
    );
  });

  group('a red baseline', () {
    test(
      '[boundary] aborts before touching any file, rather than scoring '
      'against a suite that was already failing',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        File(p.join(dir.path, 'test', 'broken_test.dart')).writeAsStringSync(
          "import 'package:test/test.dart';\n\nvoid main() { test('x', () => throw Exception('always red')); }\n",
        );
        final String detectedBefore = File(
          p.join(dir.path, 'lib', 'detected.dart'),
        ).readAsStringSync();

        final MutationRunReport report = await _runnerFor(dir).run(<String>[
          p.join(dir.path, 'lib', 'detected.dart'),
        ]);

        expect(report.aborted, isTrue);
        expect(report.abortKind, AbortKind.baselineFailed);
        expect(report.abortReason, contains('red'));
        expect(report.files, isEmpty);
        expect(
          File(p.join(dir.path, 'lib', 'detected.dart')).readAsStringSync(),
          detectedBefore,
        );
      },
    );
  });

  group('a caller-supplied operators list', () {
    test(
      '[boundary] only the given operators run — not silently falling back '
      'to the full defaultOperators() set',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));

        final MutationTestRunner runner = MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: const AnalyzerProcessGate(
            ProcessCommand('dart', <String>['analyze']),
          ),
          operators: <MutationOperator>[TernarySwap()],
          mutantTimeout: const Duration(seconds: 10),
        );

        final MutationRunReport report = await runner.run(<String>[
          p.join(dir.path, 'lib', 'custom_operators.dart'),
        ]);

        final FileMutationReport f = report.files.single;
        // defaultOperators() would also propose the two relational `<`
        // mutants on this file. Their absence — one mutant total, and it is
        // the ternary swap — is what proves the caller's list was actually
        // used rather than defaultOperators() silently winning.
        expect(f.undetected, 1);
        expect(f.undetectedMutants.single.mutant.operatorName, 'ternary_swap');
      },
    );
  });

  group('the test compilation cache', () {
    test(
      '[partition] is cleared before the baseline runs — a stale marker '
      'left over from a previous session must not survive into this run',
      () async {
        final Directory dir = await _fixturePackage();
        addTearDown(() => dir.deleteSync(recursive: true));
        final Directory cacheDir = Directory(
          p.join(dir.path, '.dart_tool', 'test'),
        );
        cacheDir.createSync(recursive: true);
        final File marker = File(p.join(cacheDir.path, 'stale_marker.txt'));
        marker.writeAsStringSync('leftover from a previous run');

        await _runnerFor(dir).run(<String>[
          p.join(dir.path, 'lib', 'no_mutants.dart'),
        ]);

        expect(
          marker.existsSync(),
          isFalse,
          reason:
              'dart test never writes a file with this name — its survival '
              'past the run means the cache was never cleared before the '
              'baseline compiled',
        );
      },
    );
  });

  group('a baseline that never finishes', () {
    test(
      '[boundary] aborts with its own reason, distinct from a baseline '
      'that finishes but fails',
      () async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'mutation_test_runner_hang_test_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: hang_fixture
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
''');
        Directory(p.join(dir.path, 'lib')).createSync();
        Directory(p.join(dir.path, 'test')).createSync();
        File(p.join(dir.path, 'lib', 'target.dart')).writeAsStringSync(
          "String classify(bool isPositive) => isPositive ? 'positive' : "
          "'negative';\n",
        );
        // Hangs unconditionally, on the very first (unmutated) run — unlike
        // hangs.dart above, which only hangs once mutated. That is the
        // distinction this test exists for: an ALREADY-hanging baseline,
        // not a mutant that induces one.
        File(p.join(dir.path, 'test', 'target_test.dart')).writeAsStringSync('''
import 'package:test/test.dart';

void main() {
  test('hangs forever', () {
    // ignore: literal_only_boolean_expressions
    while (true) {}
  });
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

        final MutationTestRunner runner = MutationTestRunner(
          testCommand: ProcessCommand('dart', <String>[
            'test',
          ], workingDirectory: dir.path),
          compileSafetyGate: const AnalyzerProcessGate(
            ProcessCommand('dart', <String>['analyze']),
          ),
          mutantTimeout: const Duration(seconds: 5),
        );

        final MutationRunReport report = await runner.run(<String>[
          p.join(dir.path, 'lib', 'target.dart'),
        ]);

        expect(report.aborted, isTrue);
        expect(report.abortKind, AbortKind.baselineTimeout);
        // Kept alongside the kind: plan-cycle 1.3.1 tells this abort apart by
        // matching these words, and will until it reads abortKind instead.
        expect(report.abortReason, contains('did not finish'));
        expect(report.abortReason, contains('within the timeout'));
        expect(report.files, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

/// A real in-process gate over [dir], closed when the current test ends.
InProcessAnalyzerGate _realGate(Directory dir) {
  final InProcessAnalyzerGate gate = InProcessAnalyzerGate(<String>[dir.path]);
  addTearDown(gate.close);
  return gate;
}

/// Rejects every file in [rejected] and defers to [inner] for the rest,
/// recording each question as (path, what was on disk at that moment).
class _RecordingGate implements CompileSafetyGate {
  _RecordingGate(this.inner, {this.rejected = const <String>{}});

  final CompileSafetyGate inner;
  final Set<String> rejected;
  final List<(String, String)> asked = <(String, String)>[];

  @override
  Future<bool> compiles(String filePath) async {
    asked.add((filePath, File(filePath).readAsStringSync()));
    if (rejected.contains(filePath)) {
      return false;
    }
    return inner.compiles(filePath);
  }

  @override
  Future<void> close() async {}
}
