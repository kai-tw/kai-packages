/// Where a `SchemataRunner` pass spent its time and what it left to
/// `flutter test`, for the run's statistics.
class SchemataStats {
  int switched = 0;

  /// How many mutants were left out of a switched file, by reason.
  final Map<String, int> notSwitched = <String, int>{};

  /// Test files that failed to compile with the switched code in, or failed
  /// unmutated, and so sent their mutants to `flutter test`.
  final List<String> brokenTestFiles = <String>[];

  /// Mutants a run ended without a verdict for — a crash, an exit code
  /// other than 0 or 1 — and so sent to `flutter test`.
  int noVerdict = 0;

  Duration switching = Duration.zero;
  Duration compiling = Duration.zero;
  Duration unmutated = Duration.zero;
  int compiledTestFiles = 0;

  /// Counts one mutant left out of a switched file for [reason].
  void notSwitchedFor(String reason) =>
      notSwitched[reason] = (notSwitched[reason] ?? 0) + 1;

  Map<String, Object?> toJson() => <String, Object?>{
    'switched': switched,
    'notSwitched': notSwitched,
    'brokenTestFiles': brokenTestFiles,
    'noVerdict': noVerdict,
    'compiledTestFiles': compiledTestFiles,
    'switchSeconds': switching.inMilliseconds / 1000,
    'compileSeconds': compiling.inMilliseconds / 1000,
    'unmutatedSeconds': unmutated.inMilliseconds / 1000,
  };
}
