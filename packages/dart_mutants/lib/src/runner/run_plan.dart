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
}
