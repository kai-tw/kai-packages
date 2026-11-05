import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cache_directory.dart';
import 'test_slot.dart';

/// How many test processes every dart_mutants run on this machine may have
/// running at once, shared through one directory: [count] slots, each a
/// file `slot-<n>` there, held by whichever process holds an exclusive lock
/// on it.
///
/// A lock is the operating system's, so it is atomic between processes
/// racing for the same slot, and it goes with the process holding it: a
/// run that is killed outright leaves no slot taken. Nothing is ever
/// written into a slot file, and none is ever deleted — a process opening
/// the name after a delete would lock a different file than the one still
/// held.
///
/// These locks belong to a process, not to an open file: the same process
/// locking a file it already holds succeeds, and closing any handle on the
/// file drops every lock it holds there. So this process never opens a slot
/// it holds a second time; [_held] is how it knows which those are.
class TestSlots {
  TestSlots(this.directory, this.count) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be 1 or more');
    }
  }

  /// The slots `$DART_MUTANTS_SLOT_DIR` and `$DART_MUTANTS_SLOTS` name: by
  /// default `<cache>/slots` (see [cacheDirectory]) and a slot for every
  /// 4 GB of memory beyond the first 8 — see [countFor].
  ///
  /// Throws a [FormatException] when `$DART_MUTANTS_SLOTS` is set to
  /// anything but a whole number, 1 or more.
  static Future<TestSlots> fromEnvironment() async {
    final Map<String, String> env = Platform.environment;
    final String? given = env[countVariable];
    final int count;
    if (given == null) {
      count = countFor(await _memoryBytes());
    } else {
      final int? parsed = int.tryParse(given.trim());
      if (parsed == null || parsed < 1) {
        throw FormatException(
          '\$$countVariable must be a whole number, 1 or more',
          given,
        );
      }
      count = parsed;
    }
    return TestSlots(
      Directory(env[directoryVariable] ?? p.join(cacheDirectory(), 'slots')),
      count,
    );
  }

  static const String directoryVariable = 'DART_MUTANTS_SLOT_DIR';
  static const String countVariable = 'DART_MUTANTS_SLOTS';

  /// One slot for every 4 GB of [memoryBytes] beyond the first 8, which the
  /// system and the editor keep; at least one. A Flutter compiler and
  /// `flutter_tester` together take up to about 4 GB. Memory that cannot be
  /// read — `null` — gets the one slot that is always safe.
  static int countFor(int? memoryBytes) {
    if (memoryBytes == null) {
      return 1;
    }
    final int gigabytes = memoryBytes ~/ (1024 * 1024 * 1024);
    final int count = (gigabytes - 8) ~/ 4;
    return count < 1 ? 1 : count;
  }

  /// This machine's memory in bytes, or `null` where it cannot be read.
  static Future<int?> _memoryBytes() async {
    try {
      if (Platform.isMacOS) {
        final ProcessResult result = await Process.run('sysctl', <String>[
          '-n',
          'hw.memsize',
        ]);
        return result.exitCode == 0
            ? int.tryParse((result.stdout as String).trim())
            : null;
      }
      if (Platform.isLinux) {
        final Match? total = RegExp(
          r'^MemTotal:\s+(\d+) kB',
          multiLine: true,
        ).firstMatch(await File('/proc/meminfo').readAsString());
        return total == null ? null : int.parse(total[1]!) * 1024;
      }
      return null;
    } on FileSystemException {
      return null;
    } on ProcessException {
      return null;
    }
  }

  final Directory directory;
  final int count;

  /// The slots this process holds, by number.
  final Set<int> _held = <int>{};

  /// A slot this process gives back, for its own lanes waiting on one.
  final StreamController<void> _released = StreamController<void>.broadcast(
    sync: true,
  );

  /// How often a wait for a slot looks again with no release seen. A slot
  /// whose holder was killed comes free with no event at all; this is the
  /// only way a wait finds it.
  static const Duration _lostReleaseInterval = Duration(seconds: 2);

  /// Touched on every release, so a run waiting in another process hears
  /// of it through the directory.
  File get _releaseMark => File(p.join(directory.path, 'released'));

  File _slotFile(int number) => File(p.join(directory.path, 'slot-$number'));

  /// How many slots no process holds right now.
  int free() {
    directory.createSync(recursive: true);
    int free = 0;
    for (int number = 0; number < count; number++) {
      // Held here, so taken — and opening it again would drop the lock.
      if (_held.contains(number)) {
        continue;
      }
      final RandomAccessFile? probe = _lock(number);
      if (probe != null) {
        probe.closeSync();
        free++;
      }
    }
    return free;
  }

  /// A slot, once one is free: at once when one is, or else when another
  /// lane or another run gives one back. Never fails for want of one.
  Future<TestSlot> acquire() async {
    directory.createSync(recursive: true);
    if (_tryAcquire() case final TestSlot slot) {
      return slot;
    }
    final StreamController<void> wake = StreamController<void>();
    final List<StreamSubscription<void>> sources = <StreamSubscription<void>>[
      _released.stream.listen(wake.add),
      _watchReleases(wake),
    ];
    final Timer lostRelease = Timer.periodic(
      _lostReleaseInterval,
      (_) => wake.add(null),
    );
    final StreamIterator<void> next = StreamIterator<void>(wake.stream);
    try {
      // Tried again once the sources listen, so a slot given back between
      // the first try and now is not waited past.
      TestSlot? slot = _tryAcquire();
      while (slot == null) {
        await next.moveNext();
        slot = _tryAcquire();
      }
      return slot;
    } finally {
      lostRelease.cancel();
      for (final StreamSubscription<void> source in sources) {
        await source.cancel();
      }
      await next.cancel();
      await wake.close();
    }
  }

  /// Every change in [directory] added to [wake]. A platform that cannot
  /// watch it adds nothing, and the wait relies on [_lostReleaseInterval].
  StreamSubscription<void> _watchReleases(StreamController<void> wake) {
    try {
      return directory.watch().listen((_) => wake.add(null));
    } on FileSystemException {
      return const Stream<void>.empty().listen(null);
    }
  }

  /// The first free slot, now held — or `null` when every one is taken.
  TestSlot? _tryAcquire() {
    for (int number = 0; number < count; number++) {
      // Held here already: opening it again would drop this process's lock.
      if (_held.contains(number)) {
        continue;
      }
      if (_lock(number) case final RandomAccessFile file) {
        _held.add(number);
        return TestSlot(number, () => _release(number, file));
      }
    }
    return null;
  }

  /// Slot [number]'s file, open and locked — or `null`, closed again, when
  /// another process holds it. Locking is the only test: whether a slot is
  /// free can change between any check and the lock.
  RandomAccessFile? _lock(int number) {
    final RandomAccessFile file = _slotFile(
      number,
    ).openSync(mode: FileMode.append);
    try {
      file.lockSync(FileLock.exclusive);
      return file;
    } on FileSystemException {
      file.closeSync();
      return null;
    }
  }

  void _release(int number, RandomAccessFile file) {
    file.closeSync();
    _held.remove(number);
    _releaseMark.writeAsStringSync('$number\n');
    _released.add(null);
  }
}
