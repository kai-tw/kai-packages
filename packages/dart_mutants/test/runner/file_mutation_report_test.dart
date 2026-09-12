import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_verdict.dart';
import 'package:test/test.dart';

Mutant _mutant(int line) => Mutant(
  filePath: 'lib/src/foo.dart',
  offset: 10,
  length: 1,
  line: line,
  column: 1,
  original: 'true',
  replacement: 'false',
  operatorName: 'condition_negation',
  description: 'true -> false',
);

void main() {
  test(
    '[partition] total is detected + undetected — invalid and timedOut are '
    'deliberately not folded in',
    () {
      const FileMutationReport report = FileMutationReport(
        filePath: 'lib/src/foo.dart',
        detected: 3,
        undetected: 2,
        invalid: 10,
        timedOut: 5,
        undetectedMutants: <MutantResult>[],
        invalidMutants: <MutantResult>[],
        timedOutMutants: <MutantResult>[],
      );

      expect(report.total, 5);
    },
  );

  group('detectionRate', () {
    test('[boundary] is null when total is 0 — 0/0 is not 1.0', () {
      const FileMutationReport report = FileMutationReport(
        filePath: 'lib/src/foo.dart',
        detected: 0,
        undetected: 0,
        invalid: 4,
        timedOut: 0,
        undetectedMutants: <MutantResult>[],
        invalidMutants: <MutantResult>[],
        timedOutMutants: <MutantResult>[],
      );

      expect(report.detectionRate, isNull);
    });

    test('[partition] is detected / total when there is at least one', () {
      const FileMutationReport report = FileMutationReport(
        filePath: 'lib/src/foo.dart',
        detected: 3,
        undetected: 1,
        invalid: 0,
        timedOut: 0,
        undetectedMutants: <MutantResult>[],
        invalidMutants: <MutantResult>[],
        timedOutMutants: <MutantResult>[],
      );

      expect(report.detectionRate, 0.75);
    });
  });

  test(
    '[partition] toJson carries total plus every count, and all three '
    'mutant lists rendered as their own JSON, not the raw objects',
    () {
      final MutantResult undetected = MutantResult(
        mutant: _mutant(7),
        verdict: MutantVerdict.undetected,
      );
      final MutantResult invalid = MutantResult(
        mutant: _mutant(8),
        verdict: MutantVerdict.invalid,
      );
      final MutantResult timedOut = MutantResult(
        mutant: _mutant(9),
        verdict: MutantVerdict.timeout,
      );
      final FileMutationReport report = FileMutationReport(
        filePath: 'lib/src/foo.dart',
        detected: 1,
        undetected: 1,
        invalid: 2,
        timedOut: 1,
        undetectedMutants: <MutantResult>[undetected],
        invalidMutants: <MutantResult>[invalid],
        timedOutMutants: <MutantResult>[timedOut],
      );

      expect(report.toJson(), <String, Object?>{
        'filePath': 'lib/src/foo.dart',
        'total': 2,
        'detected': 1,
        'undetected': 1,
        'uncovered': 0,
        'invalid': 2,
        'timedOut': 1,
        'undetectedMutants': <Object?>[undetected.toJson()],
        'invalidMutants': <Object?>[invalid.toJson()],
        'timedOutMutants': <Object?>[timedOut.toJson()],
      });
    },
  );

  test(
    '[partition] uncovered counts the survivors no test executed, and only '
    'those — they stay inside undetected, and the score is unchanged',
    () {
      final FileMutationReport report = FileMutationReport(
        filePath: 'lib/src/foo.dart',
        detected: 1,
        undetected: 3,
        invalid: 0,
        timedOut: 0,
        undetectedMutants: <MutantResult>[
          MutantResult(mutant: _mutant(1), verdict: MutantVerdict.undetected),
          MutantResult(
            mutant: _mutant(2),
            verdict: MutantVerdict.undetected,
            uncovered: true,
          ),
          MutantResult(
            mutant: _mutant(3),
            verdict: MutantVerdict.undetected,
            uncovered: true,
          ),
        ],
        invalidMutants: <MutantResult>[],
        timedOutMutants: <MutantResult>[],
      );

      expect(report.uncovered, 2);
      expect(report.total, 4);
      expect(report.detectionRate, 0.25);
      expect(report.toJson()['uncovered'], 2);
    },
  );
}
