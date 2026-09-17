import 'mutant_result.dart';

/// Where one mutant's time went.
///
/// Kept for every mutant, `detected` ones included, because a run's
/// statistics are there to be compared across runs: which mutants are
/// slow, which operators produce `invalid` ones, what a selection saves.
class MutantTiming {
  const MutantTiming({
    required this.result,
    required this.elapsed,
    required this.gate,
    required this.selected,
    this.measurement,
    this.test,
    this.retry,
  });

  final MutantResult result;

  /// Everything: writing the mutant, the gate, any test runs, the restore.
  final Duration elapsed;

  /// The compile-safety gate's answer.
  final Duration gate;

  /// Whether the mutant ran only the test files selected for it. `false` for
  /// one that ran the full command, and for one that ran nothing.
  final bool selected;

  /// Measuring the selection's own budget, when this mutant was the first to
  /// need it — `null` otherwise.
  final Duration? measurement;

  /// The first test run — `null` when none ran.
  final Duration? test;

  /// The full-command run asked after a selected run that ended without a
  /// verdict — `null` when there was none.
  final Duration? retry;

  /// The bucket a statistic counts this mutant under: its verdict's name, or
  /// `uncovered` for an undetected mutant no test enters.
  String get bucket => result.uncovered ? 'uncovered' : result.verdict.name;

  Map<String, Object?> toJson() => <String, Object?>{
    'filePath': result.mutant.filePath,
    'line': result.mutant.line,
    'column': result.mutant.column,
    'operatorName': result.mutant.operatorName,
    'verdict': bucket,
    'seconds': seconds(elapsed),
    'gateSeconds': seconds(gate),
    'selected': selected,
    if (measurement != null) 'measurementSeconds': seconds(measurement!),
    if (test != null) 'testSeconds': seconds(test!),
    if (retry != null) 'retrySeconds': seconds(retry!),
    if (result.timeout != null) 'timeoutSeconds': seconds(result.timeout!),
  };

  /// Millisecond precision, the same as the rest of the report.
  static double seconds(Duration d) => d.inMilliseconds / 1000;
}
