import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/review/review_comments.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_verdict.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:test/test.dart';

MutantResult _survivor(int line, {bool uncovered = false}) => MutantResult(
  mutant: Mutant(
    filePath: '/repo/pkg/lib/a.dart',
    offset: 0,
    length: 1,
    line: line,
    column: 5,
    original: '>',
    replacement: '>=',
    operatorName: 'relational_operator_replacement',
    description: "'>' -> '>='",
  ),
  verdict: MutantVerdict.undetected,
  uncovered: uncovered,
);

void main() {
  test(
    '[decision] each survivor a test runs past becomes one comment at its '
    'line, with its path from the repository root; one on a line no test '
    'runs is left out',
    () {
      final MutationRunReport report = MutationRunReport.completed(
        <FileMutationReport>[
          FileMutationReport(
            filePath: '/repo/pkg/lib/a.dart',
            detected: 3,
            undetected: 2,
            invalid: 0,
            timedOut: 0,
            undetectedMutants: <MutantResult>[
              _survivor(7),
              _survivor(9, uncovered: true),
            ],
            invalidMutants: const <MutantResult>[],
            timedOutMutants: const <MutantResult>[],
          ),
        ],
      );

      expect(reviewComments(report, repoRoot: '/repo'), <Map<String, Object>>[
        <String, Object>{
          'path': 'pkg/lib/a.dart',
          'line': 7,
          'body':
              "Mutant survived: `relational_operator_replacement` — '>' -> "
              "'>='. No test failed with this change: no test checks the "
              'boundary.',
        },
      ]);
    },
  );

  test('[boundary] an aborted run comments on nothing', () {
    expect(
      reviewComments(
        const MutationRunReport.aborted(AbortKind.baselineFailed, 'red'),
        repoRoot: '/repo',
      ),
      isEmpty,
    );
  });
}
