import 'mutant_progress.dart';
import 'mutant_result.dart';

/// What a run is about to do, reported once, after the baseline and the
/// gate checks and before the first mutant runs.
///
/// A run over many files can take hours, and nothing else says how many
/// mutants it holds until the report arrives at the end.
class RunPlan {
  const RunPlan({
    required this.fileCount,
    required this.mutantCount,
    required this.baseline,
    required this.budget,
    required this.workers,
  });

  /// Target files, after generated files are dropped.
  final int fileCount;

  /// Every mutant the run will score, `invalid` ones included — the `total`
  /// a [MutantProgress] counts towards.
  final int mutantCount;

  /// The full test command's wall time against unmodified code.
  final Duration baseline;

  /// The full test command's budget per mutant. A mutant that runs only the
  /// tests reaching it may get less: see [MutantResult.timeout].
  final Duration budget;

  /// How many mutants run at once — `MutationTestRunner.workers`, after any
  /// fallback to one.
  final int workers;

  /// What the run would cost at one worker's baseline pace: one baseline per
  /// mutant. The only estimate available before a mutant has run, and an
  /// upper bound on three counts — a mutant the compile-safety gate rejects
  /// runs no test at all, `--select-by-coverage` runs fewer tests than the
  /// baseline did, and [workers] run at once. What it costs to be wrong is
  /// only a number on screen; [MutantProgress.projectedRemaining] replaces
  /// it with measured pace as soon as the first mutants finish.
  Duration get estimate => baseline * mutantCount;

  /// [estimate] at its most optimistic: every worker busy for the whole run,
  /// nothing rejected and no selection. Nothing can beat this, so a run
  /// whose lower bound is already too long is too long — which is what
  /// `MutationTestRunner.maxRunTime` refuses on, before anything is mutated.
  Duration get floor => estimate ~/ workers;
}
