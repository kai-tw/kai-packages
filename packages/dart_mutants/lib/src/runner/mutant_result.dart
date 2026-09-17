import '../mutant.dart';
import 'mutant_verdict.dart';

/// One [Mutant] paired with what happened when it ran.
class MutantResult {
  const MutantResult({
    required this.mutant,
    required this.verdict,
    this.uncovered = false,
    this.timeout,
  });

  final Mutant mutant;
  final MutantVerdict verdict;

  /// `true` when this mutant was scored [MutantVerdict.undetected] without a
  /// test run, because coverage showed no test enters the function it sits
  /// in. Only ever set when tests are selected by coverage. Kept apart
  /// from a survivor that ran because the two call for different fixes: one
  /// needs an assertion, the other needs a test that reaches the code at all.
  final bool uncovered;

  /// How long this mutant's last test run was allowed, or `null` when no
  /// test ran — an `invalid` or `uncovered` mutant. Per mutant, because a
  /// mutant that runs only the tests reaching it gets a budget measured
  /// against those tests, not against the whole suite: see
  /// `MutationTestRunner.selectByCoverage`.
  final Duration? timeout;

  Map<String, Object?> toJson() => <String, Object?>{
    'filePath': mutant.filePath,
    'line': mutant.line,
    'column': mutant.column,
    'operatorName': mutant.operatorName,
    'description': mutant.description,
    'verdict': verdict.name,
    if (uncovered) 'uncovered': true,
    if (timeout != null) 'timeoutSeconds': timeout!.inMilliseconds / 1000,
  };
}
