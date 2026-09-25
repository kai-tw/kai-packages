import 'file_mutation_report.dart';
import 'run_stats.dart';

/// Why a run stopped before scoring anything — the machine-readable half of
/// an abort, next to [MutationRunReport.abortReason]'s human-readable one.
///
/// Exists because the right response to an abort depends entirely on which
/// kind it is, and the two most common kinds call for opposite actions: a
/// suite that was red needs fixing, a suite that was merely too slow for the
/// budget needs a bigger budget. A caller that told them apart by matching
/// words in the reason text broke silently the moment the text changed, so
/// the kind is its own field with fixed [wireName]s, and the reason text is
/// free to be rewritten.
enum AbortKind {
  /// The test command did not finish against unmodified code in time.
  baselineTimeout('baseline-timeout'),

  /// The test command finished against unmodified code, and failed.
  baselineFailed('baseline-failed'),

  /// The compile-safety gate — and any fallback — rejected a target file
  /// before it was mutated. The gate cannot read the file, or its own
  /// configuration rejects code that compiles, or the file does not compile
  /// and no test loads it; the run cannot tell which.
  gateRejectsUnmodified('gate-rejects-unmodified'),

  /// The run would take longer than `MutationTestRunner.maxRunTime`, which
  /// the caller set. Refused before the first mutant when the plan alone
  /// says so, and otherwise stopped as soon as the pace the run held over
  /// the mutants that did finish says so. Nothing is scored either way.
  overBudget('over-budget'),

  /// `MutationTestRunner.selectByCoverage` was asked for and cannot be
  /// honoured: the test command is one the coverage pass refuses, or the
  /// pass itself failed. Refused after the coverage pass, before the first
  /// mutant — every mutant against the full command instead would be a run
  /// the caller did not ask for, many times longer than the one they did.
  selectionUnavailable('selection-unavailable');

  const AbortKind(this.wireName);

  /// The value written to JSON. Part of the output contract: renaming one is
  /// a breaking change, adding one is not.
  final String wireName;
}

/// The outcome of one whole run: why it stopped, if it stopped before
/// scoring anything, or the per-file scores if it ran to completion.
class MutationRunReport {
  const MutationRunReport.aborted(
    this.abortKind,
    this.abortReason, {
    this.baselineDuration,
    this.mutantTimeout,
    this.stats,
  }) : files = const <FileMutationReport>[],
       selectedByCoverage = null,
       reusedMutants = null;

  const MutationRunReport.completed(
    this.files, {
    this.baselineDuration,
    this.mutantTimeout,
    this.selectedByCoverage = false,
    this.reusedMutants,
    this.stats,
  }) : abortKind = null,
       abortReason = null;

  /// How many mutants were scored from a journal instead of run, or `null`
  /// when the run kept none — see `MutationTestRunner.journalPath`.
  final int? reusedMutants;

  /// Whether each mutant ran only the test files that cover it. `false` on a
  /// completed run that did not ask for coverage selection; a run that asked
  /// and could not have it aborts instead. `null` on an aborted run.
  final bool? selectedByCoverage;

  /// How long the test command took against unmodified code, or `null` when
  /// it never finished.
  final Duration? baselineDuration;

  /// The budget a mutant running the full test command got — `null` when
  /// the run stopped before one was set. Not necessarily the
  /// `--mutant-timeout` a caller passed: see
  /// `MutationTestRunner.baselineFactor`. A mutant that ran only the tests
  /// selected for it may have had less; each result carries its own, in
  /// `MutantResult.timeout`.
  final Duration? mutantTimeout;

  /// Non-null exactly when the run never produced any scores at all — see
  /// `MutationTestRunner.run` for the pre-flight checks that can stop it. A
  /// partial run still completes normally: a mutant that could not be
  /// scored is `invalid`, not an abort.
  final AbortKind? abortKind;

  /// What happened, for a person. Not a contract — match on [abortKind].
  final String? abortReason;

  final List<FileMutationReport> files;

  /// What the run cost and where the time went, or `null` when nobody
  /// collected it.
  final RunStats? stats;

  bool get aborted => abortKind != null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (abortKind != null) 'abortKind': abortKind!.wireName,
    if (abortReason != null) 'abortReason': abortReason,
    if (baselineDuration != null)
      'baselineSeconds': _seconds(baselineDuration!),
    if (mutantTimeout != null) 'mutantTimeoutSeconds': _seconds(mutantTimeout!),
    ..._howScored(),
    'files': <String, Object?>{
      for (final FileMutationReport f in files) f.filePath: f.toJson(),
    },
    if (stats != null) 'stats': stats!.toJson(),
  };

  /// How a completed run got its scores — empty on an aborted one.
  Map<String, Object?> _howScored() => <String, Object?>{
    if (selectedByCoverage != null) 'selectedByCoverage': selectedByCoverage,
    if (reusedMutants != null) 'reusedMutants': reusedMutants,
  };

  /// Millisecond precision — finer than a wall-clock test run means anything.
  static double _seconds(Duration d) => d.inMilliseconds / 1000;
}
