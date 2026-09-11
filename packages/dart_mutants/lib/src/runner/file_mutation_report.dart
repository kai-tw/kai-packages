import 'mutant_result.dart';

/// One file's mutants, scored.
///
/// [total] is [detected] + [undetected] — [invalid] and [timedOut] are
/// deliberately not folded in. Neither was a real question about this
/// file's tests, so counting either either way would move the score without
/// the tests having done anything to earn or lose it. They still matter as
/// a signal of their own, separate from the score: a file where most
/// candidates ended up `invalid` has a hollow-looking 100% the same way a
/// file with only one real mutant does — a policy layer comparing
/// `invalid`/`timedOut` against `total` is how that gets caught, which is
/// exactly why both stay in this report instead of being summed away.
///
/// **That comparison tells a caller THAT something was excluded from the
/// score, never WHICH.** A count alone is not something a caller — or an
/// agent reading the report — can act on: it cannot say which line produced
/// it, whether it is the same mutant every run, or point at anything to go
/// and look at. So both [invalidMutants] and [timedOutMutants] carry their
/// identities, not just their counts.
///
/// This used to be asymmetric on the theory that an invalid mutant, unlike a
/// timed-out one, is not legal code and never needed measuring, so there was
/// supposedly nothing to go and look at. That confused two different
/// questions: whether an invalid mutant should move the score (a scoring
/// question — still no; [total] stays unchanged) and whether its identity is
/// worth keeping (a reporting question — yes, for the same reason it is yes
/// for a timeout). A count of 27 cannot tell a caller a handful of unrelated
/// one-offs from one operator consistently misfiring against a single
/// construct in one file, and cannot point at a single line to check without
/// spending a whole extra mutation run to reverse-engineer which ones they
/// were.
class FileMutationReport {
  const FileMutationReport({
    required this.filePath,
    required this.detected,
    required this.undetected,
    required this.invalid,
    required this.timedOut,
    required this.undetectedMutants,
    required this.invalidMutants,
    required this.timedOutMutants,
  });

  final String filePath;
  final int detected;
  final int undetected;
  final int invalid;
  final int timedOut;

  /// The actual survivors, not just their count — a policy layer deciding
  /// pass/fail per file needs to show a person which ones, so they can write
  /// down why each is acceptable (an equivalent mutant, say) or fix the gap.
  final List<MutantResult> undetectedMutants;

  /// The mutants the compile-safety gate rejected, not just how many.
  ///
  /// An invalid mutant is not legal code, so — unlike [timedOutMutants] —
  /// none of these went unmeasured in the sense of missing a real question
  /// about the file's tests; [total] does not and should not count them.
  /// But a bare count is still not something a caller can act on: it cannot
  /// tell a handful of unrelated one-offs from one operator consistently
  /// producing uncompilable mutants against a particular construct, and it
  /// gives nobody a line to go check.
  ///
  /// Measured: a report reading `invalid: 27` with no per-file breakdown left
  /// a caller unable to name a single one of them without spending a whole
  /// extra mutation run just to reverse-engineer which lines they were.
  final List<MutantResult> invalidMutants;

  /// The mutants that ran out of time, not just how many.
  ///
  /// A timed-out mutant is **real code that went unmeasured**, which is the
  /// difference between it and an `invalid` one — an invalid mutant is not
  /// legal code and never needed measuring. So this is the gap a caller can
  /// actually act on, and a count alone does not let them: it says something
  /// went unmeasured without saying what, so nobody can look at it, and across
  /// runs nobody can see it is the same one every time.
  ///
  /// Measured: a file carried a mutant that timed out on **every** round, was
  /// therefore never scored once, and stayed invisible behind a number that no
  /// caller reads per-mutant. The class doc above used to claim that comparing
  /// `timedOut` against `total` is how that gets caught; that is only half
  /// true, and this list is the other half.
  final List<MutantResult> timedOutMutants;

  int get total => detected + undetected;

  /// How many of [undetectedMutants] no test executed at all — see
  /// [MutantResult.uncovered]. Always 0 unless tests are selected by
  /// coverage.
  int get uncovered =>
      undetectedMutants.where((MutantResult r) => r.uncovered).length;

  /// `null` when [total] is 0 — a file with no mutants at all has no rate to
  /// report, and `0/0` is not `1.0`.
  double? get detectionRate => total == 0 ? null : detected / total;

  Map<String, Object?> toJson() => <String, Object?>{
    'filePath': filePath,
    'total': total,
    'detected': detected,
    'undetected': undetected,
    'uncovered': uncovered,
    'invalid': invalid,
    'timedOut': timedOut,
    'undetectedMutants': undetectedMutants
        .map((MutantResult r) => r.toJson())
        .toList(),
    'invalidMutants': invalidMutants
        .map((MutantResult r) => r.toJson())
        .toList(),
    'timedOutMutants': timedOutMutants
        .map((MutantResult r) => r.toJson())
        .toList(),
  };
}
