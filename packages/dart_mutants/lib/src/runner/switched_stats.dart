/// Where a switched run's time went, for `RunStats.switched`.
class SwitchedStats {
  /// Mutants run behind a switch.
  int switched = 0;

  /// Mutants compiled alone, because they could not be switched.
  int alone = 0;

  /// Why each mutant compiled alone could not be switched, counted.
  final Map<String, int> aloneReasons = <String, int>{};

  Duration switching = Duration.zero;
  Duration compiling = Duration.zero;
  Duration unmutated = Duration.zero;
  int compiledTestFiles = 0;

  /// Test files not run at all, because every mutant that listed them was
  /// settled before a lane came to them.
  int skippedTestFiles = 0;

  /// Runs of a mutant against a test file left out because that file's
  /// unmutated run did not reach the mutant's switch — see
  /// `SwitchedRunner.selectByReach`.
  int unreachedRuns = 0;

  /// Each lane's copy of the package, in bytes, measured as the run ends.
  List<int> workerDiskBytes = <int>[];

  void aloneFor(String reason) =>
      aloneReasons[reason] = (aloneReasons[reason] ?? 0) + 1;

  Map<String, Object?> toJson() => <String, Object?>{
    'switched': switched,
    'alone': alone,
    'aloneReasons': aloneReasons,
    'compiledTestFiles': compiledTestFiles,
    'skippedTestFiles': skippedTestFiles,
    'unreachedRuns': unreachedRuns,
    'switchSeconds': switching.inMilliseconds / 1000,
    'compileSeconds': compiling.inMilliseconds / 1000,
    'unmutatedSeconds': unmutated.inMilliseconds / 1000,
    'workerDiskBytes': workerDiskBytes,
  };
}
