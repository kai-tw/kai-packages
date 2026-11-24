import 'dart:io';

import 'process_row.dart';

/// A snapshot of every process on the machine, read from `ps`.
class ProcessTable {
  const ProcessTable(this.rows);

  /// The machine's processes now, or an empty table where `ps` cannot be run.
  ///
  /// Synchronous because it is called while a run is being stopped, where
  /// there may be no event loop turn left to finish an asynchronous read.
  factory ProcessTable.read() {
    final ProcessResult result;
    try {
      result = Process.runSync('ps', <String>[
        '-ww',
        '-A',
        '-o',
        'pid=,ppid=,uid=,command=',
      ]);
    } on ProcessException {
      return const ProcessTable(<ProcessRow>[]);
    }
    if (result.exitCode != 0) {
      return const ProcessTable(<ProcessRow>[]);
    }
    return ProcessTable.parse(result.stdout as String);
  }

  /// Parses `ps -ww -A -o pid=,ppid=,uid=,command=` output. A line that does not
  /// fit that shape is skipped.
  factory ProcessTable.parse(String text) {
    final RegExp line = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$');
    final List<ProcessRow> rows = <ProcessRow>[];
    for (final String raw in text.split('\n')) {
      final RegExpMatch? match = line.firstMatch(raw);
      if (match == null) {
        continue;
      }
      rows.add(
        ProcessRow(
          pid: int.parse(match.group(1) ?? ''),
          ppid: int.parse(match.group(2) ?? ''),
          uid: int.parse(match.group(3) ?? ''),
          command: (match.group(4) ?? '').trim(),
        ),
      );
    }
    return ProcessTable(rows);
  }

  final List<ProcessRow> rows;

  /// The row for [pid], or `null` when no such process is running.
  ProcessRow? find(int pid) {
    for (final ProcessRow row in rows) {
      if (row.pid == pid) {
        return row;
      }
    }
    return null;
  }

  /// Every process descended from [rootPid], parents before their children.
  ///
  /// [killTree] relies on that order: killing a supervisor before the
  /// processes it supervises leaves nobody alive to start replacements.
  List<ProcessRow> descendantsOf(int rootPid) {
    final Map<int, List<ProcessRow>> childrenOf = <int, List<ProcessRow>>{};
    for (final ProcessRow row in rows) {
      childrenOf.putIfAbsent(row.ppid, () => <ProcessRow>[]).add(row);
    }
    final List<ProcessRow> found = <ProcessRow>[];
    final List<int> queue = <int>[rootPid];
    for (int next = 0; next < queue.length; next++) {
      for (final ProcessRow child
          in childrenOf[queue[next]] ?? const <ProcessRow>[]) {
        found.add(child);
        queue.add(child.pid);
      }
    }
    return found;
  }

  /// Which of [wanted] are still running as the same process.
  List<ProcessRow> stillRunning(Iterable<ProcessRow> wanted) => <ProcessRow>[
    for (final ProcessRow row in wanted)
      if (find(row.pid) case final ProcessRow now when now.isSameProcessAs(row))
        now,
  ];

  /// `SIGKILL`s [rootPid] and every process descended from it, root first.
  ///
  /// The descendants are listed before anything is killed, because the
  /// parent link is the only thing connecting them and killing the root
  /// breaks it. They are killed top-down on purpose. `flutter test` is three
  /// layers (the `flutter` tool, its compiler, and one `flutter_tester` per
  /// test file), and the tool supervises the testers: kill a tester while
  /// the tool is still alive and the tool starts a replacement, which the
  /// kill a moment later then leaves orphaned.
  static void killTree(int rootPid) {
    final List<ProcessRow> descendants = ProcessTable.read().descendantsOf(
      rootPid,
    );
    Process.killPid(rootPid, ProcessSignal.sigkill);
    for (final ProcessRow row in descendants) {
      Process.killPid(row.pid, ProcessSignal.sigkill);
    }
  }
}
