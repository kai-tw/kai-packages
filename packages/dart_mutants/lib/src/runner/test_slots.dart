import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test_toolkit/test_toolkit.dart';

import 'slot_wait_exception.dart';
import 'test_slot.dart';

/// The machine's test slots, which a run takes one of for each test process
/// it starts. They are test_toolkit's, so every caller on the machine counts
/// against one budget: another dart_mutants run, a `flutter test` process,
/// a CI job.
///
/// [SlotPool] does the locking. A slot is a file the operating system locks
/// for the process that holds it, so a run killed outright gives its slots
/// back. This class adds the wait: a lane that finds every slot taken waits
/// until one comes free, or until the caller gives up on it.
///
/// When a parent process already holds slots for this run,
/// `$TEST_QUEUE_HELD` names them. This hands those out instead of waiting
/// on slots its own parent holds.
class TestSlots {
  /// [count] slots in [directory], locked the way test_toolkit locks them.
  TestSlots(this.directory, this.count, {this.maxWait = defaultMaxWait})
    : _pool = SlotPool(directory, count),
      _tickets = TicketQueue.forSlotsIn(directory),
      _lendable = const <int>[];

  /// The slots [numbers], which a parent process already holds.
  TestSlots.inherited(
    this.directory,
    List<int> numbers, {
    this.maxWait = defaultMaxWait,
  }) : count = numbers.length,
       _pool = null,
       _tickets = null,
       _lendable = numbers {
    if (numbers.isEmpty) {
      throw ArgumentError.value(numbers, 'numbers', 'must name a slot');
    }
  }

  /// test_toolkit's slots, as its settings name them: by default a slot for
  /// every 4 GB of memory beyond the first 8, in `<cache>/test_queue/slots`.
  ///
  /// Throws a [FormatException] when a `TEST_QUEUE_*` variable is set to
  /// something it can't use.
  static Future<TestSlots> fromEnvironment({
    Duration maxWait = defaultMaxWait,
  }) async {
    final Map<String, String> env = Platform.environment;
    final QueueSettings settings = QueueSettings.fromEnvironment(
      env,
      memoryBytes: await MemoryProbe().totalBytes(),
    );
    final String held = (env[QueueSettings.heldVariable] ?? '').trim();
    if (held.isEmpty) {
      return TestSlots(
        settings.directory,
        settings.slotCount,
        maxWait: maxWait,
      );
    }
    return TestSlots.inherited(
      settings.directory,
      slotNumbers(held),
      maxWait: maxWait,
    );
  }

  /// The slot numbers in `$TEST_QUEUE_HELD`, such as `0,1`.
  ///
  /// Throws a [FormatException] for anything else.
  static List<int> slotNumbers(String held) {
    final List<int> numbers = <int>[];
    for (final String part in held.split(',')) {
      final int? number = int.tryParse(part.trim());
      if (number == null || number < 0) {
        throw FormatException(
          '\$${QueueSettings.heldVariable} must list slot numbers',
          held,
        );
      }
      numbers.add(number);
    }
    return numbers;
  }

  final Directory directory;
  final int count;

  /// How long one lane waits for a slot before [acquire] gives up with a
  /// [SlotWaitException]. There is no waiting forever: a slot held for good
  /// would hang the run where nobody sees it.
  final Duration maxWait;

  /// Long enough for another run's baseline to finish, which holds a slot
  /// for the whole suite.
  static const Duration defaultMaxWait = Duration(minutes: 30);

  /// The slots, or `null` when a parent holds them.
  final SlotPool? _pool;

  /// The line for [_pool]'s slots, so a lane that started waiting earlier,
  /// here or in another run, gets a slot first; `null` when a parent holds
  /// the slots.
  final TicketQueue? _tickets;

  /// The slots a parent holds, by number.
  final List<int> _lendable;

  /// Which of [_lendable] a lane has now.
  final Set<int> _lent = <int>{};

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

  /// How many slots nobody holds right now.
  int free() {
    if (_pool case final SlotPool pool) {
      return pool.survey().where((SlotStatus s) => s.holder == null).length;
    }
    return count - _lent.length;
  }

