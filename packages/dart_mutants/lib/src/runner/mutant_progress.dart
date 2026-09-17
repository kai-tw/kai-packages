import 'mutant_result.dart';
import 'run_plan.dart';

/// One mutant finished.
class MutantProgress {
  const MutantProgress({
    required this.completed,
    required this.total,
    required this.result,
    required this.elapsed,
  });

  /// How many mutants of the run have finished, this one included — 1-based.
  final int completed;

  /// [RunPlan.mutantCount].
  final int total;

  final MutantResult result;

  /// Wall time spent on this mutant: writing it, the compile-safety gate,
  /// any test runs and the restore.
  final Duration elapsed;
}
