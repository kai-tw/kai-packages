import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show pid;

import 'package:path/path.dart' as p;

import '../cache_directory.dart';
import 'temp_space.dart';
import 'worker_sandbox.dart';

/// A run in progress, as the file it keeps at `<cache>/runs/<pid>.json`
/// while it runs — see [cacheDirectory] — so that `dart_mutants pause`,
/// `resume` and `stop` can find it by its package or its pid.
///
/// A run deletes its file when it ends, interrupts included. One killed
/// outright cannot, so a file whose pid no longer runs is a leftover:
/// [live] deletes it rather than report a run that is not there.
class RunRecord {
  const RunRecord({
    required this.pid,
    required this.packagePath,
    required this.startedAt,
  });

  /// Writes this process's record, for a run in [packagePath].
  factory RunRecord.start(String packagePath) {
    final RunRecord record = RunRecord(
      pid: io.pid,
      packagePath: packagePath,
      startedAt: DateTime.now(),
    );
    record._file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<String, Object>{
          'pid': record.pid,
          'packagePath': record.packagePath,
          'startedAt': record.startedAt.toUtc().toIso8601String(),
        }),
        flush: true,
      );
    return record;
  }

  final int pid;

  /// The package the run is in, as [packageOf] gives it.
  final String packagePath;
  final DateTime startedAt;

  static Directory get _directory =>
      Directory(p.join(cacheDirectory(), 'runs'));

  File get _file => File(p.join(_directory.path, '$pid.json'));

  /// Deletes this record's file. Synchronous, so a signal handler can call
  /// it right before `exit`.
  void delete() {
    if (_file.existsSync()) {
      _file.deleteSync();
    }
  }

  /// Every run whose process still runs. The pid is the file's name, the
  /// rest its content; a file whose pid no longer runs is deleted.
  static List<RunRecord> live() {
    final Directory dir = _directory;
    if (!dir.existsSync()) {
      return const <RunRecord>[];
    }
    final List<RunRecord> found = <RunRecord>[];
    for (final File file in dir.listSync().whereType<File>()) {
      final int? owner = int.tryParse(
        p.basenameWithoutExtension(file.path),
      );
      // Not a record's name: nothing here makes one, so it is left be.
      if (owner == null || p.extension(file.path) != '.json') {
        continue;
      }
      if (!TempSpace.pidIsRunning(owner)) {
        _deleteLeftover(file);
        continue;
      }
      if (_read(owner, file) case final RunRecord record) {
        found.add(record);
      }
    }
    return found;
  }

  /// Another `pause`, `resume` or `stop` may be deleting the same leftover;
  /// gone is what both want.
  static void _deleteLeftover(File file) {
    try {
      file.deleteSync();
    } on PathNotFoundException {
      return;
    }
  }

  /// The record in [file], or `null` when its content is not one — written
  /// by hand, or still being written by a run that has just started.
  static RunRecord? _read(int owner, File file) {
    try {
      if (jsonDecode(file.readAsStringSync()) case <String, Object?>{
        'packagePath': final String packagePath,
        'startedAt': final String startedAt,
      }) {
        return RunRecord(
          pid: owner,
          packagePath: packagePath,
          startedAt: DateTime.parse(startedAt),
        );
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The package [directory] is in: the nearest directory holding a
  /// `pubspec.yaml`, at [directory] or above it, with every link resolved —
  /// or [directory] itself, resolved, when there is none.
  static String packageOf(String directory) {
    final String real = realPath(directory);
    for (String dir = real; ; dir = p.dirname(dir)) {
      if (File(p.join(dir, 'pubspec.yaml')).existsSync()) {
        return dir;
      }
      if (p.dirname(dir) == dir) {
        return real;
      }
    }
  }
}
