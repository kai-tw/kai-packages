import 'dart:async';
import 'dart:io';

import 'process_row.dart';
import 'process_table.dart';

/// Runs a command and makes sure that every process it starts ends with it.
///
/// While the command runs, its process tree is read every [trackInterval],
/// and every process ever seen in it is remembered. When the command ends,
/// for any reason, whatever is left of that list is killed. This is what
/// catches a `flutter_tester` whose `flutter` tool died first: the system
/// adopts it, so it is no longer in the tree, but it is still on the list.
class TreeRunner {
  TreeRunner({
    this.trackInterval = const Duration(seconds: 1),
    void Function(String message)? log,
  }) : _log = log ?? stderr.writeln;

  final Duration trackInterval;
  final void Function(String message) _log;

  /// Exit code for a command stopped because it ran past its timeout, the
  /// same one `timeout(1)` uses.
  static const int timedOutCode = 124;

  /// Runs [command] with this process's standard input and output, and
  /// returns its exit code.
  ///
  /// A `SIGINT`, `SIGTERM` or `SIGHUP` sent to this process kills the whole
  /// tree and returns 128 plus the signal's number, as a shell would. So
  /// does [timeout] running out, with [timedOutCode].
  ///
  /// The command gets a temporary directory of its own (`TMPDIR`, `TMP` and
  /// `TEMP`), deleted when it ends. `flutter test` makes a `flutter_tools.*`
  /// directory there on every run and does not always remove it.
  Future<int> run(
    List<String> command, {
    Duration? timeout,
    Map<String, String> environment = const <String, String>{},
  }) async {
    final Directory tmp = Directory.systemTemp.createTempSync('test_queue_');
    try {
      final Process process = await Process.start(
        command.first,
        command.skip(1).toList(),
        mode: ProcessStartMode.inheritStdio,
        environment: <String, String>{
          ...environment,
          'TMPDIR': tmp.path,
          'TMP': tmp.path,
          'TEMP': tmp.path,
        },
      );
      return await _Watch(process, trackInterval, _log).until(timeout);
    } finally {
      _delete(tmp);
    }
  }

  /// A process killed mid-write can leave a file the delete trips on. That
  /// is said, not thrown: the run's own result matters more, and the
  /// directory is under the system temp, which the system cleans.
  void _delete(Directory directory) {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      _log('test_queue: could not delete ${directory.path}: ${e.message}');
    }
  }
}

/// One running command and everything seen under it.
class _Watch {
  _Watch(this.process, Duration trackInterval, this.log) {
    _tracker = Timer.periodic(trackInterval, (_) => _track());
  }

  final Process process;
  final void Function(String message) log;
  final Map<int, ProcessRow> _seen = <int, ProcessRow>{};
  late final Timer _tracker;
  int? _stopCode;

  Future<int> until(Duration? timeout) async {
    final List<StreamSubscription<ProcessSignal>> signals =
        <StreamSubscription<ProcessSignal>>[
          for (final ProcessSignal signal in <ProcessSignal>[
            ProcessSignal.sigint,
            ProcessSignal.sigterm,
            ProcessSignal.sighup,
          ])
            signal.watch().listen(
              (ProcessSignal s) => _stop(128 + s.signalNumber),
            ),
        ];
    final Timer? deadline = timeout == null
        ? null
        : Timer(timeout, () {
            log(
              'test_queue: the command ran past ${timeout.inSeconds}s; '
              'stopping it.',
            );
            _stop(TreeRunner.timedOutCode);
          });
    final int exit = await process.exitCode;
    _tracker.cancel();
    deadline?.cancel();
    for (final StreamSubscription<ProcessSignal> signal in signals) {
      await signal.cancel();
    }
    _killLeftovers();
    return _stopCode ?? exit;
  }

  void _track() {
    for (final ProcessRow row in ProcessTable.read().descendantsOf(
      process.pid,
    )) {
      _seen[row.pid] = row;
    }
  }

  void _stop(int code) {
    if (_stopCode != null) {
      return;
    }
    _stopCode = code;
    _track();
    ProcessTable.killTree(process.pid);
  }

  void _killLeftovers() {
    final List<ProcessRow> leftovers = ProcessTable.read().stillRunning(
      _seen.values,
    );
    if (leftovers.isEmpty) {
      return;
    }
    for (final ProcessRow row in leftovers) {
      Process.killPid(row.pid, ProcessSignal.sigkill);
    }
    log(
      'test_queue: killed ${leftovers.length} process(es) the command left '
      'running:\n${leftovers.map((ProcessRow row) => '  $row').join('\n')}',
    );
  }
}
