import 'host_load.dart';
import 'mutant_timing.dart';

/// What one run cost, and where the time went — collected as the run goes,
/// and kept with its report so later runs have something to compare
/// against.
///
/// Filled in by `MutationTestRunner.run`. A phase that never happened, such
/// as the coverage pass without `--select-by-coverage`, or everything after
/// an abort, stays `null` and is left out of [toJson].
class RunStats {
  RunStats({
    required this.startedAt,
    required this.environment,
    this.loadAtStart,
  });

  final DateTime startedAt;
  DateTime? finishedAt;

  /// What the run was given and where it ran — see
  /// `MutationTestRunner.run` for the keys.
  final Map<String, Object?> environment;

  final HostLoad? loadAtStart;
  HostLoad? loadAtEnd;

  Duration? baseline;

  /// Putting every target to the gate unmodified, before any mutant.
  Duration? gateCheck;

  Duration? coveragePass;

  /// Making the workers' sandboxes — see `MutationTestRunner.workers`.
  Duration? sandboxSetup;

  /// How many workers ran the mutants.
  int? workers;

  /// Each sandboxed worker's own disk use when the last mutant finished,
  /// links not counted. Empty when the mutants ran in the package itself.
  List<int>? workerDiskBytes;

  final List<MutantTiming> mutants = <MutantTiming>[];

  Map<String, Object?> toJson() => <String, Object?>{
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (finishedAt != null) ...<String, Object?>{
      'finishedAt': finishedAt!.toUtc().toIso8601String(),
      'wallSeconds': MutantTiming.seconds(finishedAt!.difference(startedAt)),
    },
    'environment': environment,
    'loadAverage': <String, Object?>{
      'start': loadAtStart?.toJson(),
      'end': loadAtEnd?.toJson(),
    },
    'phases': _phases(),
    'verdicts': _breakdown((MutantTiming m) => m.bucket),
    'operators': _breakdown((MutantTiming m) => m.result.mutant.operatorName),
    'selection': _selection(),
    if (workers != null) 'workers': workers,
    if (workerDiskBytes != null) 'workerDiskBytes': workerDiskBytes,
    'mutants': mutants.map((MutantTiming m) => m.toJson()).toList(),
  };

  /// Seconds per phase that ran.
  Map<String, Object?> _phases() => <String, Object?>{
    for (final MapEntry<String, Duration?> phase in <String, Duration?>{
      'baselineSeconds': baseline,
      'gateCheckSeconds': gateCheck,
      'coveragePassSeconds': coveragePass,
      'sandboxSetupSeconds': sandboxSetup,
    }.entries)
      if (phase.value case final Duration took) phase.key: _s(took),
    'mutantsSeconds': _s(_sum(mutants, (MutantTiming m) => m.elapsed)),
  };

  /// Count and seconds per [key], and — per operator — per verdict too.
  Map<String, Object?> _breakdown(String Function(MutantTiming) key) {
    final Map<String, List<MutantTiming>> groups =
        <String, List<MutantTiming>>{};
    for (final MutantTiming m in mutants) {
      groups.putIfAbsent(key(m), () => <MutantTiming>[]).add(m);
    }
    return <String, Object?>{
      for (final MapEntry<String, List<MutantTiming>> group in groups.entries)
        group.key: <String, Object?>{
          'count': group.value.length,
          'seconds': _s(_sum(group.value, (MutantTiming m) => m.elapsed)),
          'verdicts': _counts(group.value),
        },
    };
  }

  Map<String, Object?> _selection() {
    final List<MutantTiming> measured = mutants
        .where((MutantTiming m) => m.measurement != null)
        .toList();
    final List<MutantTiming> retried = mutants
        .where((MutantTiming m) => m.retry != null)
        .toList();
    return <String, Object?>{
      'selectedMutants': mutants.where((MutantTiming m) => m.selected).length,
      'measuredSelections': measured.length,
      'measurementSeconds': _s(
        _sum(measured, (MutantTiming m) => m.measurement ?? Duration.zero),
      ),
      'fullCommandRetries': retried.length,
      'retrySeconds': _s(
        _sum(retried, (MutantTiming m) => m.retry ?? Duration.zero),
      ),
    };
  }

  static Map<String, int> _counts(List<MutantTiming> group) {
    final Map<String, int> counts = <String, int>{};
    for (final MutantTiming m in group) {
      counts[m.bucket] = (counts[m.bucket] ?? 0) + 1;
    }
    return counts;
  }

  static Duration _sum(
    List<MutantTiming> group,
    Duration Function(MutantTiming) of,
  ) => group.fold(Duration.zero, (Duration t, MutantTiming m) => t + of(m));

  static double _s(Duration d) => MutantTiming.seconds(d);
}
