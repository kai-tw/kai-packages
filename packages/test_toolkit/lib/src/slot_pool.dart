import 'dart:io';

import 'package:path/path.dart' as p;

import 'held_slots.dart';
import 'slot_holder.dart';
import 'slot_status.dart';

/// The machine's test slots: [count] files named `slot-<n>` in [directory],
/// each taken by whichever process holds an exclusive lock on it.
///
/// The lock is the operating system's, so two processes racing for one slot
/// cannot both get it, and it goes away with its process: a run that is
/// killed outright leaves no slot taken. Its test processes can outlive it,
/// though, which is what [OrphanReaper] is for.
///
/// These locks belong to a process, not to an open file. The same process
/// locking a slot it already holds succeeds, and closing any handle on the
/// file drops the lock. So this pool never opens a slot it holds a second
/// time; [_held] is how it knows which those are.
///
/// Who holds a slot is written to `slot-<n>.holder` next to it. The slot file
/// itself is never written or deleted: a process that opened the name after
/// a delete would lock a different file than the one still held.
class SlotPool {
  SlotPool(this.directory, this.count) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be 1 or more');
    }
  }

  final Directory directory;
  final int count;
  final Set<int> _held = <int>{};

  /// [wanted] slots at once, or `null` when that many are not free. Never
  /// some of them: a run sitting on part of what it needs keeps others
  /// waiting and still cannot start.
  HeldSlots? tryAcquire(int wanted, SlotHolder holder) {
    if (wanted < 1 || wanted > count) {
      throw ArgumentError.value(wanted, 'wanted', 'must be 1 to $count');
    }
    directory.createSync(recursive: true);
    final Map<int, RandomAccessFile> taken = _lockFree(wanted);
    if (taken.length < wanted) {
      for (final RandomAccessFile file in taken.values) {
        file.closeSync();
      }
      return null;
    }
    _held.addAll(taken.keys);
    for (final int number in taken.keys) {
      _holderFile(number).writeAsStringSync(holder.encode());
    }
    return HeldSlots(taken.keys.toList(), () => _release(taken));
  }

  /// Up to [wanted] free slots, locked.
  Map<int, RandomAccessFile> _lockFree(int wanted) {
    final Map<int, RandomAccessFile> taken = <int, RandomAccessFile>{};
    for (int number = 0; number < count && taken.length < wanted; number++) {
      if (_held.contains(number)) {
        continue;
      }
      if (_lock(number) case final RandomAccessFile file) {
        taken[number] = file;
      }
    }
    return taken;
  }

  /// Every slot, and who holds it.
  List<SlotStatus> survey() {
    directory.createSync(recursive: true);
    return <SlotStatus>[
      for (int number = 0; number < count; number++)
        SlotStatus(number, _holderOf(number)),
    ];
  }

  SlotHolder? _holderOf(int number) {
    if (_held.contains(number)) {
      return _readHolder(number);
    }
    final RandomAccessFile? probe = _lock(number);
    if (probe != null) {
      probe.closeSync();
      return null;
    }
    return _readHolder(number);
  }

  SlotHolder _readHolder(int number) {
    try {
      return SlotHolder.decode(_holderFile(number).readAsStringSync());
    } on FileSystemException {
      return SlotHolder.unknown;
    }
  }

  /// The holder file goes before the lock does. Deleted after, it could be
  /// the file the next holder has just written. While the lock is held, no
  /// other process writes or deletes it, so checking first is not a race.
  void _release(Map<int, RandomAccessFile> taken) {
    for (final MapEntry<int, RandomAccessFile> entry in taken.entries) {
      final File holder = _holderFile(entry.key);
      if (holder.existsSync()) {
        holder.deleteSync();
      }
      entry.value.closeSync();
      _held.remove(entry.key);
    }
  }

  File _slotFile(int number) => File(p.join(directory.path, 'slot-$number'));

  File _holderFile(int number) =>
      File(p.join(directory.path, 'slot-$number.holder'));

  /// Slot [number]'s file, open and locked, or `null` when another process
  /// holds it. Locking is the only check: whether a slot is free can change
  /// between any check and the lock.
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
}
