import 'mutant_result.dart';

/// Where one mutant's time went, for [RunStats](run_stats.dart).
class MutantTiming {
  const MutantTiming({
    required this.result,
    required this.elapsed,
    this.worker = 0,
    required this.gate,
    required this.selected,
    this.test,
  });

  final MutantResult result;

  /// The lane that ran it; 0 for one that never ran a test.
  final int worker;

  /// Its gate check plus its own test runs.
  final Duration elapsed;

  final Duration gate;

  /// Whether its test files were selected — see
  /// `MutationTestRunner.selectByCoverage`.
  final bool selected;

  /// Its own test runs, summed; `null` when it ran none.
  final Duration? test;

  String get bucket => result.uncovered ? 'uncovered' : result.verdict.name;

  Map<String, Object?> toJson() => <String, Object?>{
    'filePath': result.mutant.filePath,
    'line': result.mutant.line,
    'column': result.mutant.column,
    'operatorName': result.mutant.operatorName,
    'verdict': bucket,
    'worker': worker,
    'seconds': seconds(elapsed),
    'gateSeconds': seconds(gate),
    'selected': selected,
    if (test != null) 'testSeconds': seconds(test!),
    if (result.timeout != null) 'timeoutSeconds': seconds(result.timeout!),
  };

  static double seconds(Duration d) => d.inMilliseconds / 1000;
}
