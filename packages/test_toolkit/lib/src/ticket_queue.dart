import 'dart:io';

import 'package:path/path.dart' as p;

import 'ticket.dart';

/// First come, first served, for processes waiting on the same slots.
///
/// A slot goes to whoever tries its lock first, so without an order a
/// process can lose every race to newcomers and never get one. So a
/// process takes a numbered [Ticket] before it starts waiting, and may try
/// for a slot only while fewer processes that came before it are still
/// waiting than there are free slots. Numbers only go up, so the line ahead
/// of a waiting process only gets shorter.
///
/// A ticket is a file named `ticket-<n>` in [directory], locked by its
/// process for as long as it waits. The operating system drops the lock
/// when the process exits, however it exits, so a ticket nobody holds
/// belongs to a process that died waiting, and the next process to look
/// deletes it. A dead process never holds up the line.
class TicketQueue {
  TicketQueue(this.directory);

  /// The line for the slots in [slots], kept in `queue/` inside it.
  TicketQueue.forSlotsIn(Directory slots)
    : directory = Directory(p.join(slots.path, 'queue'));

  final Directory directory;

  /// The ticket files this process holds, by path.
  ///
  /// These locks belong to the process, not to an open file: this process
  /// locking its own ticket again succeeds, and closing any handle on the
  /// file drops its lock. So this process never probes a ticket it holds.
  static final Set<String> _mine = <String>{};

  static const String _prefix = 'ticket-';

  /// A new ticket, numbered after every ticket handed out before it.
  Ticket take() {
    directory.createSync(recursive: true);
    final int number = _nextNumber();
    // Made and locked under another name, then renamed: a ticket that
    // appeared before its lock was taken would look like a dead one, and
    // be deleted while its process still waits.
    final File pending = File(p.join(directory.path, '.$_prefix$number'));
    final RandomAccessFile file = pending.openSync(mode: FileMode.write);
    file.lockSync(FileLock.exclusive);
    final String path = p.join(directory.path, '$_prefix$number');
    pending.renameSync(path);
    _mine.add(path);
    return Ticket(number, () => _leave(path, file));
  }

  /// How many processes that took a ticket before [ticket] are still
  /// waiting. Deletes the tickets of processes that died waiting.
  int waitingAhead(Ticket ticket) {
    int ahead = 0;
    for (final FileSystemEntity entry in directory.listSync()) {
      final int? number = _numberOf(entry.path);
      if (number == null || number >= ticket.number) {
        continue;
      }
      if (_mine.contains(entry.path) || _isHeld(entry.path)) {
        ahead++;
      }
    }
    return ahead;
  }

  /// Whether a process still holds the ticket at [path]. Deletes it when
  /// none does.
  bool _isHeld(String path) {
    final RandomAccessFile probe;
    try {
      probe = File(path).openSync();
    } on FileSystemException {
      return false; // Gone already: its process stopped waiting.
    }
    try {
      probe.lockSync(FileLock.shared);
    } on FileSystemException {
      probe.closeSync();
      return true;
    }
    _deleteIfThere(path);
    probe.closeSync();
    return false;
  }

  /// The next ticket number, counted in the file `next` under a lock, so
  /// two processes never get the same one.
  int _nextNumber() {
    final RandomAccessFile counter = File(
      p.join(directory.path, 'next'),
    ).openSync(mode: FileMode.append);
    try {
      counter.lockSync(FileLock.blockingExclusive);
      counter.setPositionSync(0);
      final String text = String.fromCharCodes(
        counter.readSync(counter.lengthSync()),
      );
      final int number = int.tryParse(text.trim()) ?? 0;
      counter
        ..truncateSync(0)
        ..setPositionSync(0)
        ..writeStringSync('${number + 1}\n');
      return number;
    } finally {
      counter.closeSync();
    }
  }

  static int? _numberOf(String path) {
    final String name = p.basename(path);
    if (!name.startsWith(_prefix)) {
      return null;
    }
    return int.tryParse(name.substring(_prefix.length));
  }

  /// Gives up the ticket at [path], whose lock [file] holds.
  ///
  /// The file goes before the lock does: a process that looked in between
  /// would otherwise find it unlocked and take this process for dead.
  static void _leave(String path, RandomAccessFile file) {
    _deleteIfThere(path);
    file.closeSync();
    _mine.remove(path);
  }

  /// Deletes [path]. Another process may have deleted it first, when it
  /// took the ticket's process for dead, so a missing file is no error.
  static void _deleteIfThere(String path) {
    try {
      File(path).deleteSync();
    } on PathNotFoundException {
      return;
    }
  }
}
