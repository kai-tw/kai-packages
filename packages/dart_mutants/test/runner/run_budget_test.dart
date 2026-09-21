import 'package:dart_mutants/src/runner/run_budget.dart';
import 'package:test/test.dart';

void main() {
  group('projectedRemaining', () {
    test(
      '[partition] the pace so far, over the mutants still to come',
      () {
        expect(
          RunBudget.projectedRemaining(
            elapsed: const Duration(seconds: 40),
            completed: 4,
            planned: 10,
          ),
          const Duration(seconds: 60),
        );
      },
    );

    test(
      '[boundary] nothing has finished, so there is no pace to project '
      'from — zero, not a division by zero',
      () {
        expect(
          RunBudget.projectedRemaining(
            elapsed: const Duration(seconds: 3),
            completed: 0,
            planned: 10,
          ),
          Duration.zero,
        );
      },
    );

    test(
      '[boundary] the last mutant has nothing left to project — a `0s left` '
      'beside a finished run reads as one still going',
      () {
        expect(
          RunBudget.projectedRemaining(
            elapsed: const Duration(seconds: 40),
            completed: 10,
            planned: 10,
          ),
          Duration.zero,
        );
      },
    );
  });

  group('exceeded', () {
    const RunBudget budget = RunBudget(
      Duration(seconds: 100),
      paceAfterPerWorker: 4,
    );

    test(
      '[decision] a pace that runs past the limit stops the run',
      () {
        // 4 of 10 in 60s: 90s more to come, 150s in all.
        expect(
          budget.exceeded(
            elapsed: const Duration(seconds: 60),
            completed: 4,
            planned: 10,
            workers: 1,
          ),
          isTrue,
        );
      },
    );

    test(
      '[decision] a pace that fits carries on',
      () {
        // 4 of 10 in 20s: 30s more, 50s in all.
        expect(
          budget.exceeded(
            elapsed: const Duration(seconds: 20),
            completed: 4,
            planned: 10,
            workers: 1,
          ),
          isFalse,
        );
      },
    );

    test(
      '[boundary] a run projected to land exactly on the limit is not over '
      'it — the limit is what is allowed, not what is refused',
      () {
        expect(
          budget.exceeded(
            elapsed: const Duration(seconds: 40),
            completed: 4,
            planned: 10,
            workers: 1,
          ),
          isFalse,
        );
      },
    );

    test(
      '[boundary] one mutant short of the threshold says nothing, however '
      'long it took — a projection off too few is worse than waiting',
      () {
        expect(
          budget.exceeded(
            elapsed: const Duration(hours: 1),
            completed: 3,
            planned: 10,
            workers: 1,
          ),
          isFalse,
        );
      },
    );

    test(
      '[decision] the threshold is per worker: with two, the same four '
      'finished mutants are not yet a pace',
      () {
        expect(
          budget.exceeded(
            elapsed: const Duration(seconds: 60),
            completed: 4,
            planned: 10,
            workers: 2,
          ),
          isFalse,
        );
        expect(budget.paceAfter(2), 8);
      },
    );

    test(
      '[state] the shipped threshold is eight mutants per worker',
      () {
        expect(
          const RunBudget(Duration(seconds: 1)).paceAfter(1),
          RunBudget.defaultPaceAfter,
        );
        expect(RunBudget.defaultPaceAfter, 8);
      },
    );
  });
}
