import 'dart:async';
import 'dart:io';

/// Ends a run cleanly on `SIGINT` (Ctrl-C) or `SIGTERM` (what `kill` sends
/// by default, and what most timeout wrappers send before escalating): runs
/// the cleanup [arm] was given, then exits 1. It cannot catch `SIGKILL` — no
/// process can, by design of the signal itself.
class RunSignalHandler {
  /// [watchSignal] and [exitProcess] default to the real `ProcessSignal.watch`
  /// and `exit`; a test swaps them to deliver a signal, or refuse to watch
  /// one, and to observe the exit, without ending its own process.
  RunSignalHandler({
    Stream<ProcessSignal> Function(ProcessSignal signal) watchSignal =
        _watchReal,
    void Function(int code) exitProcess = exit,
  }) : _watchSignal = watchSignal,
       _exitProcess = exitProcess;

  static Stream<ProcessSignal> _watchReal(ProcessSignal signal) =>
      signal.watch();

  final Stream<ProcessSignal> Function(ProcessSignal signal) _watchSignal;
  final void Function(int code) _exitProcess;
  StreamSubscription<ProcessSignal>? _sigintSubscription;
  StreamSubscription<ProcessSignal>? _sigtermSubscription;
  void Function()? _beforeExit;

  bool get isArmed => _sigintSubscription != null;

  /// Starts watching for `SIGINT`/`SIGTERM`. A second call, already armed,
  /// does nothing — its [beforeExit] included.
  ///
  /// [beforeExit] is the run's cleanup: an interrupt otherwise leaves the
  /// in-flight test process running with nobody left to reap it, and the
  /// run's temporary directories on disk.
  ///
  /// It must be **synchronous**. This ends in `exit()`, which does not wait
  /// for pending futures, so async work here would be scheduled and then
  /// discarded.
  void arm({void Function()? beforeExit}) {
    if (isArmed) {
      return;
    }
    _beforeExit = beforeExit;
    _sigintSubscription = _watchSignal(ProcessSignal.sigint).listen(_onSignal);
    try {
      _sigtermSubscription = _watchSignal(
        ProcessSignal.sigterm,
      ).listen(_onSignal);
    } on SignalException catch (e) {
      // Windows cannot watch SIGTERM. SIGINT alone still covers an
      // interactive Ctrl-C, but a `kill` or timeout wrapper sending SIGTERM
      // ends the run with no cleanup — so it is said out loud.
      stderr.writeln(
        'dart_mutants: cannot watch SIGTERM on this platform (${e.message}) '
        '— only SIGINT (Ctrl-C) will stop this run cleanly.',
      );
    }
  }

  // `test/runner/signal_restore_test.dart` proves this against a real signal
  // in a subprocess; the injected [_watchSignal] and [_exitProcess] let this
  // process's own tests drive it as well.
  void _onSignal(ProcessSignal _) {
    handleSignal();
    _exitProcess(1);
  }

  /// The signal handler without its `exit(1)`: runs the `beforeExit` [arm]
  /// was given. Apart from [_onSignal] so a test can drive it — the exit
  /// cannot run inside a test process without ending it.
  void handleSignal() => _beforeExit?.call();

  /// Stops watching signals. Call once a run has finished normally.
  Future<void> disarm() async {
    await _sigintSubscription?.cancel();
    await _sigtermSubscription?.cancel();
    _sigintSubscription = null;
    _sigtermSubscription = null;
    _beforeExit = null;
  }
}
