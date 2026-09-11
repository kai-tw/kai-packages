import 'file_mutation_report.dart';

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
  gateRejectsUnmodified('gate-rejects-unmodified');

  const AbortKind(this.wireName);

  /// The value written to JSON. Part of the output contract: renaming one is
  /// a breaking change, adding one is not.
  final String wireName;
}

/// The outcome of one whole run: why it stopped, if it stopped before
/// scoring anything, or the per-file scores if it ran to completion.
class MutationRunReport {
  const MutationRunReport.aborted(this.abortKind, this.abortReason)
    : files = const <FileMutationReport>[];

  const MutationRunReport.completed(this.files)
    : abortKind = null,
      abortReason = null;

  /// Non-null exactly when the run never produced any scores at all — see
  /// `MutationTestRunner.run` for the pre-flight checks that can stop it. A
  /// partial run still completes normally: a mutant that could not be
  /// scored is `invalid`, not an abort.
  final AbortKind? abortKind;

  /// What happened, for a person. Not a contract — match on [abortKind].
  final String? abortReason;

  final List<FileMutationReport> files;

  bool get aborted => abortKind != null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (abortKind != null) 'abortKind': abortKind!.wireName,
    if (abortReason != null) 'abortReason': abortReason,
    'files': <String, Object?>{
      for (final FileMutationReport f in files) f.filePath: f.toJson(),
    },
  };
}
