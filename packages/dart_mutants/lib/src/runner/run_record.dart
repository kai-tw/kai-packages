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
/// outright cannot, so a file whose pid no longer runs, or now belongs to a
/// process started after the file was written, is a leftover: [live]
/// deletes it rather than report a run that is not there.
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
  /// rest its content; a leftover file is deleted.
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
      final RunRecord? record = _read(owner, file);
      switch (_ownerOf(owner, record)) {
        case _RunFileOwner.run:
          found.add(record!);
        case _RunFileOwner.gone:
          _deleteLeftover(file);
        case _RunFileOwner.unconfirmed:
          break;
      }
    }
    return found;
  }

  /// Whether process [pid] is the run that wrote [record] (`null` when the
  /// file holds none).
  static _RunFileOwner _ownerOf(int pid, RunRecord? record) {
    if (!TempSpace.pidIsRunning(pid)) {
      return _RunFileOwner.gone;
    }
    if (record == null) {
      return _RunFileOwner.unconfirmed;
    }
    final DateTime? started;
    try {
      started = _processStart(pid);
    } on ProcessException {
      // No `ps` to ask: the comparison below, which only guards against a
      // reused pid, is skipped, and the process is taken for the run.
      return _RunFileOwner.run;
    }
    if (started == null) {
      return _RunFileOwner.unconfirmed;
    }
    // A process that started after the record was written is not the run
    // that wrote it: that run ended without deleting it — the machine went
    // down mid-run, say — and its pid has since gone to another process,
    // which a signal meant for the run must not reach.
    return started.isAfter(record.startedAt)
        ? _RunFileOwner.gone
        : _RunFileOwner.run;
  }

  /// When process [pid] started, as `ps` gives it — to the second, rounded
  /// down, so never after the real start — or `null` when `ps` ran but
  /// cannot say. Throws [ProcessException] when `ps` cannot run at all.
  static DateTime? _processStart(int pid) {
    final ProcessResult result = Process.runSync(
      'ps',
      <String>['-o', 'lstart=', '-p', '$pid'],
      // `lstart` is spelled in the locale's own words otherwise.
      environment: <String, String>{'LC_ALL': 'C'},
    );
    return result.exitCode == 0
        ? _parseStart((result.stdout as String).trim())
        : null;
  }

  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// `ps`'s `lstart` in the C locale — `Fri Nov  6 10:23:45 2026`, local
  /// time — or `null` for anything else.
  static DateTime? _parseStart(String lstart) {
    final List<String> parts = lstart.split(RegExp(r'\s+'));
    if (parts.length != 5) {
      return null;
    }
    final int month = _months.indexOf(parts[1]) + 1;
    final int? day = int.tryParse(parts[2]);
    final int? year = int.tryParse(parts[4]);
    final List<int?> time = parts[3].split(':').map(int.tryParse).toList();
    if (month == 0 ||
        day == null ||
        year == null ||
        time.length != 3 ||
        time.contains(null)) {
      return null;
    }
    return DateTime(year, month, day, time[0]!, time[1]!, time[2]!);
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

/// Who a run file's pid belongs to now.
enum _RunFileOwner {
  /// The run that wrote the file, still going.
  run,

  /// No process, or one that started after the file was written: the file
  /// is a leftover.
  gone,

  /// A running process that cannot be confirmed as the run — the file is
  /// not a record yet, or `ps` cannot say when the process started. Not
  /// reported, and not deleted, since it may be.
  unconfirmed,
}