  /// A slot, once one is free: at once when one is, or else when another
  /// lane or another run gives one back.
  ///
  /// `null` when [until] completes first: the caller no longer wants a
  /// slot, and nothing is left waiting for one. Throws a
  /// [SlotWaitException] once [maxWait] runs out with no slot free.
  Future<TestSlot?> acquire({Future<void>? until}) async {
    directory.createSync(recursive: true);
    final Ticket? ticket = _tickets?.take();
    try {
      return await _acquire(ticket, until);
    } finally {
      ticket?.leave();
    }
  }

  /// [acquire], once [ticket] holds this wait's place in the line.
  Future<TestSlot?> _acquire(Ticket? ticket, Future<void>? until) async {
    if (_tryAcquire(ticket) case final TestSlot slot) {
      return slot;
    }
    final StreamController<void> wake = StreamController<void>();
    bool givenUp = false;
    // Not awaited: it only wakes the wait below, and [until] — a signal the
    // caller completes, never with an error — has no failure to observe. A
    // completion after the wait ended changes nothing.
    if (until != null) {
      unawaited(() async {
        await until;
        givenUp = true;
        if (!wake.isClosed) {
          wake.add(null);
        }
      }());
    }
    final List<StreamSubscription<void>> sources = <StreamSubscription<void>>[
      _released.stream.listen(wake.add),
      _watchReleases(wake),
    ];
    final Timer lostRelease = Timer.periodic(
      _lostReleaseInterval,
      (_) => wake.add(null),
    );
    final Stopwatch waited = Stopwatch()..start();
    final Timer limit = Timer(maxWait, () => wake.add(null));
    final StreamIterator<void> next = StreamIterator<void>(wake.stream);
    try {
      // Tried again once the sources listen, so a slot given back between
      // the first try and now is not waited past.
      TestSlot? slot = _tryAcquire(ticket);
      while (slot == null) {
        if (givenUp) {
          return null;
        }
        if (waited.elapsed >= maxWait) {
          throw SlotWaitException(waited.elapsed, _holders());
        }
        await next.moveNext();
        slot = _tryAcquire(ticket);
      }
      return slot;
    } finally {
      lostRelease.cancel();
      limit.cancel();
      for (final StreamSubscription<void> source in sources) {
        await source.cancel();
      }
      await next.cancel();
      // Not awaited: when the second try above succeeds, nothing ever
      // listened to [wake], and the future close() returns completes only
      // once a listener has had its done event. Awaiting it hung the lane
      // for good, holding its slot and its place in the line.
      unawaited(wake.close());
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

  /// Whether lanes and runs that started waiting before [ticket], and are
  /// still waiting, need every free slot. Never for a wait with no ticket:
  /// slots a parent holds have no line.
  bool _isBehindOthers(Ticket? ticket) {
    final TicketQueue? tickets = _tickets;
    if (ticket == null || tickets == null) {
      return false;
    }
    final int ahead = tickets.waitingAhead(ticket);
    return ahead > 0 && ahead >= free();
  }

  /// The first free slot, now held, or `null` when every one is taken, or
  /// when the lanes and runs that started waiting before [ticket] still
  /// need every free one.
  TestSlot? _tryAcquire(Ticket? ticket) {
    if (_pool case final SlotPool pool) {
      if (_isBehindOthers(ticket)) {
        return null;
      }
      final HeldSlots? held = pool.tryAcquire(1, _holder());
      if (held == null) {
        return null;
      }
      return TestSlot(held.numbers.single, () => _release(held.release));
    }
    for (final int number in _lendable) {
      if (_lent.add(number)) {
        return TestSlot(number, () => _release(() => _lent.remove(number)));
      }
    }
    return null;
  }

  /// Who holds each slot now, for a [SlotWaitException].
  List<String> _holders() {
    final DateTime now = DateTime.now();
    return <String>[
      for (final SlotStatus status in _pool?.survey() ?? const <SlotStatus>[])
        if (status.holder case final SlotHolder holder)
          'slot-${status.number}  ${holder.describe(now)}',
    ];
  }

  /// What a slot's holder file says while a lane holds it.
  SlotHolder _holder() => SlotHolder(
    pid: pid,
    label: p.basename(Directory.current.path),
    workingDirectory: Directory.current.path,
    command: 'dart_mutants (one test process)',
    startedAt: DateTime.now(),
  );

  void _release(void Function() giveBack) {
    giveBack();
    if (_pool != null) {
      _releaseMark.writeAsStringSync('released\n');
    }
    _released.add(null);
  }
}
