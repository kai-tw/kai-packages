import 'dart:async';
import 'dart:io';

import 'temp_space.dart';

/// One external command this package shells out to — the project's own test
/// command (`flutter test test/foo_test.dart`) or its analyzer
/// (`dart analyze` / `flutter analyze`). Neither is fixed: a Flutter package
/// has no `dart test` that works at all, and `dart_lints.yaml` already
/// established in this same workspace that the analyzer invocation itself
/// varies by project — this type exists so both are the caller's decision,
/// not this package's guess.
class ProcessCommand {
  const ProcessCommand(
    this.executable,
    this.arguments, {
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;

  /// Defaults to the current process's working directory when `null`.
  final String? workingDirectory;

  /// Every child started by [run] that has not yet exited.
  ///
  /// Exists so an interrupt can kill them. Sequential execution means this
  /// holds at most one pid today, but it is a set rather than a field because
  /// "at most one" is a property of the current runner, not of this class.
  static final Set<int> _running = <int>{};

  /// A snapshot of [_running], for tests only — production code has no
  /// legitimate reason to read what this class is tracking; [killAllRunning]
  /// is the only thing outside this class that ever needs to act on it.
  static Set<int> trackedPidsForTest() => Set<int>.of(_running);

  /// Where [run] makes each child's own temporary directory. Replaceable so
  /// a test can point it somewhere it can inspect.
  static TempSpace temps = TempSpace();

  /// Runs the command to completion and returns its exit code, or `null` if
  /// it did not finish within [timeout].
  ///
  /// A mutant can turn a normal loop into an infinite one — the whole reason
  /// this exists. `package:test`'s own per-test timeout cannot be trusted to
  /// catch that: it is cooperative, built on the event loop, and a
  /// synchronous `while (true) {}` never yields to it at all, so the test
  /// framework's timeout never gets a chance to fire and this package's own
  /// `await` on the subprocess would hang forever. [timeout] is enforced
  /// from outside the subprocess instead — a `SIGKILL`, which cannot be
  /// blocked or ignored by whatever the child process is doing — so a
  /// mutant that hangs ends that one mutant's run, not the whole session.
  ///
  /// The kill goes to the whole process **tree**, not the child — see
  /// [killTree] for the leak that taught this.
  ///
  /// The child gets a temporary directory of its own (`TMPDIR`, `TMP` and
  /// `TEMP`), deleted when it exits or is killed. `flutter test` makes a
  /// `flutter_tools.*` directory there on every invocation and does not
  /// always remove it, and a run makes one invocation per mutant — measured
  /// on one host, 111 left behind at about 270 MB each, which filled the disk
  /// before the run could write its report. Whatever the child leaves, this
  /// directory takes with it.
  Future<int?> run({Duration? timeout}) async {
    final Directory tmp = temps.create('child');
    try {
      return await _runIn(tmp, timeout);
    } finally {
      temps.delete(tmp);
    }
  }

  Future<int?> _runIn(Directory tmp, Duration? timeout) async {
    final Process process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: <String, String>{
        'TMPDIR': tmp.path,
        'TMP': tmp.path,
        'TEMP': tmp.path,
      },
    );
    _running.add(process.pid);
    // The child's own output is not this package's concern, and an unread
    // pipe can fill up and deadlock the child — drain it unconditionally.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    try {
      if (timeout == null) {
        return await process.exitCode;
      }
      try {
        return await process.exitCode.timeout(timeout);
      } on TimeoutException {
        killTree(process.pid);
        await process.exitCode; // Reap it — otherwise it is left a zombie.
        return null;
      }
    } finally {
      _running.remove(process.pid);
    }
  }

  /// `SIGKILL`s [rootPid] **and every process descended from it**.
  ///
  /// Killing the direct child alone leaks, and the leak is unbounded. A
  /// `flutter test` is three processes, not one — the `flutter` wrapper
  /// spawns `dartaotruntime`, which spawns the `flutter_tester` engine that
  /// actually runs the test — and a signal to the wrapper does not propagate
  /// downward. POSIX reparents an orphan to init rather than killing it, so
  /// the tester survives, keeps executing the mutant's infinite loop, and
  /// nothing will ever reap it.
  ///
  /// Measured, because it reads like a technicality until it is a number: a
  /// mutant that allocates inside its loop left a `flutter_tester` at 1.86 GB
  /// at the moment of the kill and 2.25 GB three seconds later — roughly
  /// 130 MB/s, forever, from **one** timed-out mutant. It survives the run
  /// that created it, so the cost accumulates across runs and does not come
  /// back when this binary exits. Two such runs exhausted a workstation's
  /// memory, which is how it was found.
  ///
  /// Descendants are collected before anything is killed, because the parent
  /// link is the only thing connecting them and killing the root destroys it.
  ///
  /// They are then killed **top-down — root first, leaves last**, and the
  /// order is load-bearing rather than arbitrary. Leaves-first was tried and
  /// measured: `flutter_tools` is a supervisor, so killing the tester it owns
  /// while it is still alive makes it do its job and **spawn a replacement**,
  /// which is then orphaned by the kill arriving a moment later. The leak
  /// survived the fix, one process smaller. Killing a parent before its child
  /// leaves nobody running who could notice.
  ///
  /// Two honest limits. A descendant started between the snapshot and the
  /// kill is missed by construction — hence the survivor check, which turns
  /// that from a silent leak into a line on stderr, and which is what caught
  /// the respawn above. And process enumeration here is `ps`, so on a
  /// platform without it this degrades to killing the direct child, exactly
  /// as before; that is said out loud rather than failing quietly, since the
  /// leak it reintroduces is invisible.
  ///
  /// [maxPollAttempts] and [pollInterval] tune the survivor poll below and
  /// exist for tests — production callers get the real 20-attempts/100ms
  /// budget the class doc above measures against; a test can shrink both to
  /// force the poll to exhaust its budget against a real, deliberately-slow-
  /// to-reap process without waiting out the real one.
  ///
  /// [reportSurvivors] receives the same message [stderr] gets by default —
  /// overridable so a test can capture it instead of asserting on process
  /// output, which nothing in this package can otherwise intercept.
  static void killTree(
    int rootPid, {
    int maxPollAttempts = 20,
    Duration pollInterval = const Duration(milliseconds: 100),
    void Function(String)? reportSurvivors,
  }) {
    final List<int> descendants = _descendantsOf(rootPid);
    Process.killPid(rootPid, ProcessSignal.sigkill);
    for (final int pid in descendants) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }

