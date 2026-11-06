import 'package:path/path.dart' as p;

import '../runner/file_mutation_report.dart';
import '../runner/mutant_result.dart';
import '../runner/mutation_run_report.dart';
import '../runner/worker_sandbox.dart';

/// One review comment per survivor a test runs past without failing: the
/// list `--review` writes, as `{path, line, body}` with [path] relative to
/// [repoRoot], ready to post on a pull request at that line.
///
/// A survivor on a line no test executes is left out. That is line
/// coverage's finding, and a comment asking for an assertion on code no test
/// runs asks for the wrong thing. Timed-out and invalid mutants are left out
/// too: neither says anything about what the tests assert.
List<Map<String, Object>> reviewComments(
  MutationRunReport report, {
  required String repoRoot,
}) {
  final String repo = realPath(repoRoot);
  return <Map<String, Object>>[
    for (final FileMutationReport file in report.files)
      for (final MutantResult result in file.undetectedMutants)
        if (!result.uncovered)
          <String, Object>{
            'path': p.posix.joinAll(
              p.split(p.relative(realPath(result.mutant.filePath), from: repo)),
            ),
            'line': result.mutant.line,
            'body': reviewBody(result),
          },
  ];
}

/// What a review comment on [result] says: the mutant, and what the missing
/// test would have to check.
String reviewBody(MutantResult result) {
  final String hint =
      _hints[result.mutant.operatorName] ?? 'no test asserts this behaviour';
  return 'Mutant survived: `${result.mutant.operatorName}` — '
      '${result.mutant.description}. No test failed with this change: $hint.';
}

const Map<String, String> _hints = <String, String>{
  'statement_deletion': 'nothing asserts these lines ran',
  'condition_negation': 'no test checks which way the condition goes',
  'relational_operator_replacement': 'no test checks the boundary',
  'logical_operator_replacement': 'no test checks which operand decides',
  'arithmetic_operator_replacement': 'the arithmetic result is unasserted',
  'ternary_swap': 'no test checks which branch is taken',
  'switch_expression_arm_swap':
      'no test checks which case maps to which result',
  'null_coalescing_deletion': 'no test checks the fallback',
};
