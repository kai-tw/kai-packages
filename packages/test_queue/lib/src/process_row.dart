/// One line of the machine's process table.
class ProcessRow {
  const ProcessRow({
    required this.pid,
    required this.ppid,
    required this.uid,
    required this.command,
  });

  final int pid;

  /// The parent's pid. `1` means the process is an orphan: its parent exited
  /// and the system's init process adopted it.
  final int ppid;

  /// The id of the user that owns the process.
  final int uid;

  /// The full command line, executable first.
  final String command;

  /// Whether [other] is the same process, not just a later one that was
  /// given the same pid after this one exited.
  bool isSameProcessAs(ProcessRow other) =>
      other.pid == pid && other.command == command;

  @override
  String toString() => '$pid $command';
}