    if (descendants.isEmpty) {
      return;
    }

    // Polled, not a single sample. The kill is delivered asynchronously and a
    // process that has just allocated gigabytes does not disappear from the
    // table promptly — one 50ms sample reported a survivor that was in fact
    // gone, on the very first real run. A check that cries wolf on every
    // timeout is a check nobody reads, which is worse than not having one.
    List<int> survivors = descendants;
    for (
      int attempt = 0;
      attempt < maxPollAttempts && survivors.isNotEmpty;
      attempt++
    ) {
      sleep(pollInterval);
      survivors = _aliveAmong(survivors);
    }
    if (survivors.isNotEmpty) {
      (reportSurvivors ?? stderr.writeln)(
        'dart_mutants: ${survivors.length} subprocess(es) survived the '
        'timeout kill and are now orphaned — ${survivors.join(', ')}. They '
        'will keep running until killed by hand. This means a descendant '
        'started after the process tree was snapshotted.',
      );
    }
  }

  /// `SIGKILL`s the tree under every child still running, then deletes their
  /// temporary directories.
  ///
  /// Synchronous on purpose: its caller is a signal handler that ends in
  /// `exit()`, and `exit()` does not wait for pending futures — an async
  /// cleanup there would be scheduled and then discarded, which is
  /// indistinguishable from not having written it.
  static void killAllRunning() {
    for (final int pid in _running.toList()) {
      killTree(pid);
    }
    _running.clear();
    temps.deleteAll();
  }

  /// Every pid descended from [rootPid], breadth-first — so the result lists
  /// every parent before its own children, which is the order [killTree]
  /// depends on.
  static List<int> _descendantsOf(int rootPid) {
    final Map<int, List<int>> childrenOf = <int, List<int>>{};
    for (final List<int> row in _processTable()) {
      childrenOf.putIfAbsent(row[1], () => <int>[]).add(row[0]);
    }

    final List<int> found = <int>[];
    final List<int> queue = <int>[rootPid];
    while (queue.isNotEmpty) {
      for (final int child in childrenOf[queue.removeAt(0)] ?? const <int>[]) {
        found.add(child);
        queue.add(child);
      }
    }
    return found;
  }

  static List<int> _aliveAmong(List<int> pids) {
    final Set<int> alive = <int>{
      for (final List<int> row in _processTable()) row[0],
    };
    return pids.where(alive.contains).toList();
  }

  /// `[pid, ppid]` for every process on the machine, or empty when this
  /// platform has no `ps` to ask.
  static List<List<int>> _processTable() => processTableForTest(
    () => Process.runSync('ps', <String>['-Ao', 'pid=,ppid=']),
  );

  /// [_processTable] with the `ps` call passed in, so a test can make it
  /// fail — `Process.runSync` resolves `ps` against the inherited `PATH`,
  /// which a running Dart process cannot rewrite for itself.
  static List<List<int>> processTableForTest(ProcessResult Function() runPs) {
    final ProcessResult result;
    try {
      result = runPs();
    } on ProcessException {
      stderr.writeln(
        'dart_mutants: no `ps` on this platform, so only the direct child is '
        'killed on a timeout. A test runner that spawns its own engine '
        'process (`flutter test` does) will leak that engine.',
      );
      return const <List<int>>[];
    }

    final List<List<int>> rows = <List<int>>[];
    for (final String line in (result.stdout as String).split('\n')) {
      final List<String> fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 2) {
        continue;
      }
      final int? pid = int.tryParse(fields[0]);
      final int? ppid = int.tryParse(fields[1]);
      if (pid != null && ppid != null) {
        rows.add(<int>[pid, ppid]);
      }
    }
    return rows;
  }

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}
