import 'dart:async';
import 'dart:io';

/// Whether a run is paused, by signal: `SIGUSR1` pauses it and `SIGUSR2`
/// resumes it — what `dart_mutants pause` and `resume` send.
///
/// A pause never interrupts a test file's run: each lane asks [resumed]
/// between runs, and only there does it wait.
class RunControl {
  /// [watchSignal] defaults to the real `ProcessSignal.watch`; a test swaps
  /// it to deliver a signal itself.
  RunControl({
    Stream<ProcessSignal> Function(ProcessSignal signal) watchSignal =
        _watchReal,
  }) : _watchSignal = watchSignal;

  static Stream<ProcessSignal> _watchReal(ProcessSignal signal) =>
      signal.watch();

  final Stream<ProcessSignal> Function(ProcessSignal signal) _watchSignal;
  final List<StreamSubscription<ProcessSignal>> _subscriptions =
      <StreamSubscription<ProcessSignal>>[];

  /// Completes when the pause in force ends; `null` while not paused.
  Completer<void>? _pause;

  /// `true` each time the run pauses and `false` each time it resumes,
  /// delivered as it happens, so a clock can stop on the very event.
  final StreamController<bool> _changes = StreamController<bool>.broadcast(
    sync: true,
  );

  bool get isPaused => _pause != null;

  Stream<bool> get changes => _changes.stream;

  /// Completes at once when not paused, or else when the run resumes.
  Future<void> get resumed => _pause?.future ?? Future<void>.value();

  /// Starts watching for `SIGUSR1` and `SIGUSR2`; a second call, already
  /// watching, does nothing.
  ///
  /// Watching them is what keeps them from ending the process: unwatched,
  /// either one terminates it. So a run is armed before anything can find
  /// it to send one.
  void arm() {
    if (_subscriptions.isNotEmpty) {
      return;
    }
    try {
      _subscriptions
        ..add(_watchSignal(ProcessSignal.sigusr1).listen((_) => pause()))
        ..add(_watchSignal(ProcessSignal.sigusr2).listen((_) => resume()));
    } on SignalException catch (e) {
      // Windows cannot watch either. The run goes on; it just cannot be
      // paused, and says so.
      stderr.writeln(
        'dart_mutants: cannot watch SIGUSR1/SIGUSR2 on this platform '
        '(${e.message}) — this run cannot be paused.',
      );
    }
  }

  /// A second pause while paused changes nothing.
  void pause() {
    if (isPaused) {
      return;
    }
    _pause = Completer<void>();
    _changes.add(true);
  }

  /// A resume while not paused changes nothing.
  void resume() {
    final Completer<void>? pause = _pause;
    if (pause == null) {
      return;
    }
    _pause = null;
    pause.complete();
    _changes.add(false);
  }

  /// Stops watching the signals, and resumes a run left paused so nothing
  /// waits on a resume that can no longer come.
  Future<void> disarm() async {
    for (final StreamSubscription<ProcessSignal> s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    resume();
  }
}
