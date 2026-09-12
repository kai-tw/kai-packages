import '../mutant.dart';
import 'mutant_verdict.dart';

/// One [Mutant] paired with what happened when it ran.
class MutantResult {
  const MutantResult({
    required this.mutant,
    required this.verdict,
    this.uncovered = false,
  });

  final Mutant mutant;
  final MutantVerdict verdict;

  /// `true` when this mutant was scored [MutantVerdict.undetected] without a
  /// test run, because coverage showed no test enters the function it sits
  /// in. Only ever set when tests are selected by coverage. Kept apart
  /// from a survivor that ran because the two call for different fixes: one
  /// needs an assertion, the other needs a test that reaches the code at all.
  final bool uncovered;

  Map<String, Object?> toJson() => <String, Object?>{
    'filePath': mutant.filePath,
    'line': mutant.line,
    'column': mutant.column,
    'operatorName': mutant.operatorName,
    'description': mutant.description,
    'verdict': verdict.name,
    if (uncovered) 'uncovered': true,
  };
}
