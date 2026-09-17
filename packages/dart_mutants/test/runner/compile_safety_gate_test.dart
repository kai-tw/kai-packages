import 'dart:io';

import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Both gates run against real analyzers, not mocks — the subprocess one
/// against a real `dart analyze`, whose exit codes (0 clean, 2 warnings-only,
/// 3 has an error) are empirically confirmed rather than assumed from
/// documentation, and the in-process one against a real
/// `AnalysisContextCollection`. Getting this classification wrong is the
/// single most dangerous failure mode this whole package has (see the
/// interface doc on [CompileSafetyGate]).
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('compile_safety_gate_test_');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  /// The contract both implementations share, run once per implementation so
  /// the two cannot drift apart on the cases that decide a score.
  final Map<String, CompileSafetyGate Function()> gates =
      <String, CompileSafetyGate Function()>{
        'AnalyzerProcessGate': () => const AnalyzerProcessGate(
          ProcessCommand('dart', <String>['analyze']),
        ),
        'InProcessAnalyzerGate': () =>
            InProcessAnalyzerGate(<String>[tempDir.path]),
      };

  for (final MapEntry<String, CompileSafetyGate Function()> entry
      in gates.entries) {
    group(entry.key, () {
      late CompileSafetyGate gate;

      setUp(() => gate = entry.value());
      tearDown(() => gate.close());

      test('[partition] a clean file compiles', () async {
        final File file = File(p.join(tempDir.path, 'clean.dart'))
          ..writeAsStringSync('int f() => 1;\n');
        expect(await gate.compiles(file.path), isTrue);
      });

      test(
        '[boundary] a file with only a warning still counts as compiling',
        () async {
          // An unused import is a warning, not an error — the file still runs.
          final File file = File(p.join(tempDir.path, 'warn.dart'))
            ..writeAsStringSync("import 'dart:math';\n\nint f() => 1;\n");
          expect(await gate.compiles(file.path), isTrue);
        },
      );

      test(
        '[error] a file that does not exist does not compile — fail closed',
        () async {
          // Not reachable through the runner today: it reads every target's
          // source before putting it to a gate, so a missing target throws
          // there first. Pinned anyway, for any direct use of a gate and for
          // the day that read moves — the analyzer resolves a missing file as
          // an EMPTY one, which has no errors, and the in-process gate read
          // it as compiling until this was checked.
          expect(
            await gate.compiles(p.join(tempDir.path, 'missing.dart')),
            isFalse,
          );
        },
      );

      test('[partition] a genuine type error does not compile', () async {
        final File file = File(p.join(tempDir.path, 'broken.dart'))
          ..writeAsStringSync('int f() => "not an int";\n');
        expect(await gate.compiles(file.path), isFalse);
      });

      test(
        '[boundary] a file with both a warning and an error is rejected — the '
        'error dominates, not "any diagnostic at all"',
        () async {
          final File file = File(p.join(tempDir.path, 'both.dart'))
            ..writeAsStringSync(
              "import 'dart:math';\n\nint f() => \"not an int\";\n",
            );
          expect(await gate.compiles(file.path), isFalse);
        },
      );
    });
  }

  group('InProcessAnalyzerGate', () {
    late InProcessAnalyzerGate gate;

    setUp(() => gate = InProcessAnalyzerGate(<String>[tempDir.path]));
    tearDown(() => gate.close());

    test(
      '[state] the same file rewritten over and over is judged on what is on '
      'disk NOW, not on what the analyzer read last',
      () async {
        // The one way a long-lived analyzer can go wrong and a fresh process
        // cannot: answering from a cached earlier read. This is exactly the
        // runner's inner loop — one file, rewritten to a new mutant, judged,
        // restored, rewritten again — so alternating valid and invalid
        // content catches a stale answer as a verdict one step behind, which
        // a run of all-valid or all-invalid rewrites never would.
        final File file = File(p.join(tempDir.path, 'target.dart'));
        const String valid = 'int f(int a, int b) => a < b ? -1 : 0;\n';
        const String invalid = 'int f(int a, int b) {\n  ;\n}\n';

        for (int round = 0; round < 3; round++) {
          file.writeAsStringSync(valid);
          expect(
            await gate.compiles(file.path),
            isTrue,
            reason: 'round $round, valid',
          );
          file.writeAsStringSync(invalid);
          expect(
            await gate.compiles(file.path),
            isFalse,
            reason: 'round $round, invalid',
          );
        }
      },
    );

    test(
      '[state] a file judged after another is resolved against what is on '
      'disk for BOTH, not against the other file as the analyzer last saw it',
      () async {
        // The runner mutates a.dart, asks, restores it — then moves on to
        // b.dart, which imports it. The restore happens behind the
        // analyzer's back exactly as the mutation did. The type of `limit`
        // is inferred, so a mutant on its initializer changes what b.dart
        // sees: `?? 10` gone makes it `int?`, and `limit + 1` stops
        // compiling. Measured through the real CLI before this was fixed:
        // b.dart's one valid mutant read `invalid`.
        final File a = File(p.join(tempDir.path, 'a.dart'));
        final File b = File(p.join(tempDir.path, 'b.dart'))
          ..writeAsStringSync("import 'a.dart';\n\nint g() => limit + 1;\n");
        const String original =
            'int? maybe() => null;\n'
            'final limit = maybe() ?? 10;\n';

        a.writeAsStringSync('int? maybe() => null;\nfinal limit = maybe();\n');
        expect(await gate.compiles(a.path), isTrue, reason: 'a alone compiles');
        a.writeAsStringSync(original);

        expect(
          await gate.compiles(b.path),
          isTrue,
          reason: 'b.dart against the restored a.dart compiles',
        );
      },
    );

    test(
      '[decision] a lint the project promotes to an error does NOT make the '
      'file invalid — it still compiles, so it is still measurable',
      () async {
        // One of two differences from AnalyzerProcessGate, pinned here
        // in both directions so it cannot drift silently: the subprocess gate
        // honours the promotion and rejects the file, the in-process gate
        // judges each diagnostic on its own severity and does not.
        File(
          p.join(tempDir.path, 'analysis_options.yaml'),
        ).writeAsStringSync('analyzer:\n  errors:\n    unused_import: error\n');
        final File file = File(p.join(tempDir.path, 'promoted.dart'))
          ..writeAsStringSync("import 'dart:math';\n\nint f() => 1;\n");

        expect(await gate.compiles(file.path), isTrue);
        expect(
          await const AnalyzerProcessGate(
            ProcessCommand('dart', <String>['analyze']),
          ).compiles(file.path),
          isFalse,
          reason:
              'if `dart analyze` stopped honouring the promotion, this test '
              'is no longer describing a real difference between the gates',
        );
      },
    );

    test(
      '[decision] a real compile error the project DOWNGRADES still makes the '
      'file invalid here — the subprocess gate is the one that gets this '
      'wrong',
      () async {
        // The second difference between the gates, and the opposite way
        // round from the promoted lint above. Downgrading an error in
        // `analysis_options.yaml` changes what the analyzer reports, not what
        // the compiler accepts: this file does not compile. `dart analyze`
        // then exits with warnings only, which the subprocess gate accepts as
        // compiling — so it hands a broken mutant to the test command, whose
        // non-zero exit reads as `detected`.
        File(
          p.join(tempDir.path, 'analysis_options.yaml'),
        ).writeAsStringSync(
          'analyzer:\n  errors:\n    return_of_invalid_type: warning\n',
        );
        final File file = File(p.join(tempDir.path, 'downgraded.dart'))
          ..writeAsStringSync("int f() => 'not an int';\n");

        expect(await gate.compiles(file.path), isFalse);
        expect(
          await const AnalyzerProcessGate(
            ProcessCommand('dart', <String>['analyze']),
          ).compiles(file.path),
          isTrue,
          reason:
              'if `dart analyze` stopped honouring the downgrade, this test is '
              'no longer describing a real difference between the gates',
        );
      },
    );

    test(
      '[partition] a relative path is resolved the same as an absolute one',
      () async {
        // The CLI hands over paths exactly as the caller typed them, and the
        // analyzer only accepts absolute, normalised ones.
        File(
          p.join(tempDir.path, 'relative.dart'),
        ).writeAsStringSync('int f() => "not an int";\n');
        final String original = Directory.current.path;
        addTearDown(() => Directory.current = original);
        Directory.current = tempDir.path;

        final InProcessAnalyzerGate relativeGate = InProcessAnalyzerGate(
          <String>['relative.dart'],
        );
        addTearDown(relativeGate.close);

        expect(
          await relativeGate.compiles(p.join('.', 'relative.dart')),
          isFalse,
        );
      },
    );

    test(
      '[error] a file outside the included paths is a caller bug and throws, '
      'rather than quietly reading every mutant as invalid',
      () async {
        // Failing closed here would be the wrong kind of safe: every mutant
        // of the file would score `invalid`, the file would read n/a, and a
        // wiring mistake would pass for a file with nothing to measure.
        final Directory elsewhere = Directory.systemTemp.createTempSync(
          'compile_safety_gate_outside_',
        );
        addTearDown(() => elsewhere.deleteSync(recursive: true));
        final File outside = File(p.join(elsewhere.path, 'outside.dart'))
          ..writeAsStringSync('int f() => 1;\n');

        await expectLater(gate.compiles(outside.path), throwsStateError);
      },
    );

    test(
      '[boundary] close is safe before any file was analysed, and twice',
      () async {
        await gate.close();
        await gate.close();
      },
    );
  });

  group('InProcessAnalyzerGate, judging content in memory', () {
    late InProcessAnalyzerGate gate;
    late File callee;
    late File caller;

    setUp(() {
      gate = InProcessAnalyzerGate(<String>[tempDir.path]);
      callee = File(p.join(tempDir.path, 'callee.dart'))
        ..writeAsStringSync('int limit() => 10;\n');
      caller = File(p.join(tempDir.path, 'caller.dart'))
        ..writeAsStringSync("import 'callee.dart';\n\nint f() => limit();\n");
    });
    tearDown(() => gate.close());

    test('[partition] content that compiles, and content that does not, '
        'judged without the file changing', () async {
      expect(
        await gate.compilesSource(callee.path, 'int limit() => 3;\n'),
        isTrue,
      );
      expect(
        await gate.compilesSource(callee.path, "int limit() => 'ten';\n"),
        isFalse,
      );
      expect(callee.readAsStringSync(), 'int limit() => 10;\n');
    });

    test('[state] once answered, the content is gone: the file, and one that '
        'imports it, are judged from disk again', () async {
      expect(
        await gate.compilesSource(callee.path, 'String other() => "";\n'),
        isTrue,
      );
      // With the content above still laid over the file, `limit` would not
      // exist and the caller would not compile.
      expect(await gate.compiles(caller.path), isTrue);
      expect(await gate.compiles(callee.path), isTrue);
    });

    test('[state] questions asked at once are answered one at a time, each '
        'against its own content only', () async {
      final List<bool> answers = await Future.wait(<Future<bool>>[
        gate.compilesSource(callee.path, 'String other() => "";\n'),
        gate.compiles(caller.path),
        gate.compilesSource(caller.path, 'int f() => missing();\n'),
        gate.compiles(caller.path),
      ]);

      expect(answers, <bool>[true, true, false, true]);
    });
  });
}
