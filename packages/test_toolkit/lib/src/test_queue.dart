import 'held_slots.dart';
import 'memory_probe.dart';
import 'orphan_reaper.dart';
import 'process_row.dart';
import 'slot_holder.dart';
import 'slot_pool.dart';
import 'slot_status.dart';
import 'ticket.dart';
import 'ticket_queue.dart';

/// Decides when a run may start: once its turn has come, and it holds its
/// slots, and the machine has the free memory those slots stand for.
///
/// The slots cap how many suites run at once. The memory check covers what
/// the slots cannot see: an Xcode build, a browser, an editor's analysis
/// server. A machine with two slots free and 2 GB of memory free has no room
/// for a suite, whatever the slot count says. The [tickets] keep the order:
/// a run that started waiting earlier gets a slot first.
class TestQueue {
  TestQueue({
    required this.pool,
    required this.memoryPerSlot,
    TicketQueue? tickets,
    MemoryProbe? memory,
    OrphanReaper? reaper,
    this.pollInterval = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : tickets = tickets ?? TicketQueue.forSlotsIn(pool.directory),
       _memory = memory ?? MemoryProbe(),
       _reaper = reaper ?? OrphanReaper(),
       _clock = clock ?? DateTime.now;

  final SlotPool pool;

  /// The line for [pool]'s slots.
  final TicketQueue tickets;

  /// The free memory one slot needs before a run may start, in bytes.
  final int memoryPerSlot;

  /// How long a waiting run sleeps before it looks again.
  final Duration pollInterval;

  final MemoryProbe _memory;
  final OrphanReaper _reaper;
  final DateTime Function() _clock;

  static const int _gigabyte = 1024 * 1024 * 1024;

  /// [slots] slots for [holder], once the run may start; or `null` when
  /// [wait] ran out first. There is no waiting forever: a run stuck behind
  /// another for good would only move the hang from the suite to the queue.
  ///
  /// The run takes a ticket first, so runs that came before it, and are
  /// still waiting, get their slots before it does.
  ///
  /// Every look first kills stray test processes, so a slot that a killed
  /// run gave back is never handed out while that run's testers still hold
  /// its memory. [onWait] hears each new reason the run is waiting, and
  /// [onReaped] each stray that was killed.
  Future<HeldSlots?> admit({
    required int slots,
    required SlotHolder holder,
    required Duration wait,
    void Function(String reason)? onWait,
    void Function(ProcessRow stray)? onReaped,
  }) async {
    final DateTime deadline = _clock().add(wait);
    final Ticket ticket = tickets.take();
    String? lastKey;
    bool first = true;
    try {
      do {
        if (!first) {
          await Future<void>.delayed(pollInterval);
        }
        first = false;
        (await _reaper.reap()).forEach(onReaped ?? _ignore);
        final HeldSlots? held = await _tryOnce(slots, holder, ticket, (
          String key,
          String reason,
        ) {
          if (key != lastKey) {
            onWait?.call(reason);
            lastKey = key;
          }
        });
        if (held != null) {
          return held;
        }
      } while (_clock().isBefore(deadline));
      return null;
    } finally {
      ticket.leave();
    }
  }

  /// The slots, when the line, memory and slots all allow; otherwise
  /// `null`, after telling [blockedBy] why. Its key stays the same while the
  /// reason does, so a wait reports a new reason only: the holders' times,
  /// the free memory and the length of the line change on every look and
  /// are not one.
  Future<HeldSlots?> _tryOnce(
    int slots,
    SlotHolder holder,
    Ticket ticket,
    void Function(String key, String reason) blockedBy,
  ) async {
    final int ahead = tickets.waitingAhead(ticket);
    if (ahead > 0) {
      final int free = pool
          .survey()
          .where((SlotStatus s) => s.holder == null)
          .length;
      // Each run ahead wants a slot at least, and gets the first free ones.
      if (ahead + slots > free) {
        blockedBy(
          'line',
          'waiting for a slot, behind $ahead test '
              '${ahead == 1 ? 'process' : 'processes'} that started waiting '
              'first',
        );
        return null;
      }
    }
    final String? memoryShort = await _memoryShortfall(slots);
    if (memoryShort != null) {
      blockedBy('memory', memoryShort);
      return null;
    }
    final HeldSlots? held = pool.tryAcquire(slots, holder);
    if (held == null) {
      final List<SlotStatus> taken = pool.survey();
      blockedBy(
        taken.map((SlotStatus s) => s.holder?.pid).join(','),
        _slotsTaken(slots, taken),
      );
    }
    return held;
  }

  /// Why the machine's free memory is too little for [slots] slots, or
  /// `null` when it is enough or cannot be read.
  Future<String?> _memoryShortfall(int slots) async {
    final int? available = await _memory.availableBytes();
    final int needed = memoryPerSlot * slots;
    if (available == null || available >= needed) {
      return null;
    }
    return 'only ${_gb(available)} GB of memory is free, and this run needs '
        '${_gb(needed)} GB';
  }

  String _slotsTaken(int slots, List<SlotStatus> taken) {
    final DateTime now = _clock();
    final List<String> lines = <String>[
      'waiting for $slots of ${pool.count} slots; holding now:',
      for (final SlotStatus status in taken)
        if (status.holder case final SlotHolder holder)
          '  slot-${status.number}  ${holder.describe(now)}',
    ];
    return lines.join('\n');
  }

  static String _gb(int bytes) => (bytes / _gigabyte).toStringAsFixed(1);

  static void _ignore(ProcessRow row) {}
}
