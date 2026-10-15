/// One test file's part of a coverage pass: the lines of each source file it
/// was reported on, split into those it hit and those it did not. A journal
/// records one as each test file finishes, so a pass cut short resumes from
/// the next file instead of the first — under `flutter test` the pass is one
/// run per test file, and on a large suite the whole pass outlives a cloud VM.
///
/// Lines are stored as `[start, end]` runs: a test file is usually reported
/// on long stretches of each file it loads.
class SuiteCoverage {
  SuiteCoverage(this.testFile, {required this.hit, required this.zero});

  /// A test file that ran no test: nothing reported, nothing to run again.
  SuiteCoverage.empty(this.testFile)
    : hit = const <String, Set<int>>{},
      zero = const <String, Set<int>>{};

  final String testFile;

  /// source file -> the lines [testFile] hit.
  final Map<String, Set<int>> hit;

  /// source file -> the lines [testFile] was reported on and did not hit.
  final Map<String, Set<int>> zero;

  Map<String, Object?> toJson() => <String, Object?>{
    'coverageOf': testFile,
    'hit': _runsOf(hit),
    'zero': _runsOf(zero),
  };

  /// The suite [toJson] wrote, or `null` for a line in any other shape.
  static SuiteCoverage? fromJson(Object? json) {
    if (json case {
      'coverageOf': final String testFile,
      'hit': final Map<String, Object?> hit,
      'zero': final Map<String, Object?> zero,
    }) {
      final Map<String, Set<int>>? h = _linesOf(hit);
      final Map<String, Set<int>>? z = _linesOf(zero);
      return h == null || z == null
          ? null
          : SuiteCoverage(testFile, hit: h, zero: z);
    }
    return null;
  }

  static Map<String, List<List<int>>> _runsOf(Map<String, Set<int>> lines) =>
      <String, List<List<int>>>{
        for (final MapEntry<String, Set<int>> file in lines.entries)
          file.key: _runs(file.value.toList()..sort()),
      };

  static List<List<int>> _runs(List<int> sorted) {
    final List<List<int>> runs = <List<int>>[];
    for (final int line in sorted) {
      if (runs.isNotEmpty && runs.last[1] == line - 1) {
        runs.last[1] = line;
      } else {
        runs.add(<int>[line, line]);
      }
    }
    return runs;
  }

  static Map<String, Set<int>>? _linesOf(Map<String, Object?> runs) {
    final Map<String, Set<int>> lines = <String, Set<int>>{};
    for (final MapEntry<String, Object?> file in runs.entries) {
      final Object? value = file.value;
      if (value is! List<Object?>) {
        return null;
      }
      final Set<int> set = lines.putIfAbsent(file.key, () => <int>{});
      for (final Object? run in value) {
        if (run case [final int start, final int end] when start <= end) {
          for (int line = start; line <= end; line++) {
            set.add(line);
          }
        } else {
          return null;
        }
      }
    }
    return lines;
  }
}
