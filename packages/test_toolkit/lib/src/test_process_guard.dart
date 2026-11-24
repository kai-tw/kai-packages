import 'dart:io';

import 'package:path/path.dart' as p;

import 'held_slots.dart';
import 'memory_limit.dart';
import 'memory_probe.dart';
import 'process_row.dart';
import 'queue_settings.dart';
import 'slot_holder.dart';
import 'slot_pool.dart';
import 'slot_timeout_exception.dart';
import 'test_queue.dart';

/// Sets up one test process: a memory limit, and a turn in the machine's
/// queue.
///
/// [guard] starts [memoryLimit], then waits for one of the machine's test
/// slots, and returns once this process holds one. The slot is held until
/// the process exits, however it exits: the operating system drops the lock
/// then. `testExecutable` only declares the tests, and `flutter test` runs
/// them after it returns, so there is no earlier point to give the slot back.
///
/// A process whose parent already holds a slot for it doesn't wait for
/// another: `$TEST_QUEUE_HELD` says so. A mutation tester that takes a slot
/// for each test process it starts sets it.
class TestProcessGuard {
  TestProcessGuard({
    required this.memoryLimit,
    required this.queue,
    required this.holder,
    required this.slotWait,
    this.parentHoldsSlot = false,
    void Function(String line)? log,
  }) : _log = log ?? stderr.writeln;

  /// The guard [guardTestProcess] uses: the machine's slots as
  /// [QueueSettings.fromEnvironment] reads them.
  ///
  /// Throws a [FormatException] when a `TEST_QUEUE_*` variable is set to
  /// something it can't use.
  static Future<TestProcessGuard> fromEnvironment({
    required int maxGigabytes,
    required Duration slotWait,
  }) async {
    final Map<String, String> env = Platform.environment;
    final MemoryProbe probe = MemoryProbe();
    final QueueSettings settings = QueueSettings.fromEnvironment(
      env,
      memoryBytes: await probe.totalBytes(),
    );
    final String cwd = Directory.current.path;
    return TestProcessGuard(
      memoryLimit: MemoryLimit(maxBytes: maxGigabytes * _gigabyte),
      queue: TestQueue(
        pool: SlotPool(settings.directory, settings.slotCount),
        memoryPerSlot: settings.memoryPerSlot,
        memory: probe,
      ),
      holder: SlotHolder(
        pid: pid,
        label: p.basename(cwd),
        workingDirectory: cwd,
        command: 'flutter test (one test file)',
        startedAt: DateTime.now(),
      ),
      slotWait: slotWait,
      parentHoldsSlot: (env[QueueSettings.heldVariable] ?? '')
          .trim()
          .isNotEmpty,
    );
  }

  final MemoryLimit memoryLimit;
  final TestQueue queue;

  /// What `slot-<n>.holder` says about this process while it holds a slot.
  final SlotHolder holder;

  /// How long to wait for a slot before giving up with a
  /// [SlotTimeoutException].
  final Duration slotWait;

  /// Whether a parent process already holds a slot for this one.
  final bool parentHoldsSlot;

  final void Function(String line) _log;

  /// The slot this process holds. Kept here, never released: closing the
  /// slot's file would drop the lock while the tests still run.
  static final List<HeldSlots> _held = <HeldSlots>[];

  static const int _gigabyte = 1024 * 1024 * 1024;

  /// Starts the memory limit, then waits for a slot.
  ///
  /// Throws a [SlotTimeoutException] when no slot comes free within
  /// [slotWait]. `flutter test` then reports the test file as failed to
  /// load, with the exception's message.
  Future<void> guard() async {
    await memoryLimit.start();
    if (parentHoldsSlot) {
      return;
    }
    final Stopwatch waited = Stopwatch()..start();
    final HeldSlots? slot = await queue.admit(
      slots: 1,
      holder: holder,
      wait: slotWait,
      onWait: (String reason) => _log('test_toolkit: $reason'),
      onReaped: (ProcessRow stray) =>
          _log('test_toolkit: killed a leftover test process: $stray'),
    );
    if (slot == null) {
      throw SlotTimeoutException(waited.elapsed, queue.pool);
    }
    _held.add(slot);
  }
}

/// Sets up this test process: kills it once it uses more than
/// [maxGigabytes] of memory, and waits for one of the machine's test slots
/// before its tests run.
///
/// Call it once, from `test/flutter_test_config.dart`, which `flutter test`
/// runs around every test file in that directory and below it:
///
/// ```dart
/// import 'dart:async';
///
/// import 'package:test_toolkit/test_toolkit.dart';
///
/// Future<void> testExecutable(FutureOr<void> Function() testMain) async {
///   await guardTestProcess();
///   await testMain();
/// }
/// ```
///
/// Throws an [ArgumentError] when [maxGigabytes] is below 1, a
/// [FormatException] when a `TEST_QUEUE_*` variable can't be used, and a
/// [SlotTimeoutException] when no slot comes free within [slotWait].
Future<void> guardTestProcess({
  int maxGigabytes = 4,
  Duration slotWait = const Duration(minutes: 30),
}) async {
  if (maxGigabytes < 1) {
    throw ArgumentError.value(
      maxGigabytes,
      'maxGigabytes',
      'must be 1 or more',
    );
  }
  final TestProcessGuard guard = await TestProcessGuard.fromEnvironment(
    maxGigabytes: maxGigabytes,
    slotWait: slotWait,
  );
  await guard.guard();
}
