import 'run_plan.dart';

/// How long a run may take, and when its own pace is allowed to speak for
/// what is left of it.
///
/// A run's cost cannot be known before it starts and is not worth guessing
/// at: [RunPlan.floor] is the one bound nothing can beat, and everything
/// else about the cost — how many candidates the compile-safety gate
/// rejects for free, what a selected command costs against the full one,
/// how much parallel workers really win — only exists once mutants have
/// run. So this holds both readings: the limit, and how much of the run has
/// to be over before the pace it is holding is taken as a projection.
class RunBudget {
  const RunBudget(this.limit, {this.paceAfterPerWorker = defaultPaceAfter});

  /// The longest the mutants may take. The baseline, the coverage pass and
  /// the worker sandbox check are not counted against it — they run before
  /// the first mutant, and they are what makes any estimate possible.
  final Duration limit;

  /// How many mutants each worker must finish before the pace they set is
  /// projected over the rest — see [paceAfter].
  final int paceAfterPerWorker;

  /// Small enough that a run stopped here has wasted little, large enough
  /// that a few free rejections in a row cannot read as a pace the rest of
  /// the run will hold.
  static const int defaultPaceAfter = 8;

  /// How many mutants must finish before [exceeded] answers at all. Scaled
  /// by the workers, since with n of them the first n finish at about the
  /// same time and say between them about as much as one mutant does.
  int paceAfter(int workers) => paceAfterPerWorker * workers;

  /// What the mutants still to come cost at the pace held so far: the wall
  /// time since the first mutant started, over the mutants finished in it,
  /// times the ones left. Zero before the first one finishes, and zero once
  /// the last one has — nothing is left to project.
  static Duration projectedRemaining({
    required Duration elapsed,
    required int completed,
    required int planned,
  }) {
    if (completed <= 0) {
      return Duration.zero;
    }
    return (elapsed ~/ completed) * (planned - completed);
  }

  /// Whether this run, at the pace it is holding, runs past [limit] — and
  /// `false` while too few mutants have finished for that pace to mean
  /// anything, however long they took. A projection off one cheap mutant
  /// would stop runs that fit and let runs that do not carry on, which is
  /// worse than waiting for [paceAfter] of them.
  bool exceeded({
    required Duration elapsed,
    required int completed,
    required int planned,
    required int workers,
  }) {
    if (completed < paceAfter(workers)) {
      return false;
    }
    final Duration projected =
        elapsed +
        projectedRemaining(
          elapsed: elapsed,
          completed: completed,
          planned: planned,
        );
    return projected > limit;
  }
}
