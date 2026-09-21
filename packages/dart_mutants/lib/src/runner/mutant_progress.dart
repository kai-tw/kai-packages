import 'mutant_result.dart';
import 'run_plan.dart';

/// One mutant finished.
class MutantProgress {
  const MutantProgress({
    required this.completed,
    required this.total,
    required this.result,
    required this.elapsed,
    required this.projectedRemaining,
  });

  /// How many mutants of the run have finished, this one included — 1-based.
  final int completed;

  /// [RunPlan.mutantCount].
  final int total;

  final MutantResult result;

  /// Wall time spent on this mutant: writing it, the compile-safety gate,
  /// any test runs and the restore.
  final Duration elapsed;

  /// How long the mutants still to come would take at the pace this run has
  /// held so far — the wall time since the first mutant started, divided
  /// over the mutants finished in it, times the ones left.
  ///
  /// Measured rather than assumed, so it already carries whatever
  /// [RunPlan.estimate] could only guess at: how much parallel workers
  /// actually win, what a selected command costs against the full one, and
  /// how many candidates the compile-safety gate rejects for free. It moves
  /// while the run does — an early stretch of rejected mutants reads fast,
  /// and a file whose tests are slow reads slow.
  final Duration projectedRemaining;
}
