import 'mutant_progress.dart';
import 'mutant_result.dart';

/// What a run is about to do, reported once, after the baseline and the
/// gate checks and before the first mutant runs.
///
/// A run over many files can take hours, and nothing else says how many
/// mutants it holds until the report arrives at the end. How long it will
/// take is left to the progress lines, which measure it: a mutant costs one
/// run of each test file it reaches, and only the run itself knows how many
/// files that is and how fast they are.
class RunPlan {
  const RunPlan({
    required this.fileCount,
    required this.mutantCount,
    required this.baseline,
    required this.budget,
    required this.workers,
    this.reused = 0,
    this.baselineReused = false,
    this.coverageReused = false,
  });

  /// Target files, after generated files are dropped.
  final int fileCount;

  /// Every mutant the run will run, `invalid` ones included — the `total`
  /// a [MutantProgress] counts towards. Not the [reused] ones.
  final int mutantCount;

  /// Mutants whose result a journal already holds, scored without running
  /// — see `MutationTestRunner.journalPath`.
  final int reused;

  /// Whether [baseline] was read from a journal instead of run.
  final bool baselineReused;

  /// Whether the coverage map was read from a journal instead of collected.
  final bool coverageReused;

  /// The full test command's wall time against unmodified code.
  final Duration baseline;

  /// The least budget a mutant gets on one test file; a slower file gets
  /// more — see [MutantResult.timeout].
  final Duration budget;

  /// How many lanes run mutants at once — `MutationTestRunner.workers`.
  final int workers;
}
