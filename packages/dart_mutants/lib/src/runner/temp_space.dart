import 'dart:io';

import 'package:path/path.dart' as p;

/// Every temporary directory a run creates, so that each one is gone when
/// the run ends: at the end of a normal run, on an interrupt, and — for a
/// run that was killed outright — at the start of the next one.
///
/// A mutation run can take hours on a machine short of disk, and a
/// directory left behind by every interrupted run adds up without anyone
/// seeing it. So nothing in this package creates a temporary directory any
/// other way.
///
/// Each directory is named `dart_mutants_<pid>_<purpose>_…`, with the pid of
/// the run that made it. That is what lets a later run tell a leftover from
/// a directory another run, still going, is using: it deletes only those
/// whose pid is no longer running.
class TempSpace {
  TempSpace({Directory? root, bool Function(int pid)? isRunning})
    : root = root ?? Directory.systemTemp,
      _isRunning = isRunning ?? _pidIsRunning;

  static const String prefix = 'dart_mutants_';

  /// Where the directories go — the system temporary directory by default.
  final Directory root;

  final bool Function(int pid) _isRunning;
  final Set<String> _live = <String>{};

  /// A new, empty directory for [purpose] (letters only), tracked until
  /// [delete] or [deleteAll].
  Directory create(String purpose) {
    final Directory dir = root.createTempSync('$prefix${pid}_${purpose}_');
    _live.add(dir.path);
    return dir;
  }

  /// Deletes [dir] if it is still there, and stops tracking it.
  void delete(Directory dir) {
    _live.remove(dir.path);
    _deleteQuietly(dir);
  }

  /// Deletes every directory still tracked. Synchronous, so a signal
  /// handler can call it right before `exit`.
  void deleteAll() {
    for (final String path in _live.toList()) {
      delete(Directory(path));
    }
  }

  /// Deletes the directories earlier runs left behind: named by this
  /// package, made by a pid other than this process's, and that pid no
  /// longer running. Returns how many. A directory it cannot judge — no pid
  /// in its name, or no way to tell whether the pid runs — is left alone.
  int sweepStale() {
    int swept = 0;
    for (final Directory dir in _candidates()) {
      final int? owner = ownerOf(p.basename(dir.path));
      if (owner != null && owner != pid && !_isRunning(owner)) {
        _deleteQuietly(dir);
        swept++;
      }
    }
    return swept;
  }

  Iterable<Directory> _candidates() {
    try {
      return root
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((Directory d) => p.basename(d.path).startsWith(prefix))
          .toList();
    } on FileSystemException {
      return const <Directory>[];
    }
  }

  /// The pid in a name [create] made, or `null` for any other name.
  static int? ownerOf(String name) {
    final Match? match = RegExp(
      '^${RegExp.escape(prefix)}(\\d+)_',
    ).firstMatch(name);
    return match == null ? null : int.parse(match[1]!);
  }

  /// Another process may be deleting the same leftover, or it may already
  /// be gone; neither is worth failing a run over. One that is still there
  /// afterwards is taking disk space, so that is said out loud.
  static void _deleteQuietly(Directory dir) {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      if (dir.existsSync()) {
        stderr.writeln(
          'dart_mutants: could not delete the temporary directory '
          '${dir.path}: ${e.message}',
        );
      }
    }
  }

  /// `true` unless `ps` says [pid] is not running. Where `ps` is missing,
  /// every pid counts as running, so nothing is swept.
  static bool _pidIsRunning(int pid) {
    try {
      return Process.runSync('ps', <String>['-p', '$pid']).exitCode == 0;
    } on ProcessException {
      return true;
    }
  }
}
