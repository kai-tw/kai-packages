import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cache_directory.dart';
import 'outdated_engine_exception.dart';
import 'version.dart';

export 'outdated_engine_exception.dart';

/// Where releases are tagged, `dart_mutants-v<version>`.
const String releaseRepository = 'https://github.com/kai-tw/kai-packages.git';

/// Stops a run on an engine older than the newest release.
///
/// A consuming project pins the engine by tag, so nothing moves it forward
/// but someone changing the ref — and a run on an old engine scores
/// mutants the way that release did, fixes and all left out, with nothing
/// to say so. There is no option to skip this: an outdated engine is
/// updated, not run.
///
/// The newest tag is read with `git ls-remote` and kept for a day under
/// the user's cache directory, so a run asks the network at most once a
/// day. With no answer from the network and nothing kept from the last
/// day, the run stops too: it cannot tell an up-to-date engine from an
/// outdated one.
class VersionCheck {
  VersionCheck({
    this.current = packageVersion,
    Future<String?> Function()? fetchLatest,
    String? cachePath,
    DateTime Function()? now,
  }) : _fetchLatest = fetchLatest ?? _fromGit,
       cachePath = cachePath ?? _defaultCachePath(),
       _now = now ?? DateTime.now;

  /// The version running.
  final String current;

  /// The file the newest version is kept in, with when it was read.
  final String cachePath;

  final Future<String?> Function() _fetchLatest;
  final DateTime Function() _now;

  /// How long a version read from the network is trusted.
  static const Duration maxAge = Duration(days: 1);

  /// Completes when [current] is the newest release or newer; throws
  /// [OutdatedEngineException] otherwise.
  Future<void> check() async {
    final String? latest = _cached() ?? await _fetched();
    if (latest == null) {
      throw const OutdatedEngineException(
        'could not find out the newest dart_mutants release (git ls-remote '
        '$releaseRepository gave no answer), and none was found in the last '
        'day. Nothing has run: an outdated engine scores mutants the way an '
        'older release did. Check the network and run again.',
      );
    }
    if (compareVersions(current, latest) < 0) {
      throw OutdatedEngineException(
        'dart_mutants $latest is out, and this project resolves $current. '
        'Nothing has run. Set the ref in pubspec.yaml to dart_mutants-v'
        '$latest, then run `pub get`. What changed: '
        'https://github.com/kai-tw/kai-packages/blob/main/packages/'
        'dart_mutants/CHANGELOG.md',
      );
    }
  }

  /// The newest version kept from the last [maxAge], or `null`.
  String? _cached() {
    try {
      final Object? kept = jsonDecode(File(cachePath).readAsStringSync());
      if (kept is! Map<String, Object?>) {
        return null;
      }
      final Object? checkedAt = kept['checkedAt'];
      final Object? latest = kept['latest'];
      if (checkedAt is! String || latest is! String) {
        return null;
      }
      final DateTime? at = DateTime.tryParse(checkedAt);
      if (at == null || _now().difference(at) > maxAge) {
        return null;
      }
      return latest;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The newest version from the network, kept for the next run; `null`
  /// when there was no answer.
  Future<String?> _fetched() async {
    final String? latest = await _fetchLatest();
    if (latest != null) {
      try {
        File(cachePath)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'latest': latest,
              'checkedAt': _now().toUtc().toIso8601String(),
            }),
          );
      } on FileSystemException {
        // Not kept: the next run asks the network again.
        return latest;
      }
    }
    return latest;
  }

  static String _defaultCachePath() =>
      p.join(cacheDirectory(), 'latest_release.json');

  /// The newest `dart_mutants-v*` tag, or `null` without an answer in 15s.
  static Future<String?> _fromGit() async {
    final Process process;
    try {
      process = await Process.start(
        'git',
        <String>[
          '-c',
          'http.lowSpeedLimit=1000',
          '-c',
          'http.lowSpeedTime=5',
          'ls-remote',
          '--tags',
          '--refs',
          releaseRepository,
          'dart_mutants-v*',
        ],
        environment: <String, String>{'GIT_TERMINAL_PROMPT': '0'},
      );
    } on ProcessException {
      return null;
    }
    unawaited(process.stderr.drain<void>());
    final Future<String> out = process.stdout.transform(utf8.decoder).join();
    final int exit = await process.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exit != 0) {
      return null;
    }
    return newestTag(await out);
  }
}

/// The newest `x.y.z` among the `dart_mutants-v<x.y.z>` tags in [lsRemote],
/// `git ls-remote` output; `null` when there is none.
String? newestTag(String lsRemote) {
  String? newest;
  for (final RegExpMatch m in RegExp(
    r'refs/tags/dart_mutants-v(\d+\.\d+\.\d+)$',
    multiLine: true,
  ).allMatches(lsRemote)) {
    if (newest == null || compareVersions(m[1]!, newest) > 0) {
      newest = m[1];
    }
  }
  return newest;
}

/// [a] against [b], both `x.y.z`: negative when [a] is older.
int compareVersions(String a, String b) {
  final List<int> x = a.split('.').map(int.parse).toList();
  final List<int> y = b.split('.').map(int.parse).toList();
  for (int i = 0; i < 3; i++) {
    if (x[i] != y[i]) {
      return x[i].compareTo(y[i]);
    }
  }
  return 0;
}
