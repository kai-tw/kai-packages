import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:test/test.dart';

FileMutationReport _report(String filePath) => FileMutationReport(
  filePath: filePath,
  detected: 1,
  undetected: 0,
  invalid: 0,
  timedOut: 0,
  undetectedMutants: const <MutantResult>[],
  invalidMutants: const <MutantResult>[],
  timedOutMutants: const <MutantResult>[],
);

void main() {
  group('.aborted', () {
    test(
      '[partition] carries the kind and the reason, and files is empty — an '
      'aborted run never scored anything',
      () {
        const MutationRunReport report = MutationRunReport.aborted(
          AbortKind.baselineFailed,
          'the test command failed against unmodified code',
        );

        expect(report.aborted, isTrue);
        expect(report.abortKind, AbortKind.baselineFailed);
        expect(
          report.abortReason,
          'the test command failed against unmodified code',
        );
        expect(report.files, isEmpty);
      },
    );

    test(
      '[boundary] toJson includes abortKind, abortReason and an empty files '
      'map',
      () {
        const MutationRunReport report = MutationRunReport.aborted(
          AbortKind.baselineTimeout,
          'slow',
        );

        expect(report.toJson(), <String, Object?>{
          'abortKind': 'baseline-timeout',
          'abortReason': 'slow',
          'files': <String, Object?>{},
        });
      },
    );

    test(
      '[boundary] every kind has its own wire name, and the names are the '
      'ones callers match on — renaming one is a breaking change',
      () {
        // Pinned verbatim, not derived: the whole point of the field is a
        // value a caller can depend on while the reason text changes freely.
        expect(
          <String, String>{
            for (final AbortKind k in AbortKind.values) k.name: k.wireName,
          },
          <String, String>{
            'baselineTimeout': 'baseline-timeout',
            'baselineFailed': 'baseline-failed',
            'gateRejectsUnmodified': 'gate-rejects-unmodified',
            'overBudget': 'over-budget',
            'selectionUnavailable': 'selection-unavailable',
          },
        );
      },
    );
  });

  group('.completed', () {
    test(
      '[partition] aborted is false and abortKind / abortReason are null',
      () {
        final MutationRunReport report = MutationRunReport.completed(
          <FileMutationReport>[_report('lib/src/foo.dart')],
        );

        expect(report.aborted, isFalse);
        expect(report.abortKind, isNull);
        expect(report.abortReason, isNull);
        expect(report.files, hasLength(1));
      },
    );

    test(
      '[boundary] toJson omits the abortKind and abortReason keys entirely — '
      'not just null — and keys files by their own filePath',
      () {
        final MutationRunReport report = MutationRunReport.completed(
          <FileMutationReport>[_report('lib/src/foo.dart')],
        );

        final Map<String, Object?> json = report.toJson();
        expect(json.containsKey('abortKind'), isFalse);
        expect(json.containsKey('abortReason'), isFalse);
        expect(
          (json['files']! as Map<String, Object?>).keys,
          <String>['lib/src/foo.dart'],
        );
      },
    );
  });

  group('selectedByCoverage', () {
    test(
      '[partition] a completed run always says whether tests were selected, '
      'false included',
      () {
        expect(
          const MutationRunReport.completed(
            <FileMutationReport>[],
          ).toJson()['selectedByCoverage'],
          isFalse,
        );
        expect(
          const MutationRunReport.completed(
            <FileMutationReport>[],
            selectedByCoverage: true,
          ).toJson()['selectedByCoverage'],
          isTrue,
        );
      },
    );

    test(
      '[boundary] an aborted run omits it — nothing was selected or run',
      () {
        expect(
          const MutationRunReport.aborted(
            AbortKind.baselineFailed,
            'red',
          ).toJson().containsKey('selectedByCoverage'),
          isFalse,
        );
      },
    );
  });

  group('the baseline and the budget', () {
    test(
      '[partition] toJson reports both in seconds, to the millisecond',
      () {
        final MutationRunReport report = MutationRunReport.completed(
          <FileMutationReport>[_report('lib/src/foo.dart')],
          baselineDuration: const Duration(milliseconds: 7250),
          mutantTimeout: const Duration(milliseconds: 29001),
        );

        final Map<String, Object?> json = report.toJson();
        expect(json['baselineSeconds'], 7.25);
        expect(json['mutantTimeoutSeconds'], 29.001);
      },
    );

    test(
      '[boundary] a baseline that never finished has no duration to report, '
      'and the keys are omitted rather than null',
      () {
        const MutationRunReport report = MutationRunReport.aborted(
          AbortKind.baselineTimeout,
          'slow',
        );

        final Map<String, Object?> json = report.toJson();
        expect(json.containsKey('baselineSeconds'), isFalse);
        expect(json.containsKey('mutantTimeoutSeconds'), isFalse);
      },
    );

    test(
      '[partition] a red baseline still reports how long it took, with no '
      'budget — none was ever set',
      () {
        const MutationRunReport report = MutationRunReport.aborted(
          AbortKind.baselineFailed,
          'red',
          baselineDuration: Duration(seconds: 3),
        );

        final Map<String, Object?> json = report.toJson();
        expect(json['baselineSeconds'], 3.0);
        expect(json.containsKey('mutantTimeoutSeconds'), isFalse);
      },
    );
  });
}
