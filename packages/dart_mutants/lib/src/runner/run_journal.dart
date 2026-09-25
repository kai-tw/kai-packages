import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../mutant.dart';
import 'mutant_result.dart';
import 'mutant_verdict.dart';

/// Every mutant's result, written to a file as it finishes, so a run that is
/// stopped part-way — Ctrl-C, `kill`, `--max-minutes`, a crash — can be
/// started again and pick up where it stopped instead of from the first
/// mutant.
///
/// The file is JSON Lines: a header naming what the results depend on, then
/// one line per finished mutant. A later run reuses a recorded result only
/// when the header matches it exactly; otherwise the file is started over
/// and [discarded] says why. The header has two halves:
///
/// - the run's configuration — engine version, test command, operators,
///   compile-safety gate, test selection. Not the timeouts or the workers:
///   none of them can change a verdict that is reused (below).
/// - a fingerprint of the package's content, see [fingerprint]. Any edit to
///   the code or the tests can change any verdict, so an edited package
///   starts over rather than guessing which results still hold.
///
/// A recorded [MutantVerdict.timeout] is never reused: it is the one verdict
/// a budget decides, and the usual next step after one is a run with a
/// larger budget, which must ask that mutant again.
///
/// Lines are appended and flushed one by one, so a run killed outright loses
/// at most the line it was writing; a line that does not parse is skipped.
class RunJournal {
  RunJournal._(this.path, this._recorded, this.discarded, this.recordedCount);

  /// Opens [path] for a run whose header is [header], keeping what it
  /// recorded when the header matches and starting it over when not.
  factory RunJournal.open(String path, Map<String, Object?> header) {
    final File file = File(path);
    final String wanted = jsonEncode(header);
    final bool existed = file.existsSync();
    final List<String> lines = existed
        ? file.readAsLinesSync()
        : const <String>[];
    if (lines.firstOrNull == wanted) {
      final Map<String, _Recorded> recorded = _entries(lines.skip(1));
      return RunJournal._(path, recorded, null, recorded.length);
    }
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('$wanted\n', flush: true);
    return RunJournal._(
      path,
      <String, _Recorded>{},
      existed ? _whyNot(lines.firstOrNull, header) : null,
      0,
    );
  }

  /// The entries of [lines], each mutant's last one winning.
  static Map<String, _Recorded> _entries(Iterable<String> lines) =>
      <String, _Recorded>{
        for (final _Recorded entry in lines.map(_Recorded.parse).nonNulls)
          entry.key: entry,
      };

  final String path;
  final Map<String, _Recorded> _recorded;

  /// Why a journal already at [path] was started over, or `null` when there
  /// was none or it matched.
  final String? discarded;

  /// How many results the file held when it was opened.
  final int recordedCount;

  /// [mutant]'s recorded result, or `null` when it has none that can be
  /// reused.
  MutantResult? recall(Mutant mutant) {
    final _Recorded? entry = _recorded[_keyOf(mutant)];
    if (entry == null || entry.verdict == MutantVerdict.timeout) {
      return null;
    }
    return MutantResult(
      mutant: mutant,
      verdict: entry.verdict,
      uncovered: entry.uncovered,
      timeout: entry.timeout,
    );
  }

  /// Appends [result] to the file.
  void record(MutantResult result) {
    final _Recorded entry = _Recorded.of(result);
    _recorded[entry.key] = entry;
    File(path).writeAsStringSync(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// A hash of everything in [packageRoot] a verdict can depend on:
  /// `pubspec.yaml`, `pubspec.lock`, every file under `lib/` and `test/`,
  /// and [targets] wherever they are. Path and content both count, so a
  /// rename changes it as surely as an edit. Anything else — an asset a test
  /// reads from outside `test/`, a Dart SDK upgrade — is not seen; delete the
  /// journal after changing one.
  ///
  /// FNV-1a over the bytes, not a cryptographic hash: it only has to notice
  /// an edit, and this package takes no dependency for it.
  static String fingerprint(String packageRoot, Iterable<String> targets) {
    final String root = p.normalize(p.absolute(packageRoot));
    final Set<String> files = <String>{
      for (final String name in <String>['pubspec.yaml', 'pubspec.lock'])
        if (File(p.join(root, name)).existsSync()) p.join(root, name),
      for (final String dir in <String>['lib', 'test'])
        ..._filesUnder(p.join(root, dir)),
      for (final String target in targets) p.normalize(p.absolute(target)),
    };
    int hash = _fnvOffset;
    for (final String file in files.toList()..sort()) {
      hash = _fnv(hash, utf8.encode(p.relative(file, from: root)));
      hash = _fnv(hash, const <int>[0]);
      final File f = File(file);
      if (f.existsSync()) {
        hash = _fnv(hash, f.readAsBytesSync());
      }
      hash = _fnv(hash, const <int>[0]);
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  static Iterable<String> _filesUnder(String dir) {
    final Directory d = Directory(dir);
    if (!d.existsSync()) {
      return const <String>[];
    }
    return d
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((File f) => p.normalize(f.path));
  }

  static const int _fnvOffset = 0xcbf29ce484222325;
  static const int _fnvPrime = 0x100000001b3;

  static int _fnv(int hash, List<int> bytes) {
    int h = hash;
    for (final int byte in bytes) {
      h = (h ^ byte) * _fnvPrime;
    }
    return h;
  }

  /// Which half of the header differs, for [discarded].
  static String _whyNot(String? firstLine, Map<String, Object?> header) {
    final Object? old = firstLine == null ? null : _tryDecode(firstLine);
    if (old is! Map<String, Object?>) {
      return 'it is not a journal this version can read';
    }
    final List<String> changed = <String>[
      for (final String key in header.keys)
        if (jsonEncode(old[key]) != jsonEncode(header[key])) key,
    ];
    return changed.isEmpty
        ? 'its header differs'
        : 'it was recorded with a different ${changed.join(', ')}';
  }

  static Object? _tryDecode(String line) {
    try {
      return jsonDecode(line);
    } on FormatException {
      return null;
    }
  }
}

/// A mutant is known by where it is and what it becomes. Its file and the
/// file's content are already pinned by the header's fingerprint.
String _keyOf(Mutant m) => jsonEncode(<Object>[
  p.normalize(p.absolute(m.filePath)),
  m.offset,
  m.length,
  m.replacement,
  m.operatorName,
]);

class _Recorded {
  const _Recorded(this.key, this.verdict, this.uncovered, this.timeout);

  factory _Recorded.of(MutantResult r) =>
      _Recorded(_keyOf(r.mutant), r.verdict, r.uncovered, r.timeout);

  /// `null` for a line that is not a whole entry — the one a run killed
  /// mid-write leaves last.
  static _Recorded? parse(String line) {
    final Object? json = RunJournal._tryDecode(line);
    if (json case {
      'mutant': final String key,
      'verdict': final String verdict,
    }) {
      final MutantVerdict? v = MutantVerdict.values
          .where((MutantVerdict m) => m.name == verdict)
          .firstOrNull;
      if (v == null) {
        return null;
      }
      final Object? ms = json['timeoutMs'];
      return _Recorded(
        key,
        v,
        json['uncovered'] == true,
        ms is int ? Duration(milliseconds: ms) : null,
      );
    }
    return null;
  }

  final String key;
  final MutantVerdict verdict;
  final bool uncovered;
  final Duration? timeout;

  Map<String, Object?> toJson() => <String, Object?>{
    'mutant': key,
    'verdict': verdict.name,
    if (uncovered) 'uncovered': true,
    if (timeout != null) 'timeoutMs': timeout!.inMilliseconds,
  };
}
