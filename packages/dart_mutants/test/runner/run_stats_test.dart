import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/host_load.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_timing.dart';
import 'package:dart_mutants/src/runner/mutant_verdict.dart';
import 'package:dart_mutants/src/runner/run_stats.dart';
import 'package:dart_mutants/src/runner/switched_stats.dart';
import 'package:test/test.dart';

Mutant _mutant(String operatorName, int line) => Mutant(
  filePath: 'lib/foo.dart',
  offset: 0,
  length: 1,
  line: line,
  column: 3,
  original: 'a',
  replacement: 'b',
  operatorName: operatorName,
  description: 'a -> b',
);

MutantTiming _timing(
  String operatorName,
  MutantVerdict verdict, {
  required int ms,
  bool uncovered = false,
  bool selected = false,
  int worker = 0,
}) => MutantTiming(
  worker: worker,
  result: MutantResult(
    mutant: _mutant(operatorName, ms),
    verdict: verdict,
    uncovered: uncovered,
    timeout: verdict == MutantVerdict.invalid || uncovered
        ? null
        : const Duration(seconds: 30),
  ),
  elapsed: Duration(milliseconds: ms),
  compileCheck: const Duration(milliseconds: 5),
  selected: selected,
  test: verdict == MutantVerdict.invalid || uncovered
      ? null
      : Duration(milliseconds: ms - 5),
);

RunStats _stats() =>
    RunStats(
        startedAt: DateTime.utc(2026, 9, 17, 1),
        environment: <String, Object?>{'processors': 10},
        loadAtStart: const HostLoad(<double>[1, 2, 3]),
      )
      ..baseline = const Duration(milliseconds: 1500)
      ..compileCheck = const Duration(milliseconds: 40)
      ..workers = 2
      ..switched = (SwitchedStats()
        ..switched = 3
        ..alone = 1
        ..aloneFor('constant context')
        ..compiledTestFiles = 2
        ..workerDiskBytes = <int>[1024, 2048])
      ..finishedAt = DateTime.utc(2026, 9, 17, 1, 0, 10)
      ..mutants.addAll(<MutantTiming>[
        _timing(
          'ternary_swap',
          MutantVerdict.detected,
          ms: 2000,
          selected: true,
          worker: 1,
        ),
        _timing('ternary_swap', MutantVerdict.invalid, ms: 10),
        _timing(
          'statement_deletion',
          MutantVerdict.undetected,
          ms: 3000,
          selected: true,
        ),
        _timing(
          'statement_deletion',
          MutantVerdict.undetected,
          ms: 7,
          uncovered: true,
        ),
        _timing('statement_deletion', MutantVerdict.timeout, ms: 30000),
      ]);

void main() {
  late Map<String, Object?> json;

  setUp(() => json = _stats().toJson());

  test('[partition] carries when the run started and finished, and how long '
      'it took', () {
    expect(json['startedAt'], '2026-09-17T01:00:00.000Z');
    expect(json['finishedAt'], '2026-09-17T01:00:10.000Z');
    expect(json['wallSeconds'], 10);
    expect(json['environment'], <String, Object?>{'processors': 10});
    expect(json['loadAverage'], <String, Object?>{
      'start': <double>[1, 2, 3],
      'end': null,
    });
  });

  test('[partition] phases that ran are timed; one that did not is absent', () {
    expect(json['phases'], <String, Object?>{
      'baselineSeconds': 1.5,
      'compileCheckSeconds': 0.04,
      'mutantsSeconds': 35.017,
    });
  });

  test('[decision] verdicts are counted and timed, with an uncovered '
      'survivor apart from one that ran', () {
    final Map<String, Object?> verdicts =
        json['verdicts']! as Map<String, Object?>;
    expect(verdicts.keys, <String>[
      'detected',
      'invalid',
      'undetected',
      'uncovered',
      'timeout',
    ]);
    expect(verdicts['undetected'], <String, Object?>{
      'count': 1,
      'seconds': 3,
      'verdicts': <String, int>{'undetected': 1},
    });
    expect((verdicts['timeout']! as Map<String, Object?>)['seconds'], 30);
  });

  test('[partition] each operator is counted, timed and split by verdict', () {
    final Map<String, Object?> operators =
        json['operators']! as Map<String, Object?>;
    expect(operators['statement_deletion'], <String, Object?>{
      'count': 3,
      'seconds': 33.007,
      'verdicts': <String, int>{'undetected': 1, 'uncovered': 1, 'timeout': 1},
    });
    expect(
      (operators['ternary_swap']! as Map<String, Object?>)['verdicts'],
      <String, int>{'detected': 1, 'invalid': 1},
    );
  });

  test('[partition] how many mutants coverage chose test files for', () {
    expect(json['selection'], <String, Object?>{'selectedMutants': 2});
  });

  test('[state] every mutant is listed, detected ones included, with only '
      'the times that apply to it', () {
    final List<Object?> mutants = json['mutants']! as List<Object?>;
    expect(mutants, hasLength(5));
    expect(mutants.first, <String, Object?>{
      'filePath': 'lib/foo.dart',
      'line': 2000,
      'column': 3,
      'operatorName': 'ternary_swap',
      'verdict': 'detected',
      'worker': 1,
      'seconds': 2,
      'compileCheckSeconds': 0.005,
      'selected': true,
      'testSeconds': 1.995,
      'timeoutSeconds': 30,
    });
    expect(mutants[1], <String, Object?>{
      'filePath': 'lib/foo.dart',
      'line': 10,
      'column': 3,
      'operatorName': 'ternary_swap',
      'verdict': 'invalid',
      'worker': 0,
      'seconds': 0.01,
      'compileCheckSeconds': 0.005,
      'selected': false,
    });
  });

  test('[partition] how many workers ran, and what the switched run did', () {
    expect(json['workers'], 2);
    expect(json['switched'], <String, Object?>{
      'switched': 3,
      'alone': 1,
      'aloneReasons': <String, int>{'constant context': 1},
      'compiledTestFiles': 2,
      'skippedTestFiles': 0,
      'unreachedRuns': 0,
      'switchSeconds': 0,
      'compileSeconds': 0,
      'unmutatedSeconds': 0,
      'workerDiskBytes': <int>[1024, 2048],
    });
  });

  test('[boundary] an unfinished run has no end and no wall time', () {
    final Map<String, Object?> unfinished = RunStats(
      startedAt: DateTime.utc(2026),
      environment: const <String, Object?>{},
    ).toJson();
    expect(unfinished.containsKey('finishedAt'), isFalse);
    expect(unfinished.containsKey('wallSeconds'), isFalse);
    expect(unfinished['phases'], <String, Object?>{'mutantsSeconds': 0});
    expect(unfinished['mutants'], isEmpty);
  });
}
