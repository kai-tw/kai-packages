import 'dart:io';

import 'package:path/path.dart' as p;

/// Which test files executed which lines of the package under test — built
/// once per run, before any mutant, so each mutant runs only the tests that
/// could possibly see it.
///
/// Files are keyed by their path relative to the package root, POSIX
/// separators (`lib/src/foo.dart`): the form `flutter test`'s lcov report
/// already uses, and the one `dart test`'s `package:` URIs map onto.
///
/// It is asked about a range of lines, and the runner asks about the whole
/// function a mutant sits in, never the mutant's own line: the VM does not
/// instrument every statement, so a line that ran can read as zero hits
/// (see `executableScope`). A function's entry is always instrumented.
///
/// Three answers, and the third is the one that keeps this honest. A range
/// every suite that loaded it reported with zero hits is **uncovered**: no
/// test executed it, so no test's behaviour can depend on a change to it. A
/// range some suite hit is covered by exactly those suites. But a range **no
/// suite reported at all** is not evidence of anything — a file with no
/// executable code (an abstract interface) does not appear in a report even
/// when every test loads it. Those get `null`, and the caller runs
/// everything, exactly as it would without a map.
class CoverageMap {
  CoverageMap._(this._lines);

  /// file -> line -> the test files that hit it. A line present with an
  /// empty set was reported, and hit by nobody.
  final Map<String, Map<int, Set<String>>> _lines;

  /// The test files that executed any of [startLine]..[endLine] of [file]
  /// (both inclusive, 1-based). Empty when every one of those lines that any
  /// suite reported was hit by none. `null` when no suite reported any of
  /// them — see the class doc for why that is not the same as empty.
  Set<String>? testsFor(String file, int startLine, int endLine) {
    final Map<int, Set<String>>? lines = _lines[file];
    if (lines == null) {
      return null;
    }
    Set<String>? tests;
    for (int line = startLine; line <= endLine; line++) {
      final Set<String>? hitBy = lines[line];
      if (hitBy != null) {
        (tests ??= <String>{}).addAll(hitBy);
      }
    }
    return tests;
  }
}

/// Accumulates one test file's coverage at a time into a [CoverageMap].
class CoverageMapBuilder {
  /// [root] is the package root every key is made relative to.
  CoverageMapBuilder(String root) : _root = _realPath(p.absolute(root));

  static String _realPath(String dir) => Directory(dir).existsSync()
      ? Directory(dir).resolveSymbolicLinksSync()
      : p.normalize(dir);

  final String _root;
  final Map<String, Map<int, Set<String>>> _lines =
      <String, Map<int, Set<String>>>{};

  /// [path] as a key: relative to the package root, POSIX separators — or
  /// `null` for a file outside it.
  String? _key(String path) {
    final String absolute = p.normalize(p.absolute(_root, path));
    if (!p.isWithin(_root, absolute)) {
      return null;
    }
    return p.posix.joinAll(p.split(p.relative(absolute, from: _root)));
  }

  /// Records that [testFile] reported [line] of [file] as hit [count] times.
  /// A zero still counts: it is what marks a line as reported, and so what
  /// makes "nobody hit it" an answer rather than an absence.
  void add(String testFile, String file, int line, int count) {
    final Set<String> hitBy = _lines
        .putIfAbsent(file, () => <int, Set<String>>{})
        .putIfAbsent(line, () => <String>{});
    if (count > 0) {
      hitBy.add(testFile);
    }
  }

  /// One suite's `dart test --coverage` output: a `CodeCoverage` document
  /// whose `hits` are alternating line / count values. Sources under
  /// `package:[packageName]/` are kept, mapped onto `lib/`, and so are
  /// `file:` sources inside the package root — a test that imports
  /// `../lib/x.dart` reports that file under its path, not its package URI.
  ///
  /// Throws a [FormatException] on any other shape rather than skipping what
  /// it cannot read: a report half understood could drop a hit line and keep
  /// its zero-hit neighbours, which would read as uncovered.
  void addDartSuite(String testFile, Object? json, String packageName) {
    if (json case {'coverage': final List<Object?> entries}) {
      for (final Object? entry in entries) {
        if (entry case {
          'source': final String uri,
          'hits': final List<Object?> hits,
        }) {
          final String? file = _sourceKey(uri, packageName);
          if (file != null) {
            _addHits(testFile, file, hits);
          }
        } else {
          throw FormatException('unexpected coverage entry', entry);
        }
      }
    } else {
      throw const FormatException('not a CodeCoverage document');
    }
  }

  void _addHits(String testFile, String file, List<Object?> hits) {
    if (hits.length.isOdd) {
      throw FormatException('odd-length hitmap for $file');
    }
    for (int i = 0; i < hits.length; i += 2) {
      final Object? count = hits[i + 1];
      if (count is! int) {
        throw FormatException('non-integer hit count for $file', count);
      }
      for (final int line in _hitmapLines(hits[i])) {
        add(testFile, file, line, count);
      }
    }
  }

  String? _sourceKey(String uri, String packageName) {
    final String prefix = 'package:$packageName/';
    if (uri.startsWith(prefix)) {
      return 'lib/${uri.substring(prefix.length)}';
    }
    if (uri.startsWith('file:')) {
      return _key(Uri.parse(uri).toFilePath());
    }
    return null;
  }

  /// One test file's `flutter test --coverage` output, in lcov: `SF:` opens
  /// a file — relative to the package root, or absolute — and
  /// `DA:line,count` records a line.
  void addLcov(String testFile, String lcov) {
    String? file;
    for (final String raw in lcov.split('\n')) {
      final String line = raw.trim();
      if (line.startsWith('SF:')) {
        file = _key(line.substring(3));
      } else if (line.startsWith('DA:') && file != null) {
        _addDa(testFile, file, line.substring(3));
      } else if (line == 'end_of_record') {
        file = null;
      }
    }
  }

  /// `line,count[,checksum]`. Anything else throws a [FormatException], for
  /// the reason [addDartSuite] gives.
  void _addDa(String testFile, String file, String fields) {
    final List<String> parts = fields.split(',');
    final int? line = int.tryParse(parts.first);
    final int? count = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (line == null || count == null) {
      throw FormatException('unexpected lcov DA record for $file', fields);
    }
    add(testFile, file, line, count);
  }

  CoverageMap build() => CoverageMap._(_lines);

  /// A hitmap line entry is usually a line number, but `package:coverage`
  /// may also write a `"start-end"` range string.
  static Iterable<int> _hitmapLines(Object? entry) sync* {
    if (entry is int) {
      yield entry;
      return;
    }
    if (entry is! String) {
      throw FormatException('unexpected hitmap line', entry);
    }
    final List<String> bounds = entry.split('-');
    final int start = int.parse(bounds.first);
    final int end = int.parse(bounds.last);
    for (int line = start; line <= end; line++) {
      yield line;
    }
  }
}
