import 'dart:io';

import 'process_row.dart';
import 'process_table.dart';

/// Finds and kills test processes left running after the run that started
/// them is gone.
///
/// `flutter test` leaves these behind whenever a process above it is killed
/// outright: a cancelled CI job, a shell that hit its timeout, a terminal
/// that was closed. The system adopts the orphan instead of stopping it, and
/// nothing ever does, so a `flutter_tester` stuck in a test can keep running
/// for hours. Each run that starts reaps them first, so a leftover holds
/// memory until the next run at the latest.
class OrphanReaper {
  OrphanReaper({
    ProcessTable Function()? readTable,
    void Function(int pid)? kill,
    this.confirmDelay = const Duration(milliseconds: 500),
  }) : _readTable = readTable ?? ProcessTable.read,
       _kill = kill ?? ProcessTable.killTree;

  final ProcessTable Function() _readTable;

  /// Kills a stray and every process under it: an orphaned `flutter` tool
  /// still has its testers.
  final void Function(int pid) _kill;

  /// How long a stray process has to stay a stray before it is killed. A
  /// process that the `flutter` tool is stopping by itself as it exits is an
  /// orphan for a moment too, and is gone by the second look.
  final Duration confirmDelay;

  /// Kills every stray test process this user owns, and returns them.
  /// With [dryRun], only returns them.
  Future<List<ProcessRow>> reap({bool dryRun = false}) async {
    final List<ProcessRow> suspects = _strays(_readTable());
    if (suspects.isEmpty) {
      return suspects;
    }
    await Future<void>.delayed(confirmDelay);
    final ProcessTable now = _readTable();
    final List<ProcessRow> confirmed = <ProcessRow>[
      for (final ProcessRow row in now.stillRunning(suspects))
        if (row.ppid == 1) row,
    ];
    if (!dryRun) {
      confirmed.map((ProcessRow row) => row.pid).forEach(_kill);
    }
    return confirmed;
  }

  List<ProcessRow> _strays(ProcessTable table) {
    final int? uid = table.find(pid)?.uid;
    if (uid == null) {
      return <ProcessRow>[];
    }
    return <ProcessRow>[
      for (final ProcessRow row in table.rows)
        if (row.ppid == 1 && row.uid == uid && isTestProcess(row.command)) row,
    ];
  }

  /// Whether [command] is one of the processes `flutter test` runs.
  ///
  /// Only the Flutter test toolchain's own processes count, so no other
  /// orphan this user owns is ever touched:
  ///
  /// - the `flutter` tool running `test`, whose parent was killed;
  /// - `flutter_tester`, the engine that runs one test file;
  /// - the compiler, a `frontend_server` given Flutter's patched SDK. The
  ///   Dart SDK's resident compiler, which runs as an orphan on purpose, is
  ///   told apart by its `--resident-info-file-name`;
  /// - the `development-service` a `flutter_tester` started for coverage or
  ///   a debugger.
  static bool isTestProcess(String command) {
    final String executable = command.split(' ').first;
    if (executable.endsWith('/flutter_tester') ||
        command.contains('flutter_tools.snapshot test')) {
      return true;
    }
    if (command.contains('frontend_server') &&
        command.contains('flutter_patched_sdk')) {
      return !command.contains('--resident-info-file-name');
    }
    return command.contains(' development-service ') &&
        command.contains('Device: flutter tester');
  }
}
