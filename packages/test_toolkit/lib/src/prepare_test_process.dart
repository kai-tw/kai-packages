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

/// The slot this process holds. Kept here and never released: closing the
/// slot's file would drop the lock while the tests still run.
final List<HeldSlots> _held = <HeldSlots>[];

const int _gigabyte = 1024 * 1024 * 1024;

/// Keeps this test process, and every test process on the machine together,
/// within the memory there is.
///
/// - Kills this process once it uses more than [maxGigabytes] of memory.
/// - Kills leftover test processes whose parent is gone.
/// - Waits for free memory and for one of the machine's test slots, which
///   every test process shares, so the processes running at once fit.
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
///   await prepareTestProcess();
///   await testMain();
/// }
/// ```
///
/// The slot is held until the process exits, however it exits: the
/// operating system drops the lock then. `testExecutable` only declares the
/// tests, and `flutter test` runs them after it returns, so there is no
/// earlier point to give the slot back.
///
/// A process whose parent already holds a slot for it doesn't wait for
/// another: `$TEST_QUEUE_HELD` says so. A mutation tester that takes a slot
/// for each test process it starts sets it.
///
/// Throws an [ArgumentError] when [maxGigabytes] is below 1, a
/// [FormatException] when a `TEST_QUEUE_*` variable can't be used, and a
/// [SlotTimeoutException] when no slot comes free within [slotWait].
/// `flutter test` then reports the test file as failed to load, with the
/// exception's message.
Future<void> prepareTestProcess({
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
  await MemoryLimit(maxBytes: maxGigabytes * _gigabyte).start();

  final Map<String, String> env = Platform.environment;
  if ((env[QueueSettings.heldVariable] ?? '').trim().isNotEmpty) {
    return;
  }
  final MemoryProbe probe = MemoryProbe();
  final QueueSettings settings = QueueSettings.fromEnvironment(
    env,
    memoryBytes: await probe.totalBytes(),
  );
  final TestQueue queue = TestQueue(
    pool: SlotPool(settings.directory, settings.slotCount),
    memoryPerSlot: settings.memoryPerSlot,
    memory: probe,
  );
  final String cwd = Directory.current.path;
  final Stopwatch waited = Stopwatch()..start();
  final HeldSlots? slot = await queue.admit(
    slots: 1,
    holder: SlotHolder(
      pid: pid,
      label: p.basename(cwd),
      workingDirectory: cwd,
      command: 'flutter test (one test file)',
      startedAt: DateTime.now(),
    ),
    wait: slotWait,
    onWait: (String reason) => stderr.writeln('test_toolkit: $reason'),
    onReaped: (ProcessRow stray) =>
        stderr.writeln('test_toolkit: killed a leftover test process: $stray'),
  );
  if (slot == null) {
    throw SlotTimeoutException(waited.elapsed, queue.pool);
  }
  _held.add(slot);
}
