import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// Kills this process once the disk it runs on has lost more than
/// [maxWrittenBytes] of free space since [start].
///
/// A runaway test can fill a disk as well as memory: two pieces of code
/// handing the same work back and forth, each logging as it goes, wrote a
/// 38 GB log file on one machine before anyone noticed. The memory limit
/// never saw it, since a log file costs no memory.
///
/// It watches free space, not this process's own writes: Dart can't read how
/// much a process has written, and free space catches a file wherever the
/// test writes it. The cost is that another program writing a lot at the same
/// time counts too, so the default leaves plenty of room.
///
/// Like [MemoryLimit], the check runs in an isolate of its own, so a test
/// stuck in a synchronous loop can't stop it, and the process is killed with
/// `SIGKILL`.
///
/// Free space comes from `df`, which costs a few milliseconds a call, so the
/// default [interval] is a second. A fast disk can write a few more gigabytes
/// in that second, past [maxWrittenBytes].
class DiskLimit {
  /// Throws an [ArgumentError] when [maxWrittenBytes] is below 1 or
  /// [interval] isn't positive.
  DiskLimit({
    required this.maxWrittenBytes,
    this.interval = const Duration(seconds: 1),
    String? path,
  }) : path = path ?? Directory.current.path {
    if (maxWrittenBytes < 1) {
      throw ArgumentError.value(
        maxWrittenBytes,
        'maxWrittenBytes',
        'must be 1 or more',
      );
    }
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
  }

  /// How much free space the disk may lose while this process runs, in bytes.
  final int maxWrittenBytes;

  /// How often the free space is read.
  final Duration interval;

  /// A path on the disk to watch: the current directory by default.
  final String path;

  /// Starts watching. The watching isolate doesn't keep the process alive.
  ///
  /// Where `df` can't be run or read, as on Windows, it says so on stderr and
  /// doesn't watch.
  Future<void> start() async {
    final int? startFree = freeBytes(path);
    if (startFree == null) {
      stderr.writeln(
        'test_toolkit: could not read the free disk space with `df`, so there '
        'is no disk limit for this test process.',
      );
      return;
    }
    await Isolate.spawn(
      _watch,
      _WatchSettings(path, startFree, maxWrittenBytes, interval),
      debugName: 'test_toolkit disk limit',
    );
  }

  /// The free space on the disk that holds [path], in bytes, or `null` when
  /// `df` can't be run or read.
  static int? freeBytes(String path) {
    try {
      final ProcessResult result = Process.runSync('df', <String>[
        '-Pk',
        path,
      ]);
      return result.exitCode == 0 ? parseDf(result.stdout as String) : null;
    } on ProcessException {
      return null;
    }
  }

  /// The free space in `df -Pk` output, in bytes, or `null` when it can't be
  /// read. `-P` keeps each disk on one line, and `-k` counts in kilobytes.
  static int? parseDf(String output) {
    final List<String> lines = output
        .split('\n')
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) {
      return null;
    }
    final List<String> fields = lines[1].trim().split(RegExp(r'\s+'));
    if (fields.length < 4) {
      return null;
    }
    final int? kilobytes = int.tryParse(fields[3]);
    return kilobytes == null ? null : kilobytes * 1024;
  }

  static void _watch(_WatchSettings settings) {
    bool killing = false;
    Timer.periodic(settings.interval, (_) async {
      final int? free = freeBytes(settings.path);
      if (killing || free == null) {
        return;
      }
      final int lost = settings.startFree - free;
      if (lost <= settings.maxWrittenBytes) {
        return;
      }
      killing = true;
      stderr.writeln(
        'test_toolkit: the disk has lost ${_gb(lost)} GB of free space since '
        'this test process started, over its ${_gb(settings.maxWrittenBytes)} '
        'GB limit; killing it. Look for a file the test keeps writing, such '
        'as a log. The limit is set by prepareTestProcess() in '
        'flutter_test_config.dart.',
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
  const _WatchSettings(
    this.path,
    this.startFree,
    this.maxWrittenBytes,
    this.interval,
  );

  final String path;
  final int startFree;
  final int maxWrittenBytes;
  final Duration interval;
}
