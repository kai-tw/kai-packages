import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// Kills this process once it uses more than [maxBytes] of memory.
///
/// The check runs in an isolate of its own, on its own thread. That's the
/// point: a test stuck in a synchronous loop never gives its own isolate's
/// event loop a turn, so a `Timer` there would never fire. Another isolate's
/// timer still does.
///
/// It measures the whole process (`ProcessInfo.currentRss`). Under
/// `flutter test` that's one `flutter_tester`, which runs one test file.
///
/// The process is killed with `SIGKILL`, not stopped politely, because the
/// isolate that's running away won't stop when asked. `flutter test` then
/// reports the test that was running as failed ("did not complete"), and the
/// other test files carry on.
class MemoryLimit {
  /// Throws an [ArgumentError] when [maxBytes] is below 1 or [interval] isn't
  /// positive.
  MemoryLimit({
    required this.maxBytes,
    this.interval = const Duration(milliseconds: 250),
  }) {
    if (maxBytes < 1) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be 1 or more');
    }
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
  }

  /// The most resident memory this process may use, in bytes.
  final int maxBytes;

  /// How often the memory is read. A process that allocates fast can go past
  /// [maxBytes] by however much it allocates in one interval.
  final Duration interval;

  /// Starts watching. The watching isolate doesn't keep the process alive:
  /// when the main isolate is done, the process exits as usual.
  Future<void> start() async {
    await Isolate.spawn(
      _watch,
      _WatchSettings(maxBytes, interval),
      debugName: 'test_toolkit memory limit',
    );
  }

  static void _watch(_WatchSettings settings) {
    final int maxBytes = settings.maxBytes;
    bool killing = false;
    Timer.periodic(settings.interval, (_) async {
      final int rss = ProcessInfo.currentRss;
      if (killing || rss <= maxBytes) {
        return;
      }
      killing = true;
      stderr.writeln(
        'test_toolkit: this test process is using ${_gb(rss)} GB of memory, '
        'over its ${_gb(maxBytes)} GB limit; killing it. The limit is set by '
        'guardTestProcess() in flutter_test_config.dart.',
      );
      await stderr.flush().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      Process.killPid(pid, ProcessSignal.sigkill);
    });
  }

  static String _gb(int bytes) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
}

/// What the watching isolate is told when it starts.
class _WatchSettings {
  const _WatchSettings(this.maxBytes, this.interval);

  final int maxBytes;
  final Duration interval;
}
